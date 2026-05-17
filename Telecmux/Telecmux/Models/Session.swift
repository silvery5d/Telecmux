import Foundation

/// How this Session connects to the remote host.
/// - `tmux`: legacy mode — SSH + `tmux new-session -As <name>` over a PTY.
/// - `cmuxBoard`: SSH + cmux CLI; shows workspace/pane/notification overview.
/// - `cmuxPane`: SSH + cmux CLI; focused on a single cmux pane.
/// - `shell`: SSH + raw shell, no multiplexer.
enum SessionMode: String, Codable, CaseIterable {
    case tmux
    case cmuxBoard
    case cmuxPane
    case shell

    var displayLabel: String {
        switch self {
        case .tmux: "tmux"
        case .cmuxBoard: "cmux board"
        case .cmuxPane: "cmux pane"
        case .shell: "shell"
        }
    }
}

struct Session: Codable, Identifiable {
    var id: UUID
    var displayName: String
    var hostID: UUID
    var mode: SessionMode
    var tmuxSessionName: String?      // used only when mode == .tmux
    var cmuxSurfaceRef: String?       // used only when mode == .cmuxPane
                                      // e.g. "surface:34" ref or a UUID;
                                      // cmux's read/send/send-key all key off
                                      // surface, not pane
    var createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        hostID: UUID,
        mode: SessionMode = .tmux,
        tmuxSessionName: String? = nil,
        cmuxSurfaceRef: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.hostID = hostID
        self.mode = mode
        self.tmuxSessionName = tmuxSessionName
        self.cmuxSurfaceRef = cmuxSurfaceRef
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, displayName, hostID, mode, tmuxSessionName, cmuxSurfaceRef, createdAt
        // legacy key for migrating older builds
        case cmuxPaneRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        tmuxSessionName = try c.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        cmuxSurfaceRef = try c.decodeIfPresent(String.self, forKey: .cmuxSurfaceRef)
            ?? c.decodeIfPresent(String.self, forKey: .cmuxPaneRef)
        createdAt = try c.decode(Date.self, forKey: .createdAt)

        if let raw = try c.decodeIfPresent(SessionMode.self, forKey: .mode) {
            mode = raw
        } else {
            mode = (tmuxSessionName != nil) ? .tmux : .shell
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(hostID, forKey: .hostID)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
        try c.encodeIfPresent(cmuxSurfaceRef, forKey: .cmuxSurfaceRef)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
