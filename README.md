# HermesConnect

A native iOS client for a self-hosted [Hermes Agent](https://github.com/NousResearch/hermes-agent). It talks to the agent over SSH, the same way the Hermes desktop client does, with an iMessage-style chat: voice memos, tapbacks, photos, files, links and location.

## Requirements
- Xcode 27, iOS 26 SDK, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- A Hermes server you can reach over SSH

## Build
```sh
xcodegen generate
scripts/build.sh
scripts/test.sh
```

## Security
The SSH key stays in the device Keychain. The server host key is pinned. The app only forwards to `127.0.0.1` on the server. See `AGENTS.md`.

## Install on your iPhone

1. Sign in once at Xcode > Settings > Accounts with the Apple ID of team `V8X3GYRTNK`.
2. Connect the iPhone, unlock it and trust this Mac.
3. Run `scripts/device.sh`.

The script installs over the old app, so permissions, the pinned host key and the device SSH key stay. If you delete the app, iOS removes them, and you must do the setup again. Keep the team and the bundle ID the same, or the app cannot read its old Keychain items.
