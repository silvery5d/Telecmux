import SwiftUI

/// Classifies each line of a `cmux read-screen` snapshot into a renderable
/// `Kind` so PaneFocusView can pick the right SwiftUI view per line.
///
/// cmux 0.64 strips ANSI escape sequences before returning text, so all
/// styling has to be reconstructed by pattern. Coverage is intentionally
/// narrow — missing highlighting is fine; mis-coloring is not. Replace this
/// whole file once cmux ships an ANSI-preserving read method
/// (https://github.com/manaflow-ai/cmux/issues/4273).
enum CmuxScreenHighlighter {

    /// One screen line plus how PaneFocusView should render it.
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
    }

    enum Kind {
        /// Mostly box-drawing horizontals — Claude Code's input box edges,
        /// section separators. Multiple consecutive lines of this kind are
        /// collapsed to a single Line in the output stream so wrap-induced
        /// "multi-row line" smears don't appear on iPhone.
        case divider

        /// ```fence boundary``` itself.
        case codeFence

        /// `+ ...` inside a fenced code block.
        case diffAdded

        /// `- ...` inside a fenced code block.
        case diffRemoved

        /// Other content inside a fenced code block.
        case codeBody

        /// "plan mode on" / "accept edits on" / "auto mode on" — Claude
        /// mode banner, sticky at the bottom of its surface.
        case modeIndicator(Color)

        /// "✻ Cogitating… 1m 35s (esc to interrupt)" and friends. The
        /// leading glyph rotates while Claude is busy.
        case status

        /// User-typed command echo (lines starting with "❯ "). Rendered
        /// reverse-video to make Claude's own output distinct from what the
        /// user invoked. The live input-prompt "❯ " inside the dividerbox
        /// is excluded — that one stays as `.normal`.
        case userInput

        /// Anything else; the Color is a heuristic hint based on leading
        /// glyph (status dots, ✓ ✗ ⚠ etc).
        case normal(Color)
    }

    /// Light gray — close to macOS Terminal's default foreground on a dark
    /// background, which is what Claude Code itself draws on.
    static let defaultColor: Color = Color(white: 0.92)

    // MARK: - entry point

    static func lines(_ screen: String, paneColumns: Int = 80) -> [Line] {
        let rawLines = screen.split(separator: "\n", omittingEmptySubsequences: false)
        var result: [Line] = []
        var inCodeFence = false
        var lastWasDivider = false

        for slice in rawLines {
            let s = String(slice)
            let kind: Kind

            if isCodeFence(s) {
                inCodeFence.toggle()
                kind = .codeFence
            } else if isDiffLine(s, op: "+") {
                // Claude shows diffs as "  17 + content" — line number,
                // space, +/-, space, code. Independent of code fences.
                kind = .diffAdded
            } else if isDiffLine(s, op: "-") {
                kind = .diffRemoved
            } else if inCodeFence {
                kind = .codeBody
            } else if isDivider(s) {
                // Collapse consecutive divider lines into a single rendered row.
                if lastWasDivider { continue }
                lastWasDivider = true
                result.append(Line(text: "", kind: .divider))
                continue
            } else if isStatusLine(s) {
                kind = .status
            } else if let color = modeIndicatorColor(in: s) {
                kind = .modeIndicator(color)
            } else {
                kind = .normal(legacyLeadingColor(for: s))
            }

            lastWasDivider = false
            result.append(Line(text: s, kind: kind))
        }

        // Second pass: promote "❯ ..." lines to `.userInput`, except the
        // active input-prompt sitting inside Claude's bottom input box.
        let withInputs = reclassifyUserInputs(result)
        // Third pass: merge cmux-wrap continuations back into their
        // originating logical line so SwiftUI Text can re-wrap them to
        // iPhone width naturally.
        return unwrapContinuations(withInputs, paneColumns: paneColumns)
    }

    /// Merge cmux-wrap continuations back into their logical line.
    ///
    /// When cmux wraps a long logical line onto multiple physical rows
    /// (because the surface is only N columns wide), the lower rows lose
    /// their prefix (line number, ❯, +/-). We can detect the continuation
    /// using one of three signals and then **concatenate** the continuation
    /// text back onto the previous row, dropping the prefix whitespace so
    /// SwiftUI's own Text wrapping handles the iPhone width.
    ///
    /// Rule A — explicit op continuation: "  + ..." or "  - ..." (2+ leading
    /// spaces, op, space) with previous row already a diff line.
    ///
    /// Rule B — indented continuation: current row starts with 2+ leading
    /// spaces (no op needed) AND previous row is userInput/diff. Common
    /// when cmux wraps `❯ long-command` onto a second line.
    ///
    /// Rule C — long-line wrap fallback: previous row reached ≥85% of
    /// `paneColumns` AND was userInput/diff. Catches the case where cmux
    /// strips trailing whitespace so we can't rely on exact width.
    ///
    /// Exception: menu markers like "❯ 1 Yes" never merge. The next ❯ row
    /// is a separate option, not a wrap continuation.
    private static func unwrapContinuations(_ lines: [Line], paneColumns: Int) -> [Line] {
        let opPattern         = "^\\s{2,}[+\\-]\\s"
        let indentedPattern   = "^\\s{2,}\\S"
        let menuMarkerPattern = "^❯\\s+\\d"
        let widthThreshold    = max(20, Int(Double(paneColumns) * 0.85))

        var out: [Line] = []
        for line in lines {
            guard let prev = out.last else { out.append(line); continue }
            guard case .normal = line.kind else { out.append(line); continue }

            let curr = line.text
            guard !curr.trimmingCharacters(in: .whitespaces).isEmpty else {
                out.append(line); continue
            }

            // Don't merge into a menu marker — its next sibling is another option.
            if case .userInput = prev.kind,
               prev.text.trimmingCharacters(in: .whitespaces)
                  .range(of: menuMarkerPattern, options: .regularExpression) != nil {
                out.append(line); continue
            }

            let opMatch       = curr.range(of: opPattern,       options: .regularExpression)
            let indentedMatch = curr.range(of: indentedPattern, options: .regularExpression)
            let prevWide      = prev.text.count >= widthThreshold

            // Rule A
            if let m = opMatch,
               case .diffAdded = prev.kind {
                out[out.count - 1] = Line(text: prev.text + String(curr[m.upperBound...]),
                                          kind: .diffAdded); continue
            }
            if let m = opMatch,
               case .diffRemoved = prev.kind {
                out[out.count - 1] = Line(text: prev.text + String(curr[m.upperBound...]),
                                          kind: .diffRemoved); continue
            }

            // Rule B or C — strip leading whitespace, append.
            let qualifies: Bool = {
                if indentedMatch != nil { return prev.kind.allowsContinuation }
                if prevWide              { return prev.kind.allowsContinuation }
                return false
            }()
            if qualifies {
                let stripped = curr.drop { $0 == " " || $0 == "\t" }
                out[out.count - 1] = Line(text: prev.text + stripped, kind: prev.kind)
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// Walk the line stream, find every "❯"-prefixed line, and mark it
    /// `.userInput` UNLESS it's sandwiched between two dividers — that one
    /// is Claude's live input prompt and shouldn't be reverse-videoed.
    private static func reclassifyUserInputs(_ lines: [Line]) -> [Line] {
        let dividerIndexes: [Int] = lines.indices.filter {
            if case .divider = lines[$0].kind { return true } else { return false }
        }
        guard !dividerIndexes.isEmpty else { return lines.map(promoteIfUserInput) }

        var out = lines
        for i in lines.indices {
            guard lines[i].text.trimmingCharacters(in: .whitespaces).hasPrefix("❯") else { continue }
            // Sandwiched = there's a divider both above and below this line,
            // each within `inputBoxRadius` rows (the input box is small).
            let inputBoxRadius = 5
            let prev = dividerIndexes.last(where: { $0 < i })
            let next = dividerIndexes.first(where: { $0 > i })
            let nearAbove = prev.map { (i - $0) <= inputBoxRadius } ?? false
            let nearBelow = next.map { ($0 - i) <= inputBoxRadius } ?? false
            if nearAbove && nearBelow { continue }  // it's the live prompt
            out[i] = Line(text: lines[i].text, kind: .userInput)
        }
        return out
    }

    private static func promoteIfUserInput(_ line: Line) -> Line {
        guard line.text.trimmingCharacters(in: .whitespaces).hasPrefix("❯") else { return line }
        return Line(text: line.text, kind: .userInput)
    }

    // MARK: - classifiers

    /// Box-drawing horizontals + corners. `│` and `║` (vertical bars) are
    /// excluded — a line "│ ... │" shouldn't collapse to a divider.
    private static let horizontalBoxChars: Set<Character> = [
        "─", "═",
        "┌", "┐", "└", "┘",
        "╭", "╮", "╰", "╯",
        "┬", "┴", "├", "┤", "┼",
        "╤", "╧", "╪", "╞", "╡", "╫",
    ]

    private static func isDivider(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return false }
        let boxCount = trimmed.filter { horizontalBoxChars.contains($0) }.count
        return Double(boxCount) / Double(trimmed.count) >= 0.95
    }

    private static func isCodeFence(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    /// Matches Claude's diff format: optional leading spaces, line number,
    /// at least one space, `op` (+ or -), one or more spaces, anything.
    /// Examples that match (op = "+"):
    ///     "  17 +  let foo = bar"
    ///     "123 + }"
    /// Examples that do NOT match:
    ///     "+ standalone marker"     (no leading line number)
    ///     "1 + 1 = 2"               (single trailing space token, no op-space-content rule)
    private static func isDiffLine(_ s: String, op: Character) -> Bool {
        let pattern = "^\\s*\\d+\\s+\\\(op)\\s"
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Status spinner glyphs Claude / cmux rotate while busy.
    private static let statusPrefixGlyphs: Set<Character> = [
        "⏺", "✻", "✶", "✳", "✺", "●", "✦", "✧", "✫", "✩",
    ]

    private static func isStatusLine(_ s: String) -> Bool {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first, statusPrefixGlyphs.contains(first) else {
            return false
        }
        // Has an elapsed-time hint or an interrupt hint nearby — confirms
        // this is a spinner row and not e.g. a finished-task `⏺` checkmark.
        return s.range(of: #"\b\d+(s|m \d+s)\b"#, options: .regularExpression) != nil
            || s.lowercased().contains("interrupt")
    }

    /// Detects sticky mode banners. Returns the accent color for that mode.
    private static func modeIndicatorColor(in s: String) -> Color? {
        let lower = s.lowercased()
        if lower.contains("plan mode on")    { return Color(red: 0.70, green: 0.55, blue: 1.00) } // violet
        if lower.contains("accept edits on") { return Color(red: 1.00, green: 0.78, blue: 0.30) } // amber
        if lower.contains("auto mode on")    { return Color(red: 0.40, green: 0.85, blue: 0.95) } // cyan
        return nil
    }

    /// Pre-existing per-line color heuristic — used for `.normal` lines.
    private static func legacyLeadingColor(for line: String) -> Color {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return defaultColor }
        if trimmed.hasPrefix("> ")  { return Color(red: 0.5, green: 0.7, blue: 1.0) }
        switch first {
        case "⏺":           return Color(red: 0.4, green: 0.8, blue: 1.0)
        case "✓":           return Color(red: 0.4, green: 1.0, blue: 0.5)
        case "✗", "✘":      return .red
        case "⚠":           return .orange
        case "?":           return .yellow
        default:            return defaultColor
        }
    }
}

private extension CmuxScreenHighlighter.Kind {
    /// Whether a continuation row may absorb into this kind during unwrap.
    var allowsContinuation: Bool {
        switch self {
        case .userInput, .diffAdded, .diffRemoved: true
        default: false
        }
    }
}
