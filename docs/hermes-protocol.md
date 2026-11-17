# Hermes "ssh" connection protocol (reference for an iOS client)

This document tells an iOS (Swift) client how to do what Hermes Desktop does in `ssh` connection mode.

Source: `.team/ref` (read only). All paths below are relative to `.team/ref/`.

- `hermes_cli/...` is the server (Python). `hermes_cli/web_routers/*` holds the HTTP route handlers.
- `tui_gateway/...` is the JSON-RPC server. `tui_gateway/methods_*.py` holds the handlers. `tui_gateway/contracts/*.py` holds the typed params, results and events.
- `gateway/...` and `agent/...` are parts of the gateway authority and the agent.
- `apps/desktop/electron/...` is the Desktop main process (TypeScript).
- `apps/desktop/src/...` is the Desktop renderer.
- `apps/shared/src/...` is the shared wire contract. `gateway-contract.openrpc.json` is the generated JSON-RPC contract.

Limits of the source:

- The handler code is now in `.team/ref`. Items in this document cite the handler `file:line`.
- Some imported modules are still missing: `hermes_state_sessions` (the list of hidden sources), `hermes_constants`, `hermes_cli/web_upload_limit`, `cron/scheduler_delivery`, `tools/*`.
- Text marked "(inferred)" is a conclusion, not a line that was read. It stays marked until a handler confirms it.

---

## 0. Summary

| Item | Value |
|---|---|
| Transport | SSH exec (bootstrap) + SSH local port forward to `127.0.0.1:<remotePort>` |
| Server | `hermes serve --isolated --host 127.0.0.1 --port 0 ...` (headless FastAPI + uvicorn) |
| REST auth | Header `X-Hermes-Session-Token: <64 hex>` (or `Authorization: Bearer <token>`) |
| WebSocket auth | Query `?token=<64 hex>` on `ws://127.0.0.1:<localPort>/api/ws` |
| Chat protocol | JSON-RPC 2.0 text frames over one WebSocket (`/api/ws`). Not SSE. |
| Stream events | Notification `{"method":"event","params":{"type":"message.delta",...}}` |
| Token lifetime | Life of the server process. Not persisted on the server. |
| Idle exit | Server exits 900 s after the last WebSocket closes and no work runs |
| Live session after a drop | Idle live session is reaped 20 s after its WebSocket closes. The stored row stays. |

---

## 1. SSH bootstrap

### 1.1 Remote file layout

All paths are on the remote host, under the SSH user's home (`$HOME`, not `$HERMES_HOME`).

| Path | Content | Source |
|---|---|---|
| `~/.hermes/desktop-ssh/` | Root of Desktop SSH state (mode 0700) | `gateway_connections_ssh_remote.py:33` |
| `~/.hermes/desktop-ssh/<ownershipId>/` | One folder per client "ownership slot". `ownershipId` = 32 lowercase hex | `:74-91` |
| `.../<ownershipId>/backend.lock.json` | Lock file: which serve process this client owns | `:90-91` |
| `.../<ownershipId>/.connect.lock/` | mkdir mutex for a spawn (holds `owner` = `<shellpid>:<nonce>`) | `:94-95`, `:563-572` |
| `.../<ownershipId>/<nonce>.token` | One-shot session token (64 hex, mode 0600). Server reads it, then deletes it | `:102-103`, `main_dashboard.py:745-829` |
| `.../<ownershipId>/<nonce>.log` | stdout+stderr of the serve process. The client reads the port from it | `:98-99` |

- `nonce` (spawn nonce) = 16 lowercase hex (`secrets.token_hex(8)`). `gateway_connections_ssh_remote.py:80-83`, `:640`.
- Desktop computes `ownershipId = sha256(installationId + "\0" + scope)[:32]`. `apps/desktop/electron/desktop-installation.ts:281-291`.
- An iOS client must use its own `ownershipId` (any stable 32-hex value per device and connection). Do not reuse the Desktop's value, or the two clients will reap each other's server (inferred).

### 1.2 Bootstrap sequence (each step is one SSH `exec`)

Source: `connect()` at `gateway_connections_ssh_remote.py:898-910`, mirrored in `apps/desktop/electron/remote-lifecycle.ts:1535-1700`.

| # | Purpose | Remote command (simplified) | Expected output | Source |
|---|---|---|---|---|
| 1 | Platform gate | `uname -s; uname -m` | `Linux` or `Darwin`, then arch. Other OS: stop | `:149-157` |
| 2 | Hermes home | `echo "${HERMES_HOME:-$HOME/.hermes}"` | Last line = home path | `:160-165` |
| 3 | Update gate | `python3 - <marker> [ '' <hermes> ]` with a Python program on stdin (`REMOTE_MARKER_GATE_PY`) | Last line `CLEAR`. `LIVE:<pid>` or `HELD` = update running, stop | `:168-190` |
| 4 | Find binary | `bash -lc 'command -v hermes'`, then test `[ -x <p> ]` for each candidate | First executable wins | `:201-224` |
| 5 | Version | `<hermes> --version 2>&1` (with a remote timeout) | First line = version text | `:227-232` |
| 6 | Read lock | `if [ ! -e <lock> ]; then exit 0; fi; cat <lock>` | Empty or lock JSON | `read_lockfile` (`:304-310`) |
| 7a | Reuse (lock valid) | see 1.4 | | `:795-829` |
| 7b | Spawn (no reusable lock) | see 1.3 | | `:832-868` |

Binary candidates, in order (`:212-219`):

1. Output of `bash -lc 'command -v hermes'` (last line).
2. `~/.local/bin/hermes`
3. `/usr/local/bin/hermes`
4. `~/.hermes/hermes-agent/venv/bin/hermes`

An explicit "Hermes path" on the connection skips detection. It must be executable (`:203-210`).

Path quoting rule: a path `~/x` is sent as `"$HOME"'/x'` so `$HOME` expands on the remote (`expand_remote_path`, `:121-128`). Single-quote all other words (`shq`, `:106-108`).

### 1.3 Fresh spawn

Source: `spawn_remote_serve` (`:635-664`), `_spawn_payload_prefix` (`:526-542`), `build_spawn_command` (`:545-586`), `_spawn_fresh` (`:832-868`).

1. Check support. Run `help="$( <hermes> serve --help 2>&1 )"` and grep for `ssh-session-token-file` and `ssh-owner-nonce`. If not `YES`, stop with "update-required" (`:235-243`).
2. Mint the session token on the client: 32 random bytes as 64 lowercase hex (`mint_token`, `:65-66`).
3. Upload the token on **stdin**, never in argv. Command: `python3 -c '<_TOKEN_UPLOAD_PY>'` with stdin = the 64-char token, no newline (`:651`, program at `:589-616`). The program:
   - creates the folder with mode 0700 and checks the owner uid,
   - deletes `*.token` files (22-char names) older than 3600 s,
   - creates `<nonce>.token` with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600.
4. Run the update gate again (step 3 of 1.2).
5. Run the spawn command. It runs under the update-marker mutex (`with_remote_update_mutex`, `:508-511`). In plain words it does this:
   - Take the `.connect.lock` mkdir mutex (poll 50 ms, give up after 600 tries, exit 75).
   - If `backend.lock.json` names a live pid: delete the new token file, print `EXISTING`, exit 0.
   - Else start the server detached and print its pid.
   - Write the lock JSON with `"pid":<child>` (atomic `mv`).
6. The detached child command is (`:531-541`):

```sh
ulimit -n 65536 2>/dev/null || true; unset HERMES_DESKTOP_DEV_SERVER; \
exec env HERMES_DESKTOP=1 <hermes> [--profile <name>] serve --isolated --host 127.0.0.1 --port 0 \
  --ssh-session-token-file "$HOME"'/.hermes/desktop-ssh/<ownershipId>/<nonce>.token' \
  --ssh-owner-nonce <nonce> </dev/null >> <log> 2>&1 &
```

   It is wrapped in `setsid` (Linux) or `nohup` (macOS) so it survives the SSH channel (`:281-282`). The last stdout line is the child pid.

   HermesConnect differs here (issue #29). Its gate passes `--port <slot port>`, not `--port 0`. The phone key line has `permitopen="127.0.0.1:<slot port>"`, so the phone can forward to that one port only. See `server/README.md`.

7. Output handling (`:399-405`): last line `EXISTING` = another client owns a live server (needs a reuse token). A positive integer = new pid. Anything else = failure.
8. Write the lock again at once with `port: 0` (spawn in progress) (`:597`).
9. Read the port: poll `cat <log>` every 0.75 s, up to 120 s (`scrape_ready_port`, `:682-698`). Match this regex anywhere in the log (`:32`):

```
(?<!\w)HERMES_(?:BACKEND|DASHBOARD)_READY port=(\d+)
```

   The server prints `HERMES_BACKEND_READY port=<n>` then `HERMES_DASHBOARD_READY port=<n>` on fd 1 (`web_server.py:1299-1301`). If the log shows `Error: Profile '<x>' does not exist.`, the profile is missing (`:671-679`).
10. Open a local forward `127.0.0.1:<localPort>` to remote `127.0.0.1:<remotePort>` (`open_forward`, `:754-763`). Retry with a new local port on "address already in use".
11. Wait for health: `GET /api/health` (public), fallback `GET /api/status` with the token (`apps/desktop/electron/backend-health.ts:79-104`). `/api/health` returns `{ok, version, displayVersion, commit, auth_required}` (`web_routers/status.py:119-130`).
12. Prove ownership: `GET /api/ssh/ownership` with the token (`web_routers/status.py:109-116`). Accept only when the JSON has all of these (`gateway_connections_ssh_remote.py:706-709`):

```json
{ "ok": true, "sshOwnerNonce": "<nonce>", "protocolVersion": 1, "runtimeIntact": true }
```

   `runtimeIntact` may be absent; only `false` fails. A 401/403/404 means "stale". The server answers 404 `SSH ownership is not active` when it has no owner nonce (`status.py:113-114`).
13. Write the final lock with the real port (`:604`).
14. Save the token locally as the "reuse token" for the next connect (`main.ts:9675-9707`).
15. Open the keepalive WebSocket (see 2.4).

Lock file JSON (schema 2). Fields are checked in `parse_lockfile` (`:267-301`):

```json
{
  "schemaVersion": 2,
  "ownershipId": "<32 hex>",
  "spawnNonce": "<16 hex>",
  "pid": 12345,
  "port": 41234,
  "profile": "",
  "hermesPath": "~/.local/bin/hermes",
  "hermesHome": "/home/hermes/.hermes",
  "logPath": "~/.hermes/desktop-ssh/<ownershipId>/<nonce>.log",
  "tokenFingerprint": "<sha256(token) hex, first 32 chars>",
  "protocolVersion": 1,
  "devServer": "",
  "startedAt": "2026-11-16T12:00:00.000Z",
  "creationTime": "linux:123456"
}
```

The lock never holds the raw token. It holds `sha256(token)[:32]` (`fingerprint_token`, `:69-71`).

### 1.4 Reuse an existing server

Source: `_try_reuse` (`:795-829`), `lock_serves_connect` (`:712-716`).

Reuse only when all of these are true:

- `kill -0 <pid>` prints `ALIVE` (`remote_pid_alive`).
- The live argv of `<pid>` contains `serve`, `--isolated`, `--ssh-owner-nonce <spawnNonce>` and the exact token-file path (`pid_is_our_serve`, `:444-458`, script `_OWNED_PY`).
- `lock.port > 0`, the profile, `hermesPath` and `hermesHome` match.
- `lock.tokenFingerprint == sha256(reuseToken)[:32]`. The reuse token is the token you saved after the last connect.

Then forward to `lock.port`, call `GET /api/ssh/ownership` with the saved token, and check the proof (step 12 above). If any check fails, the client runs `cleanup_stale` and spawns fresh.

### 1.5 Shut down

Source: `disconnect_remote` (`:493-505`), `cleanup_stale` (`:477-490`), `_terminate` (`:461-474`).

1. Read the lock. If the pid is alive and provably ours, run `kill <pid>` and poll `kill -0` for up to 5 s.
2. If it still runs, run `kill -9 <pid>` and poll for up to 2 s.
3. Delete the log and `backend.lock.json`.
4. Cancel the forward and close SSH.

If the client does not shut down, the server exits by itself (see 2.3).

### 1.6 Token terms

| Term | What it is |
|---|---|
| Session token (per spawn) | 64 lowercase hex minted by the client. Written to `<nonce>.token`. The server reads it once at start, then deletes the file. After that it lives only in server memory. It is the credential for every REST and WebSocket call. |
| `connection.json` `token` | The same session token, saved by Desktop as the reuse token. It is wrapped: `{"encoding":"safeStorage","value":"<base64 OS-keychain ciphertext>"}` or `{"encoding":"plain","value":"<token>"}`. Source: `apps/desktop/electron/hardening.ts:43,156-198`, `main.ts:8044-8070`, `main.ts:9675-9707`. |
| Owner nonce | 16 hex. In the server argv (`--ssh-owner-nonce`). Not a credential. It proves which spawn a pid is. |

An iOS client cannot decrypt a Desktop `safeStorage` value. Mint your own token and run your own spawn.

Server-side checks on the token file (`main_dashboard.py:745-829`):

- Path must be absolute and under `$HOME/.hermes/desktop-ssh/<32 hex>/<16 hex>.token`.
- The parent folder must be mode 0700 and owned by the user. The file must be a regular file, mode 0600 or tighter, size exactly 64 bytes, content `[0-9a-f]{64}`.
- No symlinks. The file is unlinked after the read.
- `--ssh-owner-nonce` must be `[0-9a-f]{16}` (`main_dashboard.py:1121-1123`).

---

## 2. Authentication and lifetime

### 2.1 HTTP

| Rule | Source |
|---|---|
| Every `/api/*` path needs the token, except the public list (`/api/status`, `/api/health`, others) | `web_server.py:293-296`, `:458-478` |
| Header `X-Hermes-Session-Token: <token>` (preferred) | `web_server.py:227`, `:299-310` |
| Or `Authorization: Bearer <token>` | `web_server.py:309-310` |
| `?token=<token>` works only on `GET /api/files/download` | `web_server.py:318-327`, `web_routers/files.py:813-830` |
| `?ticket=` file tickets come from `POST /api/files/ticket`. That route is 404 on `serve` (`browser_files=False`) | `web_server_surface.py:60-63`, `web_routers/files.py:766` |
| Missing or wrong token: `401 {"detail":"Unauthorized"}` | `web_server.py:477` |
| `Host` header must be `127.0.0.1`, `localhost` or `::1` (any port). Else `400` | `web_server.py:384-401`, `web_server_boundary.py:84-108` |
| Comparison is constant-time (`hmac.compare_digest`) | `web_server.py:307` |

The SSH forward keeps the peer address as loopback on the server, so the loopback rules pass (inferred: `sshd` opens the `direct-tcpip` socket from the remote host itself).

### 2.2 WebSocket

| Rule | Source |
|---|---|
| URL: `ws://127.0.0.1:<localPort>/api/ws?token=<urlencoded token>` | `apps/desktop/electron/connection-config.ts:91-97` |
| The server compares `?token=` with the session token (loopback mode) | `web_server_chat.py:352-363` |
| Peer IP must be loopback on a loopback bind | `web_server_boundary.py:163-183` |
| `Origin`: omit it. If sent with `http(s)`, its host must be loopback and its `host:port` must equal the `Host` header, or the bound port | `web_server_boundary.py:252-285` |
| Do not send the header `X-Hermes-Gateway-Ticket`. A socket with that header is judged by it alone | `web_server_chat.py:252-257` |
| `/api/ws` close codes before accept: 4401 bad credential, 4403 chat disabled or request not allowed | `web_routers/chat_ws.py:102-113`, `:650-653` |
| Other WS routes also use 4408 (peer not allowed) | `web_server_chat.py:447-480` |
| Max frame size: 384 MiB | `web_server_boundary.py:24-26`, `web_server.py:1092` |
| Per-message deflate is on for the SSH-isolated server | `web_server.py:1091` |

Other WS routes that take the same `?token=`: `/api/audio/speak-stream`, `/api/audio/transcribe-stream`, `/api/pty`, `/api/events`, `/api/pub` (`web_server_idle_exit.py:11-13`). The audio routes close with 4401 or 4403 on a bad gate (`web_routers/audio.py:533-540`, `:620-627`).

### 2.3 Lifetime, idle exit and watchdogs

All watchdogs run only for the SSH-isolated server (started with `--ssh-session-token-file`). Source: `web_server.py:1240-1262`.

| Watchdog | Rule | Source |
|---|---|---|
| Idle exit | Counts accepted WebSockets on every route. Exits (code 0) when the count is 0 for `grace` seconds AND no work runs (no turn, queued prompt, delegation or cron job). Default grace 900 s. Config `dashboard.ssh_isolated_idle_grace_s`. Poll every `min(15, grace/4)` s. Unknown work state: stays up | `web_server_idle_exit.py:34-170`, `web_server.py:1241-1246` |
| WS ping (server to client) | Every 60 s, timeout 600 s. Detects a half-open tunnel | `web_server_idle_exit.py:37-38`, `web_server.py:1070-1075` |
| Owner exit | Every 15 s reads `backend.lock.json`. If a valid lock names another `spawnNonce` on 2 polls in a row, and the server is idle, it exits | `web_server_owner_exit.py:24-57`, `web_server_skew_exit.py:48-74` |
| Skew exit | Every 30 s compares the boot code revision with the install on disk. After 2 matching polls, no update in flight, and idle, it exits so the client respawns on new code | `web_server_skew_exit.py:25-97` |
| Graceful stop | SIGTERM, 3 s graceful shutdown | `web_server.py:1093-1097` |

Token lifetime: the session token lives until the process exits. There is no expiry and no refresh (`web_server_session_token.py:1-9`, `web_server.py:233-236`).

### 2.4 Keepalive rule for the client

Desktop keeps one extra WebSocket open to `/api/ws?token=` for as long as it owns the server. It only opens and holds it. Reconnect delay: 2 s, doubling to a 30 s cap (`apps/desktop/electron/ssh-isolated-keepalive.ts:37-139`, started at `main.ts:9640`).

For iOS: your chat WebSocket counts as a client. While it is open, the server does not idle-exit. When iOS suspends the app, the socket closes and the 900 s server grace starts (inferred: iOS closes the socket on suspend). Two clocks then run on the server:

| Clock | Length | Effect | Source |
|---|---|---|---|
| Live-session orphan reap | 20 s (`ws_orphan_reap_grace_s`, env `HERMES_TUI_WS_ORPHAN_REAP_GRACE_S`) | An idle detached live session is closed. Its live `session_id` and replay ring are gone. The stored row stays. | `tui_gateway/server.py:145-152`, `session_lifecycle.py:1012-1023`, `:667-668` |
| Running turn while detached | Re-checked every 20 s | The turn keeps running while it produces output. After 600 s with no activity it is interrupted, then reaped. | `server.py:160`, `session_lifecycle.py:1024-1043` |
| Server idle exit | 900 s | The process exits. The token dies. | 2.3 |

Reconnect within 900 s to keep the same server and token. After that, spawn again.

---

## 3. Chat API (JSON-RPC over `/api/ws`)

### 3.1 Frame format

All frames are UTF-8 JSON text. Source: `apps/shared/src/json-rpc-channel.ts:12-62`, `:455-560`.

| Direction | Shape |
|---|---|
| Client request | `{"jsonrpc":"2.0","id":<int or string>,"method":"<name>","params":{...}}` |
| Server response | `{"jsonrpc":"2.0","id":<same>,"result":{...}}` or `{"...","error":{"code":<int>,"message":"..."}}` |
| Server event | `{"jsonrpc":"2.0","method":"event","params":<GatewayEvent>}` (no `id`) |
| Server-to-client request | `{"jsonrpc":"2.0","id":"<string>","method":"approval","params":{...}}` (method is not `event`) |
| Client answer to it | `{"jsonrpc":"2.0","id":"<same>","result":{...}}` or an `error` (no `method`) |

`GatewayEvent` (`apps/shared/src/gateway-events.ts:57-83`):

```json
{
  "type": "message.delta",
  "session_id": "<live session id>",
  "seq": 42,
  "payload": { "text": "Hel" }
}
```

- `seq` is a per-session counter that the server stamps on every event frame that has a `session_id` (`tui_gateway/event_replay.py:72-96`). Keep the last one for reconnect replay.
- Events with no `session_id` (`sessions.changed`, `cron.changed`, `skin.changed`) get no `seq` and are not replayed (`event_replay.py:79-82`).

Errors:

| Code | Meaning | Source |
|---|---|---|
| `-32700` | Parse error | `tui_gateway/ws.py:701-706` |
| `-32601` | Method not found | `json-rpc-channel.ts:93-97` |
| `-32602` | Invalid params (some handlers) | `methods_session.py:2315` |
| `4000` | Unknown or bad param. All params models are `extra="forbid"` | `tui_gateway/contracts/base.py:18-19`, `:37`, `rpc_dispatch.py:30` |
| `4001` | Session not found (live id unknown) | `methods_prompt.py:1335-1336` |
| `4009` | Session busy (truncation while a turn runs) | `methods_prompt.py:908` |
| `4xxx`, `5xxx` | Handler errors. The message is human text | each handler |

### 3.2 Connection handshake

1. Open the WebSocket.
2. The first server frame is the event `gateway.ready` (`tui_gateway/ws.py:654-661`, contract `contracts/events.py:50-64`):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{
  "skin":{"name":"default"},"change_events":true,"heartbeat":true,"replay_epoch":"<32 hex>"}}}
```

   `session_authority: true` is added only when the app has a session authority (`ws.py:660`, `web_routers/chat_ws.py:665`).
3. Send `client.capabilities` with `{"server_requests": true}`. Without this the server fails every approval or clarify prompt at once (`tui_gateway/methods_voice.py:522-541`). Result: `{"server_requests":["approval","clarify","secret","sudo",...], "declines_not_shown":true, "canonical_clarify_batch":true}`.
4. Send a heartbeat every 15 s. Method `gateway.ping` with any `id`. The WS reader answers it at once with `{"result":{"ok":true}}`, even while a handler blocks (`ws.py:708-712`). Method `ping` also exists and answers `{"pong":true}` (`methods_voice.py:544-548`). Treat 45 s of silence as dead (`json-rpc-channel.ts:175-178`).
5. Read `session_authority`. If `true`, the server speaks the "canonical" wire (see 3.12). If absent, use the legacy methods below. `hermes serve` over SSH with `?token=` is expected to be legacy (inferred: no code in `hermes_cli` sets `app.state.session_authority`; the gateway process sets it).

### 3.3 Session ids

| Id | Meaning |
|---|---|
| `stored_session_id` (stored id) | The database row id (durable). Lists, REST, `session.resume` and `session.delete` use it. |
| `session_id` (live id) | 8-hex runtime id that `session.create` or `session.resume` returns (`methods_session.py:67`). Prompt, attach, interrupt, title and history calls use it. Events carry it. |

A live id dies when the session closes or is reaped. `session.resume` with the stored id always gives a usable live id.

### 3.4 Sessions: list, create, resume, history, title, delete

Every method also takes optional `profile`.

| Purpose | Method | Params | Result | Source |
|---|---|---|---|---|
| List | `session.list` | `{limit? (default 200), include_hidden?, title?}` | `{sessions:[{id, title, preview, started_at, message_count, source, _lineage_root_id, resolved_id?}]}` most recent activity first. No paging. | `methods_session.py:536-560`, `contracts/sessions.py:221-249` |
| Newest | `session.most_recent` | `{}` | `{session_id (stored) or null, title, started_at, source}` | `methods_session.py:563-578` |
| Create | `session.create` | `{source?, cwd?, title?, model?, provider?, messages?, close_on_disconnect? (false), hidden?, idempotency_key?, parent_session_id?}` | `{session_id, stored_session_id, message_count, messages, info}` | `methods_session.py:479-481`, `contracts/sessions.py:118-151` |
| Open stored | `session.resume` | `{session_id:<stored id or exact title>, source?, lazy?, defer_history?, omit_messages?, eager_build?, close_on_disconnect?, inline_images? (true)}` | `LiveSessionSnapshot` (below) | `methods_session.py:1044-1074`, `contracts/sessions.py:173-202` |
| Attach live | `session.activate` | `{session_id:<live>, omit_messages?}` | `LiveSessionSnapshot` | `methods_session.py:1152-1164` |
| History | `session.history` | `{session_id:<live>}` | `{count, messages:[TranscriptMessage]}`. Whole transcript with ancestors and `row_id`. No paging. | `methods_session.py:1978-1997`, `contracts/sessions.py:492-502` |
| Title | `session.title` | `{session_id:<live>, title?}` | Read: `{title, session_key}`. Set: `{title, pending}` (`pending: true` = no row yet) | `methods_session.py:1214-1243`, `contracts/sessions.py:310-321` |
| Delete | `session.delete` | `{session_id:<stored>}` | `{deleted:<stored id>}`. Error 4023 if live here, 4007 if not found | `methods_session.py:1167-1192` |
| Archive | `session.archive` | `{session_id, archived? (true)}` | `{archived, session_key}` | `methods_session.py:1246-1273` |
| Hide | `session.set_hidden` | `{session_id, hidden}` (`hidden` required) | `{hidden, session_key}` | `methods_session.py:1276-1304` |
| Close live | `session.close` | `{session_id:<live>}` | `{closed, messages:[str]}` (stored row stays) | `methods_session.py:2177-2181` |
| Live list | `session.active_list` | `{current_session_id?}` | `{sessions:[{id, session_key, title, status, running?, ...}]}` | `methods_session.py:1138-1149` |

`LiveSessionSnapshot` (`contracts/sessions.py:77-102`): `{session_id (live), stored_session_id?, message_count, messages, info, running?, status?, inflight?, queued?, pending_approval?, open_requests?, todo_state?, messages_omitted?, hydrating?}`. Use `inflight` to rebuild a turn that is still streaming.

`TranscriptMessage` (`contracts/common.py:168-186`): `role, text, content, tool_call_id, timestamp, row_id, display_kind, display_metadata, name, context, args, labels, reasoning`.

Rules:

- `session.create` writes no DB row until the first prompt, unless you send seed `messages` (`methods_session.py:440-460`). A draft you never use leaves no row.
- Do not send `close_on_disconnect: true` from iOS. Such a session is closed at once when the socket drops (`ws.py:745-752`).
- To delete a session that is open, call `session.close` first, then `session.delete`.
- `session.title` needs a live id. To rename a stored row without opening it, use REST `PATCH /api/sessions/{id}` (3.5).
- `session.resume` reuses a session that is already live in this process (`methods_session.py:1060-1063`). Two clients on one stored id share one live session.
- For mobile, send `inline_images: false`. Image parts then render as `[image]` instead of data URIs (`contracts/sessions.py:183-185`).

`source` value: on the legacy wire the server stores your value as is and also uses it as the agent platform (`agent_factory.py:36-43`, `methods_session.py:67`). Desktop sends `"desktop"`. A new value such as `"ios"` works, but the agent may lose platform hints (inferred).

### 3.5 REST endpoints for sessions (paging)

Same port, header `X-Hermes-Session-Token`. Use these for paged lists and paged history.

| Call | Params | Result | Source |
|---|---|---|---|
| `GET /api/sessions` | `limit` (0-100, default 20), `offset`, `min_messages`, `archived=exclude\|only\|include`, `order=created\|recent`, `source`, `sources` (CSV), `exclude_sources` (CSV), `cwd_prefix`, `profile` | `{sessions:[row + is_active, profile, archived, pinned], total, limit, offset, storage}` | `web_routers/sessions.py:182-241` |
| `GET /api/sessions/{id}/messages` | `limit` (max 500), `offset`, `order=oldest\|latest`, `include_compacted`, `inline_images`, `profile` | `{session_id, profile, messages, pagination:{limit, offset, order, returned}}`. No `limit` = the latest 500 rows | `sessions.py:746-790` |
| `GET /api/sessions/{id}/timeline` | `limit` (max 500), `after_row_id` | Prompt metadata + `next_cursor`. Pass `next_cursor` as `after_row_id` | `sessions.py:808-828` |
| `GET /api/sessions/{id}/messages/around` | `row_id`, `limit` (max 120) | One page that starts at a timeline prompt | `sessions.py:830-851` |
| `GET /api/sessions/search?q=` | `sources`, `exclude_sources` | Search hits | `sessions.py:286-460` |
| `GET /api/sessions/{id}` | | One row (cron rows add `scheduler_owned`) | `sessions.py:560-584` |
| `PATCH /api/sessions/{id}` | Body `{title?, archived?, hidden?, pinned?, unread?, profile?, request_id?, expected_revision?}` | Mutation receipt | `sessions.py:933-942` |
| `DELETE /api/sessions/{id}` | `profile?`, `request_id?` | Already-absent is a success | `sessions.py:853-883` |
| `GET /api/profiles/sessions` | `profile=all`, `source`, `exclude_sources` | Rows across profiles | `web_routers/profiles.py:455` |

Paging recipe for history: open the session with `session.resume {..., omit_messages:true}`. Then call `/messages?order=latest&limit=100` for the first page. Call again with a larger `offset` for older pages (inferred: with `order=latest` the offset counts back from the newest row).

### 3.6 Other platforms and cron

| Question | Answer | Source |
|---|---|---|
| Can the client see sessions from other platforms? | Yes. Each row has `source` (`photon` = iMessage, `telegram`, `discord`, `cron`, ...). They are normal stored sessions. | `methods_session.py:110-121`, `web_routers/sessions.py:206-215` |
| Which list shows them? | REST `GET /api/sessions?source=photon` (or `sources=`, `exclude_sources=`). `session.list` has no source filter. It hides the sources in `INTERNAL_LISTING_SOURCES` (kanban, tool, one-shot runs). | `sessions.py:182-215`, `methods_session.py:125-149` |
| Is `cron` hidden from `session.list`? | Not confirmed. The hidden list lives in `hermes_state_sessions`, which is not in `.team/ref`. Desktop asks REST with `exclude_sources=cron` for recents and `source=cron` for the cron section. | `methods_session.py:125`, `sessions.py:206-207` |
| Can iOS open a photon session? | Yes, with `session.resume {session_id:<stored>}` (inferred: a reply from iOS stays in the app and does not go to iMessage). | `methods_session.py:1044` |
| Which session does a cron run use? | Each agent run is its own new session, `source: "cron"`, id `cron_<job_id>_<timestamp>` or `local-*`. Script-only jobs write no session. | `web_routers/cron.py:485-500` |
| Where does a cron result go? | The job field `deliver`: `local` (save only, the default), `origin`, or a platform id with a home channel. | `cron.py:69-74`, `:754-777`, `:909-914` |
| Does `deliver: origin` post into an app session? | Not confirmed. The delivery code (`cron/scheduler_delivery`) is not in `.team/ref`. | |
| How does the client learn about a new cron run? | Event `sessions.changed` (state.db moved, at most one per 2 s) and `cron.changed` (jobs.json moved). Both have payload `{}` and no `session_id`. Then refetch REST. | `change_watcher.py:278-289`, `:378-390`, `contracts/events.py:861-862` |
| After a reconnect? | These events are not replayed. Refetch `GET /api/sessions` and `GET /api/cron/jobs/{id}/runs` on every reconnect. | `event_replay.py:79-82` |

Cron REST: `GET /api/cron/jobs`, `GET /api/cron/jobs/{id}`, `GET /api/cron/jobs/{id}/runs?limit=` (max 100, result `{runs, limit}`), `POST /api/cron/jobs/{id}/trigger`, `GET /api/cron/delivery-targets` (`cron.py:734-810`).

### 3.7 Send a prompt

`prompt.submit` (`methods_prompt.py:820-974`, `contracts/prompt_voice.py:26-83`):

| Param | Use |
|---|---|
| `session_id` | Live id (required) |
| `text` | User text. Put attachment refs first (3.8) |
| `voice_turn` | `true` for a spoken turn. The turn runs on `auxiliary.voice_chat` (`prompt_voice.py:37`, `methods_prompt.py:872`) |
| `queued` | `true` when you drain your own queue. A busy session then queues it |
| `truncate_before_row_id` + `confirm_truncate: true` | Edit or regenerate (3.11) |
| `display_kind: "hidden"` | Send with no user bubble |
| `surface`, `voice_context`, `interrupted`, `title_preview` | Optional hints |

Result: `{status:"streaming"|"queued"|"steered"|"redirected", user_row_id?, admission_id?, survivor_user_row_ids?, survivor_row_id_map?}` (`prompt_voice.py:61-80`). A busy session queues, steers or redirects the prompt. It does not refuse it (`methods_prompt.py:889-913`).

### 3.8 Attachments

Queue images and files first, then call `prompt.submit`. All attach calls take the live `session_id`.

| Method | Params | Result | Cap | Source |
|---|---|---|---|---|
| `image.attach_bytes` | `{session_id, content_base64 (or data), filename?, ext?}` | `{attached:true, path, name, width, height, token_estimate, count, bytes, text}` | 25 MiB decoded | `methods_prompt.py:1028-1056`, `prompt_attachments.py:21` |
| `file.attach` | `{session_id, data_url, name}` (or `path` for a file already on the server) | `{attached, name, path, ref_path, ref_text, uploaded}` | 256 MiB inline | `methods_prompt.py:1117-1137`, `prompt_attachments.py:20`, `:278-316` |
| `pdf.attach` | `{session_id, content_base64, filename, first_page?, last_page?}` | `{attached, filename, pages_attached, pages, count, text}` | 50 MiB, 25 pages. Needs `pdftoppm` (5028) | `methods_prompt.py:1059-1114`, `prompt_attachments.py:22-23` |
| `image.detach` | `{session_id, path}` | `{detached, count}` | | `methods_prompt.py:1140-1152` |

- Image types: `.png .jpg .jpeg .gif .webp .bmp`. The filename extension wins. With no extension, magic bytes decide (`prompt_attachments.py:93-109`).
- Errors: 4015 missing data, 4016 bad type, 4017 bad base64, 4018 over the cap (`prompt_attachments.py:76-90`).
- Queued images go with the next `prompt.submit`. With no caption, Desktop sends `What do you see in this image?` (`apps/desktop/src/app/session/hooks/use-prompt-actions/submit.ts:296-302`).
- `file.attach` writes the file to `<profile home>/attachments/` (or the workspace, if `attachments.storage: workspace`). Put each `ref_text` (an `@file:` ref) at the start of the text, then a blank line, then the user text (`prompt_attachments.py:110-127`, `submit.ts:288-303`).
- The WebSocket frame holds the whole base64 body. The frame cap is 384 MiB (`web_server_boundary.py:24-26`). Base64 adds about 33 percent. Downscale photos on iOS.

### 3.9 Voice

The server has two kinds of voice paths. Only the REST and audio-WS paths work for a remote phone.

| Path | Who has the mic and speaker | Use from iOS | Source |
|---|---|---|---|
| `POST /api/audio/transcribe` | Client sends a recorded clip | Yes | `web_routers/audio.py:89-150` |
| WS `/api/audio/transcribe-stream` | Client streams PCM | Yes | `audio.py:521-600` |
| `POST /api/audio/speak` | Server returns audio bytes | Yes | `audio.py:298-352` |
| WS `/api/audio/speak-stream` | Server streams PCM | Yes | `audio.py:604-...` |
| `voice.record` JSON-RPC | Server host mic (VAD push-to-talk) | No | `methods_voice.py:810-830` |
| `voice.tts` JSON-RPC and voice-mode turn TTS | Server host speaker | No | `methods_voice.py:886-896`, `:172-186`, `prompt_turn.py:248-256` |
| `wake.feed` | Client PCM, wake-word detection only | Not for dictation | `prompt_voice.py:538-552` |

`prompt.submit` does not transcribe audio. An audio file sent with `file.attach` reaches the agent only as an `@file:` ref (no transcription code in `methods_prompt.py` or `prompt_turn.py`).

REST shapes:

| Call | Request | Response | Limits and errors |
|---|---|---|---|
| `POST /api/audio/transcribe?profile=` | `{"data_url":"data:audio/mp4;base64,...","mime_type":"audio/mp4"}` | `{ok:true, transcript, provider}`. Silence gives `transcript: ""` | 25 MiB. MIME must be `audio/*` or `video/webm`. 400 bad payload, 413 too large (`audio.py:45-52`, `:93-115`, `:138-150`) |
| `POST /api/audio/speak?profile=` | `{"text":"..."}` | `{ok:true, data_url:"data:audio/mpeg;base64,...", mime_type, provider}` | MIME from the TTS file: mp3, ogg, opus, wav, flac (`audio.py:54-57`, `:331`) |
| WS `/api/audio/transcribe-stream?token=` | `{"sample_rate":N}` (8000-48000), binary s16le mono PCM, `{"eos":true}` | `{"type":"partial","text"}`, `{"type":"final","transcript","provider"}`, `{"type":"error","message"}` | `error` also means "no live STT". Then use the POST (`audio.py:524-532`) |
| WS `/api/audio/speak-stream?token=` | `{"text":"<delta>"}` many times, `{"done":true}`, or `{"stop":true}` | `{"type":"start","sample_rate":N,"channels":1}`, binary int16 PCM, `{"type":"end"}` or `{"type":"fallback"}` | `fallback` = no audio. Then use the POST (`audio.py:606-622`) |
| `GET /api/audio/voice-config` | | `{ok, stt, tts}`. On `serve` it may hand provider keys to the client (`client_direct_voice=True`) | `audio.py:152-180`, `web_server_surface.py:60-63` |

**Send a voice memo** (steps):

1. Record AAC in an `.m4a` container on iOS.
2. Base64-encode it. Build `data:audio/mp4;base64,<...>`.
3. Send `POST /api/audio/transcribe` with header `X-Hermes-Session-Token`. Body `{"data_url":"...","mime_type":"audio/mp4"}`.
4. If `transcript` is empty, tell the user that no speech was found. Stop.
5. Show the transcript in the composer, or send it at once.
6. Send `prompt.submit {session_id, text:<transcript>, voice_turn:true}`.
7. Optional: to keep the audio, also call `file.attach` with the same data URL. Put its `ref_text` before the transcript.

**Get a voice reply** (steps):

1. Stream the reply as usual. Collect `message.delta` text.
2. Choice A (low latency): open WS `/api/audio/speak-stream?token=T`. Send each delta as `{"text":"..."}`. Send `{"done":true}` after `message.complete`. Play the int16 PCM at the `start` frame's `sample_rate`.
3. If you get `{"type":"fallback"}`, use choice B.
4. Choice B (simple): after `message.complete`, send `POST /api/audio/speak {"text":<payload.text>}`. Decode `data_url` and play it with `AVAudioPlayer`.
5. Strip `MEDIA:` tags and code blocks from the text before TTS (inferred advice).
6. To stop speech, send `{"stop":true}` or close the socket.

The agent can also make an audio file with a TTS tool and name it in a `MEDIA:` tag (inferred: `tools/tts_tool.py` is not in `.team/ref`). Play that file with 5.2.

### 3.10 Streaming events for one turn

Schemas: `tui_gateway/contracts/events.py`.

| Event `type` | Payload | Use | Source |
|---|---|---|---|
| `message.start` | `{turn_id?, text?, display_kind?, display_text?, notification_category?}` | Turn began. Automation turns carry a card | `events.py:135-151` |
| `message.delta` | `{text: string or null, turn_id?, segment?, offset?, rendered?}` | Append `text`. `null` = segment boundary. Drop a chunk with an `offset` you already applied | `events.py:154-178` |
| `message.interim` | `{text, already_streamed, turn_id?, segment?}` | Commentary sealed beside tool calls | `events.py:194` |
| `reasoning.delta`, `reasoning.available`, `thinking.delta` | `{text}` | Reasoning | `events.py:179-181` |
| `tool.generating` | `{name}` | Model is writing tool args | `events.py:442` |
| `tool.start` | `{tool_id, name, args?, args_text?, preview?, context?, labels?}` | Tool call began | `events.py:400-413` |
| `tool.progress` | `{tool_id, name, progress, total?, percent?, message?}` | Progress | `events.py:470` |
| `tool.complete` | `{tool_id, name, args?, duration_s?, result?, summary?, result_text?, inline_diff?, todos?, image_path?}` | Tool call ended | `events.py:416-433` |
| `message.complete` | `{text, status, usage?, reasoning?, warning?, error?, recoverable?, partial?, persisted_turn?, ...}` | Turn ended. `text` is the final text | `events.py:283-305` |
| `error` | `{message}` | Session error outside a turn | `events.py:120` |
| `status.update` | `{kind, text}` | Status line (`compacting`, `loop`, `heartbeat`, `process`, ...) | `events.py:308-315` |
| `session.info` | `SessionLiveInfo` | Model, cwd, `running`, usage | `events.py:526` |
| `session.title` | `{session_id:<stored>, title}` | Auto title | `events.py:357-364` |
| `message.reaction` | `{row_id, reactions:[{emoji, author, at?, seen?}], role}` | Agent reacted | `events.py:740-748` |
| `reaction` | `{kind}` | Affection found in the user text | `events.py:367-373` |
| `notification.show` / `notification.clear` | `{text, level, kind, ttl_ms?, key?, id?, detail?}` / `{key}` | Toast | `events.py:485-506` |
| `background.complete`, `btw.complete` | side-agent answer with `task_id` | `/background`, `/btw` results | `events.py:608-609` |
| `request.cancel` | `{id, method, reason}` | Server withdrew a prompt card | `contracts/server_requests.py:373-388` |
| `approval.cancelled` | `{session_id, stored_session_id, reason, cancelled_count, request_ids}` | Approvals dropped (resolved as deny) | `events.py:560-576` |
| `sessions.changed`, `cron.changed` | `{}` | Refetch lists (3.6) | `events.py:861-862` |

Background "diagnostic" wakes can run a turn with all text events muted (`agent/notification_presentation.py:7-12`, `:20-21`). The client then sees no `message.*` events for that turn.

Example sequence after `prompt.submit` (values are examples):

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s1","seq":10,"payload":{"turn_id":"t1"}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"s1","seq":11,"payload":{"text":"User greets."}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s1","seq":12,"payload":{"text":"Hello","turn_id":"t1","segment":0,"offset":0}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s1","seq":13,"payload":{"text":"! How can I help?","turn_id":"t1","segment":0,"offset":5}}}
{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"s1","seq":14,"payload":{"text":"Hello! How can I help?","status":"complete","usage":{"input":120,"output":9,"total":129}}}}
```

### 3.11 Cancel, steer, approvals, slash commands, reactions, edit

**Cancel and steer**

| Method | Params | Result | Source |
|---|---|---|---|
| `session.interrupt` | `{session_id}` | `{status:"interrupted"|"not_interrupted", interrupted?}`. Also stops TTS | `methods_session_interrupt.py:70-100`, `contracts/sessions.py:605-623` |
| `session.steer` | `{session_id, text}` | `{status:"queued"|"rejected", text}`. `rejected` when idle: send it as a normal prompt | `methods_session_interrupt.py:160-180` |
| `session.redirect` | `{session_id, text}` | `{status:"redirected"|..., text}` | `contracts/sessions.py:643-644` |
| `session.undo` | `{session_id, intent?:"undo"|"retry"}` | `{removed, undo_hint?}` (idle session only) | `methods_session.py:2000`, `contracts/sessions.py:446-462` |

**Approvals** (server-to-client request `approval`, `server.py:704-737`, `contracts/server_requests.py:165-196`):

```json
{"jsonrpc":"2.0","id":"r-17","method":"approval","params":{
  "session_id":"s1","request_id":"a1b2","command":"rm -rf build/","description":"...",
  "choices":["once","session","always","deny"],"tool_name":"terminal",
  "allow_session":true,"allow_permanent":true}}
```

Answer on the same `id`:

```json
{"jsonrpc":"2.0","id":"r-17","result":{"choice":"once"}}
```

- `choice` is one of `params.choices`. `all: true` resolves every pending approval. An error answer is a withdrawal, not a deny (`server.py:717-728`).
- `command` and `description` are redacted on the server (`server.py:651-663`).
- Optional: `approval.received {session_id, request_id}` tells the server the card is on screen, so its timeout clock starts (`methods_prompt.py:1321-1329`).
- Fallback RPC: `approval.respond {session_id, choice, request_id?, all?}` gives `{resolved:<count>}`. `approval.pending {session_id}` gives `{approvals:[...]}` (`methods_prompt.py:1312-1344`).
- When the request ends elsewhere, you get event `request.cancel {id, method, reason}`. Remove that card.

Other server requests (`contracts/server_requests.py`):

| Method | Params | Answer `result` |
|---|---|---|
| `clarify` | `{session_id, questions:[{qid, question, choices?, multi_select}], answers?}` | `{"answers":{"<qid>":"..."}, "outcome":"submitted"}`. No `answers` = cancel all (`:34-60`) |
| `sudo` | `{session_id, command}` | `{"value":"<password>"}` or `""` to decline (`:204-213`) |
| `secret` | `{session_id, env_var, prompt, metadata?}` | `{"value":"..."}` (`:216-223`) |
| any other | | Answer `{"error":{"code":-32601,"message":"not supported"}}` at once |

After a reconnect, `session.resume`, `session.activate` and `session.events.since` return `open_requests:[{id, method, params}]`. Treat each one as a new server request (`server.py:666-680`). `request.answer {id, result}` answers a request by id from any client (`methods_prompt.py:1296-1309`).

**Slash commands**

| Method | Params | Result | Source |
|---|---|---|---|
| `commands.catalog` | `{session_id?, profile?}` | `{pairs:[[cmd, desc]], sub, canon, commands, categories:[{name, pairs}], skills, skill_count, plugin_commands, warning}` | `methods_tools.py:431-442`, `contracts/tools_commands.py:205-249`, `command_discovery.py:206` |
| `complete.slash` | `{text:"/mo", session_id?}` | `{items:[{text, display, meta}], replace_from}` | `methods_complete.py:284`, `contracts/profiles_vault_complete_foreign_subagents.py:50-67` |
| `slash.exec` | `{session_id, command:"/model gpt-x"}` | `{output, warning?}` or a dispatch directive with `type`. Error 4018 = use `command.dispatch` | `methods_tools.py:1029-1060`, `tools_commands.py:303-325` |
| `command.dispatch` | `{name:"skillname", arg?, session_id?}` | `{type:"exec"|"alias"|"plugin"|"send"|"skill"|"prefill", output?, target?, message?, display?, notice?}` | `methods_tools.py:1009-1026`, `tools_commands.py:267-300` |

Slash recipe: call `slash.exec`. If the error code is 4018, call `command.dispatch`. If `type` is `send` or `skill`, send `message` with `prompt.submit` and show `display`. If `type` is `prefill`, put `message` in the composer. If `type` is `exec` or `plugin`, show `output`. Event `skills.changed` means: fetch `commands.catalog` again.

**Reactions, edit, reply-to**

| Feature | Status | Source |
|---|---|---|
| Reaction | Supported. `message.react {session_id, row_id or newest_role:"user"|"assistant", emoji (null clears), author:"user"}` gives `{row_id, reactions}`. One per author. The same emoji again retracts | `methods_session.py:1307-1336`, `contracts/billing_delegation_pets.py:489-504` |
| Agent reaction | Event `message.reaction` | `events.py:740-748` |
| Ack / read receipt | None. There is no ack method for messages. `approval.received` is only for approval cards | search of `tui_gateway/contracts` |
| Edit a sent message | Done as rewind: `prompt.submit` with `truncate_before_row_id` and `confirm_truncate: true`. Busy session: 4009, interrupt then retry | `prompt_voice.py:26-48`, `methods_prompt.py:900-908` |
| Reply-to / quote | None. No param in any contract | search of `tui_gateway/contracts` for `reply_to`, `quote` |

### 3.12 Canonical wire (only when `gateway.ready.session_authority` is `true`)

Schemas: `tui_gateway/contracts/canonical*.py`. Differences from legacy (`apps/shared/src/gateway-canonical.ts:25-112`):

- `session.create` needs `source` (one of `cli, tui, gui, acp, tool, oneshot`) and a `request_id` (UUID).
- `prompt.submit` takes `{session_id, text, input_id, attachments?}` and returns an `AdmissionStatus` `{admission_id, status, ...}`.
- `session.resume` takes `display_projection: true`. The result has `display_messages` (use these) and `messages` (stored rows).
- `session.interrupt` needs `execution_generation` (from the snapshot).
- `prompt.cancel {session_id, admission_id}` retires a queued prompt (`contracts/canonical.py:68`).
- Approvals arrive as events `approval.request` / `clarify.request` with `prompt_id`. Answer with `approval.respond` / `clarify.respond` (`contracts/canonical.py:399`).

iOS v1 does not need the canonical wire for `hermes serve` over SSH (see 3.2 step 5).

---

## 4. Reconnect and event replay

### 4.1 How replay works

| Fact | Value | Source |
|---|---|---|
| Counter | `seq` per live `session_id`, starts at 1, stamped on every event frame | `event_replay.py:72-96` |
| Epoch | `replay_epoch` = random 32 hex per server process. A new epoch = new numbering | `event_replay.py:24-26`, `ws.py:659` |
| Ring size | Last 512 events and 4 MiB per session, 64 sessions, 64 MiB in total. Oldest first out | `event_replay.py:28-37` |
| Session-less events | Not kept | `event_replay.py:79-82` |
| Session closed or reaped | Ring freed. Numbering stays. Any older watermark reads as `truncated` | `event_replay.py:125-148` |
| Events while detached | Stamped and kept in the ring. The turn keeps running | `event_replay.py:1-13`, `session_lifecycle.py:1024-1028` |

`session.events.since` (`methods_session.py:2309-2323`, `contracts/sessions.py:716-743`):

- Params: `{session_id:<live>, last_seen:<int>, replay_epoch?}`. `replay_epoch` is accepted and ignored.
- Result: `{events:[GatewayEvent], latest_seq, truncated, count, epoch, open_requests}`.
- `events` are the `params` objects of the event frames, with `seq`. Feed them to the same handler as live events.
- `truncated: true` means some events between `last_seen` and the oldest kept event were lost. Reload state.

### 4.2 Reconnect steps for a suspended phone

1. Reopen `/api/ws?token=T`. If the socket gets HTTP 401 or close 4401, the server restarted: spawn again (1.3).
2. Wait for `gateway.ready`. Send `client.capabilities {server_requests:true}`.
3. If `replay_epoch` changed, the server process changed. Drop all `seq` watermarks and live ids. Go to step 6.
4. For each open chat, call `session.activate {session_id:<live>, omit_messages:true}`. This rebinds the live session to the new socket.
5. If `session.activate` succeeds, call `session.events.since {session_id, last_seen}`. Apply `events` in order. Handle `open_requests`. If `truncated` is `true`, go to step 6. Stop here.
6. If `session.activate` fails (the live id was reaped, usually after 20 s idle), call `session.resume {session_id:<stored>, inline_images:false}`. Use the new live id and the snapshot `messages`. Use `inflight` for a turn still running. Set the watermark to 0 for the new live id.
7. Refetch the session list (`GET /api/sessions`) and cron runs. `sessions.changed` and `cron.changed` are not replayed.

`session.resume` with a stored id also reattaches a session that is still live (`methods_session.py:1060-1063`). A client may skip step 4 and always use step 6. It then gets a full snapshot each time.

### 4.3 What the client misses while the socket is closed

- Nothing is pushed. The server has no APNs or other push path (inferred: no push code in `hermes_cli`, `tui_gateway`, `gateway`, `apps/shared` or `apps/desktop/electron`).
- A turn started before the drop finishes on the server and is saved. Read it with `session.resume` or `/messages` after the reconnect.
- An approval asked while the socket was closed stays open until its timeout. It comes back in `open_requests` (`server.py:666-680`).

---

## 5. Agent-produced files and images

### 5.1 How they appear in events

| Form | Where | Source |
|---|---|---|
| `MEDIA:<path>` tag in reply text | `message.delta`, `message.complete.text`, history `text`. The path is a file on the server host | `apps/desktop/src/lib/chat-messages/parts.ts:195-300` |
| `image_path` | `tool.complete.payload.image_path`: an image that a tool made or looked at | `tool_progress.py:357-359`, `contracts/events.py:431` |
| Image parts in history | `session.resume` with `inline_images: true` returns data URIs. With `false` they show as `[image]` | `contracts/sessions.py:183-185` |

`MEDIA:` forms: `MEDIA:/abs/path.png`, `MEDIA:"/path with spaces.pdf"`, `` MEDIA:`/x.mp3` ``. A bare path loses trailing `.,;:!?`. A value needs a `/`, `\` or a file extension (Desktop parser). The server does not parse `MEDIA:` tags in the code in `.team/ref`. The agent writes them in plain text.

### 5.2 Download routes

All need the token header unless noted. `session_id` on these routes is the **stored** id (`web_routers/files.py:1171-1176`).

| Need | Request | Limit | Source |
|---|---|---|---|
| Save any file | `GET /api/fs/download?path=<urlencoded>&session_id=<stored>&profile=` | No size cap. `Content-Disposition: attachment` | `files.py:1356-1380` |
| Small file as data URL | `GET /api/fs/read-data-url?path=&session_id=` gives `{dataUrl}`. Sends `ETag`. Answer 304 on `If-None-Match` | `WEBAPP_ATTACHMENT_MAX_BYTES` (16 MiB, inferred: value is in `hermes_constants`). 413 if larger | `files.py:1197-1230`, `web_server.py:662` |
| Image as data URL | `GET /api/media?path=` gives `{data_url}`. Only under `<home>/images`, `screenshots`, `cache`. Types png, jpg, gif, webp, svg, bmp, ico | 25 MiB. 403 outside roots, 415 bad type | `files.py:62-66`, `:405-448` |
| Audio or video | `GET` or `HEAD /api/files/stream?path=&session_id=&profile=` with `Range: bytes=a-b` | No size cap. Types avi, flac, m4a, mkv, mov, mp3, mp4, ogg, opus, wav, webm. Else 415 | `files.py:68-70`, `:833-859` |
| Managed file as data URL | `GET /api/files/read?path=` | 100 MiB | `files.py:673-688`, `web_server.py:661` |
| Link with token in URL | `GET /api/files/download?path=&token=T` | 100 MiB (media subresource: no cap) | `files.py:813-830`, `web_server.py:318-327` |

- `/api/files/stream` answers `200` (whole file) or `206` with `Content-Range`, `Accept-Ranges: bytes`, `Content-Disposition: inline`. A bad range gives `416` (`web_server_remote_media.py:62-82`).
- `/api/files/stream` never takes the token in the URL. Use the header (`files.py:838-841`).
- File tickets (`POST /api/files/ticket`) are off on `serve` (404). Ticket TTL elsewhere: download 60 s, stream 1 h (`web_server_file_tickets.py:39-50`, `web_server_surface.py:60-63`).
- Paths with `session_id` resolve in that session's workspace or sandbox (`files.py:1145-1168`). Sensitive paths give 403 (`files.py:655-656`).
- Do not follow 3xx on downloads (`apps/desktop/electron/gateway-download-transport.ts:39-43`).
- Prefer the header form. A URL with `?token=` can leak into logs (`web_server.py:313-318`).

---

## 6. Other features

| Feature | Status | Source |
|---|---|---|
| Notifications | `notification.show` / `notification.clear` events over the open WebSocket only | `contracts/events.py:485-506` |
| Push (APNs) | None (inferred, see 4.3) | |
| Automation turns | `message.start.notification_category` and `display_kind` mark them | `contracts/events.py:133-151` |
| Side agents | `prompt.background {session_id, text}` and `prompt.btw` give `{task_id}`. The answer comes as `background.complete` / `btw.complete` | `contracts/prompt_voice.py:236-251` |
| Handoff to a platform | `handoff.request {session_id, platform}`, then poll `handoff.state` | `methods_session.py:1373-1420` |
| Foreign history | `session.foreign.list` / `preview` / `import` browse other tools' session folders. Not chat platforms | `methods_session_foreign.py:9-41` |

---

## 7. Minimum viable request sequence

Placeholders: `T` = 64-hex token, `N` = 16-hex nonce, `O` = 32-hex ownership id, `L` = local port, `R` = remote port, `S` = live id, `K` = stored id.

### 7.1 Connect

1. SSH to `hermes@host` with the key.
2. `uname -s; uname -m`. Expect `Linux` or `Darwin`.
3. `echo "${HERMES_HOME:-$HOME/.hermes}"`.
4. Find `hermes` (1.2 step 4). Call it `H`.
5. Read `~/.hermes/desktop-ssh/O/backend.lock.json`.
6. If the lock is reusable with your saved token (1.4): forward `L -> 127.0.0.1:lock.port`, check `GET /api/ssh/ownership`, and go to step 12.
7. Else: if a lock exists and its pid is provably yours, stop that pid. Remove the lock.
8. Mint `T` and `N`. Upload `T` on stdin to `~/.hermes/desktop-ssh/O/N.token` (1.3 step 3).
9. Run the spawn command (1.3 steps 5-6). Read the pid.
10. Poll `cat ~/.hermes/desktop-ssh/O/N.log` for `HERMES_BACKEND_READY port=R`.
11. Forward `127.0.0.1:L -> 127.0.0.1:R`. Poll `GET http://127.0.0.1:L/api/health`. Check `GET /api/ssh/ownership` with header `X-Hermes-Session-Token: T`. Write the lock with `port: R`. Save `T` in the iOS Keychain.
12. Open `ws://127.0.0.1:L/api/ws?token=T`. Wait for `gateway.ready`.
13. Send:

```json
{"jsonrpc":"2.0","id":1,"method":"client.capabilities","params":{"server_requests":true}}
```

### 7.2 Open the newest session

```json
{"jsonrpc":"2.0","id":2,"method":"session.most_recent","params":{}}
```

Result: `{"session_id":"20261116_101500_ab12cd","title":"","started_at":1763288100.0,"source":"desktop"}`. If `session_id` is `null`, call `session.create` instead.

```json
{"jsonrpc":"2.0","id":3,"method":"session.resume","params":{"session_id":"20261116_101500_ab12cd","source":"desktop","inline_images":false}}
```

Result: `{"session_id":"3f9a1c2e","stored_session_id":"20261116_101500_ab12cd","messages":[...],"info":{...},"running":false}`. Use the live id as `S`. Render `messages`.

### 7.3 Send "hello" and stream the reply

```json
{"jsonrpc":"2.0","id":4,"method":"prompt.submit","params":{"session_id":"S","text":"hello"}}
```

Result: `{"status":"streaming","user_row_id":118}`. Then read `event` frames for `session_id` `S`:

- Append `message.delta.payload.text` (skip `null`).
- Show `reasoning.delta` and `tool.*` as side content.
- Stop on `message.complete`. Replace the bubble with `payload.text`. Check `payload.status`.
- Answer any `approval` request (3.11).
- To stop: `{"jsonrpc":"2.0","id":5,"method":"session.interrupt","params":{"session_id":"S"}}`.

### 7.4 Upload a photo with a caption

```json
{"jsonrpc":"2.0","id":6,"method":"image.attach_bytes","params":{"session_id":"S","content_base64":"/9j/4AAQ...","filename":"IMG_0001.jpg"}}
```

Wait for `{"attached":true,...}`. Then:

```json
{"jsonrpc":"2.0","id":7,"method":"prompt.submit","params":{"session_id":"S","text":"What breed is this dog?"}}
```

### 7.5 Download an agent-produced file

1. Find `MEDIA:/home/hermes/.hermes/outputs/report.pdf` in `message.complete.payload.text` (or `tool.complete.payload.image_path`).
2. Request:

```
GET /api/fs/download?path=%2Fhome%2Fhermes%2F.hermes%2Foutputs%2Freport.pdf&session_id=K HTTP/1.1
Host: 127.0.0.1:L
X-Hermes-Session-Token: T
```

3. For audio or video playback, use `GET /api/files/stream?path=...` with a `Range` header. `AVPlayer` cannot add custom headers easily, so use `AVAssetResourceLoaderDelegate` or download first (inferred advice).

### 7.6 Disconnect

Close the WebSocket. Optional: stop the server (1.5). If you do not, it exits after 900 s with no client.

---

## 8. Minimum client for iOS v1

Use these calls in this order. Everything else is optional for v1.

| # | Step | Call | Section |
|---|---|---|---|
| 1 | Bootstrap SSH and spawn or reuse | SSH exec steps, `GET /api/health`, `GET /api/ssh/ownership` | 1.2-1.4 |
| 2 | Open the chat socket | WS `/api/ws?token=T`, wait for `gateway.ready` | 3.2 |
| 3 | Answer server requests | `client.capabilities {server_requests:true}` | 3.2 |
| 4 | Heartbeat every 15 s | `gateway.ping` | 3.2 |
| 5 | Show the session list | `GET /api/sessions?order=recent&limit=40&offset=0` (add `source=` or `exclude_sources=cron` as needed) | 3.5 |
| 6 | Open a session | `session.resume {session_id:K, source, inline_images:false, omit_messages:true}` | 3.4 |
| 7 | Load history pages | `GET /api/sessions/K/messages?order=latest&limit=100&offset=` | 3.5 |
| 8 | New chat | `session.create {source}` | 3.4 |
| 9 | Attach a photo | `image.attach_bytes` | 3.8 |
| 10 | Attach a file | `file.attach {data_url, name}`, put `ref_text` first in the text | 3.8 |
| 11 | Send | `prompt.submit {session_id:S, text}` | 3.7 |
| 12 | Stream | events `message.start`, `message.delta`, `tool.start`, `tool.complete`, `message.complete`, `error` | 3.10 |
| 13 | Stop | `session.interrupt {session_id:S}` | 3.11 |
| 14 | Approve | answer server request `approval` with `{choice}`, clear on `request.cancel` | 3.11 |
| 15 | Clarify, sudo, secret | answer `clarify`, `sudo`, `secret`. Answer `-32601` to other methods | 3.11 |
| 16 | Voice memo | `POST /api/audio/transcribe`, then `prompt.submit {voice_turn:true}` | 3.9 |
| 17 | Voice reply | `POST /api/audio/speak` (or WS `/api/audio/speak-stream`) | 3.9 |
| 18 | Agent files | `GET /api/fs/download`, `GET /api/files/stream`, `GET /api/fs/read-data-url` | 5.2 |
| 19 | Title and list refresh | event `session.title`, event `sessions.changed`, then step 5 | 3.10 |
| 20 | Rename, delete | `PATCH /api/sessions/K {title}`, `session.close` then `session.delete {session_id:K}` | 3.4, 3.5 |
| 21 | Reconnect after suspend | `session.activate` + `session.events.since`, else `session.resume` | 4.2 |

Optional for v1: `message.react`, `session.steer`, `commands.catalog` + `slash.exec` + `command.dispatch`, `pdf.attach`, cron REST, the streaming audio sockets.

---

## 9. iOS notes (inferred)

- Use an SSH library with exec channels and `direct-tcpip` forwarding (for example SwiftNIO SSH or Citadel). Desktop uses OpenSSH ControlMaster with `ServerAliveInterval=15` and `ServerAliveCountMax=3` (`apps/desktop/electron/ssh-connection.ts:235-270`). iOS has no ControlMaster.
- `URLSessionWebSocketTask` can connect to `ws://127.0.0.1:L` through a local listener. A direct in-process channel bridge avoids the listener.
- Set `Host: 127.0.0.1:<port>`. Do not set `Origin`.
- iOS suspends sockets in the background. Plan for the reconnect in 4.2, and a respawn after the 900 s grace.
- Keep the stored id `K` for each chat. A live id `S` does not survive a 20 s idle drop.
