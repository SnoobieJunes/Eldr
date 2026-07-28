// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import P256K
import PQRCCore

/// NIP-OA — Owner Attestation. A portable `auth` tag proving that an *owner*
/// key authorized an *agent* key to publish events under the agent's own
/// authorship. This is Block/Buzz's agent-provenance credential; Eldr speaks it
/// so a Buzz-ecosystem relay or verifier accepts an Eldr-hosted agent, and so
/// an Eldr node can verify agents attested by a Buzz owner.
///
/// Tag format (JSON array, no whitespace):
/// ```
/// ["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
/// ```
///
/// Signing preimage:
/// ```
/// preimage = "nostr:agent-auth:" || agent_pubkey_hex || ":" || conditions
/// message  = SHA256(preimage)
/// sig      = BIP-340 Schnorr(message, owner_secret_key)
/// ```
///
/// This is an ADDITIVE interop provenance format. Eldr's own 3-key,
/// bidirectional kind-10420 identity binding (`PQRCEvents`) is unchanged and
/// remains the stronger primitive; OA is a second, simpler shape spoken for
/// Buzz interop. Verified in `NIPOATests` against Buzz's published spec vector.
public enum NIPOA {
    public enum NIPOAError: Error, Equatable {
        case invalidConditions(String)
        case selfAttestation
        case malformedTag(String)
        case invalidKey
        case signatureInvalid
    }

    // MARK: - Compute

    /// Compute an `auth` tag authorizing `agentPublicKeyHex` under `conditions`,
    /// signed by the owner key. Returns the JSON-array string form.
    public static func computeAuthTag(
        ownerPrivateKey: Data, agentPublicKeyHex: String, conditions: String,
        randomSource: any RandomSource
    ) throws -> String {
        guard let ownerKey = try? P256K.Schnorr.PrivateKey(dataRepresentation: ownerPrivateKey) else {
            throw NIPOAError.invalidKey
        }
        let ownerPubHex = Data(ownerKey.xonly.bytes).hexString
        guard ownerPubHex != agentPublicKeyHex.lowercased() else { throw NIPOAError.selfAttestation }
        try validateConditions(conditions)

        let digest = preimageDigest(agentPublicKeyHex: agentPublicKeyHex, conditions: conditions)
        let sigHex = try schnorrSign(
            message: digest, privateKey: ownerPrivateKey, randomSource: randomSource)
        return encodeTag(owner: ownerPubHex, conditions: conditions, sig: sigHex)
    }

    // MARK: - Verify

    /// Verify an `auth` tag against the agent pubkey it should authorize.
    /// Returns the owner pubkey hex on success.
    @discardableResult
    public static func verifyAuthTag(_ tagJSON: String, agentPublicKeyHex: String) throws -> String {
        let parts = try parseAuthTag(tagJSON)
        let ownerHex = parts[1]
        let conditions = parts[2]
        let sigHex = parts[3]

        try validateConditions(conditions)
        guard ownerHex != agentPublicKeyHex.lowercased() else { throw NIPOAError.selfAttestation }

        let digest = preimageDigest(agentPublicKeyHex: agentPublicKeyHex, conditions: conditions)
        guard schnorrVerify(message: digest, publicKeyHex: ownerHex, sigHex: sigHex) else {
            throw NIPOAError.signatureInvalid
        }
        return ownerHex
    }

    /// Structural parse (no crypto): validates the 4-element `["auth", …]` shape
    /// and lowercase-hex owner/sig. Returns the four string elements.
    @discardableResult
    public static func parseAuthTag(_ tagJSON: String) throws -> [String] {
        guard let data = tagJSON.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { throw NIPOAError.malformedTag("not a JSON array") }
        guard array.count == 4 else {
            throw NIPOAError.malformedTag("auth tag must have 4 elements, got \(array.count)")
        }
        guard let label = array[0] as? String, label == "auth" else {
            throw NIPOAError.malformedTag("first element must be \"auth\"")
        }
        guard let owner = array[1] as? String, isLowercaseHex(owner, length: 64) else {
            throw NIPOAError.malformedTag("owner pubkey must be 64 lowercase hex chars")
        }
        guard let conditions = array[2] as? String else {
            throw NIPOAError.malformedTag("conditions must be a string")
        }
        guard let sig = array[3] as? String, isLowercaseHex(sig, length: 128) else {
            throw NIPOAError.malformedTag("signature must be 128 lowercase hex chars")
        }
        return [label, owner, conditions, sig]
    }

    // MARK: - Conditions grammar

    /// Validate the `conditions` string. Empty is valid. Non-empty is one or
    /// more `&`-joined clauses, each `kind=<0-65535>`, `created_at<<0-2^32-1>`,
    /// or `created_at><…>`, with canonical decimals (no leading zeros) and no
    /// whitespace. Mirrors Buzz's `buzz-sdk` grammar exactly.
    public static func validateConditions(_ conditions: String) throws {
        if conditions.isEmpty { return }
        if conditions.contains(where: { $0.isWhitespace }) {
            throw NIPOAError.invalidConditions("conditions must not contain whitespace")
        }
        for clause in conditions.split(separator: "&", omittingEmptySubsequences: false) {
            if clause.isEmpty {
                throw NIPOAError.invalidConditions("empty clause (leading/trailing/double '&')")
            }
            try validateClause(String(clause))
        }
    }

    private static func validateClause(_ clause: String) throws {
        if let value = clause.stripPrefix("kind=") {
            try validateCanonicalDecimal(value, min: 0, max: 65535, label: "kind")
        } else if let value = clause.stripPrefix("created_at<") {
            try validateCanonicalDecimal(value, min: 0, max: 4_294_967_295, label: "created_at<")
        } else if let value = clause.stripPrefix("created_at>") {
            try validateCanonicalDecimal(value, min: 0, max: 4_294_967_295, label: "created_at>")
        } else {
            throw NIPOAError.invalidConditions("unsupported clause: \(clause)")
        }
    }

    private static func validateCanonicalDecimal(
        _ s: String, min: UInt64, max: UInt64, label: String
    ) throws {
        guard !s.isEmpty else { throw NIPOAError.invalidConditions("\(label) value empty") }
        if s.count > 1 && s.hasPrefix("0") {
            throw NIPOAError.invalidConditions("\(label) has leading zero: \(s)")
        }
        guard s.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw NIPOAError.invalidConditions("\(label) not a decimal: \(s)")
        }
        guard let value = UInt64(s), value >= min, value <= max else {
            throw NIPOAError.invalidConditions("\(label) out of range: \(s)")
        }
    }

    // MARK: - Preimage + BIP-340 raw-message signing

    static func preimageDigest(agentPublicKeyHex: String, conditions: String) -> Data {
        let preimage = "nostr:agent-auth:\(agentPublicKeyHex):\(conditions)"
        return sha256(Data(preimage.utf8))
    }

    /// BIP-340 Schnorr sign a raw 32-byte message digest with `privateKey`.
    /// Uses the 4-argument form with an explicit 32-byte aux (the
    /// swift-secp256k1 `strict:true` path), so aux is XOR-folded per BIP-340
    /// (NIP-AE gotcha #2), not skipped.
    static func schnorrSign(message: Data, privateKey: Data, randomSource: any RandomSource) throws
        -> String
    {
        guard let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: privateKey) else {
            throw NIPOAError.invalidKey
        }
        var msg = [UInt8](message)
        var aux = [UInt8](randomSource.bytes(32))
        let signature = try aux.withUnsafeMutableBytes { auxPtr in
            try key.signature(message: &msg, auxiliaryRand: auxPtr.baseAddress, strict: true)
        }
        return signature.dataRepresentation.hexString
    }

    static func schnorrVerify(message: Data, publicKeyHex: String, sigHex: String) -> Bool {
        guard let pubData = Data(hexString: publicKeyHex), pubData.count == 32,
            let sigData = Data(hexString: sigHex), sigData.count == 64,
            let signature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: sigData)
        else { return false }
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: pubData)
        var msg = [UInt8](message)
        return xonly.isValid(signature, for: &msg)
    }

    // MARK: - Encoding helpers

    /// Encode `["auth", owner, conditions, sig]` with no whitespace. Owner/sig
    /// are validated hex and conditions is a validated restricted grammar, so
    /// none require JSON string escaping.
    static func encodeTag(owner: String, conditions: String, sig: String) -> String {
        "[\"auth\",\"\(owner)\",\"\(conditions)\",\"\(sig)\"]"
    }

    private static func isLowercaseHex(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

extension StringProtocol {
    fileprivate func stripPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
