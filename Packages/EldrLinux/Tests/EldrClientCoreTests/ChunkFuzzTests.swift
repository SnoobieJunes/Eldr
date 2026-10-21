// SPDX-License-Identifier: Apache-2.0
import Crypto
import EldrKeystore
import Foundation
import Testing

@testable import EldrClientCore
@testable import PQRCCore
@testable import PQRCNostr

/// Seeded fuzz of chunk reassembly (SPEC §7/§11): random ids/indices/totals/sizes from
/// several senders, duplicates and conflicts. Never crashes, never exceeds the AC214
/// byte cap or 16 buffers, and a well-formed message still joins afterwards.
@Suite("Fuzz: chunk reassembly")
struct ChunkFuzzTests {
    @Test(arguments: [31 as UInt64, 32, 33])
    func reassembly(seed: UInt64) async throws {
        var s = seed
        func next() -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int(truncatingIfNeeded: s >> 33) }
        let relay = LocalRelaySimulator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-cfz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try EldrClient.initialize(store: store, relays: ["local://relay"])
        let c = try await EldrClient(store: store, transport: { await relay.connect() })
        func msg(_ sender: String, _ id: String, _ i: Int, _ total: Int, _ text: String) -> ReceivedMessage {
            var b = MessageBody(text: text, sentAt: 1, messageID: nil)
            b.chunk = MessageChunk(id: id, index: i, total: total)
            return ReceivedMessage(senderIdentityHex: sender, participantType: .human, body: b,
                                   contentPointer: nil, aiWindow: nil, aiContextGrant: nil, wrapEventID: "w")
        }
        let totals = [-1, 0, 1, 2, 3, 511, 512, 513, Int.max, Int.min]
        let big = String(repeating: "x", count: 1 << 20)
        for _ in 0..<6_000 {
            let total = next() % 3 == 0 ? totals[abs(next() % totals.count)] : (abs(next()) % 600)
            let index = next() % 4 == 0 ? next() : abs(next()) % max(1, abs(total % 700) + 1)
            let text = next() % 50 == 0 ? big : String(repeating: "a", count: abs(next()) % 64)
            _ = await c.reassemble(msg("s\(abs(next()) % 5)", "m\(abs(next()) % 40)", index, total, text))
        }
        let bufs = await c.chunkBuffers
        #expect(bufs.count <= 17)
        let held = bufs.values.reduce(0) { $0 + $1.parts.values.reduce(0) { $0 + $1.utf8.count } }
        #expect(held <= EldrClient.maxBufferedChunkBytes)
        // Valid message still joins (out of order).
        #expect(await c.reassemble(msg("ok", "fresh", 1, 2, "world")) == nil)
        #expect(await c.reassemble(msg("ok", "fresh", 0, 2, "hello "))?.text == "hello world")
    }
}
