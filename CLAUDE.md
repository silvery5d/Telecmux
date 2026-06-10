# CLAUDE.md

## Project Overview

**Telecmux** is an iOS remote for [cmux](https://cmux.com). It connects to a
Mac running cmux over SSH, calls the `cmux` CLI to mirror pane content, list
notifications, and send keystrokes from soft-keys / a text input bar.

It is **not** a general-purpose terminal emulator. The whole point is the
narrow workflow of reaching back to AI coding agents (Claude Code, etc.)
running on a Mac and answering their prompts from a phone.

## Build & Deploy

```bash
# 1. Check if iPhone is connected
xcrun xctrace list devices 2>&1 | grep -i iphone

# 2a. Connected — build, install, launch
cd Telecmux
DEVICE_ID="<paste from above>"
TEAM_ID="<your Apple Developer Team ID, 10 chars>"
xcodebuild -project Telecmux.xcodeproj -scheme Telecmux \
  -destination "id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=$TEAM_ID \
  build
# IMPORTANT: verify the bundle id before installing. A stale DerivedData
# dir from before the com.diwu.telecmux -> com.telecmux.app rename once made
# `Telecmux-*` glob/head -1 grab an old .app and resurrect a deleted bundle.
APP=$(find ~/Library/Developer/Xcode/DerivedData/Telecmux-* -name "Telecmux.app" -path "*Debug-iphoneos*" | head -1)
defaults read "$APP/Info.plist" CFBundleIdentifier   # must print com.telecmux.app
xcrun devicectl device install app --device $DEVICE_ID "$APP"
xcrun devicectl device process launch --device $DEVICE_ID com.telecmux.app

# 2b. Simulator
xcodebuild -project Telecmux.xcodeproj -scheme Telecmux \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Mac-side prerequisites for SSH transport

1. System Settings → General → Sharing → **Remote Login** on
2. SSH key in `~/.ssh/authorized_keys`
3. cmux on PATH for non-interactive shell — add to `~/.zshenv`:
   ```sh
   export PATH="/Applications/cmux.app/Contents/Resources/bin:$PATH"
   ```
4. cmux Settings → Automation → **Socket control mode = "Automation mode"**
   (default `cmuxOnly` rejects connections from outside the cmux process tree)

`scripts/cmux-probe.sh ssh user@mac` validates all four.

## Test

```bash
cd Telecmux
xcodebuild test -project Telecmux.xcodeproj -scheme Telecmux \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Tests use Swift Testing (`@Test`, `@Suite`, `#expect`).

## Key Architecture

- **iOS 17+**, portrait only, dark mode enforced
- **SSH**: Citadel (SwiftNIO SSH), ed25519 / RSA key auth
- **cmux transport**: short-lived `ssh exec("cmux <subcommand>")` calls — no
  long-lived PTY. Polling cadence 1.5s for pane content, 2s for board.
- **Data persistence**: JSON in iCloud Drive container (`telecmux-data.json`),
  local fallback when iCloud unavailable
- **Private keys**: iOS Keychain via `KeychainManager`, never exported
- **Plain-text screen render**: `cmux read-screen` returns ANSI-consumed text,
  so we use a heuristic colorizer (`CmuxScreenHighlighter`) for Claude's
  typical token shapes. Upstream issue:
  https://github.com/manaflow-ai/cmux/issues/4273

## File Layout

```
Telecmux/Telecmux/
├── App/TelecmuxApp.swift        # @main, URL handling
├── Models/                      # Host, Session, RibbonConfig, AppSettings
├── Storage/                     # DataStore (iCloud + local), KeychainManager
├── SSH/SSHConnectionManager.swift  # Citadel-backed exec channel
├── Cmux/                        # CmuxModels, CmuxCommand, CmuxController, CmuxScreenHighlighter
├── Voice/                       # Super Whisper integration
└── Views/                       # SessionList, NewSession/Host, PaneBoard, PaneFocus, etc.
```

## Conventions

- SwiftUI views use `@Environment` for `DataStore` and `VoiceInputCoordinator`
  (both `@Observable`)
- Models are plain `Codable` structs; `Session` and `Host` hand-write
  `init(from:)` for legacy-field migration
- JSON via `JSONEncoder.telecmux` / `JSONDecoder.telecmux` (ISO 8601 dates)
- Adding new source files: pbxproj must be edited by hand (no SPM package)

## Known Gotchas

- `PRODUCT_NAME` in pbxproj must be `$(TARGET_NAME)`, not empty
- `UILaunchScreen` dict must exist in `Info.plist`
- cmux Socket control mode resets to `cmuxOnly` on some cmux updates — banner
  in `PaneBoardView` walks the user through the fix
