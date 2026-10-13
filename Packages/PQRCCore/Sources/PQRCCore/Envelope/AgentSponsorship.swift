// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why an agent sponsorship (or its revocation) was rejected. Typed so UI and
/// tests can assert the exact reason without string matching.
public enum AgentSponsorshipError: Error, Equatable, Sendable {
    case wrongType
    case malformedID
    case malformedAgent
    case malformedEnabledBy
    case malformedLabel
    case selfSponsorship
    case signatureInvalid
    case durationUnbounded
    case expired
    case notFromSponsor
    case notForMe
}

/// Human-signed **agent sponsorship** (DEVIATIONS AC162): "the PQRC identity
/// `agent` is an AI account I, `enabled_by`, vouch for until `active_until`."
///
/// It follows the standing-grant model exactly: signed by the sponsor's HUMAN
/// identity key under its own domain string, at most 30 days of life (refused,
/// never truncated), revocable by the same key, and checked on every message
/// rather than cached as a flag. It rides INSIDE the ratchet ciphertext as an
/// optional `MessageBody` field, so relays never see it and older clients ignore
/// it (SPEC §12) — which is fail-closed: an older client simply shows no badge.
///
/// A sponsorship is a label with accountability, not an authorization: it grants
/// the agent no autonomy in anyone's conversation (the §13 window/invite gates
/// are unchanged) and never relabels authorship (invariant 8 still requires
/// `participant_type: "agent"` on everything the agent sends).
public struct AgentSponsorship: Codable, Equatable, Sendable {
    public static let maxIDLength = 64
    public static let maxLabelLength = 64
    public static let domain = "pqrc-agent-sponsorship-v1"

    public let type: String
    public let sponsorshipID: String
    /// The sponsored agent's PQRC identity pubkey, 64 lowercase hex.
    public let agent: String
    /// Optional display label the sponsor chose (e.g. "ELDR"). Bound in the signature.
    public let label: String?
    public let issuedAt: Int64
    public let activeUntil: Int64
    /// The sponsor's HUMAN identity pubkey (32 bytes).
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case sponsorshipID = "sponsorship_id"
        case agent
        case label
        case issuedAt = "issued_at"
        case activeUntil = "active_until"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(
        sponsorshipID: String, agent: String, label: String?, issuedAt: Int64,
        activeUntil: Int64, enabledBy: Data, sig: Data
    ) {
        self.type = "agent_sponsorship"
        self.sponsorshipID = sponsorshipID
        self.agent = agent
        self.label = label
        self.issuedAt = issuedAt
        self.activeUntil = activeUntil
        self.enabledBy = enabledBy
        self.sig = sig
    }

    /// Injective, length-prefixed encoding of every scoped field (same reasoning
    /// as `StandingGrant.scopeTag`: a delimiter join is transplantable).
    public var scopeTag: String {
        var out = "agent-sponsorship-v1"
        func add(_ v: String) { out += "|\(v.utf8.count):\(v)" }
        add(sponsorshipID)
        add(agent)
        if let label { add("label=" + label) } else { add("label=-") }
        add("issued=\(issuedAt)")
        return out
    }

    public static func signatureMessage(scopeTag: String, activeUntil: Int64, enabledBy: Data) -> Data {
        var msg = Data(domain.utf8)
        msg.append(Data(int64BE: activeUntil))
        msg.append(enabledBy)
        msg.append(Data(scopeTag.utf8))
        return msg
    }

    public static func make(
        sponsorshipID: String, agent: String, label: String?, issuedAt: Int64,
        activeUntil: Int64, identity: PQRCIdentity
    ) throws -> AgentSponsorship {
        let pub = identity.publicKeyData
        let unsigned = AgentSponsorship(
            sponsorshipID: sponsorshipID, agent: agent, label: label, issuedAt: issuedAt,
            activeUntil: activeUntil, enabledBy: pub, sig: Data())
        try unsigned.validateStructure()
        guard activeUntil > issuedAt, activeUntil - issuedAt <= PQRCConstants.maxStandingGrantDuration
        else { throw AgentSponsorshipError.durationUnbounded }
        let sig = try identity.sign(
            signatureMessage(scopeTag: unsigned.scopeTag, activeUntil: activeUntil, enabledBy: pub))
        return AgentSponsorship(
            sponsorshipID: sponsorshipID, agent: agent, label: label, issuedAt: issuedAt,
            activeUntil: activeUntil, enabledBy: pub, sig: sig)
    }

    public func validateStructure() throws {
        guard type == "agent_sponsorship" else { throw AgentSponsorshipError.wrongType }
        guard !sponsorshipID.isEmpty, sponsorshipID.utf8.count <= Self.maxIDLength
        else { throw AgentSponsorshipError.malformedID }
        guard agent.count == 64, agent == agent.lowercased(), Data(hexString: agent)?.count == 32
        else { throw AgentSponsorshipError.malformedAgent }
        guard enabledBy.count == 32 else { throw AgentSponsorshipError.malformedEnabledBy }
        if let label {
            guard !label.isEmpty, label.utf8.count <= Self.maxLabelLength,
                !label.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw AgentSponsorshipError.malformedLabel }
        }
        guard enabledBy.hexString != agent else { throw AgentSponsorshipError.selfSponsorship }
    }

    public func hasValidSignature() -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(scopeTag: scopeTag, activeUntil: activeUntil, enabledBy: enabledBy),
            publicKey: enabledBy)
    }

    /// Full receiver check, all fail-closed. `presentedBy` is the identity hex of
    /// the peer whose ratchet delivered the object; `now` is the receiver's clock.
    ///
    /// - When the AGENT receives it from the sponsor: `presentedBy == enabledBy`.
    /// - When a third party sees it attached to the agent's message:
    ///   `presentedBy == agent`.
    /// Either way the object must name the agent, verify, and be within 30 days.
    public func verify(presentedBy: String, now: Int64) throws {
        try validateStructure()
        guard presentedBy == agent || presentedBy == enabledBy.hexString
        else { throw AgentSponsorshipError.notFromSponsor }
        guard hasValidSignature() else { throw AgentSponsorshipError.signatureInvalid }
        guard activeUntil - now <= PQRCConstants.maxStandingGrantDuration
        else { throw AgentSponsorshipError.durationUnbounded }
        guard now < activeUntil else { throw AgentSponsorshipError.expired }
    }
}

/// Signed withdrawal of an ``AgentSponsorship``, effective on receipt.
public struct AgentSponsorshipRevocation: Codable, Equatable, Sendable {
    public static let domain = "pqrc-agent-sponsorship-revocation-v1"
    public let type: String
    public let sponsorshipID: String
    public let revokedAt: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case sponsorshipID = "sponsorship_id"
        case revokedAt = "revoked_at"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(sponsorshipID: String, revokedAt: Int64, enabledBy: Data, sig: Data) {
        self.type = "agent_sponsorship_revocation"
        self.sponsorshipID = sponsorshipID
        self.revokedAt = revokedAt
        self.enabledBy = enabledBy
        self.sig = sig
    }

    public static func signatureMessage(sponsorshipID: String, revokedAt: Int64, enabledBy: Data) -> Data {
        var msg = Data(domain.utf8)
        msg.append(Data(int64BE: revokedAt))
        msg.append(enabledBy)
        msg.append(Data("\(sponsorshipID.utf8.count):\(sponsorshipID)".utf8))
        return msg
    }

    public static func make(
        sponsorshipID: String, revokedAt: Int64, identity: PQRCIdentity
    ) throws -> AgentSponsorshipRevocation {
        guard !sponsorshipID.isEmpty, sponsorshipID.utf8.count <= AgentSponsorship.maxIDLength
        else { throw AgentSponsorshipError.malformedID }
        let pub = identity.publicKeyData
        return AgentSponsorshipRevocation(
            sponsorshipID: sponsorshipID, revokedAt: revokedAt, enabledBy: pub,
            sig: try identity.sign(signatureMessage(sponsorshipID: sponsorshipID, revokedAt: revokedAt, enabledBy: pub)))
    }

    /// Valid iff well-formed, signed by `enabledBy`, and delivered by that same
    /// identity (a revocation relayed by anyone else — including the agent — is ignored).
    public func verify(presentedBy: String) throws {
        guard type == "agent_sponsorship_revocation" else { throw AgentSponsorshipError.wrongType }
        guard !sponsorshipID.isEmpty, sponsorshipID.utf8.count <= AgentSponsorship.maxIDLength
        else { throw AgentSponsorshipError.malformedID }
        guard enabledBy.count == 32 else { throw AgentSponsorshipError.malformedEnabledBy }
        guard presentedBy == enabledBy.hexString else { throw AgentSponsorshipError.notFromSponsor }
        guard PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(sponsorshipID: sponsorshipID, revokedAt: revokedAt, enabledBy: enabledBy),
            publicKey: enabledBy)
        else { throw AgentSponsorshipError.signatureInvalid }
    }
}
