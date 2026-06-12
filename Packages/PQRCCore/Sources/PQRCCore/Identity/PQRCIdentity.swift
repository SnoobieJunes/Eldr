import Crypto
import Foundation

/// The long-term Ed25519 PQRC identity key (SPEC §3.1).
///
/// Distinct from the secp256k1 Nostr signing key: Nostr events require BIP-340
/// signatures, which Ed25519 cannot produce, so a PQRC user holds both and binds
/// them via the kind-10420 assertion (SPEC §3.3, NIP-XX). The private half lives
/// in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) at the app
/// layer; this type only handles the math.
public struct PQRCIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }

    /// Generate a fresh identity from the injected random source.
    public init(randomSource: RandomSource) throws {
        try self.init(seed: randomSource.bytes(32))
    }

    /// Reconstruct from a 32-byte seed (Keychain restore, test vectors).
    public init(seed: Data) throws {
        guard seed.count == 32 else { throw PQRCError.invalidKeyLength }
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }
}

/// Derives the tightly-coupled AI agent key from the identity key (SPEC §3.2).
///
/// One-way: exposure of the agent key does not expose the identity key.
/// The agent seed is re-derived on demand and never stored (APP-SPEC §3).
public enum AgentKeyDeriver {
    public static func deriveAgentKey(from identity: PQRCIdentity) throws -> Curve25519.Signing.PrivateKey {
        let identityPub = identity.publicKeyData
        var info = Data(PQRCConstants.agentHKDFInfoPrefix.utf8)
        info.append(identityPub)
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: identity.privateKey.rawRepresentation),
            salt: Data(PQRCConstants.agentHKDFSalt.utf8),
            info: info,
            outputByteCount: 32
        )
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed.rawData)
    }
}
