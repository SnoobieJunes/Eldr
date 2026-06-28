import SwiftUI

/// Pure ANSI SGR (Select Graphic Rendition) → `AttributedString` renderer for the
/// interactive terminal (feature 9, "enhanced PTY"). DISPLAY-ONLY — the streamed
/// output is never persisted (CLAUDE.md invariant 12). Handles the escape sequences
/// a coding agent's shell commonly emits: the 16 basic foreground/background colors
/// (30–37 / 90–97, 40–47 / 100–107), bold, dim, italic, underline, and reset. Other
/// CSI sequences (cursor moves, screen erases) are DROPPED rather than shown raw —
/// a scrollback view doesn't move a cursor. Static + pure so it's unit-testable
/// without building a view.
enum ANSITerminalText {
    struct Style: Equatable {
        var fg: Color?
        var bg: Color?
        var bold = false
        var italic = false
        var underline = false
    }

    /// Render `input` (a chunk of combined stdout/stderr) as styled text with the
    /// ANSI escapes interpreted and stripped.
    static func attributed(_ input: String) -> AttributedString {
        var out = AttributedString()
        var style = Style()
        let scalars = Array(input.unicodeScalars)
        var run = ""
        var i = 0

        func flush() {
            guard !run.isEmpty else { return }
            var seg = AttributedString(run)
            if let fg = style.fg { seg.foregroundColor = fg }
            if let bg = style.bg { seg.backgroundColor = bg }
            var font = Font.system(.caption, design: .monospaced)
            if style.bold { font = font.bold() }
            if style.italic { font = font.italic() }
            seg.font = font
            if style.underline { seg.underlineStyle = Text.LineStyle.single }
            out.append(seg)
            run = ""
        }

        while i < scalars.count {
            let s = scalars[i]
            // CSI: ESC '[' params final-byte
            if s == "\u{1B}", i + 1 < scalars.count, scalars[i + 1] == "[" {
                flush()
                var j = i + 2
                var params = ""
                while j < scalars.count, !(scalars[j] >= "@" && scalars[j] <= "~") {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                let final: Unicode.Scalar = j < scalars.count ? scalars[j] : "m"
                if final == "m" { applySGR(params, to: &style) }
                // Non-SGR CSI (cursor/erase) is dropped from the scrollback.
                i = j + 1
                continue
            }
            // Other lone ESC sequences (e.g. ESC ] … BEL OSC titles): skip the ESC so
            // it never renders as a raw glyph; the following bytes show as text.
            if s == "\u{1B}" { i += 1; continue }
            run.unicodeScalars.append(s)
            i += 1
        }
        flush()
        return out
    }

    private static func applySGR(_ params: String, to style: inout Style) {
        let codes = params.split(separator: ";").map { Int($0) ?? 0 }
        for code in (codes.isEmpty ? [0] : codes) {
            switch code {
            case 0: style = Style()
            case 1: style.bold = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 22: style.bold = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 30...37: style.fg = basic(code - 30)
            case 39: style.fg = nil
            case 40...47: style.bg = basic(code - 40)
            case 49: style.bg = nil
            case 90...97: style.fg = bright(code - 90)
            case 100...107: style.bg = bright(code - 100)
            default: break
            }
        }
    }

    private static let basicColors: [Color] = [
        .black, .red, .green, .yellow, .blue, .purple, .teal, Color(white: 0.85),
    ]
    private static let brightColors: [Color] = [
        Color(white: 0.5), .red, .green, .yellow, .blue, .pink, .cyan, .white,
    ]
    private static func basic(_ n: Int) -> Color { basicColors[min(max(n, 0), 7)] }
    private static func bright(_ n: Int) -> Color { brightColors[min(max(n, 0), 7)] }
}
