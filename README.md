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

## Credits

- [cmux](https://github.com/manaflow-ai/cmux) by manaflow — the terminal Telecmux is a remote for
- [Citadel](https://github.com/orlandos-nl/Citadel) — Swift SSH library
- [SwiftNIO](https://github.com/apple/swift-nio) — networking foundation
