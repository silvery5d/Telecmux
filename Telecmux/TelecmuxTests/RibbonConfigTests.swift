import Testing
import Foundation
@testable import Telecmux

@Suite("RibbonConfig Tests")
struct RibbonConfigTests {
    @Test func cmuxAgentRibbonShape() {
        let r = RibbonConfig.cmuxAgent
        #expect(r.name == "Cmux Agent")
        #expect(r.buttons.count == 7)
        #expect(r.buttons.map(\.label) == ["1", "2", "3", "return", "escape", "bell", "mic.fill"])
    }

    @Test func numberButtonsSendTheirDigit() throws {
        for (i, expected) in ["1", "2", "3"].enumerated() {
            guard case .sendText(let value) = RibbonConfig.cmuxAgent.buttons[i].action else {
                Issue.record("Expected sendText action at index \(i)")
                return
            }
            #expect(value == expected)
        }
    }

    @Test func returnButtonSendsNewline() throws {
        guard case .sendText(let value) = RibbonConfig.cmuxAgent.buttons[3].action else {
            Issue.record("Expected sendText action for return")
            return
        }
        #expect(value == "\n")
    }

    @Test func escapeButtonSendsEscapeKey() throws {
        guard case .sendKey(let key) = RibbonConfig.cmuxAgent.buttons[4].action else {
            Issue.record("Expected sendKey action for escape")
            return
        }
        #expect(key == "escape")
    }

    @Test func bellButtonJumpsToUnread() throws {
        guard case .jumpToUnread = RibbonConfig.cmuxAgent.buttons[5].action else {
            Issue.record("Expected jumpToUnread action for bell")
            return
        }
    }

    @Test func micButtonOpensVoiceInput() throws {
        let mic = RibbonConfig.cmuxAgent.buttons[6]
        guard case .voiceInput = mic.action else {
            Issue.record("Expected voiceInput action")
            return
        }
        #expect(mic.kind == .sfSymbol)
    }

    @Test func presetsContainsCmuxAgent() {
        #expect(RibbonConfig.presets == [.cmuxAgent])
    }

    @Test func ribbonRoundTripPreservesShape() throws {
        let data = try JSONEncoder.telecmux.encode(RibbonConfig.cmuxAgent)
        let decoded = try JSONDecoder.telecmux.decode(RibbonConfig.self, from: data)
        #expect(decoded.name == RibbonConfig.cmuxAgent.name)
        #expect(decoded.buttons.count == RibbonConfig.cmuxAgent.buttons.count)
    }
}
