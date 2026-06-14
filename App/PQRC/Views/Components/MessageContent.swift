import SwiftUI

/// Renders message text as formatted content (APP-SPEC beta): markdown inline
/// styling, or a SANITIZED subset of HTML. Sanitized means native only — we
/// never instantiate a web view and never load remote resources or run
/// scripts, so a message can't leak the reader's IP or execute anything
/// (privacy is cardinal, SPEC §0; DEVIATIONS app-only entry).
struct MessageContent: View {
    let text: String

    var body: some View {
        Text(Self.render(text))
            .tint(.accentColor)  // styles any links; navigation is user-initiated only
    }

    /// Plain-text fallback used for accessibility labels.
    static func plain(_ text: String) -> String {
        String(render(text).characters)
    }

    static func render(_ text: String) -> AttributedString {
        if looksLikeHTML(text) {
            return HTMLRenderer.attributedString(from: text)
        }
        // Markdown: inline styling only (bold/italic/code/links). Block elements
        // (headings/lists) aren't rendered by Text — acceptable for beta. Plain
        // text passes through unchanged.
        if let md = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            return md
        }
        return AttributedString(text)
    }

    static func looksLikeHTML(_ s: String) -> Bool {
        s.range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil
    }
}

/// A deliberately small, native HTML→AttributedString converter. It handles a
/// safe inline + light-block subset and DISCARDS everything dangerous: script,
/// style, comments, remote images, event handlers. No `NSAttributedString`
/// HTML importer — that one is WebKit-backed and fetches remote resources.
enum HTMLRenderer {
    static func attributedString(from html: String) -> AttributedString {
        var src = html
        // Drop dangerous blocks WITH their contents.
        for pattern in [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<!--[\\s\\S]*?-->",
        ] {
            src = src.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        var out = AttributedString()
        var bold = false
        var italic = false
        var mono = false
        var href: String?

        func appendText(_ raw: String) {
            guard !raw.isEmpty else { return }
            var piece = AttributedString(decodeEntities(raw))
            var intent: InlinePresentationIntent = []
            if bold { intent.insert(.stronglyEmphasized) }
            if italic { intent.insert(.emphasized) }
            if mono { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let href, let url = URL(string: href) { piece.link = url }
            out += piece
        }

        func handle(_ tagContent: String) {
            var t = tagContent.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("/") { t.removeLast() }
            let closing = t.hasPrefix("/")
            if closing { t.removeFirst() }
            let name = String(t.prefix { !$0.isWhitespace }).lowercased()
            switch name {
            case "b", "strong": bold = !closing
            case "i", "em": italic = !closing
            case "code", "tt": mono = !closing
            case "a":
                href = closing ? nil : Self.extractHref(t)
            case "br":
                out += AttributedString("\n")
            case "li":
                if !closing { out += AttributedString("\n• ") } else { out += AttributedString("\n") }
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "tr", "blockquote", "pre":
                // Block boundary → newline (avoid leading blank line).
                if !String(out.characters).isEmpty { out += AttributedString("\n") }
            default:
                break  // unknown/ignored tags drop silently (sanitized)
            }
        }

        var i = src.startIndex
        var buffer = ""
        while i < src.endIndex {
            let ch = src[i]
            if ch == "<", let close = src[i...].firstIndex(of: ">") {
                appendText(buffer)
                buffer = ""
                handle(String(src[src.index(after: i)..<close]))
                i = src.index(after: close)
            } else {
                buffer.append(ch)
                i = src.index(after: i)
            }
        }
        appendText(buffer)

        // Trim leading/trailing whitespace-only runs introduced by block tags.
        let trimmed = String(out.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return AttributedString("") }
        return out
    }

    /// Pulls the quoted href out of an `a` tag's attributes (http/https only —
    /// other schemes are dropped so a message can't smuggle `javascript:` etc.).
    static func extractHref(_ tag: String) -> String? {
        guard let r = tag.range(
            of: "href\\s*=\\s*\"[^\"]*\"", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let frag = tag[r]
        guard let q1 = frag.firstIndex(of: "\"") else { return nil }
        let after = frag.index(after: q1)
        guard let q2 = frag[after...].firstIndex(of: "\"") else { return nil }
        let url = String(frag[after..<q2])
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
