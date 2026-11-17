"""Shared helpers for the server tests. Standard library only. No test connects to a real server."""

import hashlib
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GATE = os.path.join(SERVER_DIR, "gate", "hermesconnect-gate")
INSTALL = os.path.join(SERVER_DIR, "install.sh")

TOKEN_A = "a" * 64
TOKEN_B = "0123456789abcdef" * 4

# The gate default slot and the slot port rule (issue #29): 47100 + (slot as an integer) % 100.
DEFAULT_SLOT = hashlib.sha256(b"hermesconnect\0default").hexdigest()[:32]
SLOT_PORT_BASE = 47100
SLOT_PORT_COUNT = 100


def slot_port(slot):
    return SLOT_PORT_BASE + int(slot, 16) % SLOT_PORT_COUNT


def free_port():
    """A loopback port that is free now. Tests pass it with --port, so two test runs do not collide."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]

# A fake `hermes` binary. It checks the token file the way `hermes serve` does
# (main_dashboard.py `_read_ssh_session_token_file`), reads and deletes it, writes one
# JSON record per start to $FAKE_RECORD, listens on its --port (like uvicorn), prints the
# ready line, then waits for a signal. FAKE_PORT makes it report a different port.
FAKE_HERMES = r'''#!{python}
import hashlib, json, os, re, signal, socket, stat, sys, time
argv = sys.argv[1:]
if "--help" in argv:
    if os.environ.get("FAKE_NO_SUPPORT"):
        print("usage: hermes serve [--isolated] [--host H] [--port P]")
    else:
        print("usage: hermes serve [--isolated] [--host H] [--port P] "
              "[--ssh-session-token-file F] [--ssh-owner-nonce N]")
    sys.exit(0)
mode = os.environ.get("FAKE_MODE", "ok")
if mode == "exit":
    print("Traceback: fake failure", flush=True)
    sys.exit(1)
if mode == "profile":
    print("Error: Profile 'work' does not exist.", flush=True)
    sys.exit(1)
assert argv[0] == "serve", argv
path = argv[argv.index("--ssh-session-token-file") + 1]
nonce = argv[argv.index("--ssh-owner-nonce") + 1]
root = os.path.join(os.path.expanduser("~"), ".hermes", "desktop-ssh")
rel = os.path.relpath(path, root).split(os.sep)
problems = []
if not os.path.isabs(path) or len(rel) != 2 or not re.fullmatch(r"[0-9a-f]{{32}}", rel[0]):
    problems.append("path")
if not re.fullmatch(r"[0-9a-f]{{16}}\.token", rel[-1]) or rel[-1] != nonce + ".token":
    problems.append("name")
if stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode) != 0o700:
    problems.append("dir-mode")
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) & ~0o600 or st.st_size != 64:
    problems.append("file")
token = open(path).read()
os.unlink(path)
if not re.fullmatch(r"[0-9a-f]{{64}}", token):
    problems.append("token")
record = {{"argv": argv, "pid": os.getpid(), "problems": problems,
          "fingerprint": hashlib.sha256(token.encode()).hexdigest()[:32],
          "desktop": os.environ.get("HERMES_DESKTOP"),
          "sshCommand": os.environ.get("SSH_ORIGINAL_COMMAND")}}
with open(os.environ["FAKE_RECORD"], "a") as out:
    out.write(json.dumps(record) + "\n")
if problems:
    print("Error: bad token file: " + ",".join(problems), flush=True)
    sys.exit(3)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
port = int(argv[argv.index("--port") + 1])
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    listener.bind(("127.0.0.1", port))
except OSError:
    print("ERROR: [Errno 48] address already in use", flush=True)
    sys.exit(1)
listener.listen(8)
port = listener.getsockname()[1]
if mode != "hang":
    print("starting", flush=True)
    print("HERMES_BACKEND_READY port=" + os.environ.get("FAKE_PORT", str(port)), flush=True)
    print("HERMES_DASHBOARD_READY port=1", flush=True)
while True:
    time.sleep(1)
'''


class GateTestCase(unittest.TestCase):
    """Gives each test a private $HOME and a fake hermes binary."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="hcgate-")
        self.tmp = os.path.realpath(self._tmp.name)
        self.home = os.path.join(self.tmp, "home")
        os.mkdir(self.home, 0o755)
        self.record = os.path.join(self.tmp, "record.jsonl")
        self.hermes = os.path.join(self.tmp, "bin", "hermes")
        os.mkdir(os.path.dirname(self.hermes))
        with open(self.hermes, "w") as out:
            out.write(FAKE_HERMES.format(python=sys.executable))
        os.chmod(self.hermes, 0o755)
        self.port = free_port()
        self.env = {
            "HOME": self.home,
            "PATH": "/usr/bin:/bin",
            "FAKE_RECORD": self.record,
            "HERMESCONNECT_READY_TIMEOUT": "20",
        }

    def tearDown(self):
        for record in self.records():
            self.kill(record["pid"])
        self._tmp.cleanup()

    @staticmethod
    def kill(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass

    def gate(self, command, stdin=b"", extra_env=None, options=None):
        env = dict(self.env)
        if command is not None:
            env["SSH_ORIGINAL_COMMAND"] = command
        env.update(extra_env or {})
        if options is None:
            options = ["--hermes", self.hermes, "--port", str(self.port)]
        args = [sys.executable, GATE] + options
        return subprocess.run(args, input=stdin, env=env, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)

    def records(self):
        try:
            with open(self.record) as stream:
                return [json.loads(line) for line in stream if line.strip()]
        except OSError:
            return []

    def path(self, *parts):
        return os.path.join(self.home, ".hermes", *parts)

    @staticmethod
    def mode(path):
        return os.stat(path).st_mode & 0o777

    @staticmethod
    def wait_dead(pid, timeout_s=5.0):
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.05)
        return False
