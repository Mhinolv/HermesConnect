# HermesConnect server gate

The phone key gets no shell on the Hermes server (research.md D2). sshd runs the gate as a forced command for that key. The gate accepts three commands only.

| Command (`ssh <host> <command>`) | stdin | stdout on success |
|---|---|---|
| `serve` | The 64-hex session token, then EOF | `PORT <n>` |
| `location` | One JSON object, 4096 bytes or fewer, then EOF | `OK` |
| `ping` | none | `PONG <gate version>` |

Every other request exits with code 2 and `ERROR not-allowed` on stderr. Other failures exit with code 1 and `ERROR <code>: <text>` on stderr.

## The key line

`install.sh` writes this line to `~hermes/.ssh/authorized_keys`:

```
restrict,port-forwarding,permitopen="127.0.0.1:*",permitlisten="127.0.0.1:1",command="/usr/local/libexec/hermesconnect/hermesconnect-gate --slot <slot>" ssh-ed25519 AAAA... <comment>
```

- `restrict` disables the PTY, agent forwarding, X11 forwarding and `~/.ssh/rc`.
- `port-forwarding` with `permitopen="127.0.0.1:*"` allows local (`-L`) forwards to the server loopback only.
- `permitlisten="127.0.0.1:1"` blocks remote (`-R`) forwards. A normal account cannot listen on port 1.
- `command=` runs the gate for every request, also for scp and sftp.
- `<slot>` is the first 32 hex characters of `sha256(<key base64>)`. Each phone key gets its own server slot.

## serve

`serve` follows the Hermes isolated serve contract (`docs/hermes-protocol.md` section 1):

1. The gate reads the token on stdin. It must be 64 lowercase hex characters. One trailing newline is accepted.
2. If a server that this gate started is alive, and the token fingerprint matches, the gate prints its port.
3. Otherwise the gate stops the old server and writes the token to `~/.hermes/desktop-ssh/<slot>/<nonce>.token` (mode 0600, folder 0700).
4. The gate starts `hermes serve --isolated --host 127.0.0.1 --port 0 --ssh-session-token-file <file> --ssh-owner-nonce <nonce>` in a new session.
5. The gate waits up to 120 s for `HERMES_BACKEND_READY port=<n>` in `<nonce>.log`, then prints `PORT <n>`.

The server reads and deletes the token file. The gate stores only `sha256(token)[:32]` in `~/.hermes/hermesconnect/serve-<slot>.json` (mode 0600). The gate never prints or logs the token.

| Error code | Meaning |
|---|---|
| `bad-token` | The token on stdin is not 64 lowercase hex characters. |
| `hermes-not-found` | No `hermes` binary. The gate looks in `PATH`, `~/.local/bin`, `/usr/local/bin` and `~/.hermes/hermes-agent/venv/bin`. |
| `update-required` | `hermes serve --help` has no `--ssh-session-token-file`. Update Hermes. |
| `update-in-progress` | `~/.hermes/.hermes-update-in-progress` exists. Try again later. |
| `serve-exited`, `serve-timeout`, `profile-missing` | The server did not get ready. Read `~/.hermes/desktop-ssh/<slot>/*.log`. |

The phone must forward to `127.0.0.1:<n>`. The host name `localhost` does not match `permitopen`.

## location

The input is one JSON object:

```json
{"lat": 37.3349, "lon": -122.009, "accuracy_m": 12.5, "timestamp": "2026-11-16T12:00:00Z", "speed": 1.5, "course": 90}
```

- `lat` (-90 to 90), `lon` (-180 to 180), `accuracy_m` (0 or more) and `timestamp` are required.
- `timestamp` is ISO 8601 with a time zone, or Unix seconds. A time more than 10 minutes in the future is refused.
- `speed` (m/s, 0 or more) and `course` (0 to 360) are optional and can be `null`. Other fields are refused.

The gate writes `~/.hermes/hermesconnect/location.json` (mode 0600) through an atomic rename. An older fix never replaces a newer fix. The `phone_location` plugin reads this file (see [phone_location plugin](#phone_location-plugin)):

```json
{"accuracy_m": 12.5, "course": 90.0, "lat": 37.3349, "lon": -122.009, "received_at": "2026-11-16T12:00:03.120Z",
 "schemaVersion": 1, "source": "hermesconnect", "speed": 1.5, "timestamp": "2026-11-16T12:00:00.000Z"}
```

## Install

Requirements: OpenSSH 7.8 or later, `/usr/bin/python3` (3.8 or later), and the `hermes` account.

1. Get the public key line from the app (issue #1). It starts with `ecdsa-sha2-nistp256` or `ssh-ed25519`.
2. Copy this folder to the server: `scp -r server root@<host>:/tmp/hermesconnect-server`.
3. Check the line first: `sudo /tmp/hermesconnect-server/install.sh --dry-run '<key line>'`.
4. Install the gate and the key: `sudo /tmp/hermesconnect-server/install.sh '<key line>'`.
5. Make sure that sshd allows local forwards: `sudo sshd -T | grep -Ei 'allowtcpforwarding|disableforwarding'`. You must see `allowtcpforwarding yes` (or `local`) and `disableforwarding no`.

The script copies the gate to `/usr/local/libexec/hermesconnect/hermesconnect-gate` (root, mode 0755). It replaces older lines for the same key and keeps all other lines. Run it again after a gate update. It prints `unchanged` when nothing changed.

Options: `--user NAME`, `--authorized-keys FILE`, `--gate-dest PATH`, `--no-copy-gate`, `--hermes PATH`, `--dry-run`. Run `install.sh --help` for details.

To remove a phone key: `sudo ./install.sh --remove '<key line>'`.

## Verify

Run these commands from a computer that has a test copy of the phone key (`phone_key`). Then remove the test key.

| Test | Command | Expected result |
|---|---|---|
| Gate works | `ssh -i phone_key hermes@<host> ping` | `PONG 1` |
| No login shell | `ssh -i phone_key hermes@<host>` | `ERROR not-allowed`, connection closes |
| No PTY | `ssh -t -i phone_key hermes@<host> ping` | `PTY allocation request failed`, then `PONG 1` |
| No command | `ssh -i phone_key hermes@<host> 'id; bash'` | `ERROR not-allowed` |
| No sftp | `sftp -i phone_key hermes@<host>` | Connection closes |
| No scp | `scp -i phone_key /etc/hosts hermes@<host>:/tmp/` | Fails |
| Loopback forward | `ssh -N -L 9000:127.0.0.1:22 -i phone_key hermes@<host>` and `nc 127.0.0.1 9000` | SSH banner |
| Other forward | `ssh -N -L 9000:example.com:80 -i phone_key hermes@<host>` and `nc 127.0.0.1 9000` | `open failed: administratively prohibited` |
| No reverse forward | `ssh -N -R 9001:127.0.0.1:22 -i phone_key hermes@<host>` | `remote port forwarding failed` |
| No agent | `ssh -A -i phone_key hermes@<host> ping` | `PONG 1` and no agent on the server |
| Serve | `openssl rand -hex 32 \| tr -d '\n' \| ssh -i phone_key hermes@<host> serve` | `PORT <n>` |
| Location | `echo '{"lat":1,"lon":2,"accuracy_m":5,"timestamp":"2026-11-16T12:00:00Z"}' \| ssh -i phone_key hermes@<host> location` | `OK` |

## phone_location plugin

`hermes-plugin/phone_location/` is a Hermes plugin with one tool, `phone_location`. The agent uses it for nearby places, travel and weather. The tool only reads `~/.hermes/hermesconnect/location.json`. It adds no command channel to the phone.

| State of the phone fix | Result |
|---|---|
| 30 minutes old or less | The phone fix: `latitude`, `longitude`, `accuracy_m`, `located_at`, `minutes_ago`, `apple_maps`, `"source": "hermesconnect"`, `"stale": false`. |
| Missing, not valid, older than 30 minutes, or more than 5 minutes in the future (clock skew) | The `findmy_location` result, with `"source": "findmy"` and a `phone_fix` reason. The tool calls the findmy plugin in the same process, only when its `_available()` returns true. |
| Older than 30 minutes, and no Find My result | The old phone fix with `"stale": true` and a `note`. |
| Missing, and no Find My result | An error that tells the owner to turn on location sharing in HermesConnect. |

If the Find My result is older than an old phone fix, the tool returns the phone fix. The tool never raises an exception to Hermes. An unexpected failure gives a tool error with the exception type only. The tool looks for the findmy plugin next to its own folder, then in `$HERMES_HOME/plugins/findmy`, then in `~/.hermes/plugins/findmy`.

Install (do these steps on the server as `root`):

1. Copy the plugin to the server: `scp -r server/hermes-plugin/phone_location root@<host>:/tmp/`.
2. Install the folder: `install -d -o hermes -g hermes -m 0755 ~hermes/.hermes/plugins/phone_location`.
3. Copy the files: `install -o hermes -g hermes -m 0644 /tmp/phone_location/* ~hermes/.hermes/plugins/phone_location/`.
4. Turn on the plugin as the `hermes` user: `hermes plugins enable phone_location`.
5. Make sure that it is on: `hermes plugins list` shows `phone_location`.
6. Restart the Hermes gateway, for example `systemctl restart hermes-gateway-<id>`.
7. Ask the agent "Where am I?". The reply must use the location from the phone or from Find My.

The findmy plugin is optional. Without it, the tool uses the phone fix only. To remove the plugin, run `hermes plugins disable phone_location`, delete the folder, and restart the gateway.

## Tests

`python3 -m unittest discover -s server/tests` runs the gate, install and `phone_location` tests with a fake `hermes` binary, a fake `tools.registry` and a fake findmy plugin. `scripts/test.sh` runs them first.
