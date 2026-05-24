import Foundation

/// A row of soft-key buttons rendered below the pane screen.
struct RibbonConfig: Codable, Hashable {
    var name: String
    var buttons: [RibbonButton]

    /// The default ribbon for cmux pane focus.
    static let cmuxAgent = RibbonConfig(name: "Cmux Agent", buttons: [
        RibbonButton(label: "1",          kind: .text,     action: .sendText("1")),
        RibbonButton(label: "2",          kind: .text,     action: .sendText("2")),
        RibbonButton(label: "delete.left", kind: .sfSymbol, action: .sendKey("backspace")),
        // Use sendKey('enter') rather than sendText('\n'): shell command
        // substitution strips trailing newlines, so a bare "\n" payload
        // arrives at cmux as empty and gets rejected with CommandFailed.
        RibbonButton(label: "return",   kind: .sfSymbol, action: .sendKey("enter")),
        RibbonButton(label: "Esc",      kind: .text,     action: .sendKey("escape")),
        RibbonButton(label: "mic.fill", kind: .sfSymbol, action: .voiceInput),
    ])

    static let presets: [RibbonConfig] = [.cmuxAgent]
}

struct RibbonButton: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String
    var kind: LabelKind
    var action: ButtonAction

    init(id: UUID = UUID(), label: String, kind: LabelKind, action: ButtonAction) {
        self.id = id
        self.label = label
        self.kind = kind
        self.action = action
    }
}

enum LabelKind: String, Codable {
    case text
    case sfSymbol
}

/// What a ribbon button does when tapped.
enum ButtonAction: Codable, Hashable {
    /// `cmux send --surface <ref> -- <text>`
    case sendText(String)
    /// `cmux send-key --surface <ref> <key>`
    case sendKey(String)
    /// `cmux jump-to-unread`
    case jumpToUnread
    /// Open the voice input modal.
    case voiceInput
}
