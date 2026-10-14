// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore

/// The shared sponsor-side ledger used by iOS (and the evaluate() Linux delegates to).
@Suite("Sponsorship ledger (shared, iOS)")
struct SponsorshipLedgerTests {
    let owner: PQRCIdentity
    let agent: PQRCIdentity
    let other: PQRCIdentity
    init() throws {
        owner = try PQRCIdentity(seed: Data(repeating: 0xA1, count: 32))
        agent = try PQRCIdentity(seed: Data(repeating: 0xB2, count: 32))
        other = try PQRCIdentity(seed: Data(repeating: 0xC3, count: 32))
    }
    let now: Int64 = 1_790_000_000
    var agentHex: String { agent.publicKeyData.hexString }

    /// What the agent attaches to its own messages: the sponsorship it was sent.
    func agentMessage(_ sp: AgentSponsorship?) -> MessageBody {
        var b = MessageBody(text: "hi from the AI", sentAt: now)
        b.agentSponsorship = sp
        return b
    }

    @Test func issue_thenAgentMessagesShowSponsored() throws {
        var l = SponsorshipLedger()
        let body = try l.issue(to: agentHex, days: 7, label: "ELDR", identity: owner, now: now)
        let sp = try #require(body.agentSponsorship)
        #expect(body.text.contains("7 days"))
        #expect(l.live(to: agentHex, now: now).count == 1)
        let st = l.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: agentHex, now: now + 10)
        #expect(st == .sponsored(sponsorIdentityHex: owner.publicKeyData.hexString, label: "ELDR", activeUntil: now + 7 * 86_400))
        #expect(l.status(participantType: .human, body: agentMessage(sp), senderIdentityHex: agentHex, now: now) == .human)
        #expect(l.status(participantType: .agent, body: agentMessage(nil), senderIdentityHex: agentHex, now: now) == .unsponsored)
        // Presented by someone it does not name.
        let otherHex = other.publicKeyData.hexString
        #expect(l.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: otherHex, now: now)
            == .invalid(reason: "names a different agent"))
        // Expired.
        if case .invalid = l.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: agentHex, now: now + 8 * 86_400) {} else {
            Issue.record("expired sponsorship must be invalid")
        }
    }

    @Test func issue_rejectsBadDurationAndSelf() throws {
        var l = SponsorshipLedger()
        #expect(throws: SponsorshipLedgerError.badDuration) { var c = l; _ = try c.issue(to: agentHex, days: 0, label: nil, identity: owner, now: now) }
        #expect(throws: SponsorshipLedgerError.badDuration) { var c = l; _ = try c.issue(to: agentHex, days: 8, label: nil, identity: owner, now: now) }
        #expect(throws: SponsorshipLedgerError.selfSponsorship) {
            var c = l; _ = try c.issue(to: owner.publicKeyData.hexString, days: 1, label: nil, identity: owner, now: now)
        }
        #expect(l.issued.isEmpty)
    }

    @Test func revoke_isEffectiveLocally_andProducesVerifiableRevocations() throws {
        var l = SponsorshipLedger()
        let sp1 = try #require(try l.issue(to: agentHex, days: 1, label: nil, identity: owner, now: now).agentSponsorship)
        _ = try l.issue(to: agentHex, days: 7, label: nil, identity: owner, now: now)
        let bodies = try l.revokeAll(to: agentHex, identity: owner, now: now + 5)
        #expect(bodies.count == 2)
        for b in bodies { try #require(b.agentSponsorshipRevocation).verify(presentedBy: owner.publicKeyData.hexString) }
        #expect(l.live(to: agentHex, now: now + 5).isEmpty)
        #expect(l.status(participantType: .agent, body: agentMessage(sp1), senderIdentityHex: agentHex, now: now + 6)
            == .invalid(reason: "revoked"))
        #expect(throws: SponsorshipLedgerError.nothingToRevoke) { var c = l; _ = try c.revokeAll(to: agentHex, identity: owner, now: now + 7) }
    }

    @Test func receivedRevocation_onlyFromItsSigner() throws {
        // A third person (not me) sponsored the agent and later revoked it.
        var theirs = SponsorshipLedger()
        let sp = try #require(try theirs.issue(to: agentHex, days: 7, label: nil, identity: other, now: now).agentSponsorship)
        let rev = try #require(try theirs.revokeAll(to: agentHex, identity: other, now: now + 1).first?.agentSponsorshipRevocation)
        var mine = SponsorshipLedger()
        #expect(mine.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: agentHex, now: now + 2).isSponsored)
        let byAgent = mine.receive(revocation: rev, from: agentHex)
        #expect(!byAgent, "relayed by the agent: ignored")
        #expect(mine.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: agentHex, now: now + 2).isSponsored)
        let bySigner = mine.receive(revocation: rev, from: other.publicKeyData.hexString)
        #expect(bySigner)
        #expect(mine.status(participantType: .agent, body: agentMessage(sp), senderIdentityHex: agentHex, now: now + 2)
            == .invalid(reason: "revoked"))
    }

    @Test func forget_andCodableRoundTrip() throws {
        var l = SponsorshipLedger()
        let sp = try #require(try l.issue(to: agentHex, days: 7, label: "x", identity: owner, now: now).agentSponsorship)
        _ = try l.issue(to: agentHex, days: 1, label: nil, identity: owner, now: now, sponsorshipID: "failed-send")
        l.forget(sponsorshipID: "failed-send")
        #expect(l.issued.map(\.sponsorship) == [sp])
        let back = try JSONDecoder().decode(SponsorshipLedger.self, from: JSONEncoder().encode(l))
        #expect(back == l)
        let st = SponsorshipStatus.sponsored(sponsorIdentityHex: "ab", label: nil, activeUntil: 5)
        #expect(try JSONDecoder().decode(SponsorshipStatus.self, from: JSONEncoder().encode(st)) == st)
    }

    @Test func badge_namesSponsor_stripsSpoofing_andFlagsWarnings() {
        let st = SponsorshipStatus.sponsored(sponsorIdentityHex: "abcdef0123", label: "EL\u{202E}DR\n", activeUntil: 5)
        #expect(st.badge(nameOf: { _ in "Auston" }, date: { _ in "Oct 14" }) == "AI “ELDR” · sponsored by Auston until Oct 14")
        #expect(st.badge(nameOf: { _ in nil }, date: { _ in "x" }).contains("unknown person abcdef01…"))
        #expect(!st.isWarning)
        #expect(SponsorshipStatus.unsponsored.isWarning)
        #expect(SponsorshipStatus.invalid(reason: "expired").isWarning)
        #expect(SponsorshipStatus.human.badge(nameOf: { _ in nil }, date: { _ in "" }) == "")
    }

    @Test func storedMessage_carriesStatus_andLegacyRecordsDecode() throws {
        let m = StoredMessage(id: "1", conversationID: "c", senderIdentity: "s", participantType: .agent,
            text: "t", sentAt: 1, sponsorship: .unsponsored)
        let back = try JSONDecoder().decode(StoredMessage.self, from: JSONEncoder().encode(m))
        #expect(back.sponsorship == .unsponsored)
        let legacy = #"{"id":"1","conversationID":"c","senderIdentity":"s","participantType":"agent","text":"t","sentAt":1}"#
        #expect(try JSONDecoder().decode(StoredMessage.self, from: Data(legacy.utf8)).sponsorship == nil)
        let future = #"{"id":"1","conversationID":"c","senderIdentity":"s","participantType":"agent","text":"t","sentAt":1,"sponsorship":{"newCase":{}}}"#
        #expect(try JSONDecoder().decode(StoredMessage.self, from: Data(future.utf8)).sponsorship == nil)
    }
}
