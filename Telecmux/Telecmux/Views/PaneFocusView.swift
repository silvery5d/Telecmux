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
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    /// Live input: when on, each committed keystroke (IME-aware) is forwarded
    /// to the surface immediately — no send button needed.
    @State private var liveInput = false
    @State private var liveText = ""
    /// Serial chain that keeps live keystrokes arriving in order even though
    /// each one is an async SSH exec.
    @State private var liveSendChain: Task<Void, Never>?
    /// When true, every screen update auto-scrolls to the bottom. The user
    /// can disable this implicitly (by scrolling up) or re-enable by
    /// tapping the "jump to bottom" button.
    @State private var autoFollow = true

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

    /// Which preset ribbon is showing. Cycled by the toolbar switch button.
    @State private var ribbonIndex = 0

    /// Live preset list — ignores the host's frozen ribbon snapshot (there's
    /// no per-host editor UI yet) so preset changes show up immediately.
    private var activeRibbon: RibbonConfig {
        RibbonConfig.presets[ribbonIndex % RibbonConfig.presets.count]
    }

    var body: some View {
        // Outer GeometryReader pins the VStack to the container's actual
        // width, so a misbehaving child (e.g. ScrollView whose contentSize
        // exceeds the screen) can't push the whole layout into overflow.
        GeometryReader { geo in
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
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        }
        .navigationTitle(paneTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if RibbonConfig.presets.count > 1 {
                    Button {
                        ribbonIndex = (ribbonIndex + 1) % RibbonConfig.presets.count
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
                    .accessibilityLabel("Switch ribbon (\(activeRibbon.name))")
                }
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
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(CmuxScreenHighlighter.lines(
                            controller?.screen ?? "",
                            paneColumns: initialPane?.columns ?? 80
                        )) { line in
                            render(line)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
                .background(Color(white: 0.12))
                // Any drag the user makes turns off auto-follow. They can
                // tap the floating "jump" button to opt back in.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { _ in
                            if autoFollow { autoFollow = false }
                        }
                )
                .onChange(of: controller?.lastScreenUpdate) { _, _ in
                    guard autoFollow else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }

                // Right-edge floating controls: arrow-key joystick anchored
                // at the bottom corner; "jump to bottom" appears above it
                // when the user has scrolled away from the tail.
                VStack(alignment: .trailing, spacing: 10) {
                    if !autoFollow {
                        Button {
                            autoFollow = true
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white, Color.accentColor)
                                .shadow(radius: 4)
                        }
                        .transition(.opacity.combined(with: .scale))
                    }

                    DirectionJoystick { key in
                        guard let ref = surfaceRef else { return }
                        await controller?.sendKey(surfaceRef: ref, key: key)
                    }
                }
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
            .animation(.easeOut(duration: 0.15), value: autoFollow)
        }
    }

    /// Renders one classified line. Divider → a thin Rectangle (so a
    /// terminal-wide horizontal line shows as one row on the phone, not as
    /// 3-4 wrapped rows of ─ glyphs). Diff lines get a tinted background.
    /// Everything else is plain monospaced Text with the line's color.
    @ViewBuilder
    private func render(_ line: CmuxScreenHighlighter.Line) -> some View {
        let mono = Font.system(.footnote, design: .monospaced)
        switch line.kind {
        case .divider:
            Rectangle()
                .fill(Color.gray.opacity(0.45))
                .frame(height: 1)
                .padding(.vertical, 3)

        case .codeFence:
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(Color(white: 0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .diffAdded:
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color.blue.opacity(0.22))
                .textSelection(.enabled)

        case .diffRemoved:
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color.red.opacity(0.22))
                .textSelection(.enabled)

        case .codeBody:
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .modeIndicator(let color):
            Text(verbatim: line.text)
                .font(mono.bold())
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .status:
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

        case .userInput:
            // Reverse video — black text on a near-white fill, terminal
            // convention for the user's own command echoes.
            Text(verbatim: line.text)
                .font(mono)
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .background(Color(white: 0.92))
                .textSelection(.enabled)

        case .normal(let color):
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .font(mono)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Live toggle — bolt on = keystrokes stream straight to cmux.
            Button {
                liveInput.toggle()
                liveText = ""
            } label: {
                Image(systemName: liveInput ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(liveInput ? .yellow : .gray)
                    .frame(width: 30, height: 36)
            }
            .accessibilityLabel(liveInput ? "Live input on" : "Live input off")

            if liveInput {
                LiveInputField(
                    text: $liveText,
                    placeholder: "Live → surface",
                    onDelta: { deletes, inserts in
                        enqueueLiveDelta(deletes: deletes, inserts: inserts)
                    },
                    onReturn: {
                        enqueueLiveReturn()
                    }
                )
                .frame(minHeight: 36)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
                )
            } else {
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

    // MARK: - live input forwarding

    /// Append one delta to the serial send chain. Order matters (backspaces
    /// must land before the replacement characters), and each send is an
    /// async SSH exec — chaining on the previous task guarantees FIFO.
    private func enqueueLiveDelta(deletes: Int, inserts: String) {
        guard let ref = surfaceRef, deletes > 0 || !inserts.isEmpty else { return }
        let previous = liveSendChain
        liveSendChain = Task {
            await previous?.value
            for _ in 0..<deletes {
                await controller?.sendKey(surfaceRef: ref, key: "backspace")
            }
            if !inserts.isEmpty {
                await controller?.send(surfaceRef: ref, text: inserts)
            }
        }
    }

    private func enqueueLiveReturn() {
        guard let ref = surfaceRef else { return }
        let previous = liveSendChain
        liveSendChain = Task {
            await previous?.value
            await controller?.sendKey(surfaceRef: ref, key: "enter")
        }
        // Line is committed remotely; reset the local mirror for the next one.
        liveText = ""
        debounceRefresh()
    }

    private var ribbonBar: some View {
        // Buttons share the available width equally instead of each one
        // demanding a fixed minWidth — that combination overflows the
        // screen once the ribbon has 6+ items.
        HStack(spacing: 6) {
            ForEach(activeRibbon.buttons) { button in
                Button {
                    handle(button)
                } label: {
                    Group {
                        switch button.kind {
                        case .text:
                            Text(button.label)
                                .font(.system(.body, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)  // "Esc" must not wrap in a narrow slot
                        case .sfSymbol:
                            Image(systemName: button.label)
                                .font(.body)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var paneTitle: String {
        if let pane = initialPane {
            if let t = pane.title, !t.isEmpty { return t }
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
        case .sendText(let text):
            Task {
                guard let ref = surfaceRef else { return }
                await controller?.send(surfaceRef: ref, text: text)
                debounceRefresh()
            }
        case .sendKey(let key):
            Task {
                guard let ref = surfaceRef else { return }
                await controller?.sendKey(surfaceRef: ref, key: key)
                debounceRefresh()
            }
        case .jumpToUnread:
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
