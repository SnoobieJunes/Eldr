// SPDX-License-Identifier: Apache-2.0
// EldrUIModel — GTK-free presentation logic for eldr-gtk, so it can be unit-tested
// on any machine. The GTK layer only renders what this produces.
import EldrClientCore
import Foundation
import PQRCCore
import PQRCNostr

public struct ConversationSummary: Equatable, Sendable {
    public var identityHex: String
    public var title: String
    public var preview: String
    public var lastAt: Int64
    public var isAgent: Bool
}

public struct UISnapshot: Sendable {
    public var me: String
    public var npub: String
    public var link: String
    public var isAgent: Bool
    public var agentBanner: String?
    public var contacts: [ContactRecord]
    public var requests: [RequestRecord]
    public var history: [HistoryEntry]
    public var issued: [IssuedSponsorship]
    /// Contacts whose reset (last-resort re-handshake) is waiting for my OK (AC166).
    public var pendingReconnects: Set<String> = []

    public static func capture(_ c: EldrClient) async -> UISnapshot {
        let isAgent = await c.isAgent
        var banner: String?
        if isAgent {
            do {
                let s = try await c.liveSponsorship()
                banner = "🤖 AI account · sponsored until \(UIFormat.date(s.activeUntil))"
            } catch {
                banner = "🤖 AI account · NOT sponsored — sending is paused until your owner sponsors you"
            }
        }
        return UISnapshot(
            me: c.identityHex, npub: await c.npub, link: await c.pairingLink.uri, isAgent: isAgent,
            agentBanner: banner, contacts: await c.contacts, requests: await c.requests,
            history: await c.history, issued: await c.issuedSponsorships,
            pendingReconnects: Set(await c.pendingReconnects()))
    }

    public func name(of identityHex: String) -> String? {
        if identityHex == me { return "you" }
        return contacts.first { $0.identityHex == identityHex }.map { UIFormat.title($0) }
    }

    public func conversations() -> [ConversationSummary] {
        var last: [String: HistoryEntry] = [:]
        for h in history { last[h.peerIdentityHex] = h }
        return contacts.map { c in
            let l = last[c.identityHex]
            return ConversationSummary(
                identityHex: c.identityHex, title: UIFormat.title(c),
                preview: l.map { UIFormat.preview(($0.outgoing ? "You: " : "") + $0.text) } ?? "No messages yet",
                lastAt: l?.sentAt ?? Int64(c.addedAt.timeIntervalSince1970),
                isAgent: history.last { $0.peerIdentityHex == c.identityHex && !$0.outgoing }?.agent ?? false)
        }.sorted { $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.title < $1.title }
    }

    public func messages(with identityHex: String) -> [HistoryEntry] {
        history.filter { $0.peerIdentityHex == identityHex }
    }

    /// Live (unrevoked, unexpired) sponsorships I issued to this contact.
    public func liveIssued(to identityHex: String, now: Int64 = EldrClient.nowSeconds) -> [IssuedSponsorship] {
        issued.filter { $0.sponsorship.agent == identityHex && $0.revokedAt == nil && $0.sponsorship.activeUntil > now }
    }

    /// The header line for a conversation.
    public func header(for identityHex: String, now: Int64 = EldrClient.nowSeconds) -> String {
        guard let c = contacts.first(where: { $0.identityHex == identityHex }) else { return "" }
        var parts = [UIFormat.title(c), "id \(identityHex.prefix(12))…"]
        if let lastIn = history.last(where: { $0.peerIdentityHex == identityHex && !$0.outgoing }), lastIn.agent {
            parts.append(UIFormat.badge(lastIn.sponsorship, names: name(of:)))
        }
        if let mine = liveIssued(to: identityHex, now: now).last {
            parts.append("you sponsor them until \(UIFormat.date(mine.sponsorship.activeUntil))")
        }
        return parts.joined(separator: " · ")
    }
}

public enum UIFormat {
    public static func title(_ c: ContactRecord) -> String {
        sanitizeLine(c.name ?? Bech32.npub(c.nostrPubkeyHex).prefix(16) + "…")
    }

    public static func date(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    public static func badge(_ s: SponsorshipStatus, names: (String) -> String?) -> String {
        switch s {
        case .human: return ""
        case .unsponsored: return "🤖 AI · NOT sponsored"
        case .sponsored(let by, let label, let until):
            let who = names(by) ?? "unknown person \(by.prefix(8))…"
            return "🤖 AI\(label.map { " “\(sanitizeLine($0))”" } ?? "") · sponsored by \(who) until \(date(until))"
        case .invalid(let reason): return "⚠ AI · sponsorship invalid (\(sanitizeLine(reason)))"
        }
    }

    /// One-line preview: control/bidi chars removed, newlines folded, ≤ 80 chars.
    public static func preview(_ s: String) -> String {
        let one = sanitizeLine(s.split(whereSeparator: \.isNewline).joined(separator: " "))
        return one.count > 80 ? String(one.prefix(79)) + "…" : one
    }

    /// Strips C0/C1 controls and Trojan-Source bidi overrides from untrusted text,
    /// keeping newlines and tabs (message bodies are multi-line Markdown).
    public static func sanitizeBody(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            let v = u.value
            if v == 0x0A || v == 0x09 { return true }
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { return false }
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F
                || v == 0x061C
            { return false }
            return true
        }))
    }
    public static func sanitizeLine(_ s: some StringProtocol) -> String {
        sanitizeBody(String(s)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
    }

    /// Very large bodies are rendered truncated in a bubble (full text is still
    /// stored and copyable); a GtkLabel with megabytes of text freezes layout.
    public static let maxRenderedChars = 20_000
    public static func renderBody(_ s: String) -> (text: String, truncated: Bool) {
        let clean = sanitizeBody(s)
        guard clean.count > maxRenderedChars else { return (clean, false) }
        return (String(clean.prefix(maxRenderedChars)), true)
    }

    /// Composer: Enter inserts a newline (Markdown); Ctrl+Enter sends.
    public static func composerShouldSend(isEnter: Bool, ctrl: Bool) -> Bool { isEnter && ctrl }

    /// Follow new messages only if the reader is already (near) the bottom; someone
    /// scrolled up reading history keeps their place.
    public static func shouldFollow(value: Double, pageSize: Double, upper: Double, slack: Double = 80) -> Bool {
        value + pageSize >= upper - slack
    }

    /// Escapes text for Pango markup.
    public static func pangoEscape(_ s: some StringProtocol) -> String {
        var o = ""
        o.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "'": o += "&#39;"
            default: o.append(ch)
            }
        }
        return o
    }

    /// Renders a (sanitized) Markdown body as Pango markup. Everything from the message
    /// is escaped FIRST, so message text can never inject markup; only the tags emitted
    /// here exist, each opened and closed on the same line, so the result is always
    /// well-formed. Supported: # headings, **bold**, *italic* / _italic_, `code`,
    /// ``` fenced blocks, - / * / + bullets, > quotes, [text](url) shown as "text (url)"
    /// (never clickable: links from strangers are not one click away).
    public static func markdownToPango(_ md: String) -> String {
        var out: [String] = []
        var inFence = false
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { out.append("<tt>" + pangoEscape(line) + "</tt>"); continue }
            var body = Substring(line)
            var prefix = "", suffix = ""
            let hashes = body.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), body.dropFirst(hashes).first == " " {
                body = body.dropFirst(hashes + 1)
                let size = hashes == 1 ? "x-large" : hashes == 2 ? "large" : "medium"
                prefix = "<span size=\"\(size)\" weight=\"bold\">"; suffix = "</span>"
            } else if let f = body.first, "-*+".contains(f), body.dropFirst().first == " " {
                body = body.dropFirst(2); prefix = "  • "
            } else if body.hasPrefix("> ") || body == ">" {
                body = body.dropFirst(body == ">" ? 1 : 2)
                prefix = "<span foreground=\"#888888\">▎ "; suffix = "</span>"
            }
            out.append(prefix + inline(String(body)) + suffix)
        }
        return out.joined(separator: "\n")
    }

    /// Inline spans on one line. Code spans are split out first (no formatting inside).
    static func inline(_ s: String) -> String {
        var result = ""
        let parts = s.split(separator: "`", omittingEmptySubsequences: false)
        // An odd count of parts means every backtick is paired.
        let paired = parts.count % 2 == 1
        for (i, p) in parts.enumerated() {
            if paired && i % 2 == 1 {
                result += "<tt>" + pangoEscape(p) + "</tt>"
            } else {
                let piece = paired || i == 0 ? String(p) : "`" + p
                result += emphasis(pangoEscape(piece))
            }
        }
        return result
    }

    /// Patterns are literals; `try?` + compactMap instead of `try!` (no force-try rule).
    /// `markdownRulesCompiled` in the tests pins that none is silently dropped.
    static let rules: [(NSRegularExpression, String)] = ([
        (#"\[([^\]\n<>]+)\]\(([^)\s<>]+)\)"#, "$1 <span foreground=\"#3584e4\">($2)</span>"),
        (#"\*\*([^*\n<>]+)\*\*"#, "<b>$1</b>"),
        (#"__([^_\n<>]+)__"#, "<b>$1</b>"),
        (#"(?<![\w*])\*([^*\s<>][^*\n<>]*?)\*(?![\w*])"#, "<i>$1</i>"),
        (#"(?<![\w_])_([^_\s<>][^_\n<>]*?)_(?![\w_])"#, "<i>$1</i>"),
        (#"~~([^~\n<>]+)~~"#, "<s>$1</s>"),
    ] as [(String, String)]).compactMap { p, t in (try? NSRegularExpression(pattern: p)).map { ($0, t) } }

    /// Applied to ALREADY-ESCAPED text. Groups exclude '<' and '>' so a span can never
    /// straddle a tag emitted by an earlier rule (no interleaved, malformed markup).
    static func emphasis(_ escaped: String) -> String {
        var s = escaped
        for (re, tpl) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: tpl)
        }
        return s
    }
}
