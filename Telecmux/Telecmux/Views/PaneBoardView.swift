import SwiftUI

/// Overview of a remote cmux app. Two sections:
///   1. Notifications — agents that want your attention.
///   2. Panes in the currently focused workspace.
///
/// Note: cmux's `list-panes` only returns panes in the *currently focused*
/// workspace. Cross-workspace inventory will land when we wire up `tree`.
struct PaneBoardView: View {
    let session: Session

    @Environment(DataStore.self) private var dataStore
    @State private var ssh = SSHConnectionManager()
    @State private var controller: CmuxController?
    @State private var navTarget: CmuxPane?

    private var host: Host? { dataStore.host(for: session) }

    var body: some View {
        Group {
            if let controller {
                content(controller: controller)
            } else {
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                indicator
            }
        }
        .task {
            guard let host else { return }
            let c = CmuxController(ssh: ssh)
            controller = c
            await ssh.connectExecOnly(host: host)
            await c.probe()
            c.startBoardPolling(interval: 2.0)
            // Screenshot automation: after the first tree load, auto-open the
            // focused pane so the capture script can grab PaneFocusView.
            if ProcessInfo.processInfo.environment["TELECMUX_SCREENSHOT"] == "focus" {
                await c.refreshTree()
                navTarget = c.panes.first(where: { $0.focused }) ?? c.panes.first
            }
        }
        .onDisappear {
            controller?.stopPolling()
            ssh.disconnect()
        }
        .navigationDestination(item: $navTarget) { pane in
            PaneFocusView(session: session, initialPane: pane, sharedSSH: ssh)
        }
    }

    @ViewBuilder
    private func content(controller: CmuxController) -> some View {
        switch controller.state {
        case .ready, .unknown:
            boardList(controller: controller)
        case .unreachable(let msg):
            unreachableBanner(message: msg)
        }
    }

    private func boardList(controller: CmuxController) -> some View {
        List {
            Section {
                workspacePicker(controller: controller)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

            let unread = controller.notifications.filter { !$0.isRead }
            if !unread.isEmpty {
                Section("Waiting (\(unread.count))") {
                    ForEach(unread.prefix(10)) { note in
                        notificationRow(note)
                    }
                }
            }

            let paneSectionTitle: String = {
                if let ref = controller.selectedWorkspaceRef,
                   let ws = controller.workspaces.first(where: { $0.ref == ref }) {
                    return ws.displayLabel
                }
                return controller.panes.isEmpty ? "Panes (none)" : "Panes"
            }()

            Section(paneSectionTitle) {
                if controller.panes.isEmpty {
                    Text("No panes in this workspace")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(controller.panes.sorted { $0.index < $1.index }) { pane in
                        Button {
                            navTarget = pane
                        } label: {
                            paneRow(pane, notifications: controller.notifications)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await controller.refreshWorkspaces()
            await controller.refreshPanes()
            await controller.refreshNotifications()
        }
    }

    private func workspacePicker(controller: CmuxController) -> some View {
        Menu {
            if controller.workspaces.isEmpty {
                Text("No workspaces loaded yet")
            } else {
                ForEach(controller.workspaces) { ws in
                    Button {
                        Task { await controller.selectWorkspace(ws.ref) }
                    } label: {
                        HStack {
                            Text(ws.displayLabel)
                            if ws.ref == controller.selectedWorkspaceRef {
                                Image(systemName: "checkmark")
                            }
                            if ws.pinned {
                                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await controller.refreshWorkspaces() }
            } label: {
                Label("Refresh workspaces", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack {
                Image(systemName: "rectangle.3.group")
                let currentTitle: String = {
                    if let ref = controller.selectedWorkspaceRef,
                       let ws = controller.workspaces.first(where: { $0.ref == ref }) {
                        return ws.displayLabel
                    }
                    if let ref = controller.selectedWorkspaceRef {
                        return ref
                    }
                    return controller.workspaces.isEmpty ? "Loading workspaces…" : "Select workspace"
                }()
                Text(currentTitle)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(controller.workspaces.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.gray.opacity(0.3), in: Capsule())
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.primary)
        }
    }

    private func notificationRow(_ note: CmuxNotification) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(note.title ?? "(no title)")
                    .font(.body)
                if let sub = note.subtitle, !sub.isEmpty {
                    Text("· \(sub)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let body = note.body {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }

    private func paneRow(_ pane: CmuxPane, notifications: [CmuxNotification]) -> some View {
        // Match notifications to this pane by surface UUID.
        let matched = notifications.filter { note in
            guard let sid = note.surfaceID else { return false }
            return pane.surfaceRefs.contains(sid)
        }
        let unread = matched.filter { !$0.isRead }.count

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(pane.title?.isEmpty == false ? pane.title! : "Pane \(pane.index)")
                        .font(.body)
                    if pane.focused {
                        Text("focused")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.3), in: Capsule())
                    }
                }
                Text(pane.ref)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if let latest = matched.last?.body {
                    Text(latest)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .lineLimit(2)
                }
            }
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
    }

    private func unreachableBanner(message: String) -> some View {
        let isBrokenPipe = message.localizedCaseInsensitiveContains("broken pipe") ||
                           message.localizedCaseInsensitiveContains("not owned")
        return VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(isBrokenPipe ? "cmux is rejecting external connections" : "cmux unreachable")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            if isBrokenPipe {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fix on your Mac:")
                        .font(.caption.bold())
                    Text("1. Open cmux.app")
                    Text("2. ⌘, → Settings → Automation")
                    Text("3. Socket control mode → \"Automation mode\"")
                    Text("4. Quit and relaunch cmux")
                }
                .font(.caption)
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("On your Mac:\n  open -a cmux\n  (or install from cmux.com)")
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            Button("Retry") {
                Task { await controller?.probe() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var indicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(session.displayName)
                .font(.headline)
        }
    }

    private var stateColor: Color {
        switch ssh.state {
        case .ready:      .green
        case .connecting: .yellow
        case .idle:       .gray
        case .failed:     .red
        }
    }
}
