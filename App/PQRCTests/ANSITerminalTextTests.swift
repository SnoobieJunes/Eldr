import SwiftUI
import Testing

@testable import EldrChat

/// The interactive-terminal ANSI renderer (feature 9). Display-only; the streamed
/// output is never persisted (invariant 12), so these assert on the rendered text.
@Suite("ANSI terminal rendering")
struct ANSITerminalTextTests {
    /// SGR color/bold escapes are interpreted and STRIPPED — the visible characters
    /// are exactly the plain text (no raw escape glyphs leak through).
    @Test func stripsSGREscapes() {
        let s = ANSITerminalText.attributed("\u{1B}[31mred\u{1B}[0m and \u{1B}[1mbold\u{1B}[22m")
        #expect(String(s.characters) == "red and bold")
    }

    /// A non-SGR CSI (cursor move / line erase) is DROPPED, not shown raw — a
    /// scrollback view doesn't move a cursor.
    @Test func dropsNonSGRCSI() {
        let s = ANSITerminalText.attributed("a\u{1B}[2Kb\u{1B}[10;5Hc")
        #expect(String(s.characters) == "abc")
    }

    /// Plain text with no escapes is unchanged (including newlines).
    @Test func plainTextUnchanged() {
        let s = ANSITerminalText.attributed("hello world\n$ ")
        #expect(String(s.characters) == "hello world\n$ ")
    }

    /// A colored run actually carries a foreground-color attribute (the color is
    /// applied, not just stripped).
    @Test func colorRunCarriesAttribute() {
        let s = ANSITerminalText.attributed("\u{1B}[32mok\u{1B}[0m")
        #expect(s.runs.contains { $0.foregroundColor != nil })
    }

    /// H1: feeding the buffer to the incremental renderer one scalar at a time — the WORST
    /// case, splitting every escape sequence at every position — converges to the SAME visible
    /// text as one whole-buffer parse. Proves `fold` correctly holds back an incomplete trailing
    /// escape until the rest streams, so a color code split across a chunk boundary isn't
    /// corrupted.
    @Test func incrementalRenderMatchesWholeBuffer() {
        let full = "\u{1B}[31mred\u{1B}[0m plain \u{1B}[1;32mbold-green\u{1B}[0m done"
        let whole = String(ANSITerminalText.attributed(full).characters)
        let renderer = ANSITerminalRenderer()
        var acc = ""
        var result = AttributedString()
        for scalar in full.unicodeScalars {
            acc.unicodeScalars.append(scalar)
            result = renderer.render(acc)
        }
        #expect(whole == "red plain bold-green done")
        #expect(String(result.characters) == whole)
    }

    /// H1: a head-trim (the buffer shrinks below what was already parsed — AppModel bounds it)
    /// makes the renderer re-parse from scratch instead of mis-appending onto a stale prefix.
    @Test func rendererResetsOnHeadTrim() {
        let renderer = ANSITerminalRenderer()
        _ = renderer.render("aaaaaaaa\u{1B}[32mgreen\u{1B}[0m more text here")
        let out = renderer.render("tail")  // shorter → simulates a head-trim
        #expect(String(out.characters) == "tail")
    }
}
