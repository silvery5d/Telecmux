import SwiftUI

/// Focused view on a single cmux pane: polls `read-screen` and renders the
/// snapshot as monospaced text. Ribbon buttons fire cmux send/key against
/// this pane's ref.
struct PaneFocusView: View {
    let session: Session
    let initialPane: CmuxPane?
    let sharedSSH: SSHConnectionManager?

    @Environment(DataStore.self) private var dataStore
    @Environment(VoiceInputCoordinator.self) private var voiceCoordinator

    /// PaneFocusView always owns its own SSH connection now. Sharing with
    /// PaneBoardView was causing "SSH not connected" — NavigationStack push
    /// triggers the parent's onDisappear, which disconnects the shared client.
    /// A fresh exec-only connect costs ~200ms and avoids that footgun entirely.
    @State private var ownedSSH = SSHConnectionManager()
    @State private var controller: CmuxController?
    @State private var voiceText = ""
    @State private var showingVoiceModal = false
    @State private var activeRibbonIndex = 0
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool

    /// Resolution order:
    ///   1. explicit nav target → its selectedSurfaceRef (or first surface)
    ///   2. session.cmuxSurfaceRef (configured on the session)
    private var surfaceRef: String? {
        if let pane = initialPane {
            return pane.selectedSurfaceRef ?? pane.surfaceRefs.first
        }
        return session.cmuxSurfaceRef
    }

    // sharedSSH is ignored on purpose — see comment on ownedSSH above.
    private var ssh: SSHConnectionManager { ownedSSH }
    private var host: Host? { dataStore.host(for: session) }

    private var ribbonConfigs: [RibbonConfig] {
        host?.ribbonConfigs ?? [RibbonConfig.cmuxAgent]
    }

    private var activeRibbon: RibbonConfig {
        ribbonConfigs[activeRibbonIndex % ribbonConfigs.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            if let res = controller?.lastActionResult {
                actionToast(res)
            }
            if let ref = surfaceRef {
                Text("→ \(ref)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            screenView
            inputBar
            ribbonBar
        }
        .navigationTitle(paneTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeRibbonIndex = (activeRibbonIndex + 1) % ribbonConfigs.count
                } label: {
                    Image(systemName: "rectangle.stack")
                }
                .accessibilityLabel("Switch ribbon: \(activeRibbon.name)")
            }
        }
        .task {
            await bootstrap()
        }
        .onDisappear {
            controller?.stopPolling()
            ssh.disconnect()
        }
        .sheet(isPresented: $showingVoiceModal) {
            VoiceInputModal(text: $voiceText) { finalText in
                Task {
                    guard let ref = surfaceRef else { return }
                    await controller?.send(surfaceRef: ref, text: finalText)
                    await controller?.sendKey(surfaceRef: ref, key: "enter")
                    debounceRefresh()
                }
            }
        }
        .onChange(of: voiceCoordinator.isShowingVoiceModal) { _, show in
            if show {
                voiceText = voiceCoordinator.transcribedText
                showingVoiceModal = true
                voiceCoordinator.isShowingVoiceModal = false
            }
        }
    }

    // MARK: - subviews

    private func actionToast(_ res: CmuxController.ActionResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: res.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(res.success ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(res.kind) \(res.detail.replacingOccurrences(of: "\n", with: "↵"))")
                    .font(.caption.bold())
                if let msg = res.errorMessage {
                    Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(res.at.formatted(date: .omitted, time: .standard))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(res.success ? .green.opacity(0.15) : .orange.opacity(0.2))
    }

    private var screenView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(CmuxScreenHighlighter.highlight(controller?.screen ?? ""))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("bottom")
                    .textSelection(.enabled)
            }
            .background(Color.black)
            .onChange(of: controller?.lastScreenUpdate) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send text to surface…", text: $inputText, axis: .vertical)
                .focused($inputFocused)
                .font(.body)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

            Button {
                sendInputText()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(inputText.isEmpty ? .gray : .blue)
            }
            .disabled(inputText.isEmpty || surfaceRef == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }

    private func sendInputText() {
        guard let ref = surfaceRef, !inputText.isEmpty else { return }
        let text = inputText
        inputText = ""
        Task {
            await controller?.send(surfaceRef: ref, text: text)
            debounceRefresh()
        }
    }

    private var ribbonBar: some View {
        HStack(spacing: 12) {
            ForEach(activeRibbon.buttons) { button in
                Button {
                    handle(button)
                } label: {
                    Group {
                        switch button.labelType {
                        case .text:
                            Text(button.label)
                                .font(.system(.body, design: .monospaced, weight: .medium))
                        case .sfSymbol:
                            Image(systemName: button.label)
                                .font(.body)
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var paneTitle: String {
        if let pane = initialPane {
            return "Pane \(pane.index)"
        }
        return surfaceRef ?? session.displayName
    }

    // MARK: - actions

    private func bootstrap() async {
        guard let host else { return }
        let c = CmuxController(ssh: ssh)
        controller = c
        await ssh.connectExecOnly(host: host)
        await c.probe()
        if let ref = surfaceRef {
            await c.refreshScreen(surfaceRef: ref)
            c.startSurfacePolling(surfaceRef: ref, interval: 1.5)
        }
    }

    private func handle(_ button: RibbonButton) {
        switch button.action {
        case .sendString(let s):
            // tmux/shell-shaped action used on a cmux pane: treat as send-text.
            Task {
                guard let ref = surfaceRef else { return }
                await controller?.send(surfaceRef: ref, text: s)
                debounceRefresh()
            }
        case .cmuxSend(let text):
            Task {
                guard let ref = surfaceRef else { return }
                await controller?.send(surfaceRef: ref, text: text)
                debounceRefresh()
            }
        case .cmuxKey(let key):
            Task {
                guard let ref = surfaceRef else { return }
                await controller?.sendKey(surfaceRef: ref, key: key)
                debounceRefresh()
            }
        case .cmuxJumpUnread:
            Task { await controller?.jumpToUnread() }
        case .voiceInput:
            let settings = AppSettings.load()
            voiceCoordinator.handleVoiceButton(settings: settings)
        }
    }

    /// After a write, schedule a few extra refreshes so the user sees their
    /// input echo without waiting a full poll interval.
    private func debounceRefresh() {
        guard let ref = surfaceRef else { return }
        Task {
            for delay in [0.3, 0.8, 1.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await controller?.refreshScreen(surfaceRef: ref)
            }
        }
    }
}
