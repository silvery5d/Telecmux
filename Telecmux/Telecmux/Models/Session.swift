import Foundation

/// What kind of cmux target this session points at.
/// - `board`: workspace + pane overview, with notifications surface
/// - `pane`: focused on a single cmux surface
enum SessionMode: String, Codable, CaseIterable {
    case board
    case pane

    var displayLabel: String {
        switch self {
        case .board: "cmux board"
        case .pane:  "cmux pane"
        }
    }
}

/// A user-saved cmux session. Each one binds to one Host and one optional
/// surface ref (for `pane` mode).
struct Session: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var hostID: UUID
    var mode: SessionMode = .board
    var cmuxSurfaceRef: String? = nil
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, displayName, hostID, mode, cmuxSurfaceRef, createdAt
        // Legacy keys from earlier dev builds and the upstream tmux schema.
        case tmuxSessionName, cmuxPaneRef
    }

    init(displayName: String, hostID: UUID, mode: SessionMode = .board, cmuxSurfaceRef: String? = nil) {
        self.displayName = displayName
        self.hostID = hostID
        self.mode = mode
        self.cmuxSurfaceRef = cmuxSurfaceRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        cmuxSurfaceRef = try c.decodeIfPresent(String.self, forKey: .cmuxSurfaceRef)
            ?? c.decodeIfPresent(String.self, forKey: .cmuxPaneRef)
        let rawMode = try c.decodeIfPresent(String.self, forKey: .mode)
        switch rawMode {
        case "pane", "cmuxPane": mode = .pane
        default:                 mode = .board
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(hostID, forKey: .hostID)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(cmuxSurfaceRef, forKey: .cmuxSurfaceRef)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
