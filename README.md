# Telecmux

An iOS remote for [cmux](https://cmux.com).

Reach into your Mac's panes, see what your AI agents are waiting on, and answer
in one tap from your phone.

## What it does

- Connects to a Mac over SSH and drives cmux through its native CLI
- Lists workspaces, panes, and pending agent notifications
- Streams `read-screen` content per pane (polled, ~1.5s cadence)
- Ribbon soft-keys for one-tap replies to Claude Code prompts (`1` `2` `3` `↵` `esc`)
- Free-text input bar for arbitrary messages
- Voice input via Super Whisper integration
- Workspace switcher (query-only — does not steal cmux's GUI focus)
- iCloud Drive sync of host configuration across devices (planned)

Not a general-purpose terminal emulator. Built for the specific workflow of
running parallel AI coding agents on a Mac and reaching back to them from a
phone when they need input.

## Requirements

- iOS 17+
- A Mac running cmux ≥ 0.64
- SSH access to that Mac (key auth)
- cmux `Settings → Automation → Socket control mode = "Automation mode"` (see `spec.md` §1.5)

`scripts/cmux-probe.sh ssh user@mac` validates the end-to-end path before you
install the app.

## Architecture

| Concern | Choice |
|---|---|
| Language | Swift 6 / SwiftUI |
| SSH | [Citadel](https://github.com/orlandos-nl/Citadel) (SwiftNIO SSH) |
| cmux transport | `ssh` exec channel calling `cmux <subcommand>` over JSON |
| Persistence | JSON in iCloud Drive container, local fallback |
| Key storage | iOS Keychain |

See `spec.md` for the full design.

## Build

```bash
cd Telecmux
xcodebuild -project Telecmux.xcodeproj -scheme Telecmux \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

For device install with your own signing:

```bash
TEAM_ID=<your 10-char Apple Developer Team ID>
DEVICE_ID=$(xcrun xctrace list devices 2>&1 | grep -i iphone | head -1 | grep -oE '\([^)]+\)$' | tr -d '()')

xcodebuild -project Telecmux.xcodeproj -scheme Telecmux \
  -destination "id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=$TEAM_ID \
  PRODUCT_BUNDLE_IDENTIFIER=com.yourname.telecmux \
  build
```

## Voice input

The mic ribbon button opens an in-app sheet that uses `SFSpeechRecognizer`
for live, on-device transcription (no API calls, no API keys). Recognition
language follows the device's current locale.

## Credits & Inspiration

Telecmux's ribbon soft-key UX and the Host/Session two-tier data model are
inspired by **[gotoplanb/Hermit](https://github.com/gotoplanb/Hermit)** — an
iOS SSH client built for the tmux + Claude Code workflow. Telecmux is not a
fork; the codebase was written from scratch and the cmux integration,
workspace board, surface-targeted commands, on-device live transcription,
heuristic line classifier, and wrap-unwrapping logic are original work.

If you live in tmux on a remote dev machine and aren't using cmux, Hermit
is probably what you actually want.

Built on:

- [cmux](https://github.com/manaflow-ai/cmux) by manaflow — the terminal
  Telecmux remotes
- [Citadel](https://github.com/orlandos-nl/Citadel) — Swift SSH library
- [SwiftNIO](https://github.com/apple/swift-nio) — networking foundation
