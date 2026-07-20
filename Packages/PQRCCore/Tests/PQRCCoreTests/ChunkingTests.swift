// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore

/// Relay chunking: the SPEC §11 alternative to a Blossom pointer for >64 KB
/// text. Splitting must round-trip exactly, never corrupt multi-byte scalars,
/// and keep each part within the padding budget. The `chunk` field rides inside
/// the ciphertext and must survive Codable round-trips while staying absent for
/// ordinary single-envelope messages (SPEC §12 forward compatibility).
@Suite("Relay chunking (SPEC §11)")
struct ChunkingTests {
    @Test func smallText_isNotChunked() {
        let parts = MessageChunker.split("hello world", budgetBytes: 1024)
        #expect(parts == ["hello world"])
    }

    @Test func emptyText_yieldsSingleEmptyPart() {
        #expect(MessageChunker.split("", budgetBytes: 1024) == [""])
    }

    @Test func split_thenJoin_roundTripsExactly() {
        let text = String(repeating: "The quick brown fox.\n", count: 5000)  // ~100 KB
        let parts = MessageChunker.split(text)
        #expect(parts.count > 1)
        #expect(MessageChunker.join(parts) == text)
    }

    @Test func everyPart_staysWithinBudget() {
        let budget = 4096
        let text = String(repeating: "abcdefghij", count: 5000)  // 50 KB ASCII
        let parts = MessageChunker.split(text, budgetBytes: budget)
        for part in parts {
            #expect(part.utf8.count <= budget)
        }
        #expect(MessageChunker.join(parts) == text)
    }

    @Test func multibyteAndEmoji_areNeverBisected() {
        // Mix of 4-byte emoji, combining sequences, and CJK across a tight budget.
        let unit = "🇺🇸👨‍👩‍👧‍👦café—漢字\n"
        let text = String(repeating: unit, count: 4000)
        let parts = MessageChunker.split(text, budgetBytes: 200)
        // Round-trip equality proves no scalar/grapheme was split mid-sequence.
        #expect(MessageChunker.join(parts) == text)
        // No part is wildly over budget (a single grapheme may exceed it).
        for part in parts {
            #expect(part.utf8.count <= 200 + unit.utf8.count)
        }
    }

    @Test func partCount_coversTheWholeText() {
        let budget = 1000
        let text = String(repeating: "x", count: 10_000)
        let parts = MessageChunker.split(text, budgetBytes: budget)
        #expect(parts.count == 10)
        #expect(parts.allSatisfy { $0.utf8.count == budget })
    }

    @Test func messageBody_chunkField_roundTrips() throws {
        let body = MessageBody(
            text: "part-3", sentAt: 1_700_000_000,
            chunk: MessageChunk(id: "abc", index: 2, total: 7))
        let data = try WireJSON.encoder().encode(body)
        let decoded = try WireJSON.decoder().decode(MessageBody.self, from: data)
        #expect(decoded.chunk == MessageChunk(id: "abc", index: 2, total: 7))
        #expect(decoded.text == "part-3")
    }

    @Test func messageBody_withoutChunk_omitsTheKey() throws {
        let body = MessageBody(text: "plain", sentAt: 1)
        let json = String(decoding: try WireJSON.encoder().encode(body), as: UTF8.self)
        #expect(!json.contains("chunk"))
        // And an old-style payload (no chunk key) still decodes.
        let decoded = try WireJSON.decoder().decode(MessageBody.self, from: Data(json.utf8))
        #expect(decoded.chunk == nil)
    }

    @Test func chunkTextBudget_picksLargestBucketThatFitsTheRelay() {
        // Strict 65535-byte relay → 16384-bucket budget (the safe default zone).
        #expect(PQRCConstants.chunkTextBudget(relayContentLimit: 65535) == 16384 - 1024)
        // Generous 1 MB relay → full 65536-bucket budget (4× bigger chunks).
        #expect(PQRCConstants.chunkTextBudget(relayContentLimit: 1_048_576) == 65536 - 1024)
        // 256 KB relay also clears the 65536 bucket (event ~157 KB).
        #expect(PQRCConstants.chunkTextBudget(relayContentLimit: 262_144) == 65536 - 1024)
        // Unknown limit → the safe default.
        #expect(
            PQRCConstants.chunkTextBudget(relayContentLimit: nil) == PQRCConstants.maxChunkTextBytes)
        // Absurdly tiny limit → smallest chunks, never zero/negative.
        #expect(PQRCConstants.chunkTextBudget(relayContentLimit: 100) == 200)
    }

    @Test func everyChunkBody_fitsThe16384Bucket_evenEscapeHeavy() throws {
        // The whole point of measuring escaped size: every chunk's encoded
        // MessageBody must land in the 16384 padding bucket (not 65536), so the
        // gift-wrapped event stays under common relays' 65535-byte content
        // limit. Escape-heavy text (every char a 2-byte JSON escape) is the
        // stress case — split it and check EACH chunk's encoded body.
        let escapeHeavy = String(repeating: "\"\n\\", count: 40_000)  // ~120 KB raw
        let parts = MessageChunker.split(escapeHeavy)
        #expect(parts.count > 1)
        for (i, part) in parts.enumerated() {
            let body = MessageBody(
                text: part, sentAt: 1_700_000_000,
                alias: "a-reasonably-long-display-name",
                chunk: MessageChunk(id: UUID().uuidString, index: i, total: parts.count))
            let encoded = try WireJSON.encoder().encode(body)
            #expect(encoded.count <= 16384, "chunk \(i) body \(encoded.count) > 16384 bucket")
        }
        #expect(MessageChunker.join(parts) == escapeHeavy)
    }
}
