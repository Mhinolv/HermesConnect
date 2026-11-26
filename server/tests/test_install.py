"""Tests for server/install.sh. They write only to a temporary folder."""

import base64
import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest

from support import GATE, INSTALL, slot_port

GRACE_KEY = "dashboard.ssh_isolated_idle_grace_s"

# A fake `hermes config get|set`. It keeps the config in $HOME/.hermes/config.json and writes one
# JSON record per call to $HOME/calls.jsonl. `config get` of a missing key fails like Hermes
# (hermes_cli/config.py get_config_value): "Config key not set: <key>" on stderr, exit 1.
# FAKE_CONFIG_MODE=broken makes `config get` fail for another reason.
FAKE_HERMES_CONFIG = r'''#!{python}
import json, os, sys
home = os.environ["HOME"]
with open(os.path.join(home, "calls.jsonl"), "a") as log:
    log.write(json.dumps({{"argv": sys.argv[1:], "home": home, "hermesHome": os.environ.get("HERMES_HOME"),
                          "cwd": os.getcwd()}}) + "\n")
path = os.path.join(home, ".hermes", "config.json")
config = json.load(open(path)) if os.path.exists(path) else {{}}
cmd = sys.argv[1:]
if cmd[:2] == ["config", "get"] and len(cmd) == 3:
    if os.environ.get("FAKE_CONFIG_MODE") == "broken":
        print("Error: config.yaml is not valid YAML", file=sys.stderr)
        sys.exit(1)
    if cmd[2] not in config:
        print("Config key not set: " + cmd[2], file=sys.stderr)
        sys.exit(1)
    print(config[cmd[2]])
elif cmd[:2] == ["config", "set"] and len(cmd) == 4:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    config[cmd[2]] = int(cmd[3])
    json.dump(config, open(path, "w"))
    print("Set " + cmd[2])
else:
    sys.exit("unexpected call")
'''

OPTIONS = 'restrict,port-forwarding,permitopen="127.0.0.1:%d",permitlisten="127.0.0.1:1",command="'


def ssh_string(data):
    return struct.pack(">I", len(data)) + data


def ed25519_blob(seed=1):
    return base64.b64encode(ssh_string(b"ssh-ed25519") + ssh_string(bytes([seed]) * 32)).decode()


def ecdsa_blob(seed=2):
    point = b"\x04" + bytes([seed]) * 64
    return base64.b64encode(ssh_string(b"ecdsa-sha2-nistp256") + ssh_string(b"nistp256") + ssh_string(point)).decode()


def slot_of(blob):
    return hashlib.sha256(blob.encode()).hexdigest()[:32]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="hcinstall-")
        self.tmp = os.path.realpath(self._tmp.name)
        self.keys = os.path.join(self.tmp, "home", ".ssh", "authorized_keys")
        os.makedirs(os.path.join(self.tmp, "home"))
        self.gate_dest = os.path.join(self.tmp, "libexec", "hermesconnect-gate")
        self.blob = ed25519_blob()
        self.line = "ssh-ed25519 %s owner@iPhone" % self.blob

    def tearDown(self):
        self._tmp.cleanup()

    def install(self, *args, stdin=None, env=None):
        argv = ["bash", INSTALL, "--authorized-keys", self.keys, "--gate-dest", self.gate_dest] + list(args)
        return subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
                              env=dict(os.environ, **(env or {})))

    def home(self, *parts):
        return os.path.join(self.tmp, "home", *parts)

    def fake_hermes(self, path=None):
        """Put the fake hermes CLI at ``path`` (default: ~/.local/bin/hermes of the temporary home)."""
        path = path or self.home(".local", "bin", "hermes")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as out:
            out.write(FAKE_HERMES_CONFIG.format(python=sys.executable))
        os.chmod(path, 0o755)
        return path

    def config_calls(self):
        try:
            with open(self.home("calls.jsonl")) as stream:
                return [json.loads(line) for line in stream]
        except FileNotFoundError:
            return []

    def config(self):
        with open(self.home(".hermes", "config.json")) as stream:
            return json.load(stream)

    def set_config(self, values):
        os.makedirs(self.home(".hermes"), exist_ok=True)
        with open(self.home(".hermes", "config.json"), "w") as out:
            json.dump(values, out)

    def lines(self):
        with open(self.keys) as stream:
            return stream.read().splitlines()

    def expected_line(self, blob=None, key_type="ssh-ed25519", comment="owner@iPhone", extra="", port=None):
        blob = blob or self.blob
        port = port or slot_port(slot_of(blob))
        return '%s%s --slot %s --port %d%s" %s %s %s' % (OPTIONS % port, self.gate_dest, slot_of(blob), port, extra,
                                                       key_type, blob, comment)

    def test_install_writes_restricted_line_and_gate(self):
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line()])
        self.assertEqual(os.stat(self.keys).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(self.keys)).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.gate_dest).st_mode & 0o777, 0o755)
        with open(GATE, "rb") as src, open(self.gate_dest, "rb") as dst:
            self.assertEqual(src.read(), dst.read())
        self.assertIn(b"installed the key", result.stdout)

    def test_line_has_no_shell_pty_or_agent_options(self):
        self.assertEqual(self.install(self.line).returncode, 0)
        options = self.lines()[0].split('" ssh-ed25519 ')[0]
        self.assertTrue(options.startswith("restrict,"))
        for enabler in ("pty", "agent-forwarding", "X11-forwarding", "user-rc", "no-restrict"):
            self.assertNotIn("," + enabler, options)
        self.assertEqual(options.count("permitopen="), 1)
        self.assertIn('permitopen="127.0.0.1:%d"' % slot_port(slot_of(self.blob)), options)

    def test_key_line_names_exactly_one_port(self):
        self.assertEqual(self.install(self.line).returncode, 0)
        line = self.lines()[0]
        self.assertNotIn("*", line)
        opened = re.findall(r'permitopen="([^"]*)"', line)
        self.assertEqual(len(opened), 1, line)
        self.assertRegex(opened[0], r"^127\.0\.0\.1:\d+$")
        port = int(opened[0].split(":")[1])
        self.assertTrue(47100 <= port <= 47199, port)
        command = line.split('command="', 1)[1].split('"', 1)[0].split()
        self.assertEqual(command[command.index("--port") + 1], str(port), "the gate serves on the opened port")
        self.assertEqual(command.count("--port"), 1)

    def test_star_line_is_upgraded_in_place(self):
        os.makedirs(os.path.dirname(self.keys), 0o700)
        admin = "ssh-ed25519 %s admin@laptop" % ed25519_blob(9)
        old = ('restrict,port-forwarding,permitopen="127.0.0.1:*",permitlisten="127.0.0.1:1",'
               'command="%s --slot %s" ssh-ed25519 %s owner@iPhone' % (self.gate_dest, slot_of(self.blob), self.blob))
        with open(self.keys, "w") as out:
            out.write("%s\n%s\n" % (admin, old))
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [admin, self.expected_line()])
        with open(self.keys) as stream:
            self.assertNotIn('127.0.0.1:*', stream.read())

    def test_port_option_sets_the_one_port(self):
        result = self.install("--port", "47555", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(port=47555)])

    def test_bad_port_option_is_refused(self):
        # A newline hides a second value from a line-based check (issue #18).
        for port in ("0", "80", "1023", "65536", "abc", "4710 0", "+47100", "047100", "",
                     "47100\n9119", "47100\n", "\n47100", "47100\t"):
            with self.subTest(port=port):
                result = self.install("--port", port, self.line)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(os.path.exists(self.keys))

    def test_port_of_another_key_is_refused(self):
        self.assertEqual(self.install("--port", "47150", self.line).returncode, 0)
        other = "ssh-ed25519 %s other" % ed25519_blob(5)
        result = self.install("--port", "47150", other)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"--port", result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(port=47150)])
        # The same key can keep its own port.
        again = self.install("--port", "47150", self.line)
        self.assertEqual(again.returncode, 0, again.stderr)

    def test_install_is_idempotent(self):
        self.assertEqual(self.install(self.line).returncode, 0)
        second = self.install(self.line)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn(b"unchanged", second.stdout)
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_other_keys_are_kept_and_old_line_for_same_key_is_replaced(self):
        os.makedirs(os.path.dirname(self.keys), 0o700)
        admin = "ssh-ed25519 %s admin@laptop" % ed25519_blob(9)
        with open(self.keys, "w") as out:
            out.write("# admin keys\n%s\ncommand=\"/bin/sh\" ssh-ed25519 %s old\n\n" % (admin, self.blob))
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), ["# admin keys", admin, "", self.expected_line()])

    def test_ecdsa_key_is_accepted(self):
        blob = ecdsa_blob()
        result = self.install("ecdsa-sha2-nistp256 %s" % blob)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(blob, "ecdsa-sha2-nistp256", "hermesconnect")])

    def test_key_from_stdin(self):
        result = self.install("-", stdin=(self.line + "\n").encode())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_comment_is_cleaned(self):
        result = self.install('ssh-ed25519 %s my "phone" $(id)' % self.blob)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines()[0].rsplit(" ", 1)[1], "my-phone-id")

    def test_no_location_goes_into_the_gate_command(self):
        # Issue #92: a team server key. The gate gets --no-location from the command= value only.
        result = self.install("--no-location", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(extra=" --no-location")])
        result = self.install("--hermes", "/opt/hermes/bin/hermes", "--no-location", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(extra=" --hermes /opt/hermes/bin/hermes --no-location")])
        # An install without the option makes the line of a personal server again.
        self.assertEqual(self.install(self.line).returncode, 0)
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_no_location_line_runs_the_gate_that_refuses_location(self):
        self.assertEqual(self.install("--no-location", self.line).returncode, 0)
        command = re.search(r'command="([^"]*)"', self.lines()[0]).group(1).split()
        self.assertEqual(command[-1], "--no-location")
        env = dict(os.environ, SSH_ORIGINAL_COMMAND="location", HOME=self.tmp)
        result = subprocess.run([sys.executable] + command, input=b"{}", env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR location-off", result.stderr)

    def test_hermes_option_is_passed_to_gate(self):
        result = self.install("--hermes", "/opt/hermes/bin/hermes", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(extra=" --hermes /opt/hermes/bin/hermes")])

    def test_remove_deletes_only_this_key(self):
        self.assertEqual(self.install(self.line).returncode, 0)
        other = "ssh-ed25519 %s other" % ed25519_blob(5)
        self.assertEqual(self.install(other).returncode, 0)
        result = self.install("--remove", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.lines(), [self.expected_line(ed25519_blob(5), comment="other")])

    def test_dry_run_changes_nothing(self):
        result = self.install("--dry-run", self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().strip(), self.expected_line())
        self.assertFalse(os.path.exists(self.keys))
        self.assertFalse(os.path.exists(self.gate_dest))

    def test_invalid_key_lines_are_refused(self):
        rsa = base64.b64encode(ssh_string(b"ssh-rsa") + ssh_string(b"\x01\x00\x01") + ssh_string(b"\x00" * 257)).decode()
        short = base64.b64encode(ssh_string(b"ssh-ed25519") + ssh_string(b"\x01" * 31)).decode()
        wrong_type = base64.b64encode(ssh_string(b"ssh-ed25519") + ssh_string(b"\x01" * 32)).decode()
        cases = {
            "empty": "",
            "type only": "ssh-ed25519",
            "rsa": "ssh-rsa %s" % rsa,
            "options in front": 'command="/bin/sh" ssh-ed25519 %s' % self.blob,
            "not base64": "ssh-ed25519 not*base64",
            "short key": "ssh-ed25519 %s" % short,
            "type mismatch": "ecdsa-sha2-nistp256 %s" % wrong_type,
            "two lines": "%s\n%s" % (self.line, self.line),
            "trailing data": "ssh-ed25519 %s" % base64.b64encode(base64.b64decode(self.blob) + b"x").decode(),
        }
        for name, line in cases.items():
            with self.subTest(case=name):
                result = self.install(line)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(os.path.exists(self.keys))

    def test_unsafe_gate_path_is_refused(self):
        argv = ["bash", INSTALL, "--authorized-keys", self.keys, "--gate-dest", '/tmp/x" pty', self.line]
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(os.path.exists(self.keys))

    def test_gate_accepts_the_slot_that_install_writes(self):
        self.assertEqual(self.install(self.line).returncode, 0)
        command = self.lines()[0].split('command="', 1)[1].split('"', 1)[0].split()
        self.assertEqual(command[:2], [self.gate_dest, "--slot"])
        self.assertEqual(command[3:5], ["--port", str(slot_port(slot_of(self.blob)))])
        env = {"HOME": self.tmp, "PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": "ping"}
        result = subprocess.run([sys.executable] + command, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.stdout, b"PONG 3\n", result.stderr)


    # Issue #183: keep hermes serve alive for 24 h after the last client goes.

    def test_install_sets_the_idle_grace_when_it_is_not_set(self):
        self.fake_hermes()
        result = self.install(self.line, env={"HERMES_HOME": os.path.join(self.tmp, "elsewhere")})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config(), {GRACE_KEY: 86400})
        self.assertIn(b"hermes config: set dashboard.ssh_isolated_idle_grace_s to 86400", result.stdout)
        calls = self.config_calls()
        self.assertEqual([c["argv"] for c in calls],
                         [["config", "get", GRACE_KEY], ["config", "set", GRACE_KEY, "86400"]])
        for call in calls:
            # The config of the account that runs hermes serve, not a HERMES_HOME of the caller.
            self.assertEqual(call["home"], self.home())
            self.assertIsNone(call["hermesHome"])
            self.assertEqual(os.path.realpath(call["cwd"]), self.home())
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_install_keeps_an_idle_grace_that_the_owner_set(self):
        self.fake_hermes()
        self.set_config({GRACE_KEY: 3600})
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config(), {GRACE_KEY: 3600})
        self.assertIn(b"hermes config: kept dashboard.ssh_isolated_idle_grace_s = 3600", result.stdout)
        self.assertEqual([c["argv"] for c in self.config_calls()], [["config", "get", GRACE_KEY]])

    def test_second_install_keeps_the_idle_grace(self):
        self.fake_hermes()
        self.assertEqual(self.install(self.line).returncode, 0)
        self.set_config({GRACE_KEY: 7200})
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"authorized_keys: unchanged", result.stdout)
        self.assertIn(b"kept dashboard.ssh_isolated_idle_grace_s = 7200", result.stdout)
        self.assertEqual(self.config(), {GRACE_KEY: 7200})
        self.assertEqual(sum(c["argv"][1] == "set" for c in self.config_calls()), 1)

    def test_failed_config_get_changes_nothing(self):
        self.fake_hermes()
        result = self.install(self.line, env={"FAKE_CONFIG_MODE": "broken"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"warning: hermes config get failed", result.stderr)
        self.assertEqual([c["argv"][1] for c in self.config_calls()], ["get"])
        self.assertFalse(os.path.exists(self.home(".hermes", "config.json")))
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_no_hermes_binary_gives_a_warning_only(self):
        result = self.install(self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"warning: no hermes binary found. Set dashboard.ssh_isolated_idle_grace_s by hand",
                      result.stderr)
        self.assertEqual(self.lines(), [self.expected_line()])

    def test_hermes_option_is_used_for_the_idle_grace(self):
        wrapper = self.fake_hermes(os.path.join(self.tmp, "opt", "hermes-wrapper"))
        result = self.install("--hermes", wrapper, self.line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config(), {GRACE_KEY: 86400})
        self.assertEqual(self.lines(), [self.expected_line(extra=" --hermes " + wrapper)])

    def test_remove_and_dry_run_do_not_touch_the_config(self):
        self.fake_hermes()
        self.assertEqual(self.install("--dry-run", self.line).returncode, 0)
        self.assertEqual(self.config_calls(), [])
        self.assertEqual(self.install(self.line).returncode, 0)
        calls = len(self.config_calls())
        self.assertEqual(self.install("--remove", self.line).returncode, 0)
        self.assertEqual(len(self.config_calls()), calls)


if __name__ == "__main__":
    unittest.main()
