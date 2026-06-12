import Crypto
import Foundation
import P256K
import PQRCCore

/// Encryption for the seal and gift-wrap layers ("pqrc-seal-v1").
///
/// NIP-44 v2 specifies unauthenticated ChaCha20 + HMAC, but CryptoKit exposes
/// no raw ChaCha20 and reimplementing one would violate SPEC §2 (no custom
/// primitives). pqrc-seal-v1 keeps NIP-44's shape — secp256k1 ECDH conversation
/// key + HKDF — but uses ChaChaPoly (an AEAD, strictly stronger integrity).
/// Interop with NIP-44 clients is deferred; recorded in DEVIATIONS
/// [upstream-NIP].
public enum SealCipher {
    /// Direction-independent conversation key from secp256k1 ECDH.
    static func conversationKey(privateKey: Data, peerPublicKeyHex: String) throws -> SymmetricKey {
        guard let peerData = Data(hexString: peerPublicKeyHex), peerData.count == 32 else {
            throw NostrError.invalidKey
        }
        let agreementKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        // x-only pubkey -> compressed point with even-Y prefix (BIP-340 convention).
        let peer = try P256K.KeyAgreement.PublicKey(
            dataRepresentation: Data([0x02]) + peerData, format: .compressed)
        let shared = agreementKey.sharedSecretFromKeyAgreement(with: peer)
        // x-coordinate only: lifting x-only keys to even-Y points can negate the
        // shared point between the two directions; x is identical either way.
        let sharedBytes = Data(shared.bytes.suffix(32))
        return Crypto.HKDF<Crypto.SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedBytes),
            salt: Data("pqrc-seal-v1".utf8),
            info: Data("conversation-key".utf8),
            outputByteCount: 32
        )
    }

    /// Output layout: version(0x01) || nonce(12) || ciphertext || tag(16), base64.
    public static func encrypt(
        _ plaintext: Data, privateKey: Data, peerPublicKeyHex: String,
        nonceSource: any NonceSource
    ) throws -> String {
        let key = try conversationKey(privateKey: privateKey, peerPublicKeyHex: peerPublicKeyHex)
        let nonceData = nonceSource.nextNonce()
        let sealed = try ChaChaPoly.seal(
            plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonceData))
        var payload = Data([0x01])
        payload.append(nonceData)
        payload.append(sealed.ciphertext)
        payload.append(sealed.tag)
        return payload.base64EncodedString()
    }

    public static func decrypt(
        _ payload: String, privateKey: Data, peerPublicKeyHex: String
    ) throws -> Data {
        guard let data = Data(base64Encoded: payload), data.count > 29, data.first == 0x01 else {
            throw NostrError.sealDecryptFailed
        }
        let key = try conversationKey(privateKey: privateKey, peerPublicKeyHex: peerPublicKeyHex)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: data.subdata(in: 1..<13)),
                ciphertext: data.subdata(in: 13..<(data.count - 16)),
                tag: data.suffix(16))
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw NostrError.sealDecryptFailed
        }
    }
}
