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

@Suite("Screen Highlighter Tests")
struct ScreenHighlighterTests {
    @Test func displayWidthCountsCJKAsTwo() {
        #expect(CmuxScreenHighlighter.displayWidth("abc") == 3)
        #expect(CmuxScreenHighlighter.displayWidth("中文字") == 6)
        #expect(CmuxScreenHighlighter.displayWidth("a中b") == 4)
    }

    @Test func hardWrapMergesFullWidthNormalLine() {
        // 40 CJK chars = 80 columns in an 80-column pane → full row → the
        // following normal row is a wrap continuation and must merge.
        let full = String(repeating: "中", count: 40)
        let screen = full + "\n继续的内容"
        let lines = CmuxScreenHighlighter.lines(screen, paneColumns: 80)
        #expect(lines.count == 1)
        #expect(lines[0].text == full + "继续的内容")
    }

    @Test func shortLineDoesNotMerge() {
        let screen = "短行\n另一行"
        let lines = CmuxScreenHighlighter.lines(screen, paneColumns: 80)
        #expect(lines.count == 2)
    }

    @Test func toolResultLineClassified() {
        let lines = CmuxScreenHighlighter.lines("  ⎿  Read 124 lines", paneColumns: 80)
        guard case .toolResult(let isError) = lines[0].kind else {
            Issue.record("Expected toolResult"); return
        }
        #expect(isError == false)
    }

    @Test func toolResultErrorFlagged() {
        let lines = CmuxScreenHighlighter.lines("  ⎿  Error: command not found", paneColumns: 80)
        guard case .toolResult(let isError) = lines[0].kind else {
            Issue.record("Expected toolResult"); return
        }
        #expect(isError == true)
    }

    @Test func modeBannerRequiresLineStart() {
        // Prose that merely mentions the phrase must NOT become a banner.
        let prose = CmuxScreenHighlighter.lines("我们聊聊 plan mode on 这个词", paneColumns: 80)
        if case .modeIndicator = prose[0].kind {
            Issue.record("Prose wrongly classified as mode banner")
        }
        // The real banner (⏵⏵-prefixed) must.
        let banner = CmuxScreenHighlighter.lines("⏵⏵ accept edits on (shift+tab to cycle)", paneColumns: 80)
        guard case .modeIndicator = banner[0].kind else {
            Issue.record("Banner not classified"); return
        }
    }
}
