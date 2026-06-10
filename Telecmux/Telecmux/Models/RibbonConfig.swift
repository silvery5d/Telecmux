import Foundation

/// A row of soft-key buttons rendered below the pane screen.
struct RibbonConfig: Codable, Hashable {
    var name: String
    var buttons: [RibbonButton]

    /// The single ribbon for cmux pane focus. Arrow keys live on the
    /// floating joystick (DirectionJoystick), not here.
    /// - return/Esc use sendKey: shell command substitution strips a bare
    ///   "\n" payload, so a key event is the only reliable Enter.
    /// - space uses sendText(" "): a literal space survives the shell
    ///   wrapper (only trailing newlines get stripped), and cmux send-key
    ///   may not name a "space" key.
    static let cmuxAgent = RibbonConfig(name: "Cmux Agent", buttons: [
        RibbonButton(label: "1",           kind: .text,     action: .sendText("1")),
        RibbonButton(label: "2",           kind: .text,     action: .sendText("2")),
        RibbonButton(label: "delete.left", kind: .sfSymbol, action: .sendKey("backspace")),
        RibbonButton(label: "space",       kind: .sfSymbol, action: .sendText(" ")),
        RibbonButton(label: "return",      kind: .sfSymbol, action: .sendKey("enter")),
        RibbonButton(label: "Esc",         kind: .text,     action: .sendKey("escape")),
        RibbonButton(label: "mic.fill",    kind: .sfSymbol, action: .voiceInput),
    ])

    /// Ribbons the user can cycle through (toolbar button auto-hides when
    /// there's only one).
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
