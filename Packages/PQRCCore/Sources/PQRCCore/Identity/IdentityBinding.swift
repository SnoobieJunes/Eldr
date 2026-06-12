import Crypto
import Foundation

/// The kind-10420 identity binding assertion (SPEC §3.3, NIP-XX §3).
///
/// Published as a replaceable Nostr event signed by the user's secp256k1 Nostr
/// key (the "outer" signature, verified in PQRCNostr). The payload binds three
/// keys in both directions:
///   - outward: the Nostr key asserts the PQRC identity + agent keys (outer sig);
///   - inward: the PQRC identity key cross-signs the Nostr + agent keys.
/// No key from this structure may be trusted until BOTH directions verify
/// (CLAUDE.md invariant 7).
public struct IdentityBinding: Codable, Equatable, Sendable {
    /// x-only secp256k1 Nostr pubkey (32 bytes, hex on the wire).
    public let nostrPubkey: Data
    /// Ed25519 PQRC identity pubkey.
    public let identityPubkey: Data
    /// Ed25519 derived agent pubkey.
    public let agentPubkey: Data
    public let version: String
    public let capabilities: [String]
    /// Ed25519 signature by the identity key over `crossSignatureMessage`.
    public let crossSignature: Data

    public init(
        nostrPubkey: Data, identityPubkey: Data, agentPubkey: Data,
        version: String = PQRCConstants.version,
        capabilities: [String] = ["pqxdh", "double-ratchet", "ml-kem-768"],
        crossSignature: Data
    ) {
        self.nostrPubkey = nostrPubkey
        self.identityPubkey = identityPubkey
        self.agentPubkey = agentPubkey
        self.version = version
        self.capabilities = capabilities
        self.crossSignature = crossSignature
    }

    /// Domain-separated message the identity key signs:
    /// "pqrc-binding-v1" || nostr_pubkey || identity_pubkey || agent_pubkey
    public static func crossSignatureMessage(
        nostrPubkey: Data, identityPubkey: Data, agentPubkey: Data
    ) -> Data {
        var msg = Data("pqrc-binding-v1".utf8)
        msg.append(nostrPubkey)
        msg.append(identityPubkey)
        msg.append(agentPubkey)
        return msg
    }

    /// Create a fully-signed binding for our own identity.
    public static func make(
        identity: PQRCIdentity, nostrPubkey: Data
    ) throws -> IdentityBinding {
        let agentPub = try AgentKeyDeriver.deriveAgentKey(from: identity).publicKey.rawRepresentation
        let message = crossSignatureMessage(
            nostrPubkey: nostrPubkey,
            identityPubkey: identity.publicKeyData,
            agentPubkey: agentPub
        )
        return IdentityBinding(
            nostrPubkey: nostrPubkey,
            identityPubkey: identity.publicKeyData,
            agentPubkey: agentPub,
            crossSignature: try identity.sign(message)
        )
    }
}

/// The only way to obtain trusted keys from a binding. Construction requires
/// full verification; `BindingVerifier` never returns keys from an unverified
/// binding (TEST-PLAN §3).
public struct VerifiedBinding: Equatable, Sendable {
    public let nostrPubkey: Data
    public let identityPubkey: Data
    public let agentPubkey: Data

    fileprivate init(_ binding: IdentityBinding) {
        self.nostrPubkey = binding.nostrPubkey
        self.identityPubkey = binding.identityPubkey
        self.agentPubkey = binding.agentPubkey
    }
}

public enum BindingVerifier {
    /// Verify a binding in both directions.
    ///
    /// - Parameter outerSignatureValid: result of BIP-340 verification of the
    ///   carrying kind-10420 event against `binding.nostrPubkey`, performed by
    ///   the Nostr layer (core has no secp256k1 dependency by design).
    public static func verify(
        _ binding: IdentityBinding,
        outerSignatureValid: Bool
    ) throws -> VerifiedBinding {
        guard binding.version == PQRCConstants.version else {
            throw PQRCError.bindingVerificationFailed(.wrongVersion)
        }
        guard binding.nostrPubkey.count == 32 else {
            throw PQRCError.bindingVerificationFailed(.missingTag("nostr_pubkey"))
        }
        guard binding.identityPubkey.count == 32 else {
            throw PQRCError.bindingVerificationFailed(.missingTag("identity_key"))
        }
        guard binding.agentPubkey.count == 32 else {
            throw PQRCError.bindingVerificationFailed(.missingTag("agent_key"))
        }
        // Direction 1: Nostr key -> PQRC keys (outer event signature).
        guard outerSignatureValid else {
            throw PQRCError.bindingVerificationFailed(.badOuterSignature)
        }
        // Direction 2: PQRC identity key -> Nostr + agent keys (cross-signature).
        // A swapped, mismatched, or tampered key set fails here.
        let message = IdentityBinding.crossSignatureMessage(
            nostrPubkey: binding.nostrPubkey,
            identityPubkey: binding.identityPubkey,
            agentPubkey: binding.agentPubkey
        )
        guard PQRCIdentity.verify(
            signature: binding.crossSignature,
            message: message,
            publicKey: binding.identityPubkey
        ) else {
            throw PQRCError.bindingVerificationFailed(.badCrossSignature)
        }
        return VerifiedBinding(binding)
    }
}
