"""Tests for server/gate/hermesconnect-gate. Run: python3 -m unittest discover -s server/tests"""

import json
import os
import re
import socket
import stat
import subprocess
import time
import unittest
from datetime import datetime, timedelta, timezone

from support import DEFAULT_SLOT, INSTALL, TOKEN_A, TOKEN_B, GateTestCase, free_port, slot_port


class CommandAllowListTests(GateTestCase):
    def test_ping_prints_gate_version(self):
        result = self.gate("ping")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"PONG 3\n")

    def test_shell_login_without_command_is_refused(self):
        result = self.gate(None)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"ERROR not-allowed", result.stderr)

    def test_every_other_command_is_refused(self):
        requests = ["", " ", "bash", "sh", "/bin/sh -c id", "id", "PING", "Ping", "ping ",
                    "ping extra", "ping;id", "ping && id", "ping\nid", "serve --port 1",
                    "location now", "scp -t /tmp", "sftp", "internal-sftp",
                    "/usr/lib/openssh/sftp-server", "hermes serve", "exec bash", "true"]
        for request in requests:
            with self.subTest(request=request):
                result = self.gate(request)
                if request == "ping ":
                    # Surrounding blanks are not part of the command name.
                    self.assertEqual(result.stdout, b"PONG 3\n")
                    continue
                self.assertEqual(result.returncode, 2, result.stdout)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"ERROR not-allowed", result.stderr)
        self.assertEqual(self.records(), [])

    def test_bad_gate_options_are_refused(self):
        for options in (["--slot", "xyz"], ["--slot"], ["--other"], ["--slot", "A" * 32],
                        ["--port"], ["--port", "0"], ["--port", "1023"], ["--port", "65536"],
                        ["--port", "abc"], ["--port", "+4710"], ["--port", "047100"], ["--port", "4710 0"]):
            with self.subTest(options=options):
                result = self.gate("ping", options=options)
                self.assertEqual(result.returncode, 2)
                self.assertIn(b"ERROR bad-config", result.stderr)

    def test_slot_option_is_accepted(self):
        result = self.gate("ping", options=["--slot", "0" * 32, "--hermes", self.hermes])
        self.assertEqual(result.stdout, b"PONG 3\n")

    def test_port_option_is_accepted(self):
        result = self.gate("ping", options=["--slot", "0" * 32, "--port", "47150", "--hermes", self.hermes])
        self.assertEqual(result.stdout, b"PONG 3\n", result.stderr)


class ServeTests(GateTestCase):
    def serve(self, token=TOKEN_A, **kwargs):
        return self.gate("serve", stdin=token.encode("ascii"), **kwargs)

    def state(self):
        names = [n for n in os.listdir(self.path("hermesconnect")) if re.fullmatch(r"serve-[0-9a-f]{32}\.json", n)]
        self.assertEqual(len(names), 1, names)
        path = self.path("hermesconnect", names[0])
        with open(path) as stream:
            return path, json.load(stream)

    def test_serve_spawns_isolated_loopback_server_and_prints_port(self):
        result = self.serve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"PORT %d\n" % self.port)
        records = self.records()
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["problems"], [])
        argv = record["argv"]
        self.assertEqual(argv[:6], ["serve", "--isolated", "--host", "127.0.0.1", "--port", str(self.port)])
        token_path = argv[argv.index("--ssh-session-token-file") + 1]
        nonce = argv[argv.index("--ssh-owner-nonce") + 1]
        self.assertRegex(nonce, r"^[0-9a-f]{16}$")
        self.assertTrue(token_path.startswith(self.path("desktop-ssh") + os.sep))
        self.assertFalse(os.path.exists(token_path), "the server deletes the token file")
        self.assertEqual(record["desktop"], "1")
        self.assertIsNone(record["sshCommand"])

    def test_token_is_never_printed_or_stored(self):
        result = self.serve(TOKEN_B)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(TOKEN_B.encode(), result.stdout + result.stderr)
        state_path, state = self.state()
        with open(state_path) as stream:
            self.assertNotIn(TOKEN_B, stream.read())
        self.assertEqual(self.mode(state_path), 0o600)
        self.assertEqual(state["tokenFingerprint"], self.records()[0]["fingerprint"])
        for root, _dirs, files in os.walk(self.path()):
            for name in files:
                with open(os.path.join(root, name), "rb") as stream:
                    self.assertNotIn(TOKEN_B.encode(), stream.read(), name)

    def test_private_folders_are_mode_0700(self):
        self.assertEqual(self.serve().returncode, 0)
        _path, state = self.state()
        for folder in (self.path("hermesconnect"), self.path("desktop-ssh"),
                       os.path.dirname(state["tokenPath"])):
            self.assertEqual(self.mode(folder), 0o700, folder)
        self.assertEqual(self.mode(state["logPath"]), 0o600)

    def test_existing_hermes_folder_mode_is_kept(self):
        os.mkdir(self.path(), 0o755)
        self.assertEqual(self.serve().returncode, 0)
        self.assertEqual(self.mode(self.path()), 0o755)

    def test_second_serve_with_same_token_reuses_server(self):
        first = self.serve()
        second = self.serve(TOKEN_A + "\n")
        self.assertEqual(first.stdout, b"PORT %d\n" % self.port)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, b"PORT %d\n" % self.port)
        self.assertEqual(len(self.records()), 1, "no second spawn")

    def test_new_token_replaces_server(self):
        self.assertEqual(self.serve(TOKEN_A).returncode, 0)
        old_pid = self.records()[0]["pid"]
        # The old server holds the slot port. The gate stops it, then the new server gets the same port.
        result = self.serve(TOKEN_B)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"PORT %d\n" % self.port)
        self.assertTrue(self.wait_dead(old_pid), "the old server is stopped")
        records = self.records()
        self.assertEqual(len(records), 2)
        self.assertNotEqual(records[0]["argv"], records[1]["argv"], "a new nonce for each spawn")
        _path, state = self.state()
        self.assertEqual(state["pid"], records[1]["pid"])

    def test_dead_server_is_respawned(self):
        self.assertEqual(self.serve().returncode, 0)
        old = self.records()[0]
        _path, state = self.state()
        self.kill(old["pid"])
        self.assertTrue(self.wait_dead(old["pid"]))
        result = self.serve()
        self.assertEqual(result.stdout, b"PORT %d\n" % self.port, result.stderr)
        self.assertEqual(len(self.records()), 2)
        self.assertFalse(os.path.exists(state["logPath"]), "the old log is deleted")

    def test_live_pid_that_is_not_our_server_is_not_killed(self):
        self.assertEqual(self.serve().returncode, 0)
        state_path, state = self.state()
        self.kill(state["pid"])
        self.wait_dead(state["pid"])
        state["pid"] = os.getpid()  # A live process with a different argv (pid reuse).
        with open(state_path, "w") as stream:
            json.dump(state, stream)
        result = self.serve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.records()), 2, "spawn fresh, do not trust the pid")

    def test_huge_pid_in_state_file_is_not_trusted(self):
        self.assertEqual(self.serve().returncode, 0)
        state_path, state = self.state()
        self.kill(state["pid"])
        self.wait_dead(state["pid"])
        with open(state_path, "w") as stream:
            stream.write(json.dumps(state).replace('"pid": %d' % state["pid"], '"pid": ' + "9" * 30))
        result = self.serve()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(len(self.records()), 2, "spawn fresh, do not trust the pid")

    def test_bad_tokens_are_refused(self):
        for token in ("", "A" * 64, "a" * 63, "a" * 65, "g" * 64, " " + "a" * 63, "a" * 64 + "\n\n",
                      "a" * 64 + " ", "a" * 200):
            with self.subTest(token=token[:8], length=len(token)):
                result = self.serve(token)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"ERROR bad-token", result.stderr)
        self.assertEqual(self.records(), [])

    def test_crlf_after_token_is_accepted(self):
        self.assertEqual(self.serve(TOKEN_A + "\r\n").stdout, b"PORT %d\n" % self.port)

    def test_server_that_exits_before_ready_fails_and_cleans_up(self):
        result = self.serve(extra_env={"FAKE_MODE": "exit"})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"ERROR serve-exited", result.stderr)
        self.assertEqual(os.listdir(self.path("hermesconnect")), ["serve-%s.lock" % self.default_slot()])
        slot_dir = self.path("desktop-ssh", self.default_slot())
        self.assertEqual(os.listdir(slot_dir), [], "no token file or log is left")

    def test_missing_profile_is_reported(self):
        result = self.serve(extra_env={"FAKE_MODE": "profile"})
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR profile-missing", result.stderr)

    def test_server_that_never_gets_ready_times_out_and_is_stopped(self):
        start = time.monotonic()
        result = self.serve(extra_env={"FAKE_MODE": "hang", "HERMESCONNECT_READY_TIMEOUT": "1"})
        self.assertLess(time.monotonic() - start, 15)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR serve-timeout", result.stderr)
        pid = self.records()[0]["pid"]
        self.assertTrue(self.wait_dead(pid), "the hung server is stopped")

    def test_hermes_without_token_support_needs_update(self):
        result = self.serve(extra_env={"FAKE_NO_SUPPORT": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR update-required", result.stderr)
        self.assertEqual(self.records(), [])

    def test_update_in_progress_blocks_spawn(self):
        os.makedirs(self.path(), 0o700)
        open(self.path(".hermes-update-in-progress"), "w").close()
        result = self.serve()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR update-in-progress", result.stderr)
        self.assertEqual(self.records(), [])

    def test_missing_hermes_binary(self):
        result = self.serve(options=["--hermes", os.path.join(self.tmp, "nope")])
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR hermes-not-found", result.stderr)

    def test_hermes_found_in_local_bin_without_option(self):
        local_bin = os.path.join(self.home, ".local", "bin")
        os.makedirs(local_bin)
        os.symlink(self.hermes, os.path.join(local_bin, "hermes"))
        result = self.serve(options=["--port", str(self.port)])
        self.assertEqual(result.stdout, b"PORT %d\n" % self.port, result.stderr)

    def test_slots_are_independent(self):
        slot_a, slot_b = "1" * 32, "2" * 32
        port_b = free_port()
        a = self.serve(TOKEN_A, options=["--slot", slot_a, "--hermes", self.hermes, "--port", str(self.port)])
        b = self.serve(TOKEN_B, options=["--slot", slot_b, "--hermes", self.hermes, "--port", str(port_b)])
        self.assertEqual((a.stdout, b.stdout), (b"PORT %d\n" % self.port, b"PORT %d\n" % port_b))
        records = self.records()
        self.assertEqual(len(records), 2)
        for record in records:
            os.kill(record["pid"], 0)  # Both servers still run.
        paths = [r["argv"][r["argv"].index("--ssh-session-token-file") + 1] for r in records]
        self.assertIn(os.sep + slot_a + os.sep, paths[0])
        self.assertIn(os.sep + slot_b + os.sep, paths[1])

    def test_symlinked_gate_folder_is_refused(self):
        os.makedirs(self.path(), 0o700)
        os.symlink(self.tmp, self.path("hermesconnect"))
        result = self.serve()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"ERROR unsafe-path", result.stderr)

    # --- Issue #29: one fixed port for each slot ------------------------------------------

    def listen_on(self, port):
        """Hold ``port`` with a listener that is not a Hermes server (for example the dashboard)."""
        other = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        other.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        other.bind(("127.0.0.1", port))
        other.listen(1)
        self.addCleanup(other.close)
        return other

    def spawn_ports(self):
        return [r["argv"][r["argv"].index("--port") + 1] for r in self.records()]

    def test_serve_uses_the_slot_port_when_the_key_line_has_no_port(self):
        slot = "3" * 32
        result = self.serve(options=["--slot", slot, "--hermes", self.hermes])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"PORT %d\n" % slot_port(slot))
        self.assertEqual(self.spawn_ports(), [str(slot_port(slot))])
        _path, state = self.state()
        self.assertEqual(state["port"], slot_port(slot))

    def test_default_slot_has_a_fixed_port_in_the_range(self):
        port = slot_port(DEFAULT_SLOT)
        self.assertTrue(47100 <= port <= 47199)
        result = self.serve(options=["--hermes", self.hermes])
        self.assertEqual(result.stdout, b"PORT %d\n" % port, result.stderr)
        self.assertEqual(self.spawn_ports(), [str(port)])

    def test_serve_never_asks_for_a_random_port(self):
        for token in (TOKEN_A, TOKEN_B, TOKEN_A):
            self.assertEqual(self.serve(token).stdout, b"PORT %d\n" % self.port)
        self.assertEqual(self.spawn_ports(), [str(self.port)] * 3)

    def test_busy_port_is_refused_and_nothing_starts(self):
        self.listen_on(self.port)
        result = self.serve()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"ERROR port-busy", result.stderr)
        self.assertEqual(self.records(), [], "no hermes serve starts")
        names = os.listdir(self.path("hermesconnect"))
        self.assertEqual([n for n in names if n.endswith(".json")], [], "no state file")

    def test_busy_port_does_not_stop_our_live_server(self):
        self.assertEqual(self.serve(TOKEN_A).stdout, b"PORT %d\n" % self.port)
        pid = self.records()[0]["pid"]
        other_port = free_port()
        self.listen_on(other_port)
        result = self.serve(TOKEN_A, options=["--hermes", self.hermes, "--port", str(other_port)])
        self.assertIn(b"ERROR port-busy", result.stderr)
        self.assertEqual(len(self.records()), 1)
        os.kill(pid, 0)  # The old server still runs. The gate refused before it stopped anything.

    def test_ready_port_that_differs_from_the_slot_port_fails_and_stops_the_server(self):
        result = self.serve(extra_env={"FAKE_PORT": str(self.port + 1)})
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"ERROR port-mismatch", result.stderr)
        pid = self.records()[0]["pid"]
        self.assertTrue(self.wait_dead(pid), "the server on the wrong port is stopped")
        names = os.listdir(self.path("hermesconnect"))
        self.assertEqual([n for n in names if n.endswith(".json")], [], "no state file")

    def test_new_port_in_the_key_line_replaces_the_server(self):
        self.assertEqual(self.serve(TOKEN_A).stdout, b"PORT %d\n" % self.port)
        old_pid = self.records()[0]["pid"]
        new_port = free_port()
        result = self.serve(TOKEN_A, options=["--hermes", self.hermes, "--port", str(new_port)])
        self.assertEqual(result.stdout, b"PORT %d\n" % new_port, result.stderr)
        self.assertTrue(self.wait_dead(old_pid), "the server on the old port is stopped")
        self.assertEqual(self.spawn_ports(), [str(self.port), str(new_port)])

    def default_slot(self):
        names = [n for n in os.listdir(self.path("desktop-ssh"))]
        self.assertEqual(len(names), 1)
        return names[0]


class InstallLineServeTests(GateTestCase):
    """The key line from install.sh and the gate agree on one port (issue #29)."""

    def key_line(self, *install_args):
        blob = "AAAAC3NzaC1lZDI1NTE5AAAAIAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEB"
        argv = ["bash", INSTALL, "--dry-run", "--gate-dest", "/usr/local/libexec/hermesconnect/hermesconnect-gate",
                "--hermes", self.hermes] + list(install_args) + ["ssh-ed25519 %s phone" % blob]
        result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.decode().strip()

    def serve_with(self, line):
        options = line.split('command="', 1)[1].split('"', 1)[0].split()[1:]
        return self.gate("serve", stdin=TOKEN_A.encode("ascii"), options=options)

    def test_gate_serves_on_the_one_port_that_permitopen_names(self):
        for install_args in ((), ("--port", str(self.port))):
            with self.subTest(install_args=install_args):
                line = self.key_line(*install_args)
                opened = re.findall(r'permitopen="([^"]*)"', line)
                self.assertEqual(len(opened), 1, line)
                self.assertRegex(opened[0], r"^127\.0\.0\.1:\d+$")
                port = int(opened[0].split(":")[1])
                if install_args:
                    self.assertEqual(port, self.port)
                result = self.serve_with(line)
                self.assertEqual(result.stdout, b"PORT %d\n" % port, result.stderr)
                for record in self.records():
                    self.kill(record["pid"])
                    self.wait_dead(record["pid"])


def fix(**overrides):
    value = {"lat": 37.3349, "lon": -122.009, "accuracy_m": 12.5,
             "timestamp": "2026-11-16T12:00:00Z"}
    value.update(overrides)
    return {k: v for k, v in value.items() if v is not ...}


def huge_int_fix(field):
    """A fix whose ``field`` is a 3000-digit integer (above the float range, inside 4096 bytes)."""
    text = json.dumps(fix(**{field: 0}))
    return text.replace('"%s": 0' % field, '"%s": %s' % (field, "9" * 3000)).encode("utf-8")


class LocationTests(GateTestCase):
    def send(self, payload):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
        return self.gate("location", stdin=data)

    def stored(self):
        with open(self.path("hermesconnect", "location.json")) as stream:
            return json.load(stream)

    def no_location_gate(self, command, stdin=b""):
        return self.gate(command, stdin=stdin,
                         options=["--hermes", self.hermes, "--port", str(self.port), "--no-location"])

    def test_no_location_refuses_the_fix_and_stores_nothing(self):
        # Issue #92: a team server. The gate refuses with a stable code and writes no file.
        result = self.no_location_gate("location", stdin=json.dumps(fix()).encode("utf-8"))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"ERROR location-off: this server does not accept location\n")
        self.assertFalse(os.path.exists(self.path("hermesconnect", "location.json")))
        self.assertFalse(os.path.exists(self.path("hermesconnect", "location.lock")))

    def test_no_location_keeps_ping_and_the_allow_list(self):
        # The gate version stays 3: the app reads the error code, so it needs no new version.
        result = self.no_location_gate("ping")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"PONG 3\n")
        for request in (None, "bash", "location now"):
            with self.subTest(request=request):
                self.assertEqual(self.no_location_gate(request).returncode, 2)

    def test_no_location_takes_no_value(self):
        result = self.gate("ping", options=["--no-location=yes"])
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"ERROR bad-config", result.stderr)

    def test_valid_fix_is_stored_privately(self):
        result = self.send(fix(speed=1.5, course=90))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"OK\n")
        path = self.path("hermesconnect", "location.json")
        self.assertEqual(self.mode(path), 0o600)
        self.assertEqual(self.mode(self.path("hermesconnect")), 0o700)
        stored = self.stored()
        self.assertEqual(stored["schemaVersion"], 1)
        self.assertEqual((stored["lat"], stored["lon"], stored["accuracy_m"]), (37.3349, -122.009, 12.5))
        self.assertEqual(stored["timestamp"], "2026-11-16T12:00:00.000Z")
        self.assertEqual((stored["speed"], stored["course"]), (1.5, 90.0))
        self.assertEqual(stored["source"], "hermesconnect")
        self.assertRegex(stored["received_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$")
        leftovers = [n for n in os.listdir(self.path("hermesconnect")) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_optional_fields_may_be_missing_or_null(self):
        self.assertEqual(self.send(fix()).stdout, b"OK\n")
        self.assertIsNone(self.stored()["speed"])
        self.assertEqual(self.send(fix(timestamp="2026-11-16T12:00:01Z", speed=None, course=None)).stdout, b"OK\n")
        self.assertIsNone(self.stored()["course"])

    def test_arrival_time_of_a_visit_is_stored(self):
        # QA #53 defect 1: the app sends when the owner arrived at a place (gate 3).
        result = self.send(fix(arrived_at="2026-11-16T11:15:00.250Z"))
        self.assertEqual(result.stdout, b"OK\n", result.stderr)
        self.assertEqual(self.stored()["arrived_at"], "2026-11-16T11:15:00.250Z")
        self.assertEqual(self.send(fix(timestamp="2026-11-16T12:00:01Z", arrived_at=None)).stdout, b"OK\n")
        self.assertIsNone(self.stored()["arrived_at"])
        self.assertEqual(self.send(fix(timestamp="2026-11-16T12:00:02Z")).stdout, b"OK\n")
        self.assertIsNone(self.stored()["arrived_at"])

    def test_invalid_arrival_time_is_refused(self):
        future = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for name, value in {"no zone": "2026-11-16T11:00:00", "text": "this morning", "bool": True,
                            "future": future, "year 1": "0001-01-01T00:00:00+05:00"}.items():
            with self.subTest(case=name):
                result = self.send(fix(arrived_at=value))
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(b"ERROR bad-location", result.stderr)
        self.assertFalse(os.path.exists(self.path("hermesconnect", "location.json")))

    def test_timestamp_forms(self):
        cases = {
            "2026-11-16T14:00:00+02:00": "2026-11-16T12:00:00.000Z",
            "2026-11-16T12:00:00.5Z": "2026-11-16T12:00:00.500Z",
            "2026-11-16T12:00:00.123456789Z": "2026-11-16T12:00:00.123Z",
            1763294400: "2025-11-16T12:00:00.000Z",
            1763294400.25: "2025-11-16T12:00:00.250Z",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                try:
                    os.unlink(self.path("hermesconnect", "location.json"))
                except OSError:
                    pass
                result = self.send(fix(timestamp=value))
                self.assertEqual(result.stdout, b"OK\n", result.stderr)
                self.assertEqual(self.stored()["timestamp"], expected)

    def test_older_fix_does_not_replace_newer_fix(self):
        self.assertEqual(self.send(fix(lat=10, timestamp="2026-11-16T12:00:00Z")).stdout, b"OK\n")
        self.assertEqual(self.send(fix(lat=20, timestamp="2026-11-16T11:00:00Z")).stdout, b"OK\n")
        self.assertEqual(self.stored()["lat"], 10)
        self.assertEqual(self.send(fix(lat=30, timestamp="2026-11-16T13:00:00Z")).stdout, b"OK\n")
        self.assertEqual(self.stored()["lat"], 30)

    def test_edge_values_are_accepted(self):
        for lat, lon in ((90, 180), (-90, -180), (0, 0)):
            with self.subTest(lat=lat, lon=lon):
                result = self.send(fix(lat=lat, lon=lon, accuracy_m=0, course=360, speed=0,
                                       timestamp="2026-11-16T12:00:%02dZ" % (lat % 60)))
                self.assertEqual(result.stdout, b"OK\n", result.stderr)

    def test_invalid_input_is_refused(self):
        future = (datetime.now(timezone.utc) + timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        cases = {
            "not json": b"lat=1",
            "empty": b"",
            "array": b"[1, 2]",
            "nan": b'{"lat": NaN, "lon": 0, "accuracy_m": 1, "timestamp": "2026-11-16T12:00:00Z"}',
            "infinity": b'{"lat": 1, "lon": Infinity, "accuracy_m": 1, "timestamp": "2026-11-16T12:00:00Z"}',
            "invalid utf-8": b'{"lat": "\xff"}',
            "too large": json.dumps(fix(timestamp="2026-11-16T12:00:00Z" + " " * 4096)).encode(),
            "missing lat": fix(lat=...),
            "missing timestamp": fix(timestamp=...),
            "lat 91": fix(lat=91),
            "lat -90.1": fix(lat=-90.1),
            "lon 181": fix(lon=181),
            "lat text": fix(lat="37"),
            "lat bool": fix(lat=True),
            "lat null": fix(lat=None),
            "accuracy negative": fix(accuracy_m=-1),
            "speed negative": fix(speed=-0.1),
            "speed text": fix(speed="fast"),
            "course 361": fix(course=361),
            "course negative": fix(course=-1),
            "unknown field": fix(altitude=10),
            "timestamp no zone": fix(timestamp="2026-11-16T12:00:00"),
            "timestamp text": fix(timestamp="yesterday"),
            "timestamp future": fix(timestamp=future),
            "timestamp bool": fix(timestamp=True),
            "timestamp huge": fix(timestamp=1e20),
            "lat huge integer": huge_int_fix("lat"),
            "lon huge integer": huge_int_fix("lon"),
            "accuracy huge integer": huge_int_fix("accuracy_m"),
            "speed huge integer": huge_int_fix("speed"),
            "course huge integer": huge_int_fix("course"),
            "timestamp huge integer": huge_int_fix("timestamp"),
            "timestamp year 1 east of UTC": fix(timestamp="0001-01-01T00:00:00+05:00"),
            "timestamp year 9999 west of UTC": fix(timestamp="9999-12-31T23:59:59-05:00"),
        }
        for name, payload in cases.items():
            with self.subTest(case=name):
                result = self.send(payload)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stdout, b"")
                self.assertIn(b"ERROR bad-location", result.stderr)
        self.assertFalse(os.path.exists(self.path("hermesconnect", "location.json")))

    def test_exactly_4096_bytes_is_accepted(self):
        body = json.dumps(fix())
        padded = body[:-1] + " " * (4096 - len(body)) + "}"
        self.assertEqual(len(padded.encode()), 4096)
        self.assertEqual(self.send(padded.encode()).stdout, b"OK\n")


if __name__ == "__main__":
    unittest.main()
