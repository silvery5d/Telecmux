# Telecmux — iOS Remote for cmux

iOS client for **[manaflow-ai/cmux](https://github.com/manaflow-ai/cmux)** — a native macOS terminal/orchestrator for AI coding agents. Connects over SSH, drives cmux through its CLI, and surfaces pane content + agent notifications on the phone with one-tap reply.

A legacy tmux mode is preserved for the case where you'd rather attach to a real PTY, but the primary UX is the new **cmux pane / cmux board** modes.

---

## 1. Why this exists

cmux is not a PTY multiplexer you can attach to over SSH. It is a macOS GUI that owns its panes. But it ships a complete `cmux` CLI on top of a Unix-domain socket (`docs/cli-contract.md`), and that CLI is reachable over SSH. So Hermit's existing pieces — soft-key ribbon, voice input, iCloud-synced host config, Citadel SSH — map almost 1:1 onto a cmux-remote workflow if we replace the "attach a PTY" assumption with "call cmux commands and render their output."

Concretely the value is:

- **Notification routing** — cmux already knows which agent is waiting. Telecmux surfaces that on the phone and lets you reply with one tap (`1` / `2` / `3` / `esc`).
- **No terminal emulation cost** — `cmux read-screen` returns the rendered text. No xterm.js needed for the cmux modes.
- **Composable with existing cmux workflows** — cmux's own `cmux ssh` lets you run agents on remote VMs from your Mac; Telecmux is the phone-side companion that talks back to your Mac.

---

## 1.5 Mac-side prerequisites

Telecmux runs nothing on the Mac itself — but for it to reach cmux through SSH, three things must be true:

1. **Remote Login enabled** — System Settings → General → Sharing → Remote Login (command-line equivalents like `systemsetup -setremotelogin on` are not enough on Sequoia+; the UI toggle must also be on).
2. **Public key in `~/.ssh/authorized_keys`** — Telecmux is key-auth only.
3. **cmux Socket control mode = "Automation mode"** (cmux ≥ 0.64) — open cmux.app → ⌘, → Settings → Automation → **Socket control mode** → "Automation mode". **Quit and relaunch cmux** after changing, otherwise the daemon keeps the old mode bound to the socket.

The default `cmuxOnly` mode does a process-ancestry check that only admits processes started *inside* a cmux terminal. SSH-launched cmux CLI is not in that ancestry, so socket writes get rejected with `Broken pipe (errno 32)`. `password` and `allowAll` modes also work — see cmux's own docs/skills/cmux-settings — but `automation` is the right default for Telecmux (same-UID local processes, no extra credential to manage).

`cmux` itself also needs to be on the SSH session's PATH. cmux installs into `/Applications/cmux.app/Contents/Resources/bin/cmux`, which isn't on the default non-interactive shell PATH. Add to `~/.zshenv` (loaded for non-interactive SSH too):

```sh
export PATH="/Applications/cmux.app/Contents/Resources/bin:$PATH"
```

`scripts/cmux-probe.sh ssh user@mac` validates all three preconditions end-to-end.

## 2. Scope

### In scope (v1)
- Connect to a Mac over SSH (Citadel, ed25519/RSA key auth — unchanged from Hermit).
- **cmuxBoard mode** — list workspaces, panes, and notifications; jump to unread.
- **cmuxPane mode** — focus one cmux pane; poll `read-screen`; send keys / text via ribbon.
- **tmux mode** — original Hermit behavior, untouched.
- Ribbon button actions extended with `cmuxSend` / `cmuxKey` / `cmuxJumpUnread`.
- iCloud Drive sync of host/session/ribbon config (unchanged storage layer).

### Out of scope (v1)
- Subscribing to `cmux events` as a long-lived push channel. v1 polls. (v2 owns this — see §9.)
- A bridge daemon on the Mac that exposes cmux over HTTP/WS. (v2.)
- Editing cmux panes' layout from the phone (split, move, close). v1 is read + send keys.
- Browser pane interaction.
- iPad / landscape.

---

## 3. Architecture

```
 iPhone (Telecmux)              Mac
 ┌──────────────────────┐         ┌──────────────────────────┐
 │ SwiftUI Views        │         │ cmux.app                 │
 │ ┌──────────────────┐ │         │ ┌──────────────────────┐ │
 │ │ PaneBoardView    │ │         │ │ Unix socket          │ │
 │ │ PaneFocusView    │ │         │ │ /Users/$U/.cmux/...  │ │
 │ │ TerminalView*    │ │         │ └─────────▲────────────┘ │
 │ └────────┬─────────┘ │         │           │              │
 │          │           │         │ ┌─────────┴────────────┐ │
 │ ┌────────▼─────────┐ │  SSH    │ │ cmux CLI             │ │
 │ │ CmuxController   │─┼────────►│ │ list-panes / send /  │ │
 │ │  (per session)   │ │ exec()  │ │ read-screen / events │ │
 │ └────────┬─────────┘ │         │ └──────────────────────┘ │
 │          │           │         └──────────────────────────┘
 │ ┌────────▼─────────┐ │
 │ │ SSHConnection-   │ │           * preserved for tmux
 │ │ Manager (Citadel)│ │
 │ └──────────────────┘ │
 └──────────────────────┘
```

**Single-connection invariant** — one open SSH session per `SessionMode`. For `cmuxBoard` and `cmuxPane`, `CmuxController` reuses that one session for short-lived `ssh exec("cmux …")` calls. There is no second TCP socket back to cmux from the phone — everything multiplexes over SSH.

---

## 4. Data model (changes from Hermit)

### 4.1 `Session`
```swift
enum SessionMode: String, Codable {
    case tmux        // original behavior
    case cmuxPane    // focused on a single pane
    case cmuxBoard   // workspace/notification overview
    case shell       // raw shell, no multiplexer
}

struct Session: Codable, Identifiable {
    var id: UUID
    var displayName: String
    var hostID: UUID
    var mode: SessionMode               // NEW; defaults to .tmux for migration
    var tmuxSessionName: String?        // used only when mode == .tmux
    var cmuxPaneRef: String?            // used only when mode == .cmuxPane
                                        // e.g. "workspace:2.pane:0" or UUID
    var createdAt: Date
}
```

**Migration**: legacy records with no `mode` decode as `.tmux` if `tmuxSessionName != nil`, else `.shell`.

### 4.2 `ButtonAction`
```swift
enum ButtonAction: Codable {
    case sendString(String)                 // existing — writes to SSH stdin
    case cmuxSend(text: String)             // NEW — `cmux send --pane $REF <text>`
    case cmuxKey(key: String)               // NEW — `cmux send-key --pane $REF <key>`
    case cmuxJumpUnread                     // NEW — `cmux jump-to-unread`
    case voiceInput                         // unchanged
}
```

The `$REF` is resolved at action time from the enclosing `Session.cmuxPaneRef` (or the focused pane in `cmuxBoard`). Buttons stay portable across panes — you don't bake pane IDs into the ribbon.

### 4.3 Ribbon presets (added)

```swift
static let cmuxAgent = RibbonConfig(name: "Cmux Agent", buttons: [
    RibbonButton(label: "1",      labelType: .text,     action: .cmuxSend(text: "1")),
    RibbonButton(label: "2",      labelType: .text,     action: .cmuxSend(text: "2")),
    RibbonButton(label: "3",      labelType: .text,     action: .cmuxSend(text: "3")),
    RibbonButton(label: "return", labelType: .sfSymbol, action: .cmuxKey(key: "Enter")),
    RibbonButton(label: "escape", labelType: .sfSymbol, action: .cmuxKey(key: "Escape")),
    RibbonButton(label: "bell",   labelType: .sfSymbol, action: .cmuxJumpUnread),
    RibbonButton(label: "mic.fill", labelType: .sfSymbol, action: .voiceInput),
])
```

---

## 5. CmuxController contract

One controller per active session. Wraps an `SSHConnectionManager` and exposes typed cmux calls.

```swift
@Observable
final class CmuxController {
    init(ssh: SSHConnectionManager)

    // Inventory
    func listPanes() async throws -> [CmuxPane]
    func tree() async throws -> CmuxTree
    func listNotifications() async throws -> [CmuxNotification]

    // Read
    func readScreen(paneRef: String) async throws -> String

    // Write
    func send(paneRef: String, text: String) async throws
    func sendKey(paneRef: String, key: String) async throws
    func jumpToUnread() async throws

    // Polling
    func startPolling(paneRef: String, interval: TimeInterval, onUpdate: @escaping (String) -> Void)
    func stopPolling()
}

struct CmuxPane: Identifiable, Codable {
    let id: String                          // accepts UUID or ref like "workspace:2.pane:0"
    let workspaceID: String
    let title: String?
    let cwd: String?
    let unreadCount: Int
    let latestNotification: String?
}
```

### 5.1 Command shape

All commands shell out through `SSHClient.executeCommand(...)` (Citadel) — a fresh non-interactive channel per call. The connection itself is kept open by the existing `withPTY` session for backwards compatibility, but cmux calls don't share that PTY.

```
ssh user@mac "cmux --json list-panes"
ssh user@mac "cmux --json tree"
ssh user@mac "cmux --json list-notifications"
ssh user@mac "cmux read-screen --pane <ref>"
ssh user@mac "cmux send --pane <ref> -- <base64-encoded text>"
ssh user@mac "cmux send-key --pane <ref> <key>"
ssh user@mac "cmux jump-to-unread"
```

**Quoting**: `cmux send` text is base64-encoded on the Swift side and decoded on the remote with `echo $B64 | base64 -d | cmux send --pane <ref> --stdin` to avoid every shell-escape footgun for newlines, quotes, and Unicode. (Exact form depends on what cmux's CLI accepts for stdin input — to be confirmed by `cmux-probe.sh` round-trip.)

### 5.2 Polling cadence

- `cmuxBoard`: refresh inventory + notifications every 2s; pause on background.
- `cmuxPane`: refresh `read-screen` every 1.5s; debounce immediately after a `send` (refresh at 0.3s, 0.8s, 1.5s) so the user sees their input echo fast.
- All polls cancel on view disappear.

v2 will replace this with a long-lived `cmux events` stream over a persistent ssh channel.

---

## 6. View map

```
SessionListView
  ├─ tmux row     → TerminalView (existing, xterm.js)
  ├─ cmuxBoard    → PaneBoardView
  ├─ cmuxPane     → PaneFocusView
  └─ shell        → TerminalView
```

### PaneBoardView
- Top: connection indicator + notification count badge.
- Body: `List` of workspaces (section) → panes (rows). Each row shows pane title, cwd, unread badge, latest notification text (truncated 2 lines).
- Tap row → push `PaneFocusView` for that pane.
- Bottom ribbon: minimal — `[bell]` jumps to unread, `[↻]` forces refresh.

### PaneFocusView
- Top 80%: `ScrollView` containing a `Text` of the last `read-screen` snapshot, monospaced, dark theme. Auto-scroll to bottom on update.
- Bottom: ribbon, identical mechanics to original Hermit (multi-page ribbon + snippets + voice still work).
- Pull-to-refresh forces an immediate `read-screen`.
- Long-press a button → quick-edit override for next send (e.g. "send `1` then `Enter`" composer).

### TerminalView (preserved)
- Unchanged behavior when `session.mode == .tmux` or `.shell`.
- A small "switch to cmux board" button in the toolbar if the host has any cmux session — convenience.

---

## 7. Settings additions

```swift
struct AppSettings: Codable {
    var voiceProvider: VoiceProvider              // existing
    var cmuxPollIntervalSeconds: Double = 1.5     // NEW
    var cmuxAutoJumpOnUnread: Bool = false        // NEW — when notification arrives, auto-navigate
}
```

---

## 8. Failure modes & messages

| Failure                              | Surface                                                                 |
|--------------------------------------|-------------------------------------------------------------------------|
| `cmux ping` returns `Broken pipe`    | Daemon is in `cmuxOnly` mode. Banner walks through Settings → Automation → "Automation mode" + quit/relaunch. |
| `cmux ping` returns `socket … not owned by current user` | Same root cause as above; usually seen when someone tried `sudo launchctl asuser`. Same fix. |
| `cmux ping` fails                    | Board shows banner "cmux is not running on $host" with retry button.   |
| `cmux` not on PATH (SSH)             | Banner with one-line fix: add the App bundle bin dir to `~/.zshenv`.   |
| Pane ref no longer exists            | Row greyed out; tapping it offers "remove from session" or "rebind".   |
| SSH transport drops mid-poll         | Existing Hermit reconnect UX; cmux controller pauses until reconnected.|
| `read-screen` returns empty          | Treat as "pane is idle" — don't blank out the buffer; keep last snapshot|

The `scripts/cmux-probe.sh` (see repo root) is the canonical diagnostic the user runs from a Mac when something feels off.

---

## 9. v2 (post-MVP) sketch

- **Push channel**: dedicate one SSH channel to `cmux events` per host. Parse newline-delimited JSON; turn `notification.created` events into local iOS notifications via `UNUserNotificationCenter`.
- **HTTP bridge daemon**: optional small Swift/Go binary on the Mac that wraps the cmux socket as authenticated HTTPS+WS. Removes the SSH dependency, enables true push, and is easier to expose via Tailscale Funnel.
- **Pane management**: `cmux new-pane`, `cmux split-off`, `cmux close-surface` exposed as ribbon actions.
- **Snapshot ANSI rendering**: keep xterm.js around as an opt-in renderer when `read-screen` includes escape sequences worth showing in color.
- **MCP integration**: cmux-mcp already exists; expose a "send to my phone" tool so agents can request human input through Telecmux.

---

## 10. File layout (delta vs. Hermit)

```
Telecmux/
├── scripts/
│   └── cmux-probe.sh                          # NEW — diagnostic
├── spec.md                                    # THIS FILE (replaces original)
└── Hermit/Hermit/
    ├── Models/
    │   ├── Session.swift                      # MODIFIED — adds SessionMode, cmuxPaneRef
    │   └── RibbonConfig.swift                 # MODIFIED — adds cmux* actions + preset
    ├── Cmux/                                  # NEW
    │   ├── CmuxController.swift
    │   ├── CmuxModels.swift                   # Pane, Notification, Tree DTOs
    │   └── CmuxCommand.swift                  # command-string builder + base64 escape
    ├── SSH/
    │   └── SSHConnectionManager.swift         # MODIFIED — adds exec() helper
    └── Views/
        ├── PaneBoardView.swift                # NEW
        ├── PaneFocusView.swift                # NEW
        ├── SessionListView.swift              # MODIFIED — route by mode
        ├── NewSessionView.swift               # MODIFIED — mode picker
        └── TerminalView.swift                 # UNCHANGED for tmux compat
```

---

## 11. Acceptance criteria (MVP)

1. `scripts/cmux-probe.sh ssh user@mac` exits 0 against a Mac with cmux running.
2. Adding a session with `mode = cmuxBoard` and opening it shows the live list of panes within 2s.
3. Tapping a pane opens `PaneFocusView`; `read-screen` content appears within 2s.
4. Pressing the `1` button on the `cmuxAgent` ribbon advances a Claude Code option-menu prompt running in that pane within 2s.
5. With Claude Code "waiting for input" in a pane, the board's unread badge updates within 4s of the underlying cmux notification.
6. All existing Hermit tests still pass (`xcodebuild test`).
7. A legacy `hermit-data.json` from upstream Hermit imports cleanly (tmux session continues to work).
