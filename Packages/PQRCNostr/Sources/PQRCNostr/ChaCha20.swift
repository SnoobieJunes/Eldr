// SPDX-License-Identifier: Apache-2.0
import Foundation

/// RFC 8439 ChaCha20 stream cipher (raw keystream, unauthenticated).
///
/// **Why this exists.** NIP-44 v2 (the Buzz/Nostr agent-plane encryption used by
/// NIP-AM, NIP-AO, and NIP-AE) mandates *raw* ChaCha20 as its stream cipher,
/// with a separate HMAC-SHA256 for integrity. Apple's CryptoKit / swift-crypto
/// expose only the AEAD `ChaChaPoly` (ChaCha20-Poly1305) and no bare ChaCha20
/// keystream, so speaking NIP-44 on the wire requires the block function here.
///
/// **Scope.** This is INTEROP code, isolated to `PQRCNostr`. It is a faithful
/// implementation of a published IETF standard (RFC 8439 §2.3–2.4), verified in
/// `ChaCha20Tests` against RFC 8439's own test vectors and, transitively,
/// against Buzz's published NIP-44/NIP-AE event vectors. It is NOT a new
/// primitive and it does NOT touch the PQRC protocol core — `SealCipher`
/// (PQRC's own seal/gift-wrap layer) continues to use the vetted `ChaChaPoly`
/// AEAD per SPEC §2. See DEVIATIONS `[upstream-NIP]` NIP-44 interop.
enum ChaCha20 {
    private static let constants: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    @inline(__always)
    private static func quarterRound(_ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    @inline(__always)
    private static func loadLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    /// Produce one 64-byte keystream block for the given key/counter/nonce.
    private static func block(key: [UInt8], counter: UInt32, nonce: [UInt8]) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = constants[0]; state[1] = constants[1]
        state[2] = constants[2]; state[3] = constants[3]
        for i in 0..<8 { state[4 + i] = loadLE32(key, i * 4) }
        state[12] = counter
        for i in 0..<3 { state[13 + i] = loadLE32(nonce, i * 4) }

        var working = state
        for _ in 0..<10 {
            // Column rounds.
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            // Diagonal rounds.
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        var out = [UInt8](repeating: 0, count: 64)
        for i in 0..<16 {
            let word = working[i] &+ state[i]
            out[i * 4 + 0] = UInt8(word & 0xff)
            out[i * 4 + 1] = UInt8((word >> 8) & 0xff)
            out[i * 4 + 2] = UInt8((word >> 16) & 0xff)
            out[i * 4 + 3] = UInt8((word >> 24) & 0xff)
        }
        return out
    }

    /// XOR `data` with the ChaCha20 keystream (encryption == decryption).
    ///
    /// - Parameters:
    ///   - key: 32-byte key.
    ///   - nonce: 12-byte nonce (RFC 8439 96-bit nonce form — what NIP-44 uses).
    ///   - counter: initial block counter (NIP-44 starts at 0).
    static func xor(key: [UInt8], nonce: [UInt8], counter: UInt32 = 0, data: [UInt8]) -> [UInt8] {
        precondition(key.count == 32, "ChaCha20 key must be 32 bytes")
        precondition(nonce.count == 12, "ChaCha20 nonce must be 12 bytes")
        var out = [UInt8](repeating: 0, count: data.count)
        var blockCounter = counter
        var offset = 0
        while offset < data.count {
            let ks = block(key: key, counter: blockCounter, nonce: nonce)
            let n = min(64, data.count - offset)
            for i in 0..<n { out[offset + i] = data[offset + i] ^ ks[i] }
            offset += 64
            blockCounter &+= 1
        }
        return out
    }

    static func xor(key: Data, nonce: Data, counter: UInt32 = 0, data: Data) -> Data {
        Data(xor(key: [UInt8](key), nonce: [UInt8](nonce), counter: counter, data: [UInt8](data)))
    }
}
