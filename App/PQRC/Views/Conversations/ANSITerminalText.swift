// SPDX-License-Identifier: AGPL-3.0-only
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

    /// Render `input` (a whole buffer) as styled text with the ANSI escapes interpreted
    /// and stripped. Convenience over `fold(_:into:)` for tests / one-shot callers; the
    /// LIVE terminal uses `ANSITerminalRenderer` to parse only newly-appended output (H1).
    static func attributed(_ input: String) -> AttributedString {
        var style = Style()
        return fold(Array(input.unicodeScalars), into: &style).text
    }

    /// Parse `scalars` (a 0-based slice of the buffer) starting from `style`, advancing `style`
    /// to the SGR state at the end. Returns the styled text AND the number of LEADING scalars
    /// consumed — it stops BEFORE a trailing INCOMPLETE escape (a CSI whose final byte hasn't
    /// streamed yet, or a lone trailing ESC) so a caller streaming in chunks can re-offer those
    /// bytes once the rest arrives, instead of corrupting a color code split across the boundary.
    /// For a complete buffer `consumed == scalars.count`, so `attributed(_:)` is unchanged.
    static func fold(_ scalars: [Unicode.Scalar], into style: inout Style) -> (text: AttributedString, consumed: Int) {
        var out = AttributedString()
        var run = ""
        var i = 0
        var consumed = 0
        let n = scalars.count

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

        while i < n {
            let s = scalars[i]
            if s == "\u{1B}" {
                // The whole escape sequence must be present in this slice; if it's cut off at
                // the end, hold it back (consumed stops here) for the next render.
                if i + 1 >= n { break }  // lone trailing ESC — incomplete
                if scalars[i + 1] == "[" {
                    // CSI: ESC '[' params final-byte (final byte in '@'…'~').
                    var j = i + 2
                    while j < n, !(scalars[j] >= "@" && scalars[j] <= "~") { j += 1 }
                    if j >= n { break }  // CSI final byte hasn't streamed yet — incomplete
                    flush()
                    if scalars[j] == "m" {
                        let params = String(String.UnicodeScalarView(scalars[(i + 2)..<j]))
                        applySGR(params, to: &style)
                    }
                    // Non-SGR CSI (cursor/erase) is dropped from the scrollback.
                    i = j + 1
                    consumed = i
                    continue
                }
                // A lone ESC not introducing a CSI (e.g. ESC ] … OSC title): skip just the ESC
                // so it never renders as a raw glyph; the following bytes show as text.
                flush()
                i += 1
                consumed = i
                continue
            }
            run.unicodeScalars.append(s)
            i += 1
            consumed = i
        }
        flush()
        return (out, consumed)
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

/// Incremental ANSI renderer for a LIVE terminal stream (H1). Caches the parsed
/// `AttributedString` and folds in only newly-appended output, carrying SGR state across
/// chunks — so a streaming session costs O(total) instead of re-parsing the whole (≤256 KB)
/// buffer on every chunk (that was O(n²), the source of progressive frame drops). A head-trim
/// (`AppModel` bounds the buffer) shrinks it, changing the prefix → a one-off full reparse; an
/// escape split across the append boundary is held back by `fold` until the rest streams.
/// A reference type held in `@State` so the cache survives the view's body re-evaluations.
final class ANSITerminalRenderer {
    private var parsed = 0  // scalars already folded into `attributed`
    private var trailingStyle = ANSITerminalText.Style()
    private var attributed = AttributedString()

    func render(_ output: String) -> AttributedString {
        let scalars = Array(output.unicodeScalars)
        if scalars.count < parsed {
            // Buffer shrank (head-trim) → the prefix changed; re-parse from scratch.
            attributed = AttributedString()
            trailingStyle = ANSITerminalText.Style()
            parsed = 0
        }
        if scalars.count > parsed {
            let (delta, consumed) = ANSITerminalText.fold(Array(scalars[parsed...]), into: &trailingStyle)
            attributed.append(delta)
            parsed += consumed
        }
        return attributed
    }
}
