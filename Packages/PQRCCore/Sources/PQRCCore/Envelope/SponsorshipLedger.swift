// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How a received message's agent sponsorship checked out, evaluated PER MESSAGE at
/// receipt (never cached as a contact-level flag). Shared by iOS and Linux.
public enum SponsorshipStatus: Codable, Sendable, Equatable {
    /// Human-labeled message: sponsorship does not apply.
    case human
    /// Agent-labeled message with no sponsorship attached.
    case unsponsored
    /// Agent-labeled, carrying a valid, unexpired, unrevoked sponsorship.
    case sponsored(sponsorIdentityHex: String, label: String?, activeUntil: Int64)
    /// Agent-labeled, carrying a sponsorship that failed (bad signature, wrong agent,
    /// expired, revoked, over 7 days…). Shown as a warning, never as sponsored.
    case invalid(reason: String)

    public var isSponsored: Bool { if case .sponsored = self { return true } else { return false } }

    /// True when the UI should warn (an agent with no valid sponsorship).
    public var isWarning: Bool {
        switch self {
        case .unsponsored, .invalid: return true
        case .human, .sponsored: return false
        }
    }

    /// Short badge for an AI message (empty for human). `nameOf` maps an identity hex
    /// to a local contact name; `date` formats the expiry. Text from the wire (label,
    /// reason) has controls and bidi overrides removed so it can't spoof the badge.
    public func badge(nameOf: (String) -> String?, date: (Int64) -> String) -> String {
        switch self {
        case .human: return ""
        case .unsponsored: return "AI · not sponsored"
        case .sponsored(let by, let label, let until):
            let who = nameOf(by) ?? "unknown person \(by.prefix(8))…"
            return "AI\(label.map { " “\(Self.clean($0))”" } ?? "") · sponsored by \(who) until \(date(until))"
        case .invalid(let reason): return "AI · sponsorship invalid (\(Self.clean(reason)))"
        }
    }

    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            let v = u.value
            if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) { return false }
            if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || v == 0x200E || v == 0x200F || v == 0x061C { return false }
            return true
        })).prefix(80).description
    }

    /// The single check every client runs on a received message.
    public static func evaluate(
        participantType: ParticipantType, body: MessageBody, senderIdentityHex: String,
        now: Int64, isRevoked: (AgentSponsorship) -> Bool
    ) -> SponsorshipStatus {
        guard participantType == .agent else { return .human }
        guard let sp = body.agentSponsorship else { return .unsponsored }
        guard sp.agent == senderIdentityHex else { return .invalid(reason: "names a different agent") }
        do { try sp.verify(presentedBy: senderIdentityHex, now: now) } catch {
            return .invalid(reason: "\(error)")
        }
        if isRevoked(sp) { return .invalid(reason: "revoked") }
        return .sponsored(sponsorIdentityHex: sp.enabledBy.hexString, label: sp.label, activeUntil: sp.activeUntil)
    }
}

/// A sponsorship THIS identity issued to an agent (sponsor side).
public struct IssuedSponsorship: Codable, Sendable, Equatable {
    public var sponsorship: AgentSponsorship
    public var revokedAt: Int64?
    public init(sponsorship: AgentSponsorship, revokedAt: Int64? = nil) {
        self.sponsorship = sponsorship
        self.revokedAt = revokedAt
    }
}

public enum SponsorshipLedgerError: Error, Equatable, Sendable {
    case badDuration
    case selfSponsorship
    case nothingToRevoke
}

/// Sponsor-side bookkeeping plus the revocation set, for a HUMAN persona. Pure value
/// type (persist it encrypted); signing uses the caller's identity, and sending the
/// returned bodies is the caller's job. Used by iOS; mirrors EldrClient (Linux).
public struct SponsorshipLedger: Codable, Sendable, Equatable {
    public static let dayChoices = [1, 7]
    public static let maxRevoked = 2000
    public private(set) var issued: [IssuedSponsorship] = []
    /// "<sponsorHex>:<sponsorshipID>" for every revocation issued or verified-received.
    public private(set) var revoked: [String] = []

    public init() {}

    public func isRevoked(_ s: AgentSponsorship) -> Bool {
        // My own revocations are authoritative from `issued`, so no amount of
        // revocation traffic from others can evict them (security/audit-1, AC212).
        if issued.contains(where: {
            $0.revokedAt != nil && $0.sponsorship.sponsorshipID == s.sponsorshipID
                && $0.sponsorship.enabledBy == s.enabledBy
        }) { return true }
        return revoked.contains("\(s.enabledBy.hexString):\(s.sponsorshipID)")
    }

    /// Live (unrevoked, unexpired) sponsorships I issued to this agent.
    public func live(to agentHex: String, now: Int64) -> [IssuedSponsorship] {
        issued.filter { $0.sponsorship.agent == agentHex && $0.revokedAt == nil && $0.sponsorship.activeUntil > now }
    }

    /// Signs a sponsorship of `agentHex` for `days` (1–30) and returns the body to send
    /// to that contact. Recorded as issued immediately; call `forget` if sending fails.
    public mutating func issue(
        to agentHex: String, days: Int, label: String?, identity: PQRCIdentity, now: Int64,
        sponsorshipID: String = UUID().uuidString.lowercased()
    ) throws -> MessageBody {
        guard (1...7).contains(days) else { throw SponsorshipLedgerError.badDuration }
        guard agentHex != identity.publicKeyData.hexString else { throw SponsorshipLedgerError.selfSponsorship }
        let label = label.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let sp = try AgentSponsorship.make(
            sponsorshipID: sponsorshipID, agent: agentHex, label: label,
            issuedAt: now, activeUntil: now + Int64(days) * 86_400, identity: identity)
        var body = MessageBody(
            text: "🛡 I sponsor this AI account\(label.map { " (\($0))" } ?? "") for \(days) day\(days == 1 ? "" : "s"). "
                + "I can revoke it at any time.",
            sentAt: now, messageID: UUID().uuidString)
        body.agentSponsorship = sp
        issued.append(IssuedSponsorship(sponsorship: sp))
        return body
    }

    /// Drops an issued record whose delivery failed (nothing reached the agent).
    public mutating func forget(sponsorshipID: String) {
        issued.removeAll { $0.sponsorship.sponsorshipID == sponsorshipID }
    }

    /// Revokes every live sponsorship I issued to `agentHex`. Returns one body per
    /// revocation, to send to the agent. Effective locally at once.
    public mutating func revokeAll(to agentHex: String, identity: PQRCIdentity, now: Int64) throws -> [MessageBody] {
        let me = identity.publicKeyData.hexString
        var out: [MessageBody] = []
        for i in issued.indices where issued[i].sponsorship.agent == agentHex && issued[i].revokedAt == nil {
            let id = issued[i].sponsorship.sponsorshipID
            let r = try AgentSponsorshipRevocation.make(sponsorshipID: id, revokedAt: now, identity: identity)
            issued[i].revokedAt = now
            remember("\(me):\(id)")
            var body = MessageBody(
                text: "🛡 I revoked my sponsorship of this AI account.", sentAt: now, messageID: UUID().uuidString)
            body.agentSponsorshipRevocation = r
            out.append(body)
        }
        guard !out.isEmpty else { throw SponsorshipLedgerError.nothingToRevoke }
        return out
    }

    /// Records a revocation received from `senderHex` if it verifies (a revocation
    /// relayed by anyone but its signer is ignored). Returns whether it was accepted.
    @discardableResult
    public mutating func receive(revocation r: AgentSponsorshipRevocation, from senderHex: String) -> Bool {
        guard (try? r.verify(presentedBy: senderHex)) != nil else { return false }
        remember("\(senderHex):\(r.sponsorshipID)")
        return true
    }

    /// Status of a received message, honoring every revocation this ledger knows.
    public func status(
        participantType: ParticipantType, body: MessageBody, senderIdentityHex: String, now: Int64
    ) -> SponsorshipStatus {
        SponsorshipStatus.evaluate(
            participantType: participantType, body: body, senderIdentityHex: senderIdentityHex,
            now: now, isRevoked: isRevoked)
    }

    private mutating func remember(_ key: String) {
        RevocationSet.remember(key, into: &revoked, max: Self.maxRevoked)
    }
}

/// Bounded revocation memory that one sender cannot flush (security/audit-1, AC212).
///
/// Keys are "<sponsorHex>:<sponsorshipID>". Any contact can sign revocations of
/// made-up IDs under its OWN key, so a single global FIFO let one contact push
/// thousands of junk entries and evict a real sponsor's revocation, after which the
/// revoked AI's old (≤30-day) sponsorship verified again. Now each sponsor has its
/// own quota, and over the global cap the eviction comes from the LARGEST sponsor's
/// oldest entry, so a flood only ever evicts the flooder's own entries.
public enum RevocationSet {
    public static let perSponsorMax = 256

    public static func remember(_ key: String, into revoked: inout [String], max: Int) {
        guard !revoked.contains(key) else { return }
        let sponsor = key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
        let prefix = sponsor + ":"
        revoked.append(key)
        let mine = revoked.filter { $0.hasPrefix(prefix) }.count
        if mine > perSponsorMax, let i = revoked.firstIndex(where: { $0.hasPrefix(prefix) }) {
            revoked.remove(at: i)
        }
        while revoked.count > max {
            var counts: [Substring: Int] = [:]
            for k in revoked { counts[k.split(separator: ":", maxSplits: 1).first ?? "", default: 0] += 1 }
            guard let biggest = counts.max(by: { $0.value < $1.value })?.key,
                let i = revoked.firstIndex(where: { $0.hasPrefix(biggest + ":") })
            else { revoked.removeFirst(); continue }
            revoked.remove(at: i)
        }
    }
}
