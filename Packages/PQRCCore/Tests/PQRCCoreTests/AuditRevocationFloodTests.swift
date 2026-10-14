// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore

/// security/audit-1 (AC212): a contact floods self-signed revocations of junk IDs to
/// evict a real sponsor's revocation, so the revoked AI shows as sponsored again.
@Suite("Audit: revocation flood")
struct AuditRevocationFloodTests {
    let owner = try! PQRCIdentity(seed: Data(repeating: 0xA1, count: 32))
    let agent = try! PQRCIdentity(seed: Data(repeating: 0xB2, count: 32))
    let thirdParty = try! PQRCIdentity(seed: Data(repeating: 0xD4, count: 32))
    let attacker = try! PQRCIdentity(seed: Data(repeating: 0xE5, count: 32))
    let now: Int64 = 1_790_000_000

    func flood(_ l: inout SponsorshipLedger) throws {
        let hex = attacker.publicKeyData.hexString
        for i in 0..<(SponsorshipLedger.maxRevoked + 50) {
            let r = try AgentSponsorshipRevocation.make(sponsorshipID: "junk-\(i)", revokedAt: now, identity: attacker)
            let ok = l.receive(revocation: r, from: hex); #expect(ok)
        }
    }

    @Test func floodCannotEvictThirdPartyRevocation() throws {
        var issuer = SponsorshipLedger()
        let sp = try #require(try issuer.issue(to: agent.publicKeyData.hexString, days: 30, label: nil, identity: owner, now: now).agentSponsorship)
        let rev = try #require(try issuer.revokeAll(to: agent.publicKeyData.hexString, identity: owner, now: now + 1).first?.agentSponsorshipRevocation)
        var viewer = SponsorshipLedger()  // someone the owner notified
        let ok = viewer.receive(revocation: rev, from: owner.publicKeyData.hexString); #expect(ok)
        try flood(&viewer)
        var b = MessageBody(text: "still sponsored?", sentAt: now + 100); b.agentSponsorship = sp
        let st = viewer.status(participantType: .agent, body: b, senderIdentityHex: agent.publicKeyData.hexString, now: now + 100)
        #expect(st == .invalid(reason: "revoked"))
        #expect(viewer.revoked.count <= SponsorshipLedger.maxRevoked)
    }

    @Test func floodCannotEvictMyOwnRevocation() throws {
        var l = SponsorshipLedger()
        let sp = try #require(try l.issue(to: agent.publicKeyData.hexString, days: 30, label: nil, identity: owner, now: now).agentSponsorship)
        _ = try l.revokeAll(to: agent.publicKeyData.hexString, identity: owner, now: now + 1)
        try flood(&l)
        #expect(l.isRevoked(sp))
    }
}
