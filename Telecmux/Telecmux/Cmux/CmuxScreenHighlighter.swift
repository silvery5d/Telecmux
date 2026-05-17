import SwiftUI

/// Heuristic colorizer for `cmux read-screen` plain-text output.
///
/// cmux 0.64 returns text with ANSI escape sequences already consumed, so we
/// can't reconstruct real color. Instead we recognize a small set of Claude
/// Code / cmux notification token shapes and colorize them line-by-line.
///
/// Coverage is intentionally narrow — we'd rather miss highlighting than
/// mis-color a line. Once cmux ships an ANSI-preserving read method, this
/// whole file is throwaway.
enum CmuxScreenHighlighter {

    /// Default foreground for any line that doesn't match a rule.
    static let defaultColor: Color = .green
    static let baseFont: Font = .system(.footnote, design: .monospaced)

    static func highlight(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString("") }
        var out = AttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() {
            out.append(highlightLine(String(line)))
            if i < lines.count - 1 {
                out.append(AttributedString("\n"))
            }
        }
        return out
    }

    /// Line-level coloring. Rules apply in order; first match wins, except
    /// `optionNumber` is additive (bolds the leading digit substring).
    private static func highlightLine(_ line: String) -> AttributedString {
        var attr = AttributedString(line)
        attr.font = baseFont
        attr.foregroundColor = defaultColor

        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first else { return attr }

        // 1. Status dots — Claude Code / cmux use these as line-leading markers.
        switch first {
        case "⏺":          attr.foregroundColor = Color(red: 0.4, green: 0.8, blue: 1.0)   // cyan-ish, "thinking"
        case "✻", "✶", "✺": attr.foregroundColor = .yellow                                  // streaming
        case "✳":          attr.foregroundColor = .purple                                  // alt streaming
        case "●":          attr.foregroundColor = .gray                                    // muted dot
        case "✓":          attr.foregroundColor = Color(red: 0.4, green: 1.0, blue: 0.5)  // bright green, completed
        case "✗", "✘":     attr.foregroundColor = .red
        case "⚠":          attr.foregroundColor = .orange
        case "?":          attr.foregroundColor = .yellow
        default: break
        }

        // 2. User input prefix "> " or "│ > "
        if trimmed.hasPrefix("> ") || line.contains("│ > ") {
            attr.foregroundColor = Color(red: 0.5, green: 0.7, blue: 1.0)  // soft blue
        }

        // 3. Option menu: leading "N. " gets bold weight (sub-string highlight)
        if let optionRange = line.range(of: #"^\s*[1-9]\."#, options: .regularExpression),
           let attrRange = Range(NSRange(optionRange, in: line), in: attr) {
            attr[attrRange].font = baseFont.bold()
            attr[attrRange].foregroundColor = .white
        }

        // 4. File path token "name.ext:line" — underline (sub-string)
        let pathPattern = #"[\w./_-]+\.(swift|ts|tsx|js|jsx|py|go|rs|md|json|yml|yaml|sh|html|css|c|cpp|h|m)(:\d+)?"#
        if let regex = try? NSRegularExpression(pattern: pathPattern) {
            let nsLine = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for m in matches {
                if let r = Range(m.range, in: line), let ar = Range(NSRange(r, in: line), in: attr) {
                    attr[ar].underlineStyle = .single
                }
            }
        }

        // 5. Code fence line "```" → muted accent
        if trimmed.hasPrefix("```") {
            attr.foregroundColor = Color(white: 0.6)
        }

        return attr
    }
}
