// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCMCP

/// WS-G5 chunk seam, proven headlessly: the pure split/reassemble math the node runs to
/// carry a big wall post as ordered, bounded, ratcheted relay events (CLAUDE.md invariant
/// 4 — content > 64 KB is never inlined). No transport, no clock, no randomness.
@Suite("Wall chunking (WS-G5 data seam)")
struct WallChunkingTests {
    private func author() -> WallAuthor { WallAuthor(town: "acme-town", agent: "worker") }

    @Test func smallBodyIsASingleChunk() {
        let chunks = WallChunking.split("a short coordination note", maxBytes: 4096, id: "g1")
        #expect(chunks.count == 1)
        #expect(chunks[0].ref == WallChunkRef(id: "g1", index: 0, total: 1))
        #expect(WallChunking.reassemble(chunks) == "a short coordination note")
    }

    @Test func emptyBodyYieldsNoChunks() {
        #expect(WallChunking.split("", maxBytes: 4096, id: "g").isEmpty)
        // And reassembling an empty set is a hard failure, never "".
        #expect(WallChunking.reassemble([]) == nil)
    }

    @Test func everyChunkRespectsTheByteBudgetAndIndicesAreDense() {
        let text = String(repeating: "abcdefghij", count: 1000)  // 10 KB ASCII
        let chunks = WallChunking.split(text, maxBytes: 1024, id: "g")
        #expect(chunks.count == 10)
        for (i, chunk) in chunks.enumerated() {
            #expect(chunk.body.utf8.count <= 1024)
            #expect(chunk.ref == WallChunkRef(id: "g", index: i, total: 10))
        }
        #expect(WallChunking.reassemble(chunks) == text)
    }

    @Test func neverSplitsAMultiByteScalar_soEveryChunkIsValidUTF8() {
        // Each 🪿 is 4 UTF-8 bytes; a byte-blind splitter at maxBytes=5 would sever one and
        // produce invalid UTF-8. Scalar-boundary splitting keeps each piece decodable and
        // reassembly lossless.
        let text = String(repeating: "🪿", count: 50)  // 200 bytes
        let chunks = WallChunking.split(text, maxBytes: 5, id: "geese")
        for chunk in chunks {
            #expect(chunk.body.utf8.count <= 5)
            // Round-trips through UTF-8 with no replacement characters.
            #expect(String(decoding: Array(chunk.body.utf8), as: UTF8.self) == chunk.body)
            #expect(!chunk.body.unicodeScalars.contains("\u{FFFD}"))
        }
        #expect(WallChunking.reassemble(chunks) == text)
    }

    @Test func maxBytesIsFlooredSoASingleWideScalarAlwaysFits() {
        // maxBytes below one scalar's width must still make progress, not loop or drop.
        let chunks = WallChunking.split("🪿🪿🪿", maxBytes: 1, id: "g")
        #expect(chunks.count == 3)  // one 4-byte scalar per chunk (cap floored at 4)
        #expect(WallChunking.reassemble(chunks) == "🪿🪿🪿")
    }

    @Test func aPostAboveThe64KBInlineCeilingRoundTripsAsBoundedChunks() {
        // Invariant 4's inline ceiling. A ~100 KB logical body split at a 64 KB relay
        // content limit yields ordered frames each <= 64 KB, reassembling to the original —
        // proving the wall never needs to inline anything above the ceiling.
        let relayLimit = 64 * 1024
        let big = String(repeating: "coordination-payload ", count: 5000)  // ~105 KB
        #expect(big.utf8.count > relayLimit)
        let chunks = WallChunking.split(big, maxBytes: relayLimit, id: "finding-42")
        #expect(chunks.count >= 2)
        for chunk in chunks { #expect(chunk.body.utf8.count <= relayLimit) }
        #expect(WallChunking.reassemble(chunks) == big)
    }

    @Test func aSerializedWallPostRoundTripsThroughChunkingAndDecoding() throws {
        // Ties the seam to the wall's own wire type: the node serializes a WallPost to
        // carry it over the thread; when the frame exceeds the relay limit it is chunked
        // here and reassembled+decoded on receipt, byte-identical.
        let post = WallPost(
            sequence: 7, author: author(), text: String(repeating: "x", count: 4096),
            targets: ["reviewer"], priorityForHuman: true, postedAt: 1_781_500_120)
        let json = try JSONEncoder().encode(post)
        let frame = String(decoding: json, as: UTF8.self)
        let chunks = WallChunking.split(frame, maxBytes: 512, id: "post-7")
        #expect(chunks.count > 1)
        let reassembled = try #require(WallChunking.reassemble(chunks))
        let decoded = try JSONDecoder().decode(WallPost.self, from: Data(reassembled.utf8))
        #expect(decoded == post)
    }

    // MARK: - reassemble fails closed on any incomplete / corrupted set

    @Test func reassembleRefusesAMissingPiece() {
        var chunks = WallChunking.split(String(repeating: "z", count: 3000), maxBytes: 1000, id: "g")
        chunks.removeLast()  // drop the tail
        #expect(WallChunking.reassemble(chunks) == nil)
    }

    @Test func reassembleRefusesADuplicatedIndex() {
        let chunks = WallChunking.split(String(repeating: "z", count: 3000), maxBytes: 1000, id: "g")
        let dupe = [chunks[0], chunks[0], chunks[2]]  // right count, index 1 missing, 0 doubled
        #expect(WallChunking.reassemble(dupe) == nil)
    }

    @Test func reassembleRefusesMixedGroupIds() {
        let a = WallChunking.split("hello world payload", maxBytes: 8, id: "A")
        let b = WallChunking.split("hello world payload", maxBytes: 8, id: "B")
        // Splice one B-piece into A's set: same shape, foreign id → refused, never spliced.
        var mixed = a
        mixed[mixed.count - 1] = b[b.count - 1]
        #expect(WallChunking.reassemble(mixed) == nil)
    }

    @Test func reassembleRefusesADisagreeingTotalOrOutOfRangeIndex() {
        let good = WallChunking.split("abcdefghij", maxBytes: 4, id: "g")
        // Forge a piece claiming total 99.
        let bogusTotal = good.map { WallChunk(ref: WallChunkRef(id: "g", index: $0.ref.index, total: 99), body: $0.body) }
        #expect(WallChunking.reassemble(bogusTotal) == nil)
        // A single piece claiming index==total (out of range).
        let oob = [WallChunk(ref: WallChunkRef(id: "g", index: 1, total: 1), body: "x")]
        #expect(WallChunking.reassemble(oob) == nil)
    }

    @Test func chunkOrderDoesNotMatterOnlyIndicesDo() {
        let chunks = WallChunking.split("the quick brown fox jumps", maxBytes: 6, id: "g")
        #expect(WallChunking.reassemble(chunks.reversed()) == "the quick brown fox jumps")
    }
}
