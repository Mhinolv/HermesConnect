# AGENTS.md — HermesConnect

## Product Overview

HermesConnect is a native iOS app. It connects one owner to their self-hosted Hermes Agent over SSH. It must feel like iMessage.

- Transport: the same path as the Hermes desktop client in `ssh` mode. The app opens SSH to the server as user `hermes`, starts or reuses `hermes serve` on `127.0.0.1`, and forwards a local channel to it. The API reference is `docs/hermes-protocol.md`.
- Core features: text chat with streamed replies, voice memos (record, send, play), tapback reactions, photos and screenshots, files (send, preview, save), links, location share, cron and background deliveries, sessions list.
- One user: the owner. There is no account system and no app server of ours.
- Security comes first: the SSH private key never leaves the device Keychain, the host key is pinned, no secrets in logs, and Hermes never gets access to the phone (no reverse channels).
- Functionality comes before looks. Looks still matter: follow iOS 26 conventions (Liquid Glass, SF Symbols, Dynamic Type, dark mode).

## Architecture Map

| Area | Files |
|---|---|
| App entry, navigation | `HermesConnect/App/` |
| Chat UI (MessageKit, UIKit in SwiftUI) | `HermesConnect/Chat/` |
| Settings, server setup, key management UI | `HermesConnect/Settings/` |
| SSH transport (Citadel) | `Packages/HermesKit/Sources/HermesKit/Transport/` |
| Hermes `serve` API client (HTTP, streaming) | `Packages/HermesKit/Sources/HermesKit/API/` |
| Models (session, message, attachment, reaction) | `Packages/HermesKit/Sources/HermesKit/Models/` |
| Local store (message cache, outbox) | `Packages/HermesKit/Sources/HermesKit/Store/` |
| Package tests (fast, macOS) | `Packages/HermesKit/Tests/HermesKitTests/` |
| App tests (iOS Simulator) | `HermesConnectTests/` |
| Project definition | `project.yml` (XcodeGen). Run `xcodegen generate` after you change it, and commit the regenerated `HermesConnect.xcodeproj`. |
| Hermes reference source (local only, not in git) | `.team/ref/` (server `hermes_cli/web_server*.py`, desktop `apps/desktop/electron`) |

## Build and test

- Build: `scripts/build.sh` (prints `BUILD PASS`).
- Full suite: `scripts/test.sh` (HermesKit `swift test`, then app tests on the iOS Simulator `iPhone 18 Pro`; prints `SUITE PASS`).
- Put logic in HermesKit when you can. Its tests run in seconds on macOS.
- Use fakes for the network, SSH, microphone and file system in tests. No test may connect to a real server.
- Swift 6 strict concurrency. Use `PreviewProvider`, not `#Preview` macros.
- Light CI (owner decision 2026-11-08): PRs run only the `PR template` check. The `CI` workflow runs by hand only. The merge gate is the local full suite.

## Security rules

- Never log or print key material, tokens, the session token file content, or message bodies at info level.
- The SSH key is a Secure Enclave P-256 key made on the device (not extractable). Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no per-use Face ID, so background location and catch-up work. App Lock (Face ID on open) is on by default. See research.md D1.
- Pin the server host key on first connect (show the SHA256 fingerprint). Refuse a changed host key with a clear error.
- Only forward to `127.0.0.1` on the server. Never accept remote forwards or agent forwarding.
- Do not add third-party analytics or crash SDKs.

## Team Roadmap Workflow (multi-agent, GitHub)

A multi-agent team works the release milestone in GitHub (`Mhinolv/HermesConnect`). GitHub Issues are the single source of truth; every change ships as a pull request into `main`. Everyone writes in ASD-STE100 Simplified Technical English with hard length budgets (see the product-team skill, `~/.claude/writing_standard.md`). Roles:

| Role | Responsibility | Output |
|---|---|---|
| Orchestrator | Supervises, prioritizes, creates issue branches, commits/pushes for the engineer, opens PRs, final approver | Merges PRs, closes issues |
| Product Research | Competitor analysis and gap finding | `research.md` |
| Product Manager | Turns gaps/requests into issues (Problem, Scope & Boundaries, Acceptance criteria) | Issues + `**PM review**` comments |
| UI/UX | `## Design notes` section of each issue | Body section + `**UX notes**` comment |
| Engineer | Implements one issue on its linked branch; regression test first for bugs | Changes + `PR BODY` / `COMMIT FILES` blocks |
| QA | Reviews the PR against the issue's acceptance criteria, design notes and owner decisions | Inline review comments + `QA RESULT: PASS/FAIL` PR comment |

Issue flow labels (exactly one at a time): `needs-pm` → `needs-ux` → `ready` → `in-progress` → `in-review` → (`needs-owner-check`) → closed. Also: `bug`/`feature`, `P0`–`P3`, `owner-request`, `redesign`, `blocked`; PR labels `qa-pass`/`qa-fail`.

Rules:
- Issue bodies use the sections `## Problem / Request`, `## Scope & Boundaries`, `## Acceptance criteria`, `## Design notes`, `## Owner decisions`. Edit one section at a time; never drop the others.
- Product-owner decisions are posted as `**Owner decision:** …` comments and mirrored in `## Owner decisions`; they override earlier wording.
- One issue = one branch (`<n>-<slug>`, created with `gh issue develop`) = one PR into `main`. Commits: `#<n>: <summary>`. Stage only the files changed for that issue. Never `git add -A`. Never commit to main.
- PRs must satisfy the PR template (Issue / What changed / How it was tested / Screenshots). `Refs #n` instead of `Closes #n` while the owner still has to check it.
- CI (build + tests) and the PR-template check must be green before merge.
- The Engineer does not commit, push, open PRs or close issues. QA does not modify source. Only the Orchestrator merges PRs and closes issues.
- For this milestone, **QA PASS + green CI + Orchestrator approval replaces the manual user-test gate** (delegated by the product owner), except issues labelled `needs-owner-check`.
- No agent may use browser/Chrome/computer-use/GUI automation tools.
