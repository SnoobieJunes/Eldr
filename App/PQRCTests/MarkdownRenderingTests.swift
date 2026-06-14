import Foundation
import Testing

@testable import EldrChat

/// The message renderer turns markdown (and a sanitized HTML subset) into block
/// structure. These cover the parser and the HTML→markdown normalizer; the
/// privacy-critical guarantee (no remote loads, no scripts) is exercised by the
/// sanitizer cases. SwiftUI layout itself is covered by the UI smoke tests.
@Suite("Message content rendering")
struct MarkdownRenderingTests {
    @Test func headings_parseByLevel() {
        #expect(MarkdownBlock.parse("# Title") == [.heading(level: 1, text: "Title")])
        #expect(MarkdownBlock.parse("### Deep") == [.heading(level: 3, text: "Deep")])
        // Seven hashes is not a heading.
        #expect(MarkdownBlock.parse("####### nope") == [.paragraph("####### nope")])
    }

    @Test func bulletAndOrderedLists_parse() {
        let blocks = MarkdownBlock.parse("- one\n- two\n1. first\n2. second")
        #expect(blocks == [
            .bullet(level: 0, text: "one"),
            .bullet(level: 0, text: "two"),
            .ordered(number: 1, level: 0, text: "first"),
            .ordered(number: 2, level: 0, text: "second"),
        ])
    }

    @Test func fencedCodeBlock_preservesContentVerbatim() {
        let md = "```swift\nlet x = 1\n# not a heading\n```"
        #expect(MarkdownBlock.parse(md) == [.code(language: "swift", code: "let x = 1\n# not a heading")])
    }

    @Test func blockquote_collectsConsecutiveLines() {
        #expect(MarkdownBlock.parse("> a\n> b") == [.quote(["a", "b"])])
    }

    @Test func horizontalRule_parses() {
        #expect(MarkdownBlock.parse("---") == [.rule])
        #expect(MarkdownBlock.parse("***") == [.rule])
    }

    @Test func table_parsesHeaderAndRows() {
        let md = "| A | B |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
        #expect(MarkdownBlock.parse(md) == [
            .table(headers: ["A", "B"], rows: [["1", "2"], ["3", "4"]])
        ])
    }

    @Test func paragraphs_splitOnBlankLines() {
        #expect(MarkdownBlock.parse("one\ntwo\n\nthree") == [
            .paragraph("one\ntwo"), .paragraph("three"),
        ])
    }

    // MARK: HTML normalization (sanitized, native)

    @Test func html_convertsInlineAndBlockTags() {
        let md = HTMLToMarkdown.convert("<h2>Hi</h2><p>This is <b>bold</b> and <i>it</i>.</p>")
        #expect(md.contains("## Hi"))
        #expect(md.contains("**bold**"))
        #expect(md.contains("*it*"))
    }

    @Test func html_keepsHttpLinks_dropsDangerousSchemes() {
        let ok = HTMLToMarkdown.convert("<a href=\"https://example.com\">site</a>")
        #expect(ok.contains("[site](https://example.com)"))
        // javascript: is dropped — link text survives, the scheme does not.
        let bad = HTMLToMarkdown.convert("<a href=\"javascript:alert(1)\">x</a>")
        #expect(!bad.contains("javascript"))
        #expect(bad.contains("x"))
    }

    @Test func html_stripsScriptAndStyleEntirely() {
        let md = HTMLToMarkdown.convert(
            "<p>safe</p><script>steal()</script><style>body{}</style>")
        #expect(md.contains("safe"))
        #expect(!md.localizedCaseInsensitiveContains("steal"))
        #expect(!md.localizedCaseInsensitiveContains("script"))
    }

    @Test func looksLikeHTML_detectsTags() {
        #expect(MessageContent.looksLikeHTML("<p>hi</p>"))
        #expect(!MessageContent.looksLikeHTML("just **markdown** text"))
        // A lone comparison is not HTML.
        #expect(!MessageContent.looksLikeHTML("3 < 5 and 5 > 3"))
    }

    @Test func plain_stripsMarkupForAccessibility() {
        let plain = MessageContent.plain("# Heading\n\n- **bold** item")
        #expect(plain.contains("Heading"))
        #expect(plain.contains("bold"))
        #expect(!plain.contains("#"))
        #expect(!plain.contains("**"))
    }
}
