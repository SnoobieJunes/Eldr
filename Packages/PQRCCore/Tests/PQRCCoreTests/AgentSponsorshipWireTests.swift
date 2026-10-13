// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore

@Suite("Agent sponsorship wire format")
struct AgentSponsorshipWireTests {
    static func owner() throws -> PQRCIdentity { try PQRCIdentity(seed: Data(repeating: 0xA1, count: 32)) }
    static func agent() throws -> PQRCIdentity { try PQRCIdentity(seed: Data(repeating: 0xB2, count: 32)) }
    static func other() throws -> PQRCIdentity { try PQRCIdentity(seed: Data(repeating: 0xC3, count: 32)) }
    static let now: Int64 = 1_790_000_000
    static let day: Int64 = 86_400

    static func make(days: Int64 = 7, label: String? = "ELDR") throws -> AgentSponsorship {
        try AgentSponsorship.make(
            sponsorshipID: "s1", agent: agent().publicKeyData.hexString, label: label,
            issuedAt: now, activeUntil: now + days * day, identity: owner())
    }

    @Test func validSponsorship_verifiesFromSponsorAndFromAgent() throws {
        let s = try Self.make()
        try s.verify(presentedBy: Self.owner().publicKeyData.hexString, now: Self.now)
        try s.verify(presentedBy: Self.agent().publicKeyData.hexString, now: Self.now + 1)
    }

    @Test func thirdPartyCannotPresentIt() throws {
        let s = try Self.make()
        #expect(throws: AgentSponsorshipError.notFromSponsor) {
            try s.verify(presentedBy: Self.other().publicKeyData.hexString, now: Self.now)
        }
    }

    @Test func over30Days_refusedAtMakeAndAtReceipt() throws {
        #expect(throws: AgentSponsorshipError.durationUnbounded) { try Self.make(days: 31) }
        // A forged-long one (signed directly) is refused on receipt.
        let o = try Self.owner()
        let a = try Self.agent().publicKeyData.hexString
        let unsigned = AgentSponsorship(
            sponsorshipID: "s1", agent: a, label: nil, issuedAt: Self.now,
            activeUntil: Self.now + 400 * Self.day, enabledBy: o.publicKeyData, sig: Data())
        let sig = try o.sign(AgentSponsorship.signatureMessage(
            scopeTag: unsigned.scopeTag, activeUntil: unsigned.activeUntil, enabledBy: o.publicKeyData))
        let long = AgentSponsorship(
            sponsorshipID: "s1", agent: a, label: nil, issuedAt: Self.now,
            activeUntil: unsigned.activeUntil, enabledBy: o.publicKeyData, sig: sig)
        #expect(throws: AgentSponsorshipError.durationUnbounded) {
            try long.verify(presentedBy: a, now: Self.now)
        }
    }

    @Test func expired_isRefused() throws {
        let s = try Self.make(days: 1)
        #expect(throws: AgentSponsorshipError.expired) {
            try s.verify(presentedBy: s.agent, now: Self.now + Self.day)
        }
    }

    @Test func tamperedFields_failSignature() throws {
        let s = try Self.make()
        let other = try Self.other().publicKeyData.hexString
        for t in [
            AgentSponsorship(sponsorshipID: s.sponsorshipID, agent: other, label: s.label, issuedAt: s.issuedAt,
                activeUntil: s.activeUntil, enabledBy: s.enabledBy, sig: s.sig),
            AgentSponsorship(sponsorshipID: s.sponsorshipID, agent: s.agent, label: "Owner", issuedAt: s.issuedAt,
                activeUntil: s.activeUntil, enabledBy: s.enabledBy, sig: s.sig),
            AgentSponsorship(sponsorshipID: s.sponsorshipID, agent: s.agent, label: s.label, issuedAt: s.issuedAt,
                activeUntil: s.activeUntil + 1, enabledBy: s.enabledBy, sig: s.sig),
            AgentSponsorship(sponsorshipID: "s2", agent: s.agent, label: s.label, issuedAt: s.issuedAt,
                activeUntil: s.activeUntil, enabledBy: s.enabledBy, sig: s.sig),
        ] {
            #expect(!t.hasValidSignature())
        }
    }

    @Test func selfSponsorship_refused() throws {
        let a = try Self.agent()
        #expect(throws: AgentSponsorshipError.selfSponsorship) {
            try AgentSponsorship.make(sponsorshipID: "s", agent: a.publicKeyData.hexString, label: nil,
                issuedAt: Self.now, activeUntil: Self.now + Self.day, identity: a)
        }
    }

    @Test func domainSeparation_revocationAndGrantSignaturesDoNotCrossReplay() throws {
        let o = try Self.owner()
        let s = try Self.make()
        let r = try AgentSponsorshipRevocation.make(sponsorshipID: "s1", revokedAt: Self.now, identity: o)
        // The revocation sig is not valid as a sponsorship and vice versa.
        let forged = AgentSponsorship(sponsorshipID: s.sponsorshipID, agent: s.agent, label: s.label,
            issuedAt: s.issuedAt, activeUntil: s.activeUntil, enabledBy: s.enabledBy, sig: r.sig)
        #expect(!forged.hasValidSignature())
        let forgedR = AgentSponsorshipRevocation(sponsorshipID: "s1", revokedAt: Self.now,
            enabledBy: o.publicKeyData, sig: s.sig)
        #expect(throws: AgentSponsorshipError.signatureInvalid) {
            try forgedR.verify(presentedBy: o.publicKeyData.hexString)
        }
        for d in ["pqrc-ai-window-v1", "pqrc-ai-context-grant-v1", "pqrc-standing-grant-v1",
                  "pqrc-standing-grant-revocation-v1", "pqrc-agent-msg-v1"] {
            for mine in [AgentSponsorship.domain, AgentSponsorshipRevocation.domain] {
                #expect(!mine.hasPrefix(d) && !d.hasPrefix(mine))
            }
        }
        #expect(!AgentSponsorshipRevocation.domain.hasPrefix(AgentSponsorship.domain))
    }

    @Test func revocation_onlyFromTheSigner() throws {
        let r = try AgentSponsorshipRevocation.make(sponsorshipID: "s1", revokedAt: Self.now, identity: Self.owner())
        try r.verify(presentedBy: Self.owner().publicKeyData.hexString)
        #expect(throws: AgentSponsorshipError.notFromSponsor) {
            try r.verify(presentedBy: Self.agent().publicKeyData.hexString)
        }
    }

    @Test func messageBody_roundTrips_andIsOmittedWhenNil() throws {
        let plain = MessageBody(text: "hi", sentAt: 1)
        let enc = try JSONEncoder().encode(plain)
        #expect(!String(decoding: enc, as: UTF8.self).contains("agent_sponsorship"))
        var b = MessageBody(text: "hi", sentAt: 1)
        b.agentSponsorship = try Self.make()
        let back = try JSONDecoder().decode(MessageBody.self, from: JSONEncoder().encode(b))
        #expect(back.agentSponsorship == b.agentSponsorship)
        #expect(back.agentSponsorship?.hasValidSignature() == true)
    }
}
