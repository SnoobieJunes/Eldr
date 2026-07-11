import Foundation

/// Shared framing + reassembly core for the relay-carried line transports
/// (`RelayACPTransport`, `RelayMCPTransport`). Both carry a newline-free line
/// protocol over the gift-wrapped + Double-Ratcheted message mesh, so the relay
/// only ever sees the same E2EE ciphertext a normal chat carries (SPEC §2 — no new
/// crypto here; confidentiality/authenticity are the mesh's). The two transports
/// differ ONLY in their MAGIC prefix, which is what keeps an ACP frame, an MCP
/// frame, and a JSON-RPC `{` line mutually un-confusable on the same inbound
/// stream. Everything else — chunking under a byte budget, out-of-order/interleaved
/// reassembly keyed by `lineId`, and sender-order restoration — is identical, so it
/// lives here ONCE rather than duplicated per transport.
///
/// ## Envelope (one chunk per relay message)
///
/// ```text
///   <MAGIC>|<lineId>|<seq>|<total>|<payloadB64Url>
/// ```
/// where `<MAGIC>` is e.g. `ACP1` or `MCP1`. Pipe-delimited, five fields:
/// - `<MAGIC>|` — fixed magic. A JSON-RPC line always begins with `{`, never the
///   magic, and the two transports' magics differ, so a prefix test routes each
///   inbound body unambiguously (ACP→its transport, MCP→its, chat→the normal path).
/// - `lineId` — `<random-instance-salt>-<base36 counter>`: the salt keeps two
///   senders' ids from colliding at a shared receiver; the counter is unique per
///   line within a sender AND monotonic in send order, so the receiver restores
///   line order from it. Hex/base36 — no `|`.
/// - `seq` — 1-based chunk index (base 10).
/// - `total` — total chunk count for this line (base 10).
/// - `payloadB64Url` — base64url (RFC 4648 §5, no padding) of this chunk's UTF-8
///   bytes. base64url's alphabet (`A–Z a–z 0–9 - _`) contains no `|`, so the
///   delimiter is never ambiguous and the original line round-trips byte-exact.
enum RelayFraming {
    /// Header is `<MAGIC>|<lineId>|<seq>|<total>|`; with a payload of ≥1 base64url
    /// char this is the floor on a viable frame. The salt+seq id and small seq/total
    /// numbers stay well under this in practice; the guard just keeps a
    /// caller-supplied tiny budget from making chunking diverge.
    static let minViableFrameBytes = 64
    /// Cap on inbound lines buffered ahead of a missing index before we give up on
    /// it and skip forward — bounds memory + guarantees liveness under genuine line
    /// loss or a peer that withholds a low index to wedge the stream.
    static let maxReorderBuffer = 1000

    /// Cap on the chunk count a single line may declare. `total` is a wire value and
    /// a peer can lie about it (the parse admits anything up to `UInt32.max`). Nothing
    /// is preallocated from it, but an incomplete set pins its received payloads, so
    /// an absurd `total` must not be accepted in the first place. 4096 chunks is far
    /// above any legitimate ACP/MCP line (the chat path's ceiling is 512).
    static let maxChunksPerLine: UInt32 = 4096

    /// Cap on concurrently-INCOMPLETE lines held for reassembly.
    ///
    /// This is the bound that was missing: `maxReorderBuffer` bounds the *order*
    /// buffer (`pendingLines`), a different map. A line missing any chunk never emits
    /// — and, without this, never frees either. On a lossy relay every dropped chunk
    /// permanently retained the rest of its line, and a peer could grow the map without
    /// limit by sending one `seq` of each of many distinct `lineId`s. On overflow we
    /// abandon the least-recently-touched incomplete line: bounded degradation, never
    /// unbounded growth. Mirrors `PersonaRuntime.evictStaleChunkBuffersIfNeeded`.
    static let maxPendingReassemblies = 256

    /// Per-line reassembly state: the expected chunk count and the payload bytes
    /// received so far, keyed by 1-based seq (so duplicates overwrite, gaps show).
    /// `receivedOrder` is a monotonic touch stamp used only for LRU eviction.
    struct Reassembly {
        let total: UInt32
        var chunks: [UInt32: Data] = [:]
        var receivedOrder: UInt64 = 0
    }

    /// Drops the least-recently-touched incomplete line once the map is over capacity.
    /// Shared by both relay transports so the bound can't drift between them.
    static func evictStaleReassembliesIfNeeded(_ map: inout [String: Reassembly]) {
        guard map.count > maxPendingReassemblies else { return }
        if let oldest = map.min(by: { $0.value.receivedOrder < $1.value.receivedOrder })?.key {
            map[oldest] = nil
        }
    }

    /// A decoded inbound frame chunk.
    struct FrameChunk {
        let lineId: String
        let seq: UInt32
        let total: UInt32
        let payload: Data

        /// Parse `<MAGIC>|<lineId>|<seq>|<total>|<payloadB64Url>` for the given
        /// `magic` (e.g. `"ACP1"`). The payload may itself be empty (an empty line
        /// is legal) but the four header fields and all four delimiters must be
        /// present and well-formed.
        init?(parsing body: String, magic: String) {
            // `magic` here is the bare token (no trailing `|`); the prefix test
            // below uses "<magic>|" so a body that is literally the token without
            // the delimiter is rejected.
            guard body.hasPrefix(magic + "|") else { return nil }
            // Split into exactly 5 fields. `omittingEmptySubsequences: false`
            // keeps an empty trailing payload field; capping at 5 keeps any `=`/
            // base64url payload intact (base64url has no `|` so 5 is exact, but
            // the cap is belt-and-suspenders against a malformed payload).
            let parts = body.split(
                separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == magic else { return nil }
            let lineId = String(parts[1])
            guard !lineId.isEmpty,
                let seq = UInt32(parts[2]), let total = UInt32(parts[3]),
                total >= 1, seq >= 1, seq <= total,
                let payload = RelayFraming.base64URLDecode(String(parts[4]))
            else { return nil }
            self.lineId = lineId
            self.seq = seq
            self.total = total
            self.payload = payload
        }
    }

    /// Frame `line` into one-or-more chunks under `magic`, each ≤ `maxFrameBytes`
    /// UTF-8 bytes INCLUDING the header. The line's **raw UTF-8 bytes** are sliced,
    /// and EACH slice is base64url-encoded independently as that chunk's payload.
    /// This is the key to correct reassembly: every chunk's payload is a
    /// self-contained base64url unit (4-char aligned by construction), so the
    /// receiver can decode each chunk on its own and concatenate the raw bytes —
    /// concatenating per-chunk-DECODED bytes round-trips, whereas slicing one big
    /// encoded string at non-4-aligned boundaries would corrupt every chunk seam.
    /// Slicing the raw bytes never splits a multibyte scalar in a way that breaks the
    /// round-trip (the bytes are reassembled before being interpreted as UTF-8).
    /// Always yields ≥1 chunk (an empty line → one empty-payload chunk).
    static func frameChunks(
        line: String, lineId: String, maxFrameBytes: Int, magic: String
    ) -> [String] {
        let rawBytes = [UInt8](Data(line.utf8))

        // The header (sans payload) for a chunk is "<MAGIC>|<lineId>|<seq>|<total>|".
        // `total`'s digit width affects header size, and seq ≤ total, so size the
        // budget with the worst-case (widest) seq width so EVERY chunk fits.
        func headerOverhead(totalDigits: Int) -> Int {
            magic.utf8.count + 1 + lineId.utf8.count + 1 + totalDigits + 1 + totalDigits + 1
        }
        // Max RAW bytes per chunk for a given payload-char budget `pb`: every 4
        // base64 chars encode 3 raw bytes, so `(pb / 4) * 3` raw bytes encode to
        // ≤ `pb` chars (unpadded ≤ padded). This under-uses the budget by ≤3 raw
        // bytes per chunk — a deliberate, obviously-correct margin.
        func rawBudget(payloadChars: Int) -> Int { max(1, (payloadChars / 4) * 3) }

        // Settle the `total` digit width to a fixed point (it grows at most a
        // couple of times as more chunks ⇒ wider total ⇒ smaller payload).
        var totalDigits = 1
        var raw = rawBudget(payloadChars: max(1, maxFrameBytes - headerOverhead(totalDigits: totalDigits)))
        var chunkCount = max(1, (rawBytes.count + raw - 1) / raw)
        while String(chunkCount).count != totalDigits {
            totalDigits = String(chunkCount).count
            raw = rawBudget(payloadChars: max(1, maxFrameBytes - headerOverhead(totalDigits: totalDigits)))
            chunkCount = max(1, (rawBytes.count + raw - 1) / raw)
        }

        var frames: [String] = []
        frames.reserveCapacity(chunkCount)
        var index = 0
        var seq = 1
        // Emit exactly `chunkCount` frames; the empty-line case (rawBytes empty)
        // still produces one chunk with an empty (base64url of "") payload.
        repeat {
            let end = min(index + raw, rawBytes.count)
            let slice = base64URLEncode(Data(rawBytes[index..<end]))
            frames.append("\(magic)|\(lineId)|\(seq)|\(chunkCount)|\(slice)")
            index = end
            seq += 1
        } while index < rawBytes.count
        return frames
    }

    /// Split a `lineId` of the form `<salt>-<base36 seq>` into its parts. The seq is
    /// base36 (no `-`); the salt is hex by default but may be caller-supplied, so we
    /// split on the LAST `-` to tolerate a salt that itself contains one. Returns nil
    /// when there is no `-` or the tail is not base36 — the caller then emits the
    /// line immediately (legacy/crafted frames keep working).
    static func splitLineId(_ lineId: String) -> (salt: String, seq: UInt64)? {
        guard let dash = lineId.lastIndex(of: "-") else { return nil }
        let salt = String(lineId[lineId.startIndex..<dash])
        let seqPart = String(lineId[lineId.index(after: dash)...])
        guard !salt.isEmpty, !seqPart.isEmpty, let seq = UInt64(seqPart, radix: 36) else {
            return nil
        }
        return (salt, seq)
    }

    /// 6 random bytes → 12 hex chars: ample to avoid cross-sender id collisions, no
    /// `|`, no crypto significance (collision-avoidance only).
    static func randomSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - base64url (RFC 4648 §5, unpadded)

    static func base64URLEncode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    static func base64URLDecode(_ string: String) -> Data? {
        if string.isEmpty { return Data() }
        var s = string.replacingOccurrences(of: "-", with: "+")
        s = s.replacingOccurrences(of: "_", with: "/")
        // Restore `=` padding to a multiple of 4.
        let remainder = s.utf8.count % 4
        if remainder != 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s)
    }
}
