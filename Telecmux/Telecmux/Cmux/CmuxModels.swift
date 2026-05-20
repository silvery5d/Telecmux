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
    /// Stable handle — either a UUID or a ref like `"pane:24"`. Both forms
    /// are accepted by every cmux command that takes a pane handle.
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

    /// Human-readable title for the pane's currently-selected surface. cmux
    /// gives panes no title of their own — the title is on the inner
    /// terminal surface (e.g. "Taibo", "deosigner@Mac:~/Documents/foo").
    /// Filled in by CmuxController after a `tree --json` fetch.
    var title: String?

    var id: String { ref }

    enum CodingKeys: String, CodingKey {
        case ref, focused, index, rows, columns
        case surfaceRefs = "surface_refs"
        case selectedSurfaceRef = "selected_surface_ref"
        case title
    }

    init(ref: String, focused: Bool, index: Int, surfaceRefs: [String],
         selectedSurfaceRef: String?, title: String?, rows: Int? = nil, columns: Int? = nil) {
        self.ref = ref
        self.focused = focused
        self.index = index
        self.rows = rows
        self.columns = columns
        self.surfaceRefs = surfaceRefs
        self.selectedSurfaceRef = selectedSurfaceRef
        self.title = title
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
        title = try c.decodeIfPresent(String.self, forKey: .title)
    }
}

// MARK: - tree response

/// `cmux --json tree` — full window / workspace / pane / surface tree.
/// We only decode the fields we display.
struct CmuxTree: Decodable {
    let windows: [TreeWindow]

    struct TreeWindow: Decodable {
        let workspaces: [TreeWorkspace]
    }

    struct TreeWorkspace: Decodable {
        let ref: String
        let title: String?
        let description: String?
        let currentDirectory: String?
        let pinned: Bool?
        let index: Int?
        let panes: [TreePane]

        enum CodingKeys: String, CodingKey {
            case ref, title, description, pinned, index, panes
            case currentDirectory = "current_directory"
        }
    }

    struct TreePane: Decodable {
        let ref: String
        let focused: Bool?
        let index: Int?
        let selectedSurfaceRef: String?
        let surfaces: [TreeSurface]?

        enum CodingKeys: String, CodingKey {
            case ref, focused, index, surfaces
            case selectedSurfaceRef = "selected_surface_ref"
        }
    }

    struct TreeSurface: Decodable {
        let ref: String
        let title: String?
        let selectedInPane: Bool?

        enum CodingKeys: String, CodingKey {
            case ref, title
            case selectedInPane = "selected_in_pane"
        }
    }
}

/// One cmux workspace (a tab in the sidebar). Now sourced from
/// `cmux --json tree` which exposes `title` (cmux's own sidebar label).
/// Fall through to `description`, `current_directory` basename, then `ref`.
struct CmuxWorkspace: Identifiable, Hashable {
    let ref: String
    let title: String?
    let description: String?
    let currentDirectory: String?
    let index: Int
    let pinned: Bool

    var id: String { ref }

    var displayLabel: String {
        if let t = title, !t.isEmpty       { return t }
        if let d = description, !d.isEmpty { return d }
        if let cwd = currentDirectory, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return ref
    }

    init(from t: CmuxTree.TreeWorkspace) {
        ref              = t.ref
        title            = t.title
        description      = t.description
        currentDirectory = t.currentDirectory
        index            = t.index ?? 0
        pinned           = t.pinned ?? false
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
