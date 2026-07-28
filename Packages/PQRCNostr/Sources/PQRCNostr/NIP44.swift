// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import P256K
import PQRCCore

/// NIP-44 v2 payload encryption — the encryption scheme used across Block's
/// Buzz agent-plane NIPs (NIP-AM turn metrics, NIP-AO observer frames, NIP-AE
/// engrams). This is an **interop codec**: it lets Eldr emit and read events
/// that a Buzz relay / Buzz desktop / any NIP-44 client understands.
///
/// Scheme (per NIP-44 v2):
///   conversation_key = HKDF-Extract(salt="nip44-v2", ikm=ecdh_shared_x)
///   per message:
///     keys           = HKDF-Expand(conversation_key, info=nonce, L=76)
///     chacha_key      = keys[0..32]
///     chacha_nonce    = keys[32..44]        (12 bytes)
///     hmac_key        = keys[44..76]
///     ciphertext      = ChaCha20(chacha_key, chacha_nonce, pad(plaintext))
///     mac             = HMAC-SHA256(hmac_key, nonce || ciphertext)   (aad = nonce)
///     payload         = base64( 0x02 || nonce(32) || ciphertext || mac(32) )
///
/// **Three re-derivation gotchas** (all pinned in `NIP44Tests` against Buzz's
/// published vectors):
///   1. ECDH IKM is the RAW unhashed 32-byte shared_x (not SHA-256 of it).
///   2. HKDF-Extract salt is the ASCII bytes of "nip44-v2".
///   3. The HMAC covers `nonce || ciphertext` (nonce as AAD prefix), not just
///      the ciphertext.
///
/// This does NOT replace `SealCipher` (PQRC's own seal layer, which keeps its
/// AEAD posture per SPEC §2). It sits alongside it for Buzz interop only. See
/// DEVIATIONS `[upstream-NIP]`.
public enum NIP44 {
    public enum NIP44Error: Error, Equatable {
        case invalidKey
        case invalidPayload
        case unsupportedVersion(UInt8)
        case macMismatch
        case plaintextTooLarge
        case plaintextEmpty
    }

    /// Bounds from the spec: 1 byte minimum, 65535 bytes maximum plaintext.
    public static let minPlaintextLen = 1
    public static let maxPlaintextLen = 65535

    // MARK: - Conversation key (ECDH → HKDF-Extract)

    /// Direction-independent conversation key: `HKDF-Extract(salt="nip44-v2",
    /// ikm=shared_x)` where `shared_x` is the raw x-coordinate of the ECDH
    /// shared point. Both parties compute the identical value.
    public static func conversationKey(privateKey: Data, peerPublicKeyHex: String) throws -> Data {
        guard let peerData = Data(hexString: peerPublicKeyHex), peerData.count == 32 else {
            throw NIP44Error.invalidKey
        }
        guard let agreementKey = try? P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey),
            let peer = try? P256K.KeyAgreement.PublicKey(
                dataRepresentation: Data([0x02]) + peerData, format: .compressed)
        else { throw NIP44Error.invalidKey }
        let shared = agreementKey.sharedSecretFromKeyAgreement(with: peer)
        // Raw x-coordinate (NIP-44 gotcha #1: NOT hashed). Lifting an x-only key
        // to even-Y can negate the shared point between the two directions, but
        // the x-coordinate is identical either way.
        let sharedX = Data(shared.bytes.suffix(32))
        return hkdfExtract(salt: Data("nip44-v2".utf8), ikm: sharedX)
    }

    // MARK: - Encrypt / Decrypt

    /// Encrypt with an explicit 32-byte nonce (deterministic — used by tests and
    /// vector reproduction). Production callers use the random-nonce overload.
    public static func encrypt(
        plaintext: String, conversationKey: Data, nonce: Data
    ) throws -> String {
        let plaintextBytes = [UInt8](Data(plaintext.utf8))
        guard plaintextBytes.count >= minPlaintextLen else { throw NIP44Error.plaintextEmpty }
        guard plaintextBytes.count <= maxPlaintextLen else { throw NIP44Error.plaintextTooLarge }
        guard nonce.count == 32 else { throw NIP44Error.invalidPayload }

        let (chachaKey, chachaNonce, hmacKey) = messageKeys(conversationKey: conversationKey, nonce: nonce)
        let padded = pad(plaintextBytes)
        let ciphertext = ChaCha20.xor(
            key: [UInt8](chachaKey), nonce: [UInt8](chachaNonce), data: padded)
        let mac = hmacWithAAD(key: hmacKey, message: ciphertext, aad: [UInt8](nonce))

        var payload = Data([0x02])
        payload.append(nonce)
        payload.append(Data(ciphertext))
        payload.append(Data(mac))
        return payload.base64EncodedString()
    }

    /// Encrypt with a fresh random nonce from the given source.
    public static func encrypt(
        plaintext: String, conversationKey: Data, randomSource: any RandomSource
    ) throws -> String {
        try encrypt(plaintext: plaintext, conversationKey: conversationKey, nonce: randomSource.bytes(32))
    }

    /// Encrypt directly from sender private key + recipient x-only pubkey.
    public static func encrypt(
        plaintext: String, senderPrivateKey: Data, recipientPublicKeyHex: String,
        randomSource: any RandomSource
    ) throws -> String {
        let ck = try conversationKey(privateKey: senderPrivateKey, peerPublicKeyHex: recipientPublicKeyHex)
        return try encrypt(plaintext: plaintext, conversationKey: ck, randomSource: randomSource)
    }

    public static func decrypt(payload: String, conversationKey: Data) throws -> String {
        guard let raw = Data(base64Encoded: payload), raw.count >= 1 + 32 + 32 else {
            throw NIP44Error.invalidPayload
        }
        let bytes = [UInt8](raw)
        let version = bytes[0]
        guard version == 0x02 else { throw NIP44Error.unsupportedVersion(version) }

        let nonce = Array(bytes[1..<33])
        let ciphertext = Array(bytes[33..<(bytes.count - 32)])
        let mac = Array(bytes[(bytes.count - 32)...])
        // ChaCha20 is a stream cipher: ciphertext length == padded-plaintext
        // length (2-byte length prefix + 32-byte-bucketed plaintext), which is
        // even but NOT block-aligned — so no `% 16` check here.
        guard ciphertext.count >= 2 else { throw NIP44Error.invalidPayload }

        let (chachaKey, chachaNonce, hmacKey) = messageKeys(
            conversationKey: conversationKey, nonce: Data(nonce))
        let expectedMac = hmacWithAAD(key: hmacKey, message: ciphertext, aad: nonce)
        guard constantTimeEqual(mac, expectedMac) else { throw NIP44Error.macMismatch }

        let padded = ChaCha20.xor(
            key: [UInt8](chachaKey), nonce: [UInt8](chachaNonce), data: ciphertext)
        guard padded.count >= 2 else { throw NIP44Error.invalidPayload }
        let declaredLen = (Int(padded[0]) << 8) | Int(padded[1])
        guard declaredLen >= 1, 2 + declaredLen <= padded.count else { throw NIP44Error.invalidPayload }
        let plaintextBytes = Array(padded[2..<(2 + declaredLen)])
        guard let text = String(bytes: plaintextBytes, encoding: .utf8) else {
            throw NIP44Error.invalidPayload
        }
        return text
    }

    public static func decrypt(
        payload: String, recipientPrivateKey: Data, senderPublicKeyHex: String
    ) throws -> String {
        let ck = try conversationKey(privateKey: recipientPrivateKey, peerPublicKeyHex: senderPublicKeyHex)
        return try decrypt(payload: payload, conversationKey: ck)
    }

    // MARK: - Padding (NIP-44 calc_padded_len)

    /// NIP-44 padded length: pad the plaintext to a bucket so the ciphertext
    /// length leaks only a coarse size class.
    static func calcPaddedLen(_ unpadded: Int) -> Int {
        precondition(unpadded > 0)
        if unpadded <= 32 { return 32 }
        // nextPower = 1 << (floor(log2(unpadded-1)) + 1), computed with bit ops
        // to avoid floating-point rounding at large lengths.
        let m = unpadded - 1
        let highBit = (Int.bitWidth - 1) - m.leadingZeroBitCount
        let nextPower = 1 << (highBit + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * (((unpadded - 1) / chunk) + 1)
    }

    /// pad = u16_be(len) || plaintext || zero-fill to calcPaddedLen(len).
    static func pad(_ plaintext: [UInt8]) -> [UInt8] {
        let unpadded = plaintext.count
        var out = [UInt8]()
        out.reserveCapacity(2 + calcPaddedLen(unpadded))
        out.append(UInt8((unpadded >> 8) & 0xff))
        out.append(UInt8(unpadded & 0xff))
        out.append(contentsOf: plaintext)
        let padLen = calcPaddedLen(unpadded) - unpadded
        if padLen > 0 { out.append(contentsOf: [UInt8](repeating: 0, count: padLen)) }
        return out
    }

    // MARK: - HKDF (RFC 5869, over swift-crypto's HMAC-SHA256)

    /// HKDF-Extract(salt, ikm) = HMAC-SHA256(key=salt, message=ikm).
    static func hkdfExtract(salt: Data, ikm: Data) -> Data {
        let key = SymmetricKey(data: salt)
        return Data(HMAC<Crypto.SHA256>.authenticationCode(for: ikm, using: key))
    }

    /// HKDF-Expand(prk, info, L) per RFC 5869.
    static func hkdfExpand(prk: Data, info: Data, length: Int) -> Data {
        let key = SymmetricKey(data: prk)
        var okm = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            var input = previous
            input.append(info)
            input.append(counter)
            let block = Data(HMAC<Crypto.SHA256>.authenticationCode(for: input, using: key))
            okm.append(block)
            previous = block
            counter &+= 1
        }
        return okm.prefix(length)
    }

    /// Derive per-message ChaCha key (32) / ChaCha nonce (12) / HMAC key (32).
    static func messageKeys(conversationKey: Data, nonce: Data) -> (Data, Data, Data) {
        let expanded = hkdfExpand(prk: conversationKey, info: nonce, length: 76)
        let chachaKey = expanded.subdata(in: 0..<32)
        let chachaNonce = expanded.subdata(in: 32..<44)
        let hmacKey = expanded.subdata(in: 44..<76)
        return (chachaKey, chachaNonce, hmacKey)
    }

    // MARK: - HMAC with AAD (aad || message)

    static func hmacWithAAD(key: Data, message: [UInt8], aad: [UInt8]) -> [UInt8] {
        var input = Data(aad)
        input.append(contentsOf: message)
        return [UInt8](HMAC<Crypto.SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
