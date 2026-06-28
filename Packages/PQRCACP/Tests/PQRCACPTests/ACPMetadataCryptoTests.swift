import Foundation
import Testing

@testable import PQRCACP

/// The shared metadata codec both the agent process and Huginn's ContextLearner use.
/// Proves cross-process compatibility (encrypt here, decrypt there, same derived key) and
/// that a wrong key / corrupt input fails closed instead of leaking.
@Suite("ACP metadata crypto (events.jsonl / eldr.md at rest)")
struct ACPMetadataCryptoTests {

    private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    @Test func sealOpenRoundTrips() throws {
        let k = key(0xAB)
        let plain = Data("session ended: build green, 3 files".utf8)
        let blob = try #require(ACPMetadataCrypto.seal(plain, key: k))
        #expect(blob != plain)  // actually encrypted
        #expect(ACPMetadataCrypto.open(blob, key: k) == plain)
    }

    /// The cross-process contract: the AGENT seals an events line, Huginn's reader opens it
    /// with the SAME key. Both call this one codec, so the framing can't drift.
    @Test func lineRoundTripsAcrossTheProcessBoundary() throws {
        let k = key(0x11)
        let line = #"{"type":"shell_result","cmd":"swift build","exit":0}"#
        let sealed = try #require(ACPMetadataCrypto.sealLine(line, key: k))  // agent side
        #expect(!sealed.contains("swift build"))  // ciphertext, not the command
        #expect(ACPMetadataCrypto.openLine(sealed, key: k) == line)         // ContextLearner side
    }

    @Test func wrongKeyFailsClosed() throws {
        let blob = try #require(ACPMetadataCrypto.seal(Data("secret".utf8), key: key(0x01)))
        #expect(ACPMetadataCrypto.open(blob, key: key(0x02)) == nil)  // no leak on wrong key
    }

    @Test func corruptOrPlaintextInputFailsClosed() {
        let k = key(0x33)
        #expect(ACPMetadataCrypto.open(Data("not encrypted".utf8), key: k) == nil)
        #expect(ACPMetadataCrypto.openLine("}{ not base64 or json", key: k) == nil)
    }

    @Test func rejectsWrongSizedKey() {
        #expect(ACPMetadataCrypto.seal(Data("x".utf8), key: Data(repeating: 0, count: 16)) == nil)
    }

    @Test func freshNoncePerSeal() {
        let k = key(0x7E)
        let p = Data("same plaintext".utf8)
        // Different ciphertext each time (random nonce) — no deterministic-encryption leak.
        #expect(ACPMetadataCrypto.seal(p, key: k) != ACPMetadataCrypto.seal(p, key: k))
    }
}
