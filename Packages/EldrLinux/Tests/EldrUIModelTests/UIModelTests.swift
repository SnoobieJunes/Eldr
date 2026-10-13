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
}
