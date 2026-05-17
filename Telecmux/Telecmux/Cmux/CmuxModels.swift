import Foundation

/// Mirrors the real cmux 0.64.x JSON schema (verified against
/// `cmux --json --id-format=uuids list-panes` and `list-notifications`).
/// Decoding is permissive — unknown fields are ignored, missing ones fall
/// back to defaults so Telecmux survives minor schema drift.

/// `cmux --json list-panes` returns a single wrapper, not a list, describing
/// the panes inside the currently focused workspace.
struct CmuxPaneList: Codable {
    let windowRef: String?
    let workspaceRef: String?
    let panes: [CmuxPane]

    enum CodingKeys: String, CodingKey {
        case windowRef = "window_ref"
        case workspaceRef = "workspace_ref"
        case panes
    }
}

/// One cmux pane inside a workspace.
struct CmuxPane: Identifiable, Codable, Hashable {
    /// Stable handle — either a UUID (when `--id-format=uuids`) or a ref like
    /// `"pane:24"`. Either form is accepted by every cmux command that takes
    /// a pane handle.
    let ref: String
    let focused: Bool
    let index: Int
    let rows: Int?
    let columns: Int?

    /// `surface_refs` — each pane owns one or more surfaces (terminals).
    /// `selected_surface_ref` is the one currently visible.
    /// Notifications reference panes indirectly through `surface_id`, so we
    /// keep these to correlate.
    let surfaceRefs: [String]
    let selectedSurfaceRef: String?

    var id: String { ref }

    enum CodingKeys: String, CodingKey {
        case ref, focused, index, rows, columns
        case surfaceRefs = "surface_refs"
        case selectedSurfaceRef = "selected_surface_ref"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        focused = try c.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows)
        columns = try c.decodeIfPresent(Int.self, forKey: .columns)
        surfaceRefs = try c.decodeIfPresent([String].self, forKey: .surfaceRefs) ?? []
        selectedSurfaceRef = try c.decodeIfPresent(String.self, forKey: .selectedSurfaceRef)
    }
}

/// `cmux --json list-workspaces` returns this wrapper, not a top-level array.
struct CmuxWorkspaceList: Decodable {
    let windowRef: String?
    let workspaces: [CmuxWorkspace]

    enum CodingKeys: String, CodingKey {
        case windowRef = "window_ref"
        case workspaces
    }
}

/// One cmux workspace (a tab in the sidebar).
/// Schema verified against cmux 0.64.3 `--json list-workspaces`.
/// cmux does NOT give workspaces a human name field — the displayable label
/// is derived from `description` first, then the basename of `current_directory`,
/// finally the ref itself.
struct CmuxWorkspace: Identifiable, Decodable, Hashable {
    let ref: String
    let description: String?
    let currentDirectory: String?
    let index: Int
    let pinned: Bool

    var id: String { ref }

    /// Best-effort human label.
    var displayLabel: String {
        if let d = description, !d.isEmpty { return d }
        if let cwd = currentDirectory, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return ref
    }

    enum CodingKeys: String, CodingKey {
        case ref, description, index, pinned
        case currentDirectory = "current_directory"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        currentDirectory = try c.decodeIfPresent(String.self, forKey: .currentDirectory)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

/// One cmux notification — an agent is waiting, a task finished, etc.
/// Empirically: every Claude Code "waiting for input" prompt shows up here
/// with `body = "Claude is waiting for your input"` (or the choices text).
struct CmuxNotification: Identifiable, Codable, Hashable {
    let id: String
    let surfaceID: String?
    let workspaceID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let isRead: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case surfaceID = "surface_id"
        case workspaceID = "workspace_id"
        case title, subtitle, body
        case isRead = "is_read"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        surfaceID = try c.decodeIfPresent(String.self, forKey: .surfaceID)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
}
