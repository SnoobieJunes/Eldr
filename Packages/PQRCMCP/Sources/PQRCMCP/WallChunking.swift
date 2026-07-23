// SPDX-License-Identifier: Apache-2.0
import Foundation

// WallChunking — the DATA seam for GOOSEWORLD WS-G5's "chunking covers big posts",
// modeled with NO transport (transport lives in the node layer, which depends on
// PQRCCore/PQRCNostr and therefore cannot live in this dependency-free package).
//
// **What invariant 4 requires (CLAUDE.md).** "Content > 64 KB is never inlined — relay
// chunking only. Large text splits into ordered, ratcheted relay events
// (`MessageBody.chunk {id,index,total}` inside the ciphertext), sized from each relay's
// NIP-11 `max_content_length`." A cross-town wall post rides the shipped shared-AI thread
// + group fan-out (WS-G5), so a post larger than a relay's content limit must travel as an
// ORDERED SET of bounded frames, reassembled by the receiver before the wall ingests it —
// never as one oversize inline event.
//
// **Where the boundary sits, honestly.** A single `WallPost` is bounded by
// `TownWall.Limits.maxPostBytes`: a short-coordination wall (the 4 KiB default) refuses an
// oversize post outright (`TownWallError.textTooLarge`), so it can never inline anything
// near a relay limit. A big-finding wall (a deployment that raises `maxPostBytes` above the
// 64 KiB inline ceiling, per WS-G5's "raise hub max_content_length") produces posts that DO
// exceed it — and those the node carries by chunking the serialized frame here and
// reassembling on receipt. Either way no wall post is ever transported inline above the
// relay limit. This type is the pure split/reassemble math both sides run; the node owns
// the actual ratcheted relay events and the NIP-11-derived `maxBytes`.
//
// **No transport, no clock, no randomness.** `id` is supplied by the caller (the node
// derives it from the frame it is sending), so the split is a pure function of its inputs
// and every test is deterministic (CLAUDE.md engineering conventions).

/// Locates one chunk within a split logical body. Deliberately the exact shape invariant 4
/// fixes for ratcheted relay chunking — `MessageBody.chunk {id, index, total}` — so a
/// `WallChunk` maps one-to-one onto one relay event the node carries.
public struct WallChunkRef: Sendable, Codable, Equatable {
    /// Groups the pieces of ONE logical body. Distinct bodies MUST use distinct ids, or
    /// `reassemble` will refuse the mixed set rather than silently splice them.
    public let id: String
    /// 0-based position within the group.
    public let index: Int
    /// Number of pieces in the group.
    public let total: Int
    public init(id: String, index: Int, total: Int) {
        self.id = id
        self.index = index
        self.total = total
    }
}

/// One ordered, byte-bounded piece of a logical body plus its locating ref.
public struct WallChunk: Sendable, Codable, Equatable {
    public let ref: WallChunkRef
    /// A piece of the body, at most the requested byte budget and always valid UTF-8
    /// (never split mid-scalar). Concatenating the pieces in index order restores the
    /// original body exactly.
    public let body: String
    public init(ref: WallChunkRef, body: String) {
        self.ref = ref
        self.body = body
    }
}

public enum WallChunking {
    /// Split `text` into ordered chunks each at most `maxBytes` UTF-8 bytes.
    ///
    /// - Never splits a Unicode SCALAR across a boundary. A half-scalar is invalid UTF-8
    ///   (unrepresentable as a `String` piece) and, like truncation, can sever a
    ///   multi-byte sequence mid-way — the same hazard `TownWall` refuses rather than
    ///   truncates. `maxBytes` is floored at 4 (the widest single scalar) so every scalar
    ///   fits and the split always makes progress.
    /// - Order-preserving; `reassemble` recovers the exact original bytes.
    /// - A body already within `maxBytes` yields exactly one chunk `{index 0, total 1}`.
    /// - Empty `text` yields `[]` — there is nothing to carry (and `TownWall.append`
    ///   refuses an empty post anyway).
    public static func split(_ text: String, maxBytes: Int, id: String) -> [WallChunk] {
        let cap = max(4, maxBytes)
        guard !text.isEmpty else { return [] }
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        var currentBytes = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            if currentBytes > 0, currentBytes + width > cap {
                pieces.append(String(current))
                current = String.UnicodeScalarView()
                currentBytes = 0
            }
            current.append(scalar)
            currentBytes += width
        }
        pieces.append(String(current))
        let total = pieces.count
        return pieces.enumerated().map {
            WallChunk(ref: WallChunkRef(id: id, index: $0.offset, total: total), body: $0.element)
        }
    }

    /// Reassemble chunks into the original body, or `nil` if the set is not exactly one
    /// complete group.
    ///
    /// Refuses — never partially splices — on any of: empty input, a piece from a
    /// different `id`, disagreeing `total`s, a count that is not `total`, an out-of-range
    /// index, or a duplicated/missing index. GOOSEWORLD §4: a dropped or reordered piece
    /// that read as success would hand the reader silently corrupted remote data, which is
    /// exactly the kind of undetected boundary an injection hides behind. A `nil` here is a
    /// hard, reportable failure, not a shorter string.
    public static func reassemble(_ chunks: [WallChunk]) -> String? {
        guard let first = chunks.first else { return nil }
        let id = first.ref.id
        let total = first.ref.total
        guard total > 0, chunks.count == total else { return nil }
        var byIndex: [Int: String] = [:]
        byIndex.reserveCapacity(total)
        for chunk in chunks {
            guard chunk.ref.id == id, chunk.ref.total == total,
                chunk.ref.index >= 0, chunk.ref.index < total, byIndex[chunk.ref.index] == nil
            else { return nil }
            byIndex[chunk.ref.index] = chunk.body
        }
        var out = ""
        for i in 0..<total {
            guard let piece = byIndex[i] else { return nil }
            out += piece
        }
        return out
    }
}
