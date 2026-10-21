// SPDX-License-Identifier: Apache-2.0
//
// Deterministic (seeded) fuzz tests for the untrusted-input decoders: relay frame
// reassembly, gift-wrap unwrap, and the wire/JSON decoders. Each run is reproducible
// from its seed; the properties are "never crash, never accept a mutated envelope,
// stay within memory bounds, and still work for valid input afterwards".
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// SplitMix64: tiny, deterministic, good enough to drive mutations.
struct FuzzRNG {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8(truncatingIfNeeded: next()) } }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }

    /// Byte-level mutation: flip, insert, delete, duplicate-span, or splice a token.
    mutating func mutate(_ input: String, tokens: [String]) -> String {
        var b = [UInt8](input.utf8)
        for _ in 0...int(4) {
            switch int(6) {
            case 0 where !b.isEmpty: b[int(b.count)] ^= UInt8(1 << int(8))
            case 1: b.insert(UInt8(truncatingIfNeeded: next()), at: int(b.count + 1))
            case 2 where !b.isEmpty: b.remove(at: int(b.count))
            case 3 where b.count > 2:
                let i = int(b.count - 1), j = min(b.count, i + 1 + int(16))
                b.insert(contentsOf: b[i..<j], at: int(b.count + 1))
            case 4: b.insert(contentsOf: Array(pick(tokens).utf8), at: int(b.count + 1))
            default: if !b.isEmpty { b.removeLast(min(b.count, int(8))) }
            }
        }
        return String(decoding: b, as: UTF8.self)
    }
}

@Suite("Fuzz: untrusted decoders")
struct FuzzTests {
    static let jsonTokens = ["{", "}", "[", "]", "\"", ":", ",", "null", "true", "-1", "1e999",
                             "\"\\u0000\"", "99999999999999999999", "\"type\"", "\"chunk\"", "|", "=", "%"]

    // MARK: Relay frame reassembly (ACP/MCP/A2A share RelayFraming)

    @Test(arguments: [1 as UInt64, 2, 3])
    func relayFrameReassembly_neverCrashes_staysBounded_andStillWorks(seed: UInt64) async throws {
        var rng = FuzzRNG(s: seed)
        let sent = SentBox()
        let t = RelayACPTransport(maxFrameBytes: 512) { await sent.add($0) }
        let valid = RelayFraming.frameChunks(line: #"{"jsonrpc":"2.0","id":1,"method":"x"}"#,
                                             lineId: "L", maxFrameBytes: 64, magic: "ACP1")
        for i in 0..<20_000 {
            let frame: String
            switch rng.int(4) {
            case 0: frame = rng.mutate(rng.pick(valid), tokens: ["|", "ACP1|", "0", "4096", "4097", "-", "=="])
            case 1: frame = "ACP1|l\(rng.int(600))|\(rng.int(5000))|\(rng.int(5000))|" + RelayFraming.base64URLEncode(Data(rng.bytes(rng.int(64))))
            case 2: frame = String(decoding: rng.bytes(rng.int(200)), as: UTF8.self)
            default: frame = "ACP1|big\(i % 400)|1|4096|" + RelayFraming.base64URLEncode(Data(rng.bytes(2048)))
            }
            await t.deliverInbound(frame)
        }
        #expect(await t.pendingReassemblyCount <= RelayFraming.maxPendingReassemblies)
        // A valid line still reassembles after the barrage.
        let fresh = RelayFraming.frameChunks(line: "hello-after-fuzz", lineId: "OK", maxFrameBytes: 64, magic: "ACP1")
        var it = t.inboundLines().makeAsyncIterator()
        for f in fresh.reversed() { await t.deliverInbound(f) }
        t.close()  // ends the stream, so a missing line fails instead of hanging
        var got: String?
        while let l = await it.next() { if l == "hello-after-fuzz" { got = l; break } }
        #expect(got == "hello-after-fuzz")
    }

    /// The byte bound (audit-2): many distinct incomplete lines of large chunks can't pin
    /// more than `maxPendingReassemblyBytes`.
    @Test func relayReassembly_byteBound() {
        var map: [String: RelayFraming.Reassembly] = [:]
        let payload = Data(repeating: 7, count: 1 << 20)  // 1 MiB per chunk
        for i in 0..<200 {
            var e = RelayFraming.Reassembly(total: 4096)
            e.put(1, payload)
            e.receivedOrder = UInt64(i)
            map["l\(i)"] = e
            RelayFraming.evictStaleReassembliesIfNeeded(&map)
        }
        #expect(map.values.reduce(0) { $0 + $1.bytes } <= RelayFraming.maxPendingReassemblyBytes)
        #expect(map["l199"] != nil)  // newest kept
    }

    // MARK: Gift wrap

    @Test(arguments: [11 as UInt64, 12])
    func giftWrapUnwrap_mutationsAreNeverAccepted(seed: UInt64) throws {
        var rng = FuzzRNG(s: seed)
        let (sender, recipient) = try EnvelopeTests.fixtureKeys()
        let wrap = try GiftWrap.wrap(
            rumor: EnvelopeTests.sampleRumor(), sender: sender, recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: 1_749_900_000, randomSource: SeededRandomSource(seed: 5), nonceSource: SeededRandomSource(seed: 6))
        _ = try GiftWrap.unwrap(wrap, recipient: recipient)  // sanity: the original opens
        var accepted = 0
        for _ in 0..<1_500 {
            var e = wrap
            switch rng.int(5) {
            case 0: e.content = rng.mutate(e.content, tokens: ["A", "=", "?", "\""])
            case 1: e.sig = rng.mutate(e.sig, tokens: ["0", "f"])
            case 2: e.id = rng.mutate(e.id, tokens: ["0"])
            case 3: e.tags = [["p", rng.mutate(recipient.publicKeyHex, tokens: ["0"])]] + e.tags.dropFirst()
            default: e.createdAt += Int64(rng.int(1000)) + 1
            }
            if e == wrap { continue }
            if (try? GiftWrap.unwrap(e, recipient: recipient)) != nil { accepted += 1 }
        }
        #expect(accepted == 0)
    }

    // MARK: Wire decoders

    @Test(arguments: [21 as UInt64, 22, 23])
    func wireDecoders_neverCrash(seed: UInt64) throws {
        var rng = FuzzRNG(s: seed)
        let rumorJSON = String(decoding: try WireJSON.encoder().encode(EnvelopeTests.sampleRumor()), as: UTF8.self)
        let relayMsgs = [#"["EVENT","s",{"id":"00","pubkey":"00","created_at":1,"kind":1059,"tags":[["p","x"]],"content":"","sig":"00"}]"#,
                         #"["OK","id",true,""]"#, #"["EOSE","s"]"#, #"["AUTH","chal"]"#, #"["NOTICE","x"]"#, #"["CLOSED","s","r"]"#]
        let bech = Bech32.npub(String(repeating: "ab", count: 32))
        for _ in 0..<4_000 {
            let r = rng.mutate(rumorJSON, tokens: Self.jsonTokens)
            _ = try? WireJSON.decoder().decode(RumorContent.self, from: Data(r.utf8))
            _ = try? WireJSON.decoder().decode(MessageBody.self, from: Data(r.utf8))
            let m = rng.mutate(rng.pick(relayMsgs), tokens: Self.jsonTokens)
            _ = NostrWire.decodeRelay(m)
            _ = NostrWire.decodeClient(m)
            _ = try? JSONDecoder().decode(NostrEvent.self, from: Data(m.utf8))
            _ = Bech32.decode(rng.mutate(bech, tokens: ["1", "b", "I", "O"]))
            _ = RelayFraming.base64URLDecode(String(decoding: rng.bytes(rng.int(40)), as: UTF8.self))
        }
    }
}

private actor SentBox {
    var all: [String] = []
    func add(_ s: String) { all.append(s) }
}
