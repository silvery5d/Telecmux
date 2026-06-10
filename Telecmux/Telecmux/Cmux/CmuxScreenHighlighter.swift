import SwiftUI
import UIKit

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

        /// Tool result lines — Claude Code prefixes every tool's output
        /// summary with "⎿" ("⎿ Read 124 lines", "⎿ Error: …"). Secondary
        /// information, rendered dim; error results rendered red.
        case toolResult(isError: Bool)

        /// Todo checklist rows from TodoWrite ("☐ pending" / "☒ done").
        case todo(done: Bool)

        /// Numbered menu option ("1. Yes") — Claude's multiple-choice rows.
        /// The currently-selected one usually carries ❯ and lands in
        /// `.userInput`; the rest get this brighter treatment.
        case menuOption

        /// One row of a box-drawing table ("│ a │ b │" or "├──┼──┤").
        /// Table rows depend on column alignment: they must never be
        /// collapsed, merged, or soft-wrapped. PaneFocusView groups
        /// consecutive table rows into one horizontally-scrollable block.
        case tableRow

        /// Anything else; the Color is a heuristic hint based on leading
        /// glyph (status dots, ✓ ✗ ⚠ etc).
        case normal(Color)
    }

    /// Light gray — close to macOS Terminal's default foreground on a dark
    /// background, which is what Claude Code itself draws on.
    static let defaultColor: Color = Color(white: 0.92)

    /// A renderable unit: either one ordinary line, or a run of consecutive
    /// table rows that must be laid out together (shared horizontal scroll,
    /// no per-line wrapping) to preserve column alignment.
    enum RenderBlock: Identifiable {
        case single(Line)
        case table([Line])

        var id: UUID {
            switch self {
            case .single(let l): l.id
            case .table(let rows): rows.first?.id ?? UUID()
            }
        }
    }

    /// Classify + group: consecutive `.tableRow` lines fold into one
    /// `.table` block; everything else passes through as `.single`.
    static func blocks(_ screen: String, paneColumns: Int = 80) -> [RenderBlock] {
        var out: [RenderBlock] = []
        var run: [Line] = []
        for line in lines(screen, paneColumns: paneColumns) {
            if case .tableRow = line.kind {
                run.append(line)
            } else {
                if !run.isEmpty { out.append(.table(run)); run = [] }
                out.append(.single(line))
            }
        }
        if !run.isEmpty { out.append(.table(run)) }
        return out
    }

    // MARK: - entry point

    /// Classify a screen snapshot into lines.
    ///
    /// - reflow: true  — phone-width adaptation: consecutive dividers
    ///   collapse to one, and cmux-wrap continuations merge back into
    ///   their logical line so SwiftUI can re-wrap them.
    /// - reflow: false — terminal-grid mode: every physical row is kept
    ///   verbatim (the view renders rows un-wrapped at the pane's native
    ///   width with pan + zoom), so no collapsing or merging is wanted.
    static func lines(_ screen: String, paneColumns: Int = 80, reflow: Bool = true) -> [Line] {
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
            } else if isTableRow(s) {
                // Must run before isDivider: a table rule line ("├──┼──┤")
                // is ≥95% box chars and would otherwise collapse into a
                // plain divider, destroying the table's structure.
                kind = .tableRow
            } else if isDivider(s) {
                if reflow {
                    // Collapse consecutive divider lines into a single row.
                    if lastWasDivider { continue }
                    lastWasDivider = true
                    result.append(Line(text: "", kind: .divider))
                    continue
                }
                // Grid mode keeps the original glyphs at native width.
                kind = .divider
            } else if let toolResult = classifyToolResult(s) {
                kind = toolResult
            } else if isStatusLine(s) {
                kind = .status
            } else if let color = modeIndicatorColor(in: s) {
                kind = .modeIndicator(color)
            } else if let todo = classifyTodo(s) {
                kind = todo
            } else if isMenuOption(s) {
                kind = .menuOption
            } else {
                kind = .normal(legacyLeadingColor(for: s))
            }

            lastWasDivider = false
            result.append(Line(text: s, kind: kind))
        }

        // Second pass: promote "❯ ..." lines to `.userInput`, except the
        // active input-prompt sitting inside Claude's bottom input box.
        let withInputs = reclassifyUserInputs(result)
        guard reflow else { return withInputs }
        // Third pass (reflow only): merge cmux-wrap continuations back into
        // their originating logical line so SwiftUI Text can re-wrap them.
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
    /// Rule C — long-line wrap fallback: previous row's *display width*
    /// (CJK counts 2 columns) reached ≥85% of `paneColumns` AND it was
    /// userInput/diff.
    ///
    /// Rule D — hard-wrap continuation for ordinary rows: the previous row
    /// filled the surface to (paneColumns − 1) columns of display width.
    /// A terminal hard-wraps at exactly the column limit, so a full row is
    /// near-certain to be wrapped (a logical line ending precisely at the
    /// boundary is ~1/paneColumns). Applies to .normal → .normal and
    /// .toolResult → .normal; the continuation keeps the previous kind.
    /// Caveat: when the wrap point lands right after a space, cmux strips
    /// the trailing space and the width check fails — those wraps stay
    /// split (a miss, never a false merge). Chinese prose has no spaces, so
    /// it merges essentially every time.
    ///
    /// Exception: menu markers like "❯ 1 Yes" never merge. The next ❯ row
    /// is a separate option, not a wrap continuation.
    private static func unwrapContinuations(_ lines: [Line], paneColumns: Int) -> [Line] {
        let opPattern         = "^\\s{2,}[+\\-]\\s"
        let indentedPattern   = "^\\s{2,}\\S"
        let menuMarkerPattern = "^❯\\s+\\d"
        let widthThreshold    = max(20, Int(Double(paneColumns) * 0.85))
        let fullRowThreshold  = max(20, paneColumns - 1)

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
            let prevWidth     = displayWidth(prev.text)
            let prevWide      = prevWidth >= widthThreshold
            let prevFull      = prevWidth >= fullRowThreshold

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
            let qualifiesBC: Bool = {
                if indentedMatch != nil { return prev.kind.allowsContinuation }
                if prevWide              { return prev.kind.allowsContinuation }
                return false
            }()
            if qualifiesBC {
                let stripped = curr.drop { $0 == " " || $0 == "\t" }
                out[out.count - 1] = Line(text: prev.text + stripped, kind: prev.kind)
                continue
            }

            // Rule D — generic hard-wrap merge. No whitespace stripping:
            // a hard wrap cuts mid-character-run, so the continuation's
            // leading characters belong verbatim to the previous line.
            if prevFull, prev.kind.allowsHardWrapMerge {
                out[out.count - 1] = Line(text: prev.text + curr, kind: prev.kind)
                continue
            }

            out.append(line)
        }
        return out
    }

    /// Whether a scalar occupies two terminal columns (East Asian wide /
    /// fullwidth: CJK ideographs, kana, hangul, fullwidth forms, emoji).
    static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,     // Hangul Jamo
             0x2E80...0x303E,     // CJK Radicals, Kangxi, CJK punctuation
             0x3041...0x33FF,     // Hiragana, Katakana, CJK compat
             0x3400...0x4DBF,     // CJK Ext A
             0x4E00...0x9FFF,     // CJK Unified
             0xA000...0xA4CF,     // Yi
             0xAC00...0xD7A3,     // Hangul syllables
             0xF900...0xFAFF,     // CJK compat ideographs
             0xFE30...0xFE4F,     // CJK compat forms
             0xFF00...0xFF60,     // Fullwidth forms
             0xFFE0...0xFFE6,     // Fullwidth signs
             0x1F300...0x1FAFF,   // Emoji & pictographs
             0x20000...0x3FFFD:   // CJK Ext B+
            return true
        default:
            return false
        }
    }

    /// Terminal column width of a string — wide scalars count two columns.
    /// Close enough to wcwidth for wrap detection without a full table.
    static func displayWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isWideScalar($1) ? 2 : 1) }
    }

    /// Build a grid-exact AttributedString for one terminal row.
    ///
    /// SF Mono has no CJK glyphs; the system falls back to PingFang SC whose
    /// fullwidth advance is 1.0 em — but two terminal cells are 2 × 0.6 em =
    /// 1.2 em. (A cascadeList with a scaled descriptor doesn't fix this:
    /// UIKit ignores the fallback's size attribute.) Instead we add kern to
    /// every wide character so its advance lands on exactly two cells:
    /// kern = 1.2·size − 1.0·size = 0.2·size.
    /// Cache of built rows. read-screen mostly returns the same lines
    /// every poll, so memoizing by (text, size, weight) skips the per-char
    /// kern pass for unchanged rows. Bounded by periodic wholesale reset.
    private static var gridCache: [String: AttributedString] = [:]

    /// Bright blue for inline URLs / file paths — the closest plain-text
    /// stand-in for the links Claude Code colors blue on the Mac.
    private static let inlineLinkColor = Color(red: 0.38, green: 0.66, blue: 1.0)
    private static let inlinePatterns: [NSRegularExpression] = {
        let sources = [
            #"https?://[^\s)\]>'\"]+"#,
            #"(?:[\w@~.-]+/)*[\w.-]+\.(?:swift|ts|tsx|js|jsx|py|go|rs|rb|md|json|yml|yaml|toml|sh|c|cc|cpp|h|hpp|m|mm|css|html|sql|proto)(?::\d+)?"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func gridAttributed(_ text: String,
                               fontSize: CGFloat,
                               weight: UIFont.Weight = .regular,
                               inlineHighlights: Bool = false) -> AttributedString {
        let cacheKey = "\(Int(fontSize * 100))|\(weight.rawValue)|\(inlineHighlights ? 1 : 0)|\(text)"
        if let hit = gridCache[cacheKey] { return hit }
        if gridCache.count > 4000 { gridCache.removeAll(keepingCapacity: true) }

        var attr = AttributedString(text)
        attr.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        let wideKern = fontSize * 0.2

        // Apply kern over contiguous wide runs (fewer attribute spans than
        // per-character assignment; kern is per-glyph within the run).
        var runStart: AttributedString.Index? = nil
        var idx = attr.startIndex
        for ch in text {
            let next = attr.index(afterCharacter: idx)
            let wide = ch.unicodeScalars.first.map(isWideScalar) ?? false
            if wide {
                if runStart == nil { runStart = idx }
            } else if let start = runStart {
                attr[start..<idx].kern = wideKern
                runStart = nil
            }
            idx = next
        }
        if let start = runStart {
            attr[start..<attr.endIndex].kern = wideKern
        }
        // Inline URL / file-path tinting (normal rows only — reverse-video
        // and diff rows keep their uniform treatment).
        if inlineHighlights {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            for regex in inlinePatterns {
                for m in regex.matches(in: text, range: full) {
                    if let r = Range(m.range, in: text), let ar = Range(r, in: attr) {
                        attr[ar].foregroundColor = inlineLinkColor
                    }
                }
            }
        }

        gridCache[cacheKey] = attr
        return attr
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

    /// Table rows come in two shapes:
    ///   content rows — "│ name │ value │": two or more vertical bars
    ///   rule rows    — "├────┼────┤" / "┌──┬──┐": contain column joints
    /// Claude's input box ("╭──╮" / "│ > … │") has at most a plain border:
    /// its top/bottom carry no joints (┬ ┴ ┼) and its middle has exactly
    /// two bars — excluded by requiring joints OR ≥2 bars with inner text.
    private static let tableJoints: Set<Character> = ["┬", "┴", "┼", "╤", "╧", "╪", "╦", "╩", "╬"]
    private static let verticalBars: Set<Character> = ["│", "┃", "║"]

    private static func isTableRow(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        // Rule row: any column joint marks a table frame line.
        if trimmed.contains(where: { tableJoints.contains($0) }) { return true }
        // Content row: at least 3 bars (left edge, ≥1 column split, right
        // edge). Two bars alone is Claude's input box "│ > … │" — skip it.
        let bars = trimmed.filter { verticalBars.contains($0) }.count
        return bars >= 3
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

    /// Tool result rows: "⎿ Read 124 lines", "⎿ Error: …". The error flag
    /// looks only at the text right after the marker, so a successful result
    /// merely *mentioning* "error" deeper in the line doesn't go red.
    private static func classifyToolResult(_ s: String) -> Kind? {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("⎿") else { return nil }
        let body = trimmed.dropFirst().drop { $0 == " " }
        let isError = body.hasPrefix("Error") || body.hasPrefix("error")
        return .toolResult(isError: isError)
    }

    /// TodoWrite checklist rows. Claude Code marks pending items ☐ and
    /// completed ones ☒ (some builds use ◻/◼); in-progress shows ◐.
    private static func classifyTodo(_ s: String) -> Kind? {
        let trimmed = s.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return nil }
        switch first {
        case "☐", "◻", "◐": return .todo(done: false)
        case "☒", "◼":      return .todo(done: true)
        default:             return nil
        }
    }

    /// Numbered option rows: "1. Yes" / "  2. No, tell Claude what to do".
    /// Also matches ordinary markdown ordered lists — acceptable, the
    /// brighter treatment reads fine for those too.
    private static func isMenuOption(_ s: String) -> Bool {
        s.range(of: #"^\s*\d{1,2}\.\s+\S"#, options: .regularExpression) != nil
    }

    /// Status spinner glyphs Claude / cmux rotate while busy.
    private static let statusPrefixGlyphs: Set<Character> = [
        "⏺", "✻", "✶", "✳", "✺", "●", "✦", "✧", "✫", "✩", "✢", "✽", "·", "*",
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
    ///
    /// Anchored to the line start (after the optional ⏵⏵ marker Claude Code
    /// draws) — a `contains` check used to mis-color ordinary chat text that
    /// merely *talked about* "plan mode on".
    private static func modeIndicatorColor(in s: String) -> Color? {
        var head = s.trimmingCharacters(in: .whitespaces).lowercased()
        while head.hasPrefix("⏵") || head.hasPrefix("▶") {
            head = String(head.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Colors match Claude Code's TUI as observed on the user's Mac:
        // plan = deep green, accept edits = purple, auto = orange.
        if head.hasPrefix("plan mode on")    { return Color(red: 0.25, green: 0.65, blue: 0.40) } // deep green
        if head.hasPrefix("accept edits on") { return Color(red: 0.70, green: 0.50, blue: 0.95) } // purple
        if head.hasPrefix("auto mode on")    { return Color(red: 1.00, green: 0.62, blue: 0.26) } // orange
        return nil
    }

    /// Pre-existing per-line color heuristic — used for `.normal` lines.
    private static func legacyLeadingColor(for line: String) -> Color {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard let first = trimmed.first else { return defaultColor }
        if trimmed.hasPrefix("> ")  { return Color(red: 0.5, green: 0.7, blue: 1.0) }
        // Word-prefix signals (case kept strict to avoid false hits in prose).
        if trimmed.hasPrefix("Error") || trimmed.hasPrefix("error:")   { return .red }
        if trimmed.hasPrefix("Warning") || trimmed.hasPrefix("warning:") { return .orange }
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
    /// Whether a continuation row may absorb into this kind during unwrap
    /// (Rules B/C — indent or near-full-width signals).
    var allowsContinuation: Bool {
        switch self {
        case .userInput, .diffAdded, .diffRemoved: true
        default: false
        }
    }

    /// Whether Rule D (exact hard-wrap width match) may merge a .normal
    /// continuation into this kind. Broader than `allowsContinuation`
    /// because the full-width signal is much stronger evidence.
    var allowsHardWrapMerge: Bool {
        switch self {
        case .normal, .toolResult, .userInput, .diffAdded, .diffRemoved: true
        default: false
        }
    }
}
