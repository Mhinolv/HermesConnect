# HermesConnect product research

## Executive Summary

Research date: 2026-11-16. Scope: one owner, one Hermes host, iOS 26, SSH transport, no app service or account.

Build the secure connection first. Then add text, durable sessions, attachments, voice, reactions, location, and recovery after suspension.
Keep MessageKit 5 for v1. Keep Citadel 0.12.1 behind a transport interface.
Both choices fit the scaffold. Neither provides the complete product.

The owner supplied aggregate counts from 554 messages: about 40 voice memos, 50 images, several PDFs, and 14 location mentions.
These counts support voice and attachments as v1 requirements. They do not measure market demand.
The owner also requires voice replies, tapbacks, slash commands, and cron deliveries.

**Critical limit:** iOS does not allow an indefinite background SSH connection.
The required Keychain protection also prevents unattended authentication after the connection ends.
V1 must recover messages when the owner opens and unlocks the app.
Timely alerts while the app is closed require a push sender, potentially on the owner's existing host.
That is a separate scope decision, not a feature that background refresh can guarantee.

GitHub returned no open issues for `Mhinolv/HermesConnect` on this date. There are no issue numbers to exclude.
The first request failed inside the sandbox. The permitted retry succeeded.
No source code changed. No build, test, smoke check, app launch, or live server connection ran.

## Competitors

Prices are published US prices where available. Store regions, taxes, and subscriptions can differ.
“Unverified” means that this review did not establish the claim. It does not mean that the product lacks the feature.

| Product | Platform and price | Target user and strengths | Limits relative to HermesConnect |
|---|---|---|---|
| iMessage [1] | Apple devices. Included with the OS. | Personal chat. Audio memos, Tapbacks, inline replies, photos, location. | The owner's Hermes bridge rejects location cards. It is not the required direct SSH client. |
| Telegram [2] | iOS, Android, desktop, web. Free core, optional Premium. | Cloud chat and bots. Voice, reactions, large files, replies. | Requires Telegram infrastructure and an account. Normal cloud chats are not end-to-end encrypted. |
| WhatsApp [3] | iOS, Android, desktop, web. Free core. | Personal chat. Voice notes, reactions, files up to 2 GB. | Requires its account and service. No direct Hermes SSH workflow. |
| Signal [4] | iOS, Android, desktop. Free. | Private chat. Encrypted messages, audio, files, replies, reactions. | Requires Signal registration and a bridge for Hermes. |
| ChatGPT [5] | iOS, Android, web, desktop. Free and paid plans. | AI assistant. Text and voice in one conversation. | Hosted assistant and account. Does not replace the owner's Hermes host. |
| Claude [6] | iOS, Android, web, desktop. Free and paid plans. | AI assistant. Text and voice with conversation history. | Hosted assistant and account. No direct Hermes SSH workflow. |
| Blink [7] | iOS and iPadOS. $19.99/year after trial. | Terminal users. SSH, Mosh, SFTP, Files integration. | A terminal does not provide the requested message and voice workflow. |
| Termius [8] | Mobile and desktop. Starter free. Pro $10/month, paid annually. | Host administration. SSH, SFTP, forwarding, optional cloud vault. | Chat and agent media need a separate application. Cloud sync is unnecessary here. |
| Prompt 3 [9] | iPhone, iPad, Mac, visionOS. $9.99/year subscription. | Terminal users. SSH, Mosh, Eternal Terminal, command clips. | No verified native Hermes conversation interface. |
| Hermes HQ [10] | iOS 26 and macOS 26. Free beta. | Hermes owners. Streamed chat, voice, files, sessions, cron, approvals. | Uses gateway access over a network or Tailscale. Closed-app alerts require a host plugin. SSH parity is unverified. |
| Official Hermes Mobile [11] | Mobile beta waitlist. Price unverified. | Hermes owners. Official waitlist confirms current development. | Public feature and security contracts remain unverified. Do not claim that no official mobile app exists. |
| OpenClaw iOS [12] | iOS companion. Price unverified. | OpenClaw owners. Chat, Talk, device capabilities, push infrastructure. | Different agent protocol. Device command access conflicts with our no-reverse-access rule. |

Other leads include Onepilot, Hermex, and Hermes Client. Their full feature and security contracts remain unverified.
Do not base a dependency or security claim on a store description alone.

## Feature Matrix

Y = documented support. N = outside the product's stated workflow. U = unverified. H = requires host or bridge support.
“Alerts” describes a delivery path, not guaranteed delivery latency.

| Product | Direct Hermes SSH | Streamed AI text | Voice | Reactions | Photos/files | Reply/quote | Sessions | Closed-app alerts |
|---|---|---|---|---|---|---|---|---|
| iMessage | N | H | Y | Y | Y | Y | N | Y |
| Telegram | N | H | Y | Y | Y | Y | N | Y |
| WhatsApp | N | H | Y | Y | Y | U | N | Y |
| Signal | N | H | Y | Y | Y | Y | N | Y |
| ChatGPT | N | Y | Y | U | U | U | Y | U |
| Claude | N | Y | Y | U | U | U | Y | U |
| Blink | H | Terminal | N | N | SFTP | N | Terminal | U |
| Termius | H | Terminal | N | N | SFTP | N | Terminal | U |
| Prompt 3 | H | Terminal | N | N | U | N | Terminal | U |
| Hermes HQ | U | Y | Y | U | Y | U | Y | H |
| Official Hermes Mobile | U | U | U | U | U | U | U | U |
| OpenClaw iOS | N | U | Y | U | U | U | Y | H |
| HermesConnect today | N | N | N | N | N | N | N | N |

The matrix combines the cited product pages and support documents. It is not a hands-on benchmark.
Voice conversations and persistent voice memos are different features. HermesConnect needs the latter first.

## Gap Analysis

### Local evidence

The app contains only the placeholder in `HermesConnect/App/HermesConnectApp.swift:13`.
HermesKit contains only a version constant in `Packages/HermesKit/Sources/HermesKit/HermesKit.swift:5`.
A file inventory and source search found no transport, API, chat, model, or store implementation.
Thus, all 14 recommendations address verified app gaps, not missing Hermes server features.
Permission descriptions exist in `project.yml`. They do not implement media or security.
No release or review document was found. `docs/hermes-protocol.md` was absent during this review.

| Capability | Evidence in local reference source | Consequence |
|---|---|---|
| Isolated SSH bootstrap | `.team/ref/apps/desktop/electron/remote-lifecycle.ts:1140` | Preserve the token file and owner nonce protocol. Validate the returned port. |
| Gateway conversation | `.team/ref/apps/shared/src/gateway-contract.openrpc.json:3034` and `:3502` | `prompt.submit` and `session.history` exist. Model receipts and durable row IDs. |
| Session list and resume | Same contract, `:3538` and `:3592` | Resume server sessions instead of creating a new session after each reconnect. |
| Reactions | Same contract, `:2008` and `:51152` | `message.react` and `message.reaction` exist. Do not replace them with guessed sentiment. |
| Uploads | `.team/ref/apps/desktop/src/lib/browser-uploads.ts:144` | The desktop uses `/api/chat/file-upload`. Verify limits and response schema before implementation. |
| Speech input and output | `.team/ref/apps/desktop/src/api/system.ts:189` and `:211` | `/api/audio/transcribe` and `/api/audio/speak` exist. Keep provider secrets on the host. |
| Server file access | `.team/ref/hermes_cli/web_server_files.py:232` | Use the supported file route and authorization. Do not expose arbitrary local paths. |
| Cron | `.team/ref/hermes_cli/web_server_cron.py:244` | The server has cron support. Mobile delivery routing and retention still need contract validation. |

The reference uses HTTP endpoints plus a WebSocket gateway. Do not assume that text replies use HTTP SSE.
The available contract also includes prompt receipts, cancellation, and unknown-delivery resolution.
The API implementation must confirm the server version and exact method schemas before it sends requests.
The reference snapshot is not proof of the deployed server's version.

### MessageKit decision

| Choice | Verified strengths | Work and risks |
|---|---|---|
| MessageKit 5 [13] | Swift 6 migration. Audio, photo, location, custom and link-preview cells. InputBarAccessoryView. | UIKit bridge, incremental text updates, recorder, transfers, and reaction layout remain app work. |
| Exyte Chat [14] | SwiftUI UI. Media picker, audio capture, reply menu, link preview, document and location inputs. | More integrated behavior to adapt. Exact release compatibility with this project remains unverified. |
| Custom SwiftUI list | Full control over views and native materials. No chat package dependency. | The team must build keyboard behavior, scroll position, media cells, accessibility, and incremental updates. |

Recommend MessageKit 5 for v1. Its release explicitly supports Swift 6, and the scaffold already declares it.
The current changelog shows maintenance activity. That does not guarantee fast fixes or an iOS 26 certification.
Keep chat state outside the UIKit controller. Use a small SwiftUI wrapper and main-actor UI updates.
Throttle visual text updates without discarding protocol events.
Use custom cells for files and tapbacks. Link-preview cells still require safe metadata acquisition.
Start with tappable links. Add previews only with explicit privacy and fetch rules.

Before media work, check keyboard insets, Dynamic Type, VoiceOver, dark mode, long replies, and scroll position during updates.
Use native iOS materials in the surrounding controls. MessageKit does not automatically give the app Liquid Glass.
Exyte is the fallback if a focused MessageKit check reveals a blocker. A custom list has the highest initial scope.

### SSH and key choice

Citadel provides command execution, direct-tcpip channels, host key validators, and reconnect options [15].
Use it for v1. Keep one app-owned connection state machine with bounded retries and cancellation.
Do not use `acceptAnything` outside a test fake.
Pin the complete host key after explicit SHA256 fingerprint confirmation. Reject a changed key before authentication.
Only open forward channels to the server's `127.0.0.1`.
Do not accept remote forwards, agent forwards, or device tool requests.

| Option | Assessment |
|---|---|
| Citadel | Best scaffold fit. High-level Swift API over NIOSSH. Integrate strict concurrency through an isolated transport owner. |
| Direct SwiftNIO SSH [16] | More control. Requires more channel, command, and lifecycle code. Useful if Citadel blocks required behavior. |
| libssh2 [17] | C SSH client with broad key support. Requires C interop, packaging, and concurrency adaptation. |
| NMSSH [18] | Objective-C wrapper around libssh2. Adds another layer. Current Swift 6 and iOS 26 fit is unverified. |

The resolved Citadel version is 0.12.1 in `Packages/HermesKit/Package.resolved`.
Its `SSHAuthenticationMethod.swift:51` supports Ed25519. Line 59 supports software P-256. Line 78 exposes a custom authentication delegate.
The resolved NIOSSH source has `NIOSSHPrivateKey(secureEnclaveP256Key:)` at `Keys And Signatures/NIOSSHPrivateKey.swift:55`.
That key advertises `ecdsa-sha2-nistp256`. Citadel needs a custom delegate to use this initializer.
Therefore, Secure Enclave support exists below Citadel, but the complete app path remains untested.

Recommend a device-generated Secure Enclave P-256 key if “never leaves” means no raw private-key extraction.
Store its protected representation with device-only Keychain access and user presence [19]. Export only the public key for server installation.
An imported Ed25519 key can use protected Keychain storage, but authentication reads raw key bytes into app memory.
It cannot meet a literal non-extraction requirement. Main must resolve that wording before the key issue starts.

Keepalives can detect a dead foreground connection. They cannot prevent iOS suspension.
On resume, restore the tunnel, authenticate when needed, and reconcile durable history before any retry.
Do not assume that Citadel reconnect also restores the token, forward channels, WebSocket, or active session.

### Background delivery and hands-free use

Apple grants limited time after an app enters the background [20].
BGAppRefresh runs at system-selected times, not at a requested polling interval [21].
A local notification can describe content already fetched. It cannot discover an unknown server reply.
A fresh SSH connection cannot silently use a key that requires user presence.
Thus, BGAppRefresh plus local notifications is not a reliable closed-app delivery design under the current security rules.

V1 recommendation: keep cron work on the server, recover results on foreground reconnect, and show unread results once.
If a short background window remains, complete an active fetch and issue a permitted local notification.
Do not claim that a scheduled local reminder contains a fresh cron result.
Keep the owner's existing delivery channel until a new closed-app path is approved.

APNs needs a provider that stores device registration and sends notifications [22].
The owner's host could run that provider without an app server of ours.
It still needs APNs credentials, token lifecycle, delivery integration, and a privacy design.
Silent push is discretionary too. Visible push avoids a permanent SSH socket, but does not promise exact delivery.
Defer that host extension from this client-only roadmap.

App Shortcuts can expose an “Ask Hermes” action to Siri and the Action button [23].
Start with a text parameter and an explicit foreground authentication handoff.
Do not promise a locked-phone, hands-free send while user presence is required.
Voice memos should support tap-to-start, stop, review, cancel, and send.

CarPlay communication apps use supported SiriKit intents and Apple's category rules [24].
An App Intent alone does not establish CarPlay support.
Eligibility for this agent client remains unverified. Defer CarPlay until Apple requirements and the authentication flow are resolved.

## Recommended Features

Build order follows dependencies. Each item targets one focused PR. S = small, M = medium.
All files below are proposed paths unless they already exist. `Kit/` means `Packages/HermesKit/Sources/HermesKit/`.
Each PR needs fake-based checks for its failure states. No test may use a real host.

1. **Device key and server profile — P1, M.**
   Problem: the owner cannot establish a trusted identity. Reference: SSH clients.
   Store one host, port, and `hermes` user. Generate a protected key and show its public key.
   Exclude password login and key sync. Resolve Secure Enclave versus Ed25519 first.
   Files: `HermesConnect/Settings/`, `Kit/Transport/KeyStore.swift`, `Kit/Models/ServerProfile.swift`. Depends on: none.

2. **Pinned SSH connection — P1, M.**
   Problem: the app cannot authenticate or detect host substitution. References: Blink, Termius, Prompt.
   Show the first fingerprint, persist approval, refuse changes, and expose clear connection errors.
   Use Citadel through a fakeable interface. Exclude remote and agent forwards.
   Files: `Kit/Transport/SSHTransport.swift`, `Kit/Transport/HostKeyStore.swift`, `HermesConnect/Settings/`. Depends on: 1.

3. **Hermes bootstrap and loopback tunnel — P1, M.**
   Problem: SSH alone does not expose the agent protocol. Reference: Hermes desktop.
   Start or safely reuse the isolated service. Validate its port, token ownership, and readiness.
   Open only the loopback direct-tcpip channel. Never print tokens or terminate an unrelated process.
   Files: `Kit/Transport/HermesBootstrap.swift`, `Kit/Transport/Tunnel.swift`. Depends on: 2.

4. **Gateway conversation client — P1, M.**
   Problem: no typed protocol exists in the app. References: Hermes desktop, Hermes HQ.
   Implement session creation, prompt submission, receipts, text events, completion, and cancellation through the tunnel.
   Confirm version and schema compatibility. Reject unsupported device requests.
   Files: `Kit/API/`, `Kit/Models/Message.swift`, `Kit/Models/Session.swift`. Depends on: 3.

5. **Text conversation screen — P1, M.**
   Problem: the owner cannot chat. References: iMessage, ChatGPT, Claude.
   Bridge MessageKit, show incremental replies, expose stop and failure states, and preserve scroll position.
   Include copy, tappable links, and server-supported slash commands such as `/usage`. Exclude rich link previews.
   Files: `HermesConnect/Chat/`, `HermesConnect/App/HermesConnectApp.swift`. Depends on: 4.

6. **Durable session resume — P1, M.**
   Problem: an app restart loses context. References: Hermes HQ, AI chat apps.
   List server sessions, cache bounded transcripts, and resume by stable session and message IDs.
   Preserve one draft per session. Mark uncertain sends for reconciliation, not blind resend.
   Exclude search, bulk actions, and an automatic outbox.
   Files: `Kit/Store/`, `Kit/API/Sessions.swift`, `HermesConnect/Chat/SessionList.swift`. Depends on: 5.

7. **Photo and file attachments — P1, M.**
   Problem: screenshots and documents cannot reach Hermes. References: iMessage, WhatsApp, Hermes HQ.
   Select photos or files with system pickers. Upload through the tunnel and attach the returned reference to one prompt.
   Show size limits, progress, cancellation, and recoverable failure. Exclude camera capture and a share extension.
   Files: `Kit/API/Attachments.swift`, `Kit/Models/Attachment.swift`, `HermesConnect/Chat/AttachmentPicker.swift`. Depends on: 6.

8. **Voice memo input — P1, M.**
   Problem: the owner often speaks instead of types. References: iMessage, Signal, Hermes HQ.
   Capture, review, cancel, and send a memo. Use host transcription and preserve the memo in the conversation.
   Define upload, transcript, and prompt association before implementation. Exclude continuous voice mode.
   Files: `HermesConnect/Chat/VoiceRecorder.swift`, `Kit/API/Audio.swift`. Depends on: 7.

9. **Voice memo playback and spoken replies — P1, M.**
   Problem: voice input needs a spoken answer. References: ChatGPT, Claude, the owner's existing bridge.
   Play stored memos and host-generated reply audio. Preserve text when speech fails.
   Default to spoken replies for voice-origin prompts. Keep text-origin replies as text.
   Exclude provider credentials on the phone and continuous microphone access.
   Files: `HermesConnect/Chat/AudioPlayer.swift`, `Kit/API/Audio.swift`, `Kit/Models/Message.swift`. Depends on: 8.

10. **Message reactions and agent status — P1, M.**
    Problem: the owner needs brief acknowledgments. References: iMessage, Telegram, Signal.
    Apply server reactions by message ID. Permit set, change, and removal through `message.react`.
    Show work status from real events. Do not invent hearts or completion when the server sends none.
    Preserve the owner's no-tapback behavior for slash commands.
    Files: `Kit/Models/Reaction.swift`, `Kit/API/`, `HermesConnect/Chat/ReactionView.swift`. Depends on: 6.

11. **Received file preview and save — P1, M.**
    Problem: Hermes output files are hard to use. References: iMessage, Signal, Hermes HQ.
    Download authorized attachments through SSH, preview supported files with Quick Look, and save through the system share sheet.
    Bound cache size and validate file metadata. Exclude arbitrary server file browsing.
    Files: `Kit/API/Attachments.swift`, `Kit/Store/AttachmentCache.swift`, `HermesConnect/Chat/FilePreview.swift`. Depends on: 7.

12. **One-time location share — P1, S.**
    Problem: the current iMessage bridge rejects location cards. Reference: iMessage.
    Request location only after a tap. Preview coordinates and an Apple Maps link, then send explicit text that Hermes can read.
    Handle denial and stale fixes. Exclude live tracking and background location.
    Files: `HermesConnect/Chat/LocationShare.swift`, `Kit/Models/Attachment.swift`. Depends on: 5.

13. **Reconnect and missed deliveries — P1, M.**
    Problem: suspension hides replies and cron results. References: Hermes HQ, the owner's current bridge.
    Reconnect on foreground activation. Reconcile receipts and fetch retained replies and supported cron results.
    Mark new results unread once. Show the last sync time and the closed-app alert limitation.
    Validate cron destination and retention before issue acceptance. Exclude APNs and unattended key access.
    Files: `Kit/Transport/ConnectionLifecycle.swift`, `Kit/API/Deliveries.swift`, `Kit/Store/`, `HermesConnect/App/`. Depends on: 6.

14. **Ask Hermes shortcut — P2, S.**
    Problem: the owner needs faster entry to a question. References: voice assistants and Apple App Shortcuts.
    Add an App Intent with a text parameter. Open the chosen session and authenticate before submission.
    Expose the action to Siri and the Action button. Exclude CarPlay and locked-phone authentication bypass.
    Files: `HermesConnect/App/AskHermesIntent.swift`, `HermesConnect/App/`. Depends on: 13.

Deferred: reply/quote, rich link previews, camera capture, share extension, transcript search, automatic outbox, and host-side APNs.
These are useful follow-ups, but the 14 items prioritize the owner's current workflow.
No recommendation creates a new backend service or account.

## Sources

Primary sources accessed on 2026-11-16. Local source paths above are evidence anchors, not public URLs.
Published features are documentation claims. Device behavior remains untested.

1. Apple Messages: https://support.apple.com/guide/iphone/iph2e42d3117/ios and https://support.apple.com/guide/iphone/iph018d3c336/ios
2. Telegram: https://telegram.org/faq and https://telegram.org/faq_premium
3. WhatsApp: https://www.whatsapp.com/messaging
4. Signal: https://signal.org/ and https://signal.org/blog/pdfs/keyboard-shortcuts-pc.pdf
5. ChatGPT: https://help.openai.com/en/articles/20001274-chatgpt-voice
6. Claude: https://support.claude.com/en/articles/11101966-use-voice-mode
7. Blink: https://blink.sh/
8. Termius: https://www.termius.com/pricing
9. Prompt: https://panic.com/prompt/ and https://help.panic.com/prompt/purchase-faq/
10. Hermes HQ: https://gethermeshq.com/ and https://gethermeshq.com/support
11. Official Hermes mobile: https://hermes-agent.nousresearch.com/mobile
12. OpenClaw iOS: https://docs.openclaw.ai/platforms/ios
13. MessageKit: https://github.com/MessageKit/MessageKit and https://github.com/MessageKit/MessageKit/releases and https://github.com/MessageKit/MessageKit/blob/main/CHANGELOG.md
14. Exyte Chat: https://github.com/exyte/Chat
15. Citadel: https://github.com/orlandos-nl/Citadel/blob/main/README.md and https://github.com/orlandos-nl/Citadel/blob/main/_autodocs/types.md
16. NIOSSH: https://github.com/apple/swift-nio-ssh
17. libssh2: https://libssh2.org/
18. NMSSH: https://github.com/NMSSH/NMSSH
19. Keychain access: https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id
20. Background runtime: https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time
21. Background tasks: https://developer.apple.com/videos/play/wwdc2025/227/
22. APNs: https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app
23. Action button: https://developer.apple.com/design/human-interface-guidelines/action-button
24. CarPlay: https://developer.apple.com/carplay/

## Orchestrator Decisions (2026-11-16, override the sections above)

The owner delegated all decisions. These decisions replace conflicting text above. The PM builds issues from the final list below.

| # | Decision |
|---|---|
| D1 | Key: device-generated Secure Enclave P-256 (`ecdsa-sha2-nistp256`), not extractable. Keychain `AfterFirstUnlockThisDeviceOnly`, no per-use user presence, so background location and catch-up can run. App Lock with Face ID on open, on by default. |
| D2 | The phone key is restricted on the server: `restrict,port-forwarding,permitopen="127.0.0.1:*",command="<gate>"`. A gate script in `server/` accepts only `serve` (start or reuse `hermes serve`, token on stdin, print the port), `location` (JSON on stdin) and `ping`. No shell. |
| D3 | Hermes has no reaction API (`docs/hermes-protocol.md`). Agent acks come from turn state: eyes while the turn runs, thumbs up on complete, thumbs down on error, heart when the owner says thanks, none on slash commands. Owner tapbacks stay local in v1. |
| D4 | Owner request: automatic location sharing is critical. The app sends location in the background (significant-change and visits) through the gate `location` command. A server plugin tool `phone_location` reads it and falls back to `findmy_location`. A one-time "Send location" card stays in the composer. Replaces item 12. |
| D5 | Missed deliveries: reconcile on foreground. BGAppRefresh fetches opportunistically and posts local notifications. Host-side APNs is v2. |
| D6 | Voice: record on the phone, `/api/audio/transcribe`, then a voice turn. Voice replies come from `/api/audio/speak`. Text in gives text out. |
| D7 | Reply/quote: no server support. The app quotes the selected message in the prompt text. P2. |
| D8 | Camera capture is part of attachments. The share extension is v2. |

### Final v1 feature list (build order)
1. Device key and server profile (D1) — P1
2. Server gate script and restricted key install (D2) — P1
3. Pinned SSH connection — P1
4. Hermes bootstrap and loopback tunnel through the gate — P1
5. Gateway client (JSON-RPC over WebSocket) — P1
6. Text conversation screen (MessageKit) — P1
7. Session list, resume and local cache — P1
8. Photo, camera and file attachments — P1
9. Voice memo input (D6) — P1
10. Voice reply playback (D6) — P1
11. Tapbacks: agent acks and owner tapbacks (D3) — P1
12. Received file preview and save — P1
13. Background location sharing, app side (D4) — P1
14. `phone_location` Hermes plugin, server side (D4) — P1
15. Reconnect, missed deliveries and local notifications (D5) — P1
16. Ask Hermes App Shortcut — P2
17. Reply to a message by quote (D7) — P2
