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
    public var pinned: Bool = false
    public var unread: Int = 0
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
    public var groups: [GroupRecord] = []
    public var threads: [ThreadRecord] = []
    /// conversation or `thread:<id>` → (identity → until) of every live AI there.
    public var aiActive: [String: [String: Int64]] = [:]
    public var myWindowConversation: String?
    public var settings = ClientSettings()
    public var provider: AIProviderConfig?
    public var loopGuarded: Set<String> = []
    /// conversation id → unread count (WS-N7a).
    public var unread: [String: Int] = [:]
    /// My AIs (primary first): name, kind, autonomous.
    public var ais: [String] = []
    public var contextModes: [String: String] = [:]
    public var critique: Set<String> = []
    public var solo: Set<String> = []

    public static let threadPrefix = "thread:"
    public static func threadID(_ conversationID: String) -> String? {
        conversationID.hasPrefix(threadPrefix) ? String(conversationID.dropFirst(threadPrefix.count)) : nil
    }

    /// Conversation ids: a contact's identity hex, or `group:<groupID>`.
    public static let groupPrefix = "group:"
    public static func groupID(_ conversationID: String) -> String? {
        conversationID.hasPrefix(groupPrefix) ? String(conversationID.dropFirst(groupPrefix.count)) : nil
    }

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
            pendingReconnects: Set(await c.pendingReconnects()), groups: await c.groups,
            threads: await c.threads, aiActive: await aiActive(c), myWindowConversation: await c.myWindowConversation,
            settings: await c.settings, provider: await c.providerConfig, loopGuarded: await guarded(c),
            unread: await unreadCounts(c), ais: await c.myAIs().map(\.name), contextModes: await c.allContextModes,
            critique: await c.critiqueConversations,
            solo: Set(await c.groups.map { UIConversation.group($0.groupID) }.asyncFilter { await c.isSolo($0) }))
    }

    static func unreadCounts(_ c: EldrClient) async -> [String: Int] {
        var out: [String: Int] = [:]
        for k in await c.contacts.map(\.identityHex) + (await c.groups).map({ UIConversation.group($0.groupID) }) {
            let n = await c.unreadCount(k)
            if n > 0 { out[k] = n }
        }
        return out
    }

    static func aiActive(_ c: EldrClient) async -> [String: [String: Int64]] {
        var out: [String: [String: Int64]] = [:]
        for k in await c.contacts.map(\.identityHex) + (await c.groups).map({ UIConversation.group($0.groupID) }) {
            let m = await c.activeWindows(in: k)
            if !m.isEmpty { out[k] = m }
        }
        for t in await c.threads {
            let m = await c.activeInvites(thread: t.threadID)
            if !m.isEmpty { out[threadPrefix + t.threadID] = m }
        }
        return out
    }
    static func guarded(_ c: EldrClient) async -> Set<String> {
        var s: Set<String> = []
        for t in await c.threads where await c.loopGuardActive(thread: t.threadID) { s.insert(threadPrefix + t.threadID) }
        return s
    }

    public func name(of identityHex: String) -> String? {
        if identityHex == me { return "you" }
        return contacts.first { $0.identityHex == identityHex }.map { UIFormat.title($0) }
    }

    public func conversations() -> [ConversationSummary] {
        var last: [String: HistoryEntry] = [:]
        var lastGroup: [String: HistoryEntry] = [:]
        var lastThread: [String: HistoryEntry] = [:]
        for h in history {
            if let t = h.threadID { lastThread[t] = h } else if let g = h.groupID { lastGroup[g] = h } else { last[h.peerIdentityHex] = h }
        }
        let threadRows = threads.map { t -> ConversationSummary in
            let l = lastThread[t.threadID]
            let parent = Self.groupID(t.conversationID).flatMap { g in groups.first { $0.groupID == g }?.name }
                ?? name(of: t.conversationID) ?? "?"
            return ConversationSummary(
                identityHex: Self.threadPrefix + t.threadID, title: "🧵 " + UIFormat.sanitizeLine(t.title) + " · in " + UIFormat.sanitizeLine(parent),
                preview: l.map { UIFormat.preview(($0.outgoing ? ($0.mine == true ? "\($0.agentName ?? "Your AI"): " : "You: ") : "\(name(of: $0.peerIdentityHex) ?? "?")\($0.agent ? "'s AI" : ""): ") + $0.text) } ?? "",
                lastAt: l?.sentAt ?? 0, isAgent: false)
        }
        let groupRows = groups.map { g -> ConversationSummary in
            let l = lastGroup[g.groupID]
            return ConversationSummary(
                identityHex: Self.groupPrefix + g.groupID, title: "👥 " + UIFormat.sanitizeLine(g.name),
                preview: l.map { UIFormat.preview(($0.outgoing ? ($0.mine == true ? "\($0.agentName ?? "Your AI"): " : "You: ") : "\(name(of: $0.peerIdentityHex) ?? "?")\($0.agent ? "'s AI" : ""): ") + $0.text) }
                    ?? "\(g.members.count) members",
                lastAt: l?.sentAt ?? 0, isAgent: false, unread: unread[Self.groupPrefix + g.groupID] ?? 0)
        }
        return (threadRows + groupRows + contacts.map { c in
            let l = last[c.identityHex]
            return ConversationSummary(
                identityHex: c.identityHex, title: UIFormat.title(c),
                preview: l.map { UIFormat.preview(($0.outgoing ? "You: " : "") + $0.text) } ?? "No messages yet",
                lastAt: l?.sentAt ?? Int64(c.addedAt.timeIntervalSince1970),
                isAgent: history.last { $0.peerIdentityHex == c.identityHex && !$0.outgoing && $0.groupID == nil }?.agent ?? false,
                pinned: c.pinned == true, unread: unread[c.identityHex] ?? 0)
        }).sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.lastAt != $1.lastAt ? $0.lastAt > $1.lastAt : $0.title < $1.title
        }
    }

    public func messages(with identityHex: String) -> [HistoryEntry] {
        if let t = Self.threadID(identityHex) { return history.filter { $0.threadID == t } }
        if let g = Self.groupID(identityHex) { return history.filter { $0.groupID == g && $0.threadID == nil } }
        return history.filter { $0.peerIdentityHex == identityHex && $0.groupID == nil && $0.threadID == nil }
    }

    /// Live (unrevoked, unexpired) sponsorships I issued to this contact.
    public func liveIssued(to identityHex: String, now: Int64 = EldrClient.nowSeconds) -> [IssuedSponsorship] {
        issued.filter { $0.sponsorship.agent == identityHex && $0.revokedAt == nil && $0.sponsorship.activeUntil > now }
    }

    /// The header line for a conversation.
    /// "🤖 alice's AI on until 15:00 · your AI on until …" for the conversation/thread.
    public func aiIndicator(for id: String, now: Int64 = EldrClient.nowSeconds) -> String? {
        var parts: [String] = []
        for (who, until) in (aiActive[id] ?? [:]).sorted(by: { $0.key < $1.key }) where until > now {
            parts.append("🤖 \(who == me ? "your" : (name(of: who) ?? String(who.prefix(8))) + "'s") AI on until \(UIFormat.date(until))")
        }
        if loopGuarded.contains(id) { parts.append("⏸ AIs paused by the loop guard until a human posts") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public func header(for identityHex: String, now: Int64 = EldrClient.nowSeconds) -> String {
        let base = baseHeader(for: identityHex, now: now)
        return aiIndicator(for: identityHex, now: now).map { base + "\n" + $0 } ?? base
    }

    func baseHeader(for identityHex: String, now: Int64) -> String {
        if let tid = Self.threadID(identityHex) {
            guard let t = threads.first(where: { $0.threadID == tid }) else { return "" }
            return "🧵 \(UIFormat.sanitizeLine(t.title)) · thread in \(Self.groupID(t.conversationID).flatMap { g in groups.first { $0.groupID == g }?.name } ?? name(of: t.conversationID) ?? "?")"
        }
        if let gid = Self.groupID(identityHex) {
            guard let g = groups.first(where: { $0.groupID == gid }) else { return "" }
            let names = g.members.map { name(of: $0) ?? String($0.prefix(8)) + "…" }
            return "👥 \(UIFormat.sanitizeLine(g.name)) · \(names.joined(separator: ", ")) · roster asserted by \(name(of: g.assertedBy) ?? String(g.assertedBy.prefix(8))) (rev \(g.revision))"
        }
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
            + (c.pinned == true ? " 📌" : "") + (c.verified == true ? " ✓" : "") + (c.blocked == true ? " ⛔" : "")
    }

    public static func date(_ unix: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// Badge for a history row: a human's own AI (window/invite) reads differently from an
    /// AI account (sponsorship), and an agent row with neither is flagged.
    public static func rowBadge(_ e: HistoryEntry, names: (String) -> String?) -> (text: String, warn: Bool) {
        if e.failed == true { return ("✗ Not sent", true) }
        if e.mentionsMe == true, !e.agent { return ("@ mentions you", false) }
        guard e.agent || e.mine == true else { return ("", false) }
        if e.coauthored == true {
            return (e.outgoing ? "🤖 made with you & your AI" : "🤖 made with \(names(e.peerIdentityHex) ?? "them") & their AI", false)
        }
        if e.mine == true { return ("🤖 " + (e.agentName.map(sanitizeLine) ?? "your AI"), false) }
        if let until = e.aiAuthorizedUntil {
            return ("🤖 \(names(e.peerIdentityHex) ?? "their")'s AI · on until \(date(until))", false)
        }
        switch e.sponsorship {
        case .sponsored: return (badge(e.sponsorship, names: names), false)
        case .invalid, .unsponsored: return (badge(e.sponsorship, names: names), true)
        case .human: return ("AI · not authorized by a window, invite or sponsorship", true)
        }
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

extension Array {
    func asyncFilter(_ f: (Element) async -> Bool) async -> [Element] {
        var out: [Element] = []
        for e in self where await f(e) { out.append(e) }
        return out
    }
}

public extension ConversationSummary {
    /// Sidebar title with the unread count (iOS badge).
    var displayTitle: String { unread > 0 ? "\(title)  (\(unread))" : title }
}
