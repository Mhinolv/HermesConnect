"""Tests for server/install.sh. They write only to a temporary folder."""

import base64
import hashlib
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest

from support import GATE, INSTALL, slot_port

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

    def install(self, *args, stdin=None):
        argv = ["bash", INSTALL, "--authorized-keys", self.keys, "--gate-dest", self.gate_dest] + list(args)
        return subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)

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
        for port in ("0", "80", "1023", "65536", "abc", "4710 0", "+47100", "047100", ""):
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
        self.assertEqual(result.stdout, b"PONG 2\n", result.stderr)


if __name__ == "__main__":
    unittest.main()
