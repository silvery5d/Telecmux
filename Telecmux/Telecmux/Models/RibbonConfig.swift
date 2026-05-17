import Foundation

struct RibbonConfig: Codable {
    var name: String
    var buttons: [RibbonButton]

    static let `default` = RibbonConfig(name: "Default", buttons: [
        RibbonButton(label: "1", labelType: .text, action: .sendString("1")),
        RibbonButton(label: "2", labelType: .text, action: .sendString("2")),
        RibbonButton(label: "return", labelType: .sfSymbol, action: .sendString("\r")),
        RibbonButton(label: "escape", labelType: .sfSymbol, action: .sendString("\u{1B}")),
        RibbonButton(label: "mic.fill", labelType: .sfSymbol, action: .voiceInput),
    ])

    static let planMode = RibbonConfig(name: "Plan Mode", buttons: [
        RibbonButton(label: "1", labelType: .text, action: .sendString("1")),
        RibbonButton(label: "2", labelType: .text, action: .sendString("2")),
        RibbonButton(label: "3", labelType: .text, action: .sendString("3")),
        RibbonButton(label: "4", labelType: .text, action: .sendString("4")),
        RibbonButton(label: "5", labelType: .text, action: .sendString("5")),
    ])

    /// Default ribbon for cmux-mode sessions. Sends/keys are routed through
    /// the active pane's CmuxController instead of writing to a raw PTY.
    static let cmuxAgent = RibbonConfig(name: "Cmux Agent", buttons: [
        RibbonButton(label: "1", labelType: .text, action: .cmuxSend(text: "1")),
        RibbonButton(label: "2", labelType: .text, action: .cmuxSend(text: "2")),
        RibbonButton(label: "3", labelType: .text, action: .cmuxSend(text: "3")),
        // cmux send understands \n / \r as Enter; one send beats send + send-key.
        RibbonButton(label: "return", labelType: .sfSymbol, action: .cmuxSend(text: "\n")),
        RibbonButton(label: "escape", labelType: .sfSymbol, action: .cmuxKey(key: "escape")),
        RibbonButton(label: "bell", labelType: .sfSymbol, action: .cmuxJumpUnread),
        RibbonButton(label: "mic.fill", labelType: .sfSymbol, action: .voiceInput),
    ])

    static let presets: [RibbonConfig] = [.default, .planMode, .cmuxAgent]
}

struct RibbonButton: Codable, Identifiable {
    var id: UUID
    var label: String
    var labelType: LabelType
    var action: ButtonAction

    init(
        id: UUID = UUID(),
        label: String,
        labelType: LabelType,
        action: ButtonAction
    ) {
        self.id = id
        self.label = label
        self.labelType = labelType
        self.action = action
    }
}

enum LabelType: String, Codable {
    case text
    case sfSymbol
}

enum ButtonAction: Codable {
    /// Write a raw string to the active SSH PTY (tmux / shell mode).
    case sendString(String)

    /// `cmux send --pane <ref> -- <text>` against the active pane (cmux mode).
    case cmuxSend(text: String)

    /// `cmux send-key --pane <ref> <key>` against the active pane (cmux mode).
    /// Key names follow cmux conventions: `Enter`, `Escape`, `Tab`, `Up`, etc.
    case cmuxKey(key: String)

    /// `cmux jump-to-unread` — focuses the next pane with an unread notification.
    case cmuxJumpUnread

    /// Open the voice-input modal.
    case voiceInput
}
