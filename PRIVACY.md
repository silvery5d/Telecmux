# Privacy Policy for Telecmux

_Last updated: 2026-05-21_

Telecmux does not collect, store, transmit, or share any personal data with
the developer or any third party. There are no servers operated by the
developer, no accounts, and no analytics.

## What stays on your device

- **SSH private keys** are stored in the iOS Keychain and never leave your
  device. They are used only to authenticate your SSH connection to the Mac
  you configure.
- **Host and session configuration** (hostnames, usernames, display names,
  surface references) is stored locally. If you have iCloud Drive enabled, it
  syncs through your own private iCloud account; the developer has no access
  to it.
- **Voice input** is transcribed on-device using Apple's Speech framework.
  Audio is not uploaded anywhere by Telecmux.

## What we don't do

- No analytics, telemetry, crash reporting, tracking, or advertising SDKs.
- No accounts, no sign-in, no developer-operated servers.
- No data leaves your device except the SSH traffic flowing directly between
  your device and the host you configure.

## Network connections

Telecmux connects only to the SSH host(s) you explicitly add. All traffic
goes directly from your device to that host over an encrypted SSH channel,
using key-based authentication.

## Children

Telecmux is a developer tool and is not directed at children.

## Changes

If this policy changes, the updated version will be posted in this file.

## Contact

Questions or concerns: please open an issue at
<https://github.com/silvery5d/Telecmux/issues>.
