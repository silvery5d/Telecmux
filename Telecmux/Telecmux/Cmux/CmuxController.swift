import Foundation
import os

private let logger = Logger(subsystem: "com.telecmux.app", category: "Cmux")

/// Drives a remote cmux app via short-lived `cmux <subcommand>` calls over an
/// already-connected `SSHConnectionManager`. One controller per active session.
///
/// All methods are safe to call from the main actor; SSH I/O happens off-main
/// inside the Citadel client.
@MainActor
@Observable
final class CmuxController {
    enum CmuxState: Equatable {
        case unknown
        case ready
        case unreachable(String)
    }

    private(set) var state: CmuxState = .unknown
    private(set) var panes: [CmuxPane] = []
    private(set) var workspaces: [CmuxWorkspace] = []
    /// The workspace Telecmux is currently displaying. May differ from cmux's
    /// own focused workspace — switching this on the phone does NOT change the
    /// Mac's GUI focus.
    var selectedWorkspaceRef: String?
    private(set) var notifications: [CmuxNotification] = []
    private(set) var screen: String = ""
    private(set) var lastScreenUpdate: Date?
    /// Most recent send/sendKey/jump action result. View layer reads + clears.
    var lastActionResult: ActionResult?

    struct ActionResult: Equatable {
        let kind: String          // e.g. "send", "send-key", "jump"
        let detail: String        // text sent or key name
        let success: Bool
        let errorMessage: String? // populated when success == false
        let at: Date
    }

    private let ssh: SSHConnectionManager
    private var pollTask: Task<Void, Never>?

    init(ssh: SSHConnectionManager) {
        self.ssh = ssh
    }

    // MARK: - readiness

    /// Verify cmux is installed and its socket responds. Updates `state`.
    func probe() async {
        // If SSH itself never came up, surface that specific error instead of
        // the generic "SSH session is not connected" exec-time failure — the
        // real root cause is usually the auth / network problem captured here.
        if case .failed(let sshError) = ssh.state {
            logger.error("probe sees ssh.state=.failed: \(sshError)")
            state = .unreachable("SSH: \(sshError)")
            return
        }
        do {
            _ = try await ssh.exec(CmuxCommand.ping)
            state = .ready
        } catch {
            logger.error("cmux probe failed: \(error)")
            state = .unreachable(error.localizedDescription)
        }
    }

    // MARK: - inventory

    /// One shot at `cmux --json tree` rebuilds both workspaces and panes
    /// (and gets pane titles by reading each pane's currently-selected
    /// surface). Replaces the two separate list-workspaces / list-panes
    /// fetches because cmux only puts `title` fields on the tree endpoint.
    func refreshTree() async {
        do {
            let out = try await ssh.exec(CmuxCommand.treeJSON)
            let tree = try Self.decode(CmuxTree.self, from: out)
            let allWorkspaces = tree.windows.flatMap { $0.workspaces }
            workspaces = allWorkspaces
                .map(CmuxWorkspace.init(from:))
                .sorted { $0.index < $1.index }

            // If nothing picked yet, default to the workspace that owns the
            // currently-focused pane (or the first workspace).
            if selectedWorkspaceRef == nil {
                if let ws = allWorkspaces.first(where: { ws in
                    ws.panes.contains(where: { $0.focused == true })
                }) {
                    selectedWorkspaceRef = ws.ref
                } else {
                    selectedWorkspaceRef = allWorkspaces.first?.ref
                }
            }

            if let ref = selectedWorkspaceRef,
               let ws = allWorkspaces.first(where: { $0.ref == ref }) {
                panes = ws.panes.map { p in
                    let surfaceTitle =
                        p.surfaces?.first(where: { $0.selectedInPane == true })?.title
                        ?? p.surfaces?.first?.title
                    return CmuxPane(
                        ref: p.ref,
                        focused: p.focused ?? false,
                        index: p.index ?? 0,
                        surfaceRefs: p.surfaces?.map(\.ref) ?? [],
                        selectedSurfaceRef: p.selectedSurfaceRef,
                        title: surfaceTitle
                    )
                }
            }
        } catch {
            logger.error("tree failed: \(error)")
        }
    }

    // Compatibility shims — callers haven't migrated yet.
    func refreshPanes() async { await refreshTree() }
    func refreshWorkspaces() async { await refreshTree() }

    /// Switch which workspace Telecmux is showing. Triggers an immediate
    /// refresh of panes (and notifications, which are already global).
    func selectWorkspace(_ ref: String) async {
        selectedWorkspaceRef = ref
        await refreshPanes()
    }

    func refreshNotifications() async {
        do {
            let out = try await ssh.exec(CmuxCommand.listNotificationsJSON)
            notifications = try Self.decode([CmuxNotification].self, from: out)
        } catch {
            logger.error("listNotifications failed: \(error)")
        }
    }

    // MARK: - per-surface

    func refreshScreen(surfaceRef: String) async {
        do {
            let text = try await ssh.exec(CmuxCommand.readScreen(surfaceRef: surfaceRef))
            screen = text
            lastScreenUpdate = Date()
        } catch {
            logger.error("readScreen failed: \(error)")
        }
    }

    func send(surfaceRef: String, text: String) async {
        let cmd = CmuxCommand.send(surfaceRef: surfaceRef, text: text)
        logger.info("send → \(cmd)")
        do {
            let out = try await ssh.exec(cmd)
            logger.info("send ok, stdout: \(out.prefix(200))")
            lastActionResult = .init(kind: "send", detail: text, success: true, errorMessage: nil, at: Date())
        } catch {
            logger.error("send failed: \(error)")
            lastActionResult = .init(kind: "send", detail: text, success: false, errorMessage: error.localizedDescription, at: Date())
        }
    }

    func sendKey(surfaceRef: String, key: String) async {
        let cmd = CmuxCommand.sendKey(surfaceRef: surfaceRef, key: key)
        logger.info("sendKey → \(cmd)")
        do {
            let out = try await ssh.exec(cmd)
            logger.info("sendKey ok, stdout: \(out.prefix(200))")
            lastActionResult = .init(kind: "send-key", detail: key, success: true, errorMessage: nil, at: Date())
        } catch {
            logger.error("sendKey failed: \(error)")
            lastActionResult = .init(kind: "send-key", detail: key, success: false, errorMessage: error.localizedDescription, at: Date())
        }
    }

    func jumpToUnread() async {
        do {
            _ = try await ssh.exec(CmuxCommand.jumpToUnread)
            lastActionResult = .init(kind: "jump", detail: "unread", success: true, errorMessage: nil, at: Date())
        } catch {
            logger.error("jumpToUnread failed: \(error)")
            lastActionResult = .init(kind: "jump", detail: "unread", success: false, errorMessage: error.localizedDescription, at: Date())
        }
    }

    // MARK: - polling

    /// Poll `read-screen` for one surface at the given cadence. Auto-cancels
    /// any previous poll. Cancel with `stopPolling()`.
    func startSurfacePolling(surfaceRef: String, interval: TimeInterval) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshScreen(surfaceRef: surfaceRef)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Poll the tree + notifications at the given cadence. Tree returns
    /// everything (workspaces with titles, panes with surface titles), so
    /// the picker and the row labels stay in sync.
    func startBoardPolling(interval: TimeInterval) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTree()
                await self?.refreshNotifications()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - decode

    private static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "Cmux", code: -1, userInfo: [NSLocalizedDescriptionKey: "non-utf8 cmux output"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
