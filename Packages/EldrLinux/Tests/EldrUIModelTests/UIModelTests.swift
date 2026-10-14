// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import EldrClientCore
@testable import EldrUIModel
import PQRCCore
import PQRCNostr

@Suite("eldr-gtk presentation model")
struct UIModelTests {
    @Test func sanitizeBody_keepsMarkdownNewlines_dropsControlsAndBidi() {
        let s = "# T\n\tcode\u{1B}[31m red \u{202E}evil\u{2066} \u{7}bell 🚀"
        let out = UIFormat.sanitizeBody(s)
        #expect(out == "# T\n\tcode[31m red evil bell 🚀")
        #expect(!UIFormat.sanitizeLine("a\nb").contains("\n"))
    }

    @Test func preview_isOneLineAndBounded() {
        let p = UIFormat.preview(String(repeating: "word\n", count: 100))
        #expect(!p.contains("\n"))
        #expect(p.count == 80)
    }

    @Test func badge_namesSponsor_orFlagsUnknown() {
        let by = String(repeating: "ab", count: 32)
        let known = UIFormat.badge(.sponsored(sponsorIdentityHex: by, label: "ELDR", activeUntil: 0), names: { _ in "Auston" })
        #expect(known.contains("sponsored by Auston"))
        #expect(known.contains("“ELDR”"))
        let unknown = UIFormat.badge(.sponsored(sponsorIdentityHex: by, label: nil, activeUntil: 0), names: { _ in nil })
        #expect(unknown.contains("unknown person abababab"))
        #expect(UIFormat.badge(.unsponsored, names: { _ in nil }).contains("NOT sponsored"))
        #expect(UIFormat.badge(.invalid(reason: "revoked"), names: { _ in nil }).contains("invalid"))
        #expect(UIFormat.badge(.human, names: { _ in nil }).isEmpty)
    }

    @Test func renderBody_truncatesHugeText() {
        let big = String(repeating: "x", count: UIFormat.maxRenderedChars + 5)
        let r = UIFormat.renderBody(big)
        #expect(r.truncated && r.text.count == UIFormat.maxRenderedChars)
        #expect(!UIFormat.renderBody("small").truncated)
    }

    @Test func composer_enterIsNewline_ctrlEnterSends() {
        #expect(!UIFormat.composerShouldSend(isEnter: true, ctrl: false))
        #expect(UIFormat.composerShouldSend(isEnter: true, ctrl: true))
        #expect(!UIFormat.composerShouldSend(isEnter: false, ctrl: true))
    }

    @Test func conversations_sortByLastActivity_andHeaderShowsSponsorship() throws {
        let ev = NostrEvent(pubkey: "", createdAt: 0, kind: 10420, tags: [], content: "")
        let a = String(repeating: "aa", count: 32), b = String(repeating: "bb", count: 32)
        let me = String(repeating: "cc", count: 32)
        let cs = [
            ContactRecord(name: "alice", nostrPubkeyHex: a, identityHex: a, bindingEvent: ev, session: nil, addedAt: Date(timeIntervalSince1970: 1)),
            ContactRecord(name: "bot", nostrPubkeyHex: b, identityHex: b, bindingEvent: ev, session: nil, addedAt: Date(timeIntervalSince1970: 1)),
        ]
        let h = [
            HistoryEntry(id: "1", peerIdentityHex: a, outgoing: false, text: "hi", sentAt: 10, agent: false, sponsorship: .human),
            HistoryEntry(id: "2", peerIdentityHex: b, outgoing: false, text: "beep\nboop", sentAt: 20, agent: true,
                sponsorship: .sponsored(sponsorIdentityHex: me, label: nil, activeUntil: 99)),
        ]
        let snap = UISnapshot(me: me, npub: "", link: "", isAgent: false, agentBanner: nil, contacts: cs,
            requests: [], history: h, issued: [])
        let conv = snap.conversations()
        #expect(conv.map(\.title) == ["bot", "alice"])
        #expect(conv[0].isAgent && conv[0].preview == "beep boop")
        #expect(snap.header(for: b).contains("sponsored by you"))
        #expect(snap.messages(with: a).count == 1)
    }

    @Test func groups_areOwnConversations_andStayOutOf1to1() {
        let ev = NostrEvent(pubkey: "", createdAt: 0, kind: 10420, tags: [], content: "")
        let a = String(repeating: "aa", count: 32), me = String(repeating: "cc", count: 32)
        let cs = [ContactRecord(name: "alice", nostrPubkeyHex: a, identityHex: a, bindingEvent: ev, session: nil, addedAt: Date(timeIntervalSince1970: 1))]
        let g = GroupRecord(GroupRoster(create: GroupCreate(groupID: "G1", name: "team<b>", members: [me, a], revision: 3), assertedBy: a))
        var gm = HistoryEntry(id: "2", peerIdentityHex: a, outgoing: false, text: "group hi", sentAt: 30, agent: false, sponsorship: .human)
        gm.groupID = "G1"
        let h = [HistoryEntry(id: "1", peerIdentityHex: a, outgoing: false, text: "dm", sentAt: 10, agent: false, sponsorship: .human), gm]
        var snap = UISnapshot(me: me, npub: "", link: "", isAgent: false, agentBanner: nil, contacts: cs, requests: [], history: h, issued: [])
        snap.groups = [g]
        let conv = snap.conversations()
        #expect(conv.map(\.identityHex) == ["group:G1", a])
        #expect(conv[0].preview == "alice: group hi" && conv[1].preview == "dm")
        #expect(snap.messages(with: a).map(\.text) == ["dm"])
        #expect(snap.messages(with: "group:G1").map(\.text) == ["group hi"])
        #expect(snap.header(for: "group:G1").contains("roster asserted by alice (rev 3)"))
    }

    @Test func threads_aiIndicator_andRowBadges() {
        let ev = NostrEvent(pubkey: "", createdAt: 0, kind: 10420, tags: [], content: "")
        let a = String(repeating: "aa", count: 32), me = String(repeating: "cc", count: 32)
        let cs = [ContactRecord(name: "alice", nostrPubkeyHex: a, identityHex: a, bindingEvent: ev, session: nil, addedAt: Date(timeIntervalSince1970: 1))]
        var t1 = HistoryEntry(id: "t1", peerIdentityHex: a, outgoing: false, text: "in thread", sentAt: 50, agent: true, sponsorship: .unsponsored)
        t1.threadID = "T"; t1.aiAuthorizedUntil = 9_999_999_999
        let dm = HistoryEntry(id: "d", peerIdentityHex: a, outgoing: false, text: "dm", sentAt: 10, agent: true, sponsorship: .unsponsored)
        var snap = UISnapshot(me: me, npub: "", link: "", isAgent: false, agentBanner: nil, contacts: cs, requests: [], history: [dm, t1], issued: [])
        snap.threads = [ThreadRecord(threadID: "T", conversationID: a, title: "plan", createdBy: a)]
        snap.aiActive = ["thread:T": [a: 9_999_999_999, me: 9_999_999_999]]
        snap.loopGuarded = ["thread:T"]
        #expect(snap.conversations().first?.identityHex == "thread:T")
        #expect(snap.messages(with: a).map(\.text) == ["dm"])
        #expect(snap.messages(with: "thread:T").map(\.text) == ["in thread"])
        let h = snap.header(for: "thread:T", now: 100)
        #expect(h.contains("alice's AI on until") && h.contains("your AI on until") && h.contains("loop guard"))
        #expect(!UIFormat.rowBadge(t1, names: snap.name(of:)).warn)
        #expect(UIFormat.rowBadge(dm, names: snap.name(of:)).warn, "an agent row with no authorization is flagged")
        var mine = dm; mine.mine = true; mine.outgoing = true
        #expect(UIFormat.rowBadge(mine, names: snap.name(of:)).text == "🤖 your AI")
    }

    /// Tags must nest properly and no raw '<' may come from message text.
    private func wellFormed(_ m: String) -> Bool {
        var stack: [String] = []
        var i = m.startIndex
        while let lt = m[i...].firstIndex(of: "<") {
            guard let gt = m[lt...].firstIndex(of: ">") else { return false }
            let tag = m[m.index(after: lt)..<gt]
            let name = String(tag.split(separator: " ").first ?? "")
            if name.hasPrefix("/") {
                guard stack.popLast() == String(name.dropFirst()) else { return false }
            } else {
                guard ["b", "i", "s", "tt", "span"].contains(name) else { return false }
                stack.append(name)
            }
            i = m.index(after: gt)
        }
        return stack.isEmpty
    }

    @Test func markdown_rendersCommonSyntax() {
        let md = "# Title\n**bold** and *it* and `x < y`\n- item\n> quote\n```\n<b>raw</b>\n```\n[site](https://e.x)"
        let m = UIFormat.markdownToPango(md)
        #expect(m.contains("<span size=\"x-large\" weight=\"bold\">Title</span>"))
        #expect(m.contains("<b>bold</b> and <i>it</i> and <tt>x &lt; y</tt>"))
        #expect(m.contains("  • item"))
        #expect(m.contains("<tt>&lt;b&gt;raw&lt;/b&gt;</tt>"))
        #expect(m.contains("site <span foreground=\"#3584e4\">(https://e.x)</span>"))
        #expect(!m.contains("<a "), "links are never clickable")
        #expect(wellFormed(m))
    }

    @Test func markdown_cannotInjectMarkup_andIsAlwaysWellFormed() {
        let hostile = "<span foreground='red'>x</span> &amp; <b>**a _b** c_ *d `e* f` [g**](h)**"
        #expect(wellFormed(UIFormat.markdownToPango(hostile)))
        #expect(UIFormat.markdownToPango("<b>hi</b>") == "&lt;b&gt;hi&lt;/b&gt;")
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("*_`~[]()<>&#-> \nab\"'")
        for _ in 0..<3000 {
            let n = Int.random(in: 0..<40, using: &rng)
            let s = String((0..<n).map { _ in alphabet.randomElement(using: &rng)! })
            let m = UIFormat.markdownToPango(s)
            #expect(wellFormed(m), "\(s.debugDescription) -> \(m.debugDescription)")
        }
    }

    @Test func follow_onlyNearBottom() {
        #expect(UIFormat.shouldFollow(value: 900, pageSize: 100, upper: 1000))
        #expect(UIFormat.shouldFollow(value: 850, pageSize: 100, upper: 1000))
        #expect(!UIFormat.shouldFollow(value: 200, pageSize: 100, upper: 1000))
        #expect(UIFormat.shouldFollow(value: 0, pageSize: 500, upper: 400), "short history always follows")
    }

    @Test func markdownRulesCompiled() { #expect(UIFormat.rules.count == 6) }
}

@Suite("World + tour (WS-N7)")
struct WorldTourTests {
    @Test func worldRows_collapsePlanesPerPeer_andNeverSayConnected() {
        let now: Int64 = 1_000_000
        #expect(WorldDerivation.status(activeUntil: now - 1, now: now) == .expired)
        #expect(WorldDerivation.status(activeUntil: now + 3600, now: now) == .expiringSoon(until: now + 3600))
        #expect(WorldDerivation.status(activeUntil: now + 200_000, now: now) == .authorized(until: now + 200_000))
        for s in [WorldGrantStatus.expired, .expiringSoon(until: 1), .authorized(until: 1)] { #expect(!s.label.contains("connect")) }
    }

    @Test func tourText_isGeneratedFromIOS() {
        #expect(OnboardingTourText.steps.count >= 10)
        #expect(OnboardingTourText.steps.first?.title == "Cast off")
        #expect(OnboardingTourText.steps.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
    }
}

@Suite("World map geometry (WS-N7a)")
struct WorldMapTests {
    @Test func ringPositions_lifetime_andBreath() {
        let p0 = WorldMapLayout.unitPosition(index: 0, count: 4)
        #expect(abs(p0.x) < 1e-9 && abs(p0.y + 1) < 1e-9)  // 12 o'clock
        let p1 = WorldMapLayout.unitPosition(index: 1, count: 4)
        #expect(abs(p1.x - 1) < 1e-9 && abs(p1.y) < 1e-9)  // clockwise → 3 o'clock
        #expect(WorldMapLayout.unitPosition(index: 0, count: 0) == (0, 0))
        #expect(WorldMapLayout.ringRadius(width: 480, height: 300) == 98)
        #expect(WorldMapLayout.lifetimeFraction(expiresAt: 100, now: 200) == 0)
        #expect(WorldMapLayout.lifetimeFraction(expiresAt: nil, now: 0) == 0)
        #expect(WorldMapLayout.lifetimeFraction(expiresAt: Int64.max, now: 0) == 1)
        #expect(WorldMapLayout.breath(time: 123, urgent: false) == 0.5)
        let b = WorldMapLayout.breath(time: 0.4, urgent: true)
        #expect(b >= 0 && b <= 1 && b != 0.5)
        #expect(WorldMapLayout.until(.expired) == nil && WorldMapLayout.until(.authorized(until: 9)) == 9)
    }

    @Test func unreadTitle_andNotSentBadge() {
        var c = ConversationSummary(identityHex: "x", title: "Bob", preview: "", lastAt: 0, isAgent: false)
        #expect(c.displayTitle == "Bob")
        c.unread = 3
        #expect(c.displayTitle == "Bob  (3)")
        var e = HistoryEntry(id: "1", peerIdentityHex: "x", outgoing: true, text: "t", sentAt: 0, agent: false, sponsorship: .human)
        e.failed = true
        #expect(UIFormat.rowBadge(e, names: { _ in nil }) == ("✗ Not sent", true))
    }
}
