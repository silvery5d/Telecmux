import Foundation

/// Builds remote shell command strings that invoke the `cmux` 0.64.x CLI.
///
/// Discovery notes:
/// - The real read/write unit in cmux is `--surface`, not `--pane`. Panes are
///   layout containers; each pane owns one or more surfaces (terminals).
/// - `cmux send` already understands `\n` and `\r` as Enter, so we don't need
///   a separate send-key call after each text send.
/// - `--id-format` is in the CLI docs but not implemented in 0.64.3.
///   list-panes returns ref form ("surface:34"); notifications return UUIDs.
///   Either form is accepted by `--surface`, so we pass through whatever the
///   caller has on hand.
///
/// Quoting: text payloads round-trip through base64 to dodge every shell
/// escape footgun (newlines, quotes, Unicode).
enum CmuxCommand {
    /// `cmux --version`
    static let version = "cmux --version"

    /// `cmux ping`
    static let ping = "cmux ping"

    /// `cmux --json list-panes` — returns a wrapper for the focused workspace.
    static let listPanesJSON = "cmux --json list-panes"

    /// `cmux --json list-panes --workspace <ref>` — query a specific workspace
    /// without changing the GUI's focused workspace. (Query-only.)
    static func listPanesForWorkspaceJSON(_ workspaceRef: String) -> String {
        "cmux --json list-panes --workspace \(shQuote(workspaceRef))"
    }

    /// `cmux --json list-workspaces` — all workspaces in the current window.
    static let listWorkspacesJSON = "cmux --json list-workspaces"

    /// `cmux current-workspace` — print the currently focused workspace ref.
    static let currentWorkspace = "cmux current-workspace"

    /// `cmux --json tree` — full window/workspace/pane tree.
    static let treeJSON = "cmux --json tree"

    /// `cmux --json list-notifications` — array; surface/workspace are UUIDs.
    static let listNotificationsJSON = "cmux --json list-notifications"

    /// `cmux read-screen --surface <ref>`
    /// Optional scrollback + line limit.
    static func readScreen(surfaceRef: String, scrollback: Bool = false, lines: Int? = nil) -> String {
        var parts = ["cmux read-screen --surface \(shQuote(surfaceRef))"]
        if scrollback { parts.append("--scrollback") }
        if let n = lines { parts.append("--lines \(n)") }
        return parts.joined(separator: " ")
    }

    /// Send text to a surface.
    /// Wire form: `echo <B64> | base64 -d | cmux send --surface <ref> --`
    /// (we pipe through `--` so the decoded bytes are treated as the text arg,
    /// not as further flags).
    static func send(surfaceRef: String, text: String) -> String {
        let surface = shQuote(surfaceRef)
        if isShellSafe(text) {
            return "cmux send --surface \(surface) -- \(shQuote(text))"
        }
        let b64 = Data(text.utf8).base64EncodedString()
        return "cmux send --surface \(surface) -- \"$(echo \(shQuote(b64)) | base64 -d)\""
    }

    /// `cmux send-key --surface <ref> <key>` — key names like `enter`,
    /// `escape`, `tab`, `up`, `ctrl+c` (lowercase, per cmux's examples).
    static func sendKey(surfaceRef: String, key: String) -> String {
        "cmux send-key --surface \(shQuote(surfaceRef)) \(shQuote(key.lowercased()))"
    }

    /// `cmux jump-to-unread`
    static let jumpToUnread = "cmux jump-to-unread"

    // MARK: - shell quoting

    /// POSIX-safe single-quoting: wrap in `'…'`, replace any `'` with `'\''`.
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// "Shell-safe" = round-trips without quoting headaches.
    /// Anything outside this set forces base64 routing.
    private static func isShellSafe(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 64 else { return false }
        let allowed = CharacterSet.alphanumerics
            .union(.init(charactersIn: "-_.,:/@\\n\\r"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
