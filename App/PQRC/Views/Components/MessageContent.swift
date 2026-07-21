// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

/// Renders message text as richly-formatted content: block-level **markdown**
/// (headings, lists, code blocks, blockquotes, tables, rules) plus inline
/// styling, or a SANITIZED subset of **HTML** normalized into the same markdown
/// pipeline. Everything is native SwiftUI — we never instantiate a web view and
/// never load remote resources or run scripts, so a message can't leak the
/// reader's IP or execute anything (privacy is cardinal, SPEC §0; DEVIATIONS
/// app-only entry). Plain text passes through unchanged.
struct MessageContent: View {
    let text: String

    var body: some View {
        MarkdownView(markdown: Self.normalized(text))
            .tint(.accentColor)  // styles links; navigation stays user-initiated
    }

    /// Markdown source to render: HTML is converted to equivalent markdown
    /// first, so both paths share one renderer and one sanitizer. Pure string
    /// work — `nonisolated` so callers off the main actor (tests, accessibility
    /// label construction) don't have to hop actors.
    nonisolated static func normalized(_ text: String) -> String {
        looksLikeHTML(text) ? HTMLToMarkdown.convert(text) : text
    }

    /// Plain-text fallback used for accessibility labels — strips all markup.
    nonisolated static func plain(_ text: String) -> String {
        MarkdownBlock.parse(normalized(text))
            .map(\.plainText)
            .joined(separator: "\n")
    }

    nonisolated static func looksLikeHTML(_ s: String) -> Bool {
        s.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil
    }

    /// True when the content has real document structure worth opening full
    /// screen — any HTML, or markdown with a heading/list/code/quote/table/rule,
    /// or more than one block. A lone plain paragraph ("hello!") is not rich.
    nonisolated static func isRich(_ text: String) -> Bool {
        if looksLikeHTML(text) { return true }
        let blocks = MarkdownBlock.parse(text)
        guard blocks.count == 1 else { return blocks.count > 1 }
        if case .paragraph = blocks[0] { return false }
        return true
    }
}

/// Identifiable wrapper so a message body can drive `.fullScreenCover(item:)`.
struct FullScreenContent: Identifiable {
    let id = UUID()
    let text: String
}

// MARK: - Block model + parser

/// One renderable block of a markdown document. Inline spans inside a block
/// (bold/italic/code/links) are styled by `AttributedString(markdown:)` at
/// render time; this model only captures block structure.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(level: Int, text: String)
    case ordered(number: Int, level: Int, text: String)
    case quote([String])
    case code(language: String?, code: String)
    case rule
    case table(headers: [String], rows: [[String]])

    /// Markup-free text for accessibility / previews.
    var plainText: String {
        switch self {
        case let .heading(_, t), let .paragraph(t), let .bullet(_, t):
            return MarkdownInline.stripped(t)
        case let .ordered(n, _, t): return "\(n). " + MarkdownInline.stripped(t)
        case let .quote(lines): return lines.map(MarkdownInline.stripped).joined(separator: "\n")
        case let .code(_, code): return code
        case .rule: return "—"
        case let .table(headers, rows):
            return ([headers] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        }
    }

    /// Line-based parse of a markdown document into blocks. Deliberately small
    /// and forgiving: unknown syntax degrades to paragraphs, never throws.
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ``` or ~~~ … closing fence.
            if let fence = fenceToken(trimmed) {
                flushParagraph()
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, fenceToken(lines[i].trimmingCharacters(in: .whitespaces)) != fence {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // consume closing fence (or end of input)
                blocks.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule: ---, ***, ___ (3+).
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // ATX heading: #..###### + space.
            if let (level, text) = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: level, text: text))
                i += 1
                continue
            }

            // Table: header row followed by a |---|---| separator.
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = tableCells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"),
                    !lines[i].trimmingCharacters(in: .whitespaces).isEmpty
                {
                    rows.append(tableCells(lines[i]))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Blockquote: one or more consecutive `>` lines.
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var q = lines[i].trimmingCharacters(in: .whitespaces)
                    q.removeFirst()
                    if q.hasPrefix(" ") { q.removeFirst() }
                    quote.append(q)
                    i += 1
                }
                blocks.append(.quote(quote))
                continue
            }

            // Bullet list item: -, *, + + space (indentation → nesting level).
            if let (level, text) = bullet(line) {
                flushParagraph()
                blocks.append(.bullet(level: level, text: text))
                i += 1
                continue
            }

            // Ordered list item: `N.` + space.
            if let (number, level, text) = ordered(line) {
                flushParagraph()
                blocks.append(.ordered(number: number, level: level, text: text))
                i += 1
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: line classifiers

    private static func fenceToken(_ s: String) -> String? {
        if s.hasPrefix("```") { return "```" }
        if s.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isRule(_ s: String) -> Bool {
        let stripped = s.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return Set(stripped) == ["-"] || Set(stripped) == ["*"] || Set(stripped) == ["_"]
    }

    private static func heading(_ s: String) -> (Int, String)? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix { $0 == "#" }.count
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = s.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return (hashes, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(_ line: String) -> (Int, String)? {
        let indent = line.prefix { $0 == " " }.count
        let s = line.trimmingCharacters(in: .whitespaces)
        guard let first = s.first, "-*+".contains(first), s.dropFirst().first == " " else { return nil }
        return (indent / 2, String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func ordered(_ line: String) -> (Int, Int, String)? {
        let indent = line.prefix { $0 == " " }.count
        let s = line.trimmingCharacters(in: .whitespaces)
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = s.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (number, indent / 2, String(afterDigits.dropFirst(2)).trimmingCharacters(in: .whitespaces))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("|"), s.contains("-") else { return false }
        let cellPattern = "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$"
        return s.range(of: cellPattern, options: .regularExpression) != nil
    }

    private static func tableCells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Inline styling

enum MarkdownInline {
    /// A `Text` with inline markdown (bold/italic/code/links) applied. Block
    /// syntax has already been stripped by the parser, so this only interprets
    /// spans and never re-triggers headings/lists.
    static func text(_ source: String) -> Text {
        Text(attributed(source))
    }

    static func attributed(_ source: String) -> AttributedString {
        var s =
            (try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        highlightMentions(in: &s)
        return s
    }

    /// Tint @mention tokens (an "@" at a word boundary followed by name characters)
    /// in the accent color so an addressed AI or person stands out in a sent message
    /// (feature 6). Display-only — never mutates the stored text.
    static func highlightMentions(in s: inout AttributedString) {
        var ranges: [Range<AttributedString.Index>] = []
        let chars = s.characters
        var i = chars.startIndex
        while i < chars.endIndex {
            if chars[i] == "@" {
                let atOK = i == chars.startIndex || chars[chars.index(before: i)].isWhitespace
                var j = chars.index(after: i)
                while j < chars.endIndex,
                    chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_"
                {
                    j = chars.index(after: j)
                }
                if atOK, j > chars.index(after: i) { ranges.append(i..<j) }
                i = j
            } else {
                i = chars.index(after: i)
            }
        }
        for r in ranges {
            s[r].foregroundColor = .accentColor
        }
    }

    /// Inline markup removed, for accessibility/previews.
    static func stripped(_ source: String) -> String {
        String(attributed(source).characters)
    }
}

// MARK: - SwiftUI renderer

/// Renders parsed markdown blocks as native SwiftUI. Backgrounds use adaptive
/// material/quaternary fills so the result stays legible inside both the opaque
/// incoming bubble and the accent-tinted outgoing bubble.
struct MarkdownView: View {
    let markdown: String
    /// The dedicated full-screen reader shows one document at a time, so it can
    /// afford much higher render limits than the conversation list (where many
    /// bubbles compete). Raises the caps below.
    var expanded: Bool = false

    /// Above this source size, full block layout (a non-lazy VStack of many
    /// Text views) gets expensive enough to stutter the conversation list, so
    /// very large pastes render as a single selectable Text instead — still the
    /// whole document, just without per-block styling. Ordinary markdown docs
    /// sit far below this and get the rich treatment.
    private static let maxRichBytes = 32 * 1024
    /// Secondary guard for many-tiny-line content that's small in bytes but
    /// explodes into blocks.
    private static let maxRichBlocks = 600

    private var richByteLimit: Int { expanded ? 512 * 1024 : Self.maxRichBytes }
    private var richBlockLimit: Int { expanded ? 6000 : Self.maxRichBlocks }

    var body: some View {
        if markdown.utf8.count > richByteLimit {
            plain
        } else {
            let blocks = MarkdownBlock.parse(markdown)
            if blocks.count > richBlockLimit {
                plain
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        view(for: block)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Responsive fallback for very large content. A multi-hundred-KB inline
    /// Text janks the conversation list, so we show a bounded selectable prefix
    /// with an honest footer. The full message is still delivered and stored —
    /// this is a display bound, not data loss.
    private static let maxDisplayBytes = 24 * 1024
    private var plain: some View {
        let limit = expanded ? 256 * 1024 : Self.maxDisplayBytes
        let shown = String(markdown.prefix(limit))
        let truncated = shown.utf8.count < markdown.utf8.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: shown)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if truncated {
                Text("⋯ long message · \(markdown.utf8.count / 1024) KB total")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            MarkdownInline.text(text)
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 2 : 0)

        case let .paragraph(text):
            MarkdownInline.text(text)
                .fixedSize(horizontal: false, vertical: true)

        case let .bullet(level, text):
            listRow(marker: "•", level: level) { MarkdownInline.text(text) }

        case let .ordered(number, level, text):
            listRow(marker: "\(number).", level: level) { MarkdownInline.text(text) }

        case let .quote(lines):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tint)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        MarkdownInline.text(l).italic()
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 4) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

        case .rule:
            Divider().padding(.vertical, 2)

        case let .table(headers, rows):
            MarkdownTable(headers: headers, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }

    @ViewBuilder
    private func listRow<Content: View>(
        marker: String, level: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            content()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(min(level, 6)) * 14)
    }
}

/// Minimal bordered table. Columns size to content; rows alternate a faint fill
/// for readability.
private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                    MarkdownInline.text(cell).fontWeight(.semibold)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        MarkdownInline.text(cell)
                    }
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - HTML → markdown (sanitized, native)

/// Converts a SAFE subset of HTML into equivalent markdown so the single
/// markdown renderer handles both. DISCARDS everything dangerous: script,
/// style, comments, event handlers, remote images, and non-http(s) links. No
/// `NSAttributedString` HTML importer — that one is WebKit-backed and fetches
/// remote resources, which would leak the reader's IP.
enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        var src = html
        for pattern in [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<!--[\\s\\S]*?-->",
        ] {
            src = src.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        var out = ""
        var href: String?
        var linkText = ""
        var capturingLink = false
        // Inside a <pre> block the bytes ARE the content: tags must survive as
        // literal text (e.g. an HTML snippet shown as code), not be parsed and
        // stripped. Only </pre> and the structural <code> wrapper are special.
        var inPre = false

        func emit(_ s: String) {
            if capturingLink { linkText += s } else { out += s }
        }

        func tagName(_ tagContent: String) -> String {
            var t = tagContent.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("/") { t.removeLast() }
            if t.hasPrefix("/") { t.removeFirst() }
            return String(t.prefix { !$0.isWhitespace }).lowercased()
        }

        func handle(_ tagContent: String) {
            var t = tagContent.trimmingCharacters(in: .whitespaces)
            let selfClosing = t.hasSuffix("/")
            if selfClosing { t.removeLast() }
            let closing = t.hasPrefix("/")
            if closing { t.removeFirst() }
            let name = String(t.prefix { !$0.isWhitespace }).lowercased()

            switch name {
            case "b", "strong": emit("**")
            case "i", "em": emit("*")
            // A <code> directly wrapping a <pre> block is the structural code
            // element — swallow it; the fence already marks the block. Outside
            // pre it's inline code.
            case "code", "tt": if !inPre { emit("`") }
            case "pre":
                inPre = !closing
                out += "\n```\n"
            case "h1", "h2", "h3", "h4", "h5", "h6":
                if !closing {
                    let level = Int(String(name.dropFirst())) ?? 1
                    out += "\n\n" + String(repeating: "#", count: level) + " "
                } else { out += "\n\n" }
            case "br": out += "\n"
            case "hr": out += "\n\n---\n\n"
            case "li": out += closing ? "\n" : "\n- "
            case "blockquote": out += closing ? "\n\n" : "\n\n> "
            case "p", "div", "ul", "ol", "tr", "table", "section":
                out += "\n\n"
            case "a":
                if closing {
                    if let href, let url = sanitizedURL(href) {
                        out += "[\(linkText)](\(url))"
                    } else {
                        out += linkText
                    }
                    capturingLink = false
                    linkText = ""
                    href = nil
                } else {
                    capturingLink = true
                    linkText = ""
                    href = extractHref(t)
                }
            default:
                break  // unknown/ignored tags drop silently (sanitized)
            }
        }

        var i = src.startIndex
        var buffer = ""
        while i < src.endIndex {
            let ch = src[i]
            if ch == "<", let close = src[i...].firstIndex(of: ">") {
                let tagContent = String(src[src.index(after: i)..<close])
                let name = tagName(tagContent)
                // Inside <pre>, only </pre> and the structural <code> wrapper are
                // tags; everything else is literal code (keep the brackets).
                if inPre, name != "pre", name != "code" {
                    emit(decodeEntities(buffer))
                    buffer = ""
                    emit("<\(tagContent)>")
                } else {
                    emit(decodeEntities(buffer))
                    buffer = ""
                    handle(tagContent)
                }
                i = src.index(after: close)
            } else {
                buffer.append(ch)
                i = src.index(after: i)
            }
        }
        emit(decodeEntities(buffer))

        // Collapse the runs of blank lines the block tags introduce.
        return out
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls a quoted href out of an `a` tag (http/https only — other schemes
    /// dropped so a message can't smuggle `javascript:` etc.).
    static func extractHref(_ tag: String) -> String? {
        guard let r = tag.range(
            of: "href\\s*=\\s*\"[^\"]*\"", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let frag = tag[r]
        guard let q1 = frag.firstIndex(of: "\"") else { return nil }
        let after = frag.index(after: q1)
        guard let q2 = frag[after...].firstIndex(of: "\"") else { return nil }
        return String(frag[after..<q2])
    }

    static func sanitizedURL(_ url: String) -> String? {
        let lower = url.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://")) ? url : nil
    }

    static func decodeEntities(_ s: String) -> String {
        var r = s
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }
}

// MARK: - Full-screen reader

/// Full-screen reader for a markdown/HTML message: pinch-to-zoom, two-axis
/// scrolling, a Rendered⇄Source toggle, and landscape support (the app already
/// allows landscape). Same native renderer as the bubble — no web view, no
/// remote loads (privacy is cardinal, SPEC §0). Source mode exposes the raw,
/// fully-selectable text so even very large documents are readable in full.
struct FullScreenReaderView: View {
    let text: String

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var showSource = false

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 4

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value.magnification, minZoom), maxZoom)
            }
            .onEnded { _ in committedZoom = zoom }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    content
                        .padding()
                        // Wrap prose to the screen width at 1×; zooming scales
                        // past it and the two-axis scroll lets you pan.
                        .frame(width: geo.size.width, alignment: .leading)
                        .scaleEffect(zoom, anchor: .topLeading)
                }
                .gesture(magnify)
                .onTapGesture(count: 2) { resetZoom() }
            }
            .navigationTitle(showSource ? "Source" : "Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("fullscreen-done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSource.toggle()
                        resetZoom()
                    } label: {
                        Label(
                            showSource ? "Rendered" : "Source",
                            systemImage: showSource
                                ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("fullscreen-source-toggle")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { resetZoom() } label: {
                        Image(systemName: "1.magnifyingglass")
                    }
                    .disabled(zoom == 1)
                    .accessibilityLabel("Reset zoom")
                }
            }
            .accessibilityIdentifier("fullscreen-reader")
        }
    }

    @ViewBuilder private var content: some View {
        if showSource {
            // Source/code view shows EXACTLY what the sender wrote — the raw
            // HTML or markdown, not the markdown we derive from HTML for the
            // rendered view. Normalizing here used to convert HTML to markdown,
            // so a pasted HTML document's actual code was missing from the code
            // view. Raw `text` is the literal source.
            Text(verbatim: text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        } else {
            // Render the full document (raised caps): the reader shows one
            // message at a time, so it can afford richer layout than the list.
            MarkdownView(markdown: MessageContent.normalized(text), expanded: true)
                .tint(.accentColor)
        }
    }

    private func resetZoom() {
        withAnimation(.snappy) {
            zoom = 1
            committedZoom = 1
        }
    }
}
