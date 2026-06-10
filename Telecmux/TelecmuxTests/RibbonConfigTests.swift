import Testing
import Foundation
@testable import Telecmux

@Suite("RibbonConfig Tests")
struct RibbonConfigTests {
    @Test func cmuxAgentRibbonShape() {
        let r = RibbonConfig.cmuxAgent
        #expect(r.name == "Cmux Agent")
        #expect(r.buttons.count == 7)
        #expect(r.buttons.map(\.label) == ["1", "2", "delete.left", "space", "return", "Esc", "mic.fill"])
    }

    @Test func spaceButtonSendsSpaceChar() throws {
        guard case .sendText(let t) = RibbonConfig.cmuxAgent.buttons[3].action else {
            Issue.record("Expected sendText for space"); return
        }
        #expect(t == " ")
    }

    @Test func numberButtonsSendTheirDigit() throws {
        for (i, expected) in ["1", "2"].enumerated() {
            guard case .sendText(let value) = RibbonConfig.cmuxAgent.buttons[i].action else {
                Issue.record("Expected sendText action at index \(i)")
                return
            }
            #expect(value == expected)
        }
    }

    @Test func deleteButtonSendsBackspace() throws {
        guard case .sendKey(let key) = RibbonConfig.cmuxAgent.buttons[2].action else {
            Issue.record("Expected sendKey action for delete")
            return
        }
        #expect(key == "backspace")
    }

    @Test func returnButtonSendsEnterKey() throws {
        guard case .sendKey(let key) = RibbonConfig.cmuxAgent.buttons[4].action else {
            Issue.record("Expected sendKey action for return")
            return
        }
        #expect(key == "enter")
    }

    @Test func escapeButtonSendsEscapeKey() throws {
        guard case .sendKey(let key) = RibbonConfig.cmuxAgent.buttons[5].action else {
            Issue.record("Expected sendKey action for Esc")
            return
        }
        #expect(key == "escape")
    }

    @Test func micButtonOpensVoiceInput() throws {
        let mic = RibbonConfig.cmuxAgent.buttons[6]
        guard case .voiceInput = mic.action else {
            Issue.record("Expected voiceInput action")
            return
        }
        #expect(mic.kind == .sfSymbol)
    }

    @Test func presetsContainsOnlyCmuxAgent() {
        // Arrow keys moved to the floating joystick; one ribbon remains.
        #expect(RibbonConfig.presets == [.cmuxAgent])
    }

    @Test func ribbonRoundTripPreservesShape() throws {
        let data = try JSONEncoder.telecmux.encode(RibbonConfig.cmuxAgent)
        let decoded = try JSONDecoder.telecmux.decode(RibbonConfig.self, from: data)
        #expect(decoded.name == RibbonConfig.cmuxAgent.name)
        #expect(decoded.buttons.count == RibbonConfig.cmuxAgent.buttons.count)
    }
}
