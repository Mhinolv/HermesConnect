#!/usr/bin/env bash
# Install the HermesConnect gate and the restricted phone key on the Hermes server.
#
# Usage (as root, from a copy of the server/ folder):
#   sudo ./install.sh '<OpenSSH public key line>'
#   sudo ./install.sh - < phone.pub
#   sudo ./install.sh --remove '<OpenSSH public key line>'
#
# The key line must be "ssh-ed25519 <base64> [comment]" or
# "ecdsa-sha2-nistp256 <base64> [comment]", with no options in front.
# The script is idempotent: it replaces every older line for the same key.
# It also upgrades an older line with permitopen="127.0.0.1:*" to the one slot port.
# It sets the Hermes config dashboard.ssh_isolated_idle_grace_s to 86400 (24 h) when the
# key is not set. It keeps a value that is already set (issue #183).
#
# Options:
#   --user NAME              Account that runs Hermes (default: hermes).
#   --authorized-keys FILE   Default: ~NAME/.ssh/authorized_keys.
#   --gate-dest PATH         Where the gate goes (default: /usr/local/libexec/hermesconnect/hermesconnect-gate).
#   --no-copy-gate           Do not copy the gate. Use the file at --gate-dest as it is.
#   --hermes PATH            Pass an explicit Hermes binary to the gate.
#   --port N                 Fixed Hermes port for this key (1024-65535). Default: the slot
#                            port, 47100 + (slot as an integer) % 100.
#   --no-location            The gate refuses the phone location (a team server).
#   --remove                 Remove the key. Do not add it.
#   --dry-run                Print the authorized_keys line. Change nothing.
set -euo pipefail

USER_NAME=hermes
AUTH_KEYS=""
GATE_DEST=/usr/local/libexec/hermesconnect/hermesconnect-gate
COPY_GATE=1
HERMES_PATH=""
PORT=""
PORT_GIVEN=0
NO_LOCATION=0
REMOVE=0
DRY_RUN=0
KEY_ARG=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# hermes serve exits when no client is connected for this many seconds (default 900).
IDLE_GRACE_KEY=dashboard.ssh_isolated_idle_grace_s
IDLE_GRACE_S=86400
GATE_SRC="$SCRIPT_DIR/gate/hermesconnect-gate"

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user) [ $# -ge 2 ] || die "--user needs a value"; USER_NAME="$2"; shift 2 ;;
    --authorized-keys) [ $# -ge 2 ] || die "--authorized-keys needs a value"; AUTH_KEYS="$2"; shift 2 ;;
    --gate-dest) [ $# -ge 2 ] || die "--gate-dest needs a value"; GATE_DEST="$2"; shift 2 ;;
    --no-copy-gate) COPY_GATE=0; shift ;;
    --hermes) [ $# -ge 2 ] || die "--hermes needs a value"; HERMES_PATH="$2"; shift 2 ;;
    --port) [ $# -ge 2 ] || die "--port needs a value"; PORT="$2"; PORT_GIVEN=1; shift 2 ;;
    --remove) REMOVE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-location) NO_LOCATION=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    -) [ -z "$KEY_ARG" ] || die "give one key line"; KEY_ARG="-"; shift ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$KEY_ARG" ] || die "give one key line (quote it)"; KEY_ARG="$1"; shift ;;
  esac
done
[ -n "$KEY_ARG" ] || die "give the OpenSSH public key line"

if [ "$KEY_ARG" = "-" ]; then
  KEY_LINE="$(head -c 4096)"
else
  KEY_LINE="$KEY_ARG"
fi
KEY_LINE="$(printf '%s' "$KEY_LINE" | tr -d '\r')"
case "$KEY_LINE" in *$'\n'*) die "give exactly one key line" ;; esac

command -v python3 >/dev/null 2>&1 || die "python3 is required (the gate uses it)"

# Check the key and compute the slot (sha256 of the key blob, first 32 hex) and the
# slot port (the same rule as the gate). The helper prints
# "<type> <blob> <comment> <slot> <slot port>" or exits non-zero.
PARSED="$(python3 -I -c '
import base64, binascii, hashlib, re, struct, sys
line = sys.argv[1].strip()
parts = line.split()
if len(parts) < 2:
    sys.exit("the key line needs a type and a key")
ktype, blob = parts[0], parts[1]
if ktype not in ("ssh-ed25519", "ecdsa-sha2-nistp256"):
    sys.exit("unsupported key type (use ssh-ed25519 or ecdsa-sha2-nistp256, with no options)")
if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", blob):
    sys.exit("the key is not base64")
try:
    raw = base64.b64decode(blob, validate=True)
except (binascii.Error, ValueError):
    sys.exit("the key is not base64")
def field(data, offset):
    if offset + 4 > len(data):
        raise ValueError
    (size,) = struct.unpack(">I", data[offset:offset + 4])
    end = offset + 4 + size
    if end > len(data):
        raise ValueError
    return data[offset + 4:end], end
try:
    name, offset = field(raw, 0)
    if name.decode("ascii") != ktype:
        raise ValueError
    if ktype == "ssh-ed25519":
        point, offset = field(raw, offset)
        ok = len(point) == 32
    else:
        curve, offset = field(raw, offset)
        point, offset = field(raw, offset)
        ok = curve == b"nistp256" and len(point) == 65 and point[0] == 4
    if not ok or offset != len(raw):
        raise ValueError
except (ValueError, UnicodeDecodeError):
    sys.exit("the key data does not match its type")
comment = re.sub(r"[^A-Za-z0-9@._+:=-]", "", "-".join(parts[2:]))[:64] or "hermesconnect"
slot = hashlib.sha256(blob.encode("ascii")).hexdigest()[:32]
print(ktype, blob, comment, slot, 47100 + int(slot, 16) % 100)
' "$KEY_LINE")" || die "the public key line is not valid"
read -r KEY_TYPE KEY_BLOB KEY_COMMENT SLOT SLOT_PORT <<EOF
$PARSED
EOF

if [ "$PORT_GIVEN" -eq 0 ]; then
  PORT="$SLOT_PORT"
else
  # Digits only. `case` checks the whole value: grep checks each line, so "47100<newline>9119" passed it.
  case "$PORT" in
    ''|*[!0-9]*) die "--port must be a number from 1024 to 65535" ;;
  esac
  if ! printf '%s' "$PORT" | grep -Eq '^[1-9][0-9]{3,4}$' || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    die "--port must be a number from 1024 to 65535"
  fi
fi

case "$GATE_DEST" in
  /*) ;;
  *) die "--gate-dest must be an absolute path" ;;
esac
printf '%s' "$GATE_DEST" | grep -Eq '^/[A-Za-z0-9._/-]+$' || die "--gate-dest has unsafe characters"
if [ -n "$HERMES_PATH" ]; then
  printf '%s' "$HERMES_PATH" | grep -Eq '^/[A-Za-z0-9._/-]+$' || die "--hermes must be an absolute path with safe characters"
fi

GATE_CMD="$GATE_DEST --slot $SLOT --port $PORT"
[ -z "$HERMES_PATH" ] || GATE_CMD="$GATE_CMD --hermes $HERMES_PATH"
[ "$NO_LOCATION" -eq 0 ] || GATE_CMD="$GATE_CMD --no-location"
# permitopen names one port: the phone key reaches only its own hermes serve, not the dashboard or other ports.
# permitlisten on a privileged port blocks every remote (-R) forward: the phone key gets no reverse tunnel.
OPTIONS="restrict,port-forwarding,permitopen=\"127.0.0.1:$PORT\",permitlisten=\"127.0.0.1:1\",command=\"$GATE_CMD\""
NEW_LINE="$OPTIONS $KEY_TYPE $KEY_BLOB $KEY_COMMENT"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "$NEW_LINE"
  exit 0
fi

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

if [ -z "$AUTH_KEYS" ]; then
  printf '%s' "$USER_NAME" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "bad user name"
  USER_HOME=""
  if command -v getent >/dev/null 2>&1; then
    USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
  fi
  if [ -z "$USER_HOME" ]; then
    USER_HOME="$(eval echo "~$USER_NAME")"
  fi
  case "$USER_HOME" in /*) ;; *) die "user $USER_NAME has no home folder" ;; esac
  AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
fi
SSH_DIR="$(dirname "$AUTH_KEYS")"

if [ "$REMOVE" -eq 0 ] && [ "$COPY_GATE" -eq 1 ]; then
  [ -f "$GATE_SRC" ] || die "gate not found at $GATE_SRC"
  mkdir -p "$(dirname "$GATE_DEST")"
  TMP_GATE="$(mktemp "$(dirname "$GATE_DEST")/.hermesconnect-gate.XXXXXX")"
  cp "$GATE_SRC" "$TMP_GATE"
  chmod 0755 "$TMP_GATE"
  if [ "$IS_ROOT" -eq 1 ]; then
    chown 0:0 "$TMP_GATE"
    chmod 0755 "$(dirname "$GATE_DEST")"
  fi
  mv -f "$TMP_GATE" "$GATE_DEST"
  echo "gate: installed $GATE_DEST"
fi
if [ "$REMOVE" -eq 0 ]; then
  [ -x "$GATE_DEST" ] || die "the gate at $GATE_DEST is not executable"
  [ -x /usr/bin/python3 ] || echo "install.sh: warning: /usr/bin/python3 is missing; the gate cannot start" >&2
fi

if [ ! -d "$SSH_DIR" ]; then
  mkdir -p "$SSH_DIR"
  chmod 0700 "$SSH_DIR"
  [ "$IS_ROOT" -eq 0 ] || chown "$USER_NAME:" "$SSH_DIR" 2>/dev/null || chown "$USER_NAME" "$SSH_DIR"
fi
[ -e "$AUTH_KEYS" ] || : > "$AUTH_KEYS"
[ -f "$AUTH_KEYS" ] && [ ! -L "$AUTH_KEYS" ] || die "$AUTH_KEYS is not a regular file"

# Two phone keys must not share a port: the second serve would get "port-busy".
if [ "$REMOVE" -eq 0 ] && awk -v blob="$KEY_BLOB" -v want="permitopen=\"127.0.0.1:$PORT\"" '
    { mine = 0; for (i = 1; i <= NF; i++) if ($i == blob) mine = 1 }
    !mine && index($0, want) { found = 1 }
    END { exit found ? 0 : 1 }' "$AUTH_KEYS"; then
  die "port $PORT is in use by another key in $AUTH_KEYS. Give another port with --port"
fi

# Keep every line that does not hold this key blob, then add the new line.
TMP_KEYS="$(mktemp "$SSH_DIR/.authorized_keys.XXXXXX")"
trap 'rm -f "$TMP_KEYS"' EXIT
awk -v blob="$KEY_BLOB" '{ for (i = 1; i <= NF; i++) if ($i == blob) next; print }' "$AUTH_KEYS" > "$TMP_KEYS"
[ "$REMOVE" -eq 1 ] || printf '%s\n' "$NEW_LINE" >> "$TMP_KEYS"

# Run hermes as the account that runs it, with its home, so it uses the config.yaml of the gate.
# Root never runs the hermes binary as root: the account can write that binary.
run_hermes() {
  if [ "$IS_ROOT" -eq 1 ]; then
    if command -v runuser >/dev/null 2>&1; then
      (cd "$HERMES_USER_HOME" && runuser -u "$USER_NAME" -- env -u HERMES_HOME HOME="$HERMES_USER_HOME" "$HERMES_BIN" "$@")
    elif command -v sudo >/dev/null 2>&1; then
      (cd "$HERMES_USER_HOME" && sudo -n -u "$USER_NAME" env -u HERMES_HOME HOME="$HERMES_USER_HOME" "$HERMES_BIN" "$@")
    else
      echo "neither runuser nor sudo is available" >&2
      return 1
    fi
  else
    (cd "$HERMES_USER_HOME" && env -u HERMES_HOME HOME="$HERMES_USER_HOME" "$HERMES_BIN" "$@")
  fi
}

# Look for hermes where the gate looks: --hermes, else PATH (sshd default), ~/.local/bin, the venv.
find_hermes_cli() {
  local candidate
  if [ -n "$HERMES_PATH" ]; then
    set -- "$HERMES_PATH"
  else
    set -- /usr/local/bin/hermes /usr/bin/hermes "$HERMES_USER_HOME/.local/bin/hermes" \
      "$HERMES_USER_HOME/.hermes/hermes-agent/venv/bin/hermes"
  fi
  for candidate in "$@"; do
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Keep hermes serve alive for IDLE_GRACE_S after the last client goes (issue #183).
# Set the value only when the key is not set: a value that the owner set stays.
# A failure here prints a warning only. The key install already succeeded.
set_idle_grace() {
  local err out
  HERMES_USER_HOME="$(dirname "$SSH_DIR")"
  if ! HERMES_BIN="$(find_hermes_cli)"; then
    echo "install.sh: warning: no hermes binary found. Set $IDLE_GRACE_KEY by hand (see README.md)" >&2
    return 0
  fi
  err="$(mktemp "${TMPDIR:-/tmp}/hermesconnect-config.XXXXXX")"
  if out="$(run_hermes config get "$IDLE_GRACE_KEY" 2>"$err" </dev/null)"; then
    out="$(printf '%s' "$out" | head -n 1 | tr -cd 'A-Za-z0-9._-' | cut -c 1-32)"
    echo "hermes config: kept $IDLE_GRACE_KEY = $out"
  elif grep -q "Config key not set" "$err"; then
    if run_hermes config set "$IDLE_GRACE_KEY" "$IDLE_GRACE_S" >/dev/null 2>"$err" </dev/null; then
      echo "hermes config: set $IDLE_GRACE_KEY to $IDLE_GRACE_S. It applies at the next start of hermes serve"
    else
      echo "install.sh: warning: hermes config set failed. Set $IDLE_GRACE_KEY by hand (see README.md)" >&2
    fi
  else
    echo "install.sh: warning: hermes config get failed. $IDLE_GRACE_KEY is not changed" >&2
  fi
  rm -f "$err"
  return 0
}

if cmp -s "$TMP_KEYS" "$AUTH_KEYS"; then
  rm -f "$TMP_KEYS"
  trap - EXIT
  echo "authorized_keys: unchanged ($AUTH_KEYS)"
else
  chmod 0600 "$TMP_KEYS"
  if [ "$IS_ROOT" -eq 1 ]; then
    chown "$USER_NAME:" "$TMP_KEYS" 2>/dev/null || chown "$USER_NAME" "$TMP_KEYS"
  fi
  mv -f "$TMP_KEYS" "$AUTH_KEYS"
  trap - EXIT
  if [ "$REMOVE" -eq 1 ]; then
    echo "authorized_keys: removed the key ($AUTH_KEYS)"
  else
    echo "authorized_keys: installed the key, slot $SLOT ($AUTH_KEYS)"
  fi
fi
[ "$REMOVE" -eq 1 ] || set_idle_grace
