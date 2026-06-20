import Foundation
import PQRCACP

/// An `ACPTransport` that carries the ACP line protocol over the **relay** —
/// i.e. over the existing gift-wrapped + Double-Ratcheted message mesh
/// (`PQRCMessenger`) instead of a local radio (`NearbyACPTransport` /
/// MultipeerConnectivity). This is ACPRouterplan Phase 3: drive the Mac node
/// REMOTELY (from anywhere with relay reach), not just over local Multipeer.
///
/// Because every ACP line rides the message stack, the relay only ever sees the
/// SAME E2EE ciphertext a normal chat carries — the ACP frame is just a
/// different plaintext fed through the existing ratchet + gift-wrap. No new
/// crypto is added here (SPEC §2); confidentiality/authenticity are the mesh's.
///
/// ## Decoupled from the messenger (so it is unit-testable)
///
/// This actor knows nothing about `PQRCMessenger`. It is wired by two seams the
/// integration layer (built later) connects to the messenger:
/// - `send`: the closure publishing ONE framed body to the peer over the relay
///   (the integration wires it to `messenger.send(body, to: peerIdentityHex)`).
/// - `deliverInbound(_:)`: the integration calls this for each ACP-framed
///   message it RECEIVED from the peer (it routes a received chat-message body
///   to `deliverInbound` iff `isACPFrame(body)` is true, else the normal chat
///   path).
///
/// ## Why framing + chunking
///
/// The relay imposes a per-message byte budget (`maxFrameBytes` — e.g. the
/// relay's event-size limit minus gift-wrap overhead), and a single ACP line
/// (a `session/update` carrying a long tool-output block, an `fs/read_text_file`
/// result) can exceed it. So each ACP line is:
/// 1. **Framed** — tagged with a magic prefix, a per-line id, and a chunk header
///    (seq/total) so the receiver can tell ACP frames from chat, reassemble
///    multi-chunk lines, and tolerate the mesh's unordered delivery.
/// 2. **Chunked** — split so every FRAMED chunk (header included) is
///    ≤ `maxFrameBytes`, then each chunk is handed to `send` in order.
///
/// ## Envelope (one chunk per relay message)
///
/// ```text
///   ACP1|<lineId>|<seq>|<total>|<payloadB64Url>
/// ```
/// Pipe-delimited, five fields:
/// - `ACP1|` — fixed magic. A JSON-RPC line always begins with `{`, never with
///   `ACP1|`, so `isACPFrame` is an unambiguous prefix test against any chat
///   text (even chat that coincidentally starts with `A`/`ACP`).
/// - `lineId` — identifies the original ACP line a chunk belongs to. It is
///   `<random-instance-salt>-<base36 counter>`: the salt (per transport
///   instance) keeps two senders' ids from colliding at a shared receiver, and
///   the counter is unique per line within a sender. Hex/base36 only — no `|`.
/// - `seq` — 1-based chunk index (base 10).
/// - `total` — total chunk count for this line (base 10).
/// - `payloadB64Url` — base64url (RFC 4648 §5, no padding) of this chunk's UTF-8
///   bytes. base64url's alphabet (`A–Z a–z 0–9 - _`) contains no `|`, so the
///   delimiter is never ambiguous and the original line round-trips byte-exact.
///
/// Reassembly is keyed by `lineId`; a line emits on `inboundLines` only once all
/// `total` distinct chunks (by `seq`) have arrived — out-of-order and
/// interleaved-with-other-lines delivery both reassemble correctly, and a line
/// missing any chunk never emits.
public actor RelayACPTransport: ACPTransport {
    /// The relay's per-message byte budget. Every FRAMED chunk handed to `send`
    /// is ≤ this many UTF-8 bytes (header + payload), so it fits one relay event.
    private let maxFrameBytes: Int
    /// Publishes one framed chunk to the peer over the relay. Wired by the
    /// integration to `messenger.send(_, to: peerIdentityHex)`.
    private let sendChunk: @Sendable (String) async -> Void

    /// Per-instance random salt prefixing every `lineId` this transport mints, so
    /// ids from two different senders can never collide in a shared receiver's
    /// reassembly table. Hex, so it never contains the `|` delimiter.
    private let instanceSalt: String
    /// Monotonic per-line counter; combined with `instanceSalt` to form `lineId`.
    private var nextLineSeq: UInt64 = 0

    /// In-flight inbound lines being reassembled, keyed by `lineId`.
    private var reassembly: [String: Reassembly] = [:]

    private let inbound: AsyncStream<String>
    private let inboundContinuation: AsyncStream<String>.Continuation

    /// Frames that failed to parse/decode on the inbound side, for test
    /// introspection. The values themselves are never logged (CLAUDE.md inv. 12).
    public private(set) var droppedFrameCount = 0

    public init(
        maxFrameBytes: Int,
        instanceSalt: String? = nil,
        send: @escaping @Sendable (String) async -> Void
    ) {
        // A frame must hold the header plus at least one payload byte; guard the
        // budget up so chunking always terminates even if the caller passes a
        // pathologically small value.
        self.maxFrameBytes = max(maxFrameBytes, Self.minViableFrameBytes)
        self.sendChunk = send
        self.instanceSalt = instanceSalt ?? Self.randomSalt()
        (self.inbound, self.inboundContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: - ACPTransport

    /// Frame + chunk one ACP line and publish each chunk over the relay, in
    /// order. Synchronous + `Sendable` per the `ACPTransport` contract (it may be
    /// called from inside a JSON-RPC continuation without `await`); the actual
    /// framing/sends happen on a hop onto this actor. Ordering follows call order
    /// because each hop is enqueued in turn and the chunk loop awaits in sequence.
    public nonisolated func send(_ line: String) {
        Task { await self.frameAndSend(line) }
    }

    public nonisolated func inboundLines() -> AsyncStream<String> { inbound }

    public nonisolated func close() {
        Task { await self.shutdown() }
    }

    // MARK: - Outbound: frame + chunk

    private func frameAndSend(_ line: String) async {
        let lineId = "\(instanceSalt)-\(String(nextLineSeq, radix: 36))"
        nextLineSeq &+= 1
        for chunk in Self.frameChunks(line: line, lineId: lineId, maxFrameBytes: maxFrameBytes) {
            await sendChunk(chunk)
        }
    }

    // MARK: - Inbound: reassemble

    /// The integration calls this for each ACP-framed body received FROM the peer
    /// over the relay. Decodes the chunk, files it under its `lineId`, and — once
    /// every chunk of that line has arrived — emits the byte-identical original
    /// ACP line on `inboundLines`. Tolerant of out-of-order and interleaved
    /// chunks; a line missing any chunk never emits.
    public func deliverInbound(_ framedBody: String) {
        guard let chunk = FrameChunk(parsing: framedBody) else {
            droppedFrameCount += 1
            return
        }
        var entry = reassembly[chunk.lineId] ?? Reassembly(total: chunk.total)
        // A conflicting `total` for the same id is a corrupt/forged frame stream;
        // drop the offending chunk rather than reassemble garbage.
        guard entry.total == chunk.total, chunk.seq >= 1, chunk.seq <= chunk.total else {
            droppedFrameCount += 1
            return
        }
        entry.chunks[chunk.seq] = chunk.payload
        if entry.chunks.count == Int(chunk.total) {
            reassembly[chunk.lineId] = nil
            // Concatenate payloads in seq order (1...total) — reassembly is
            // order-independent because we sort by key here, not by arrival.
            var bytes = Data()
            for seq in 1...chunk.total {
                guard let part = entry.chunks[seq] else {
                    // Defensive: count matched but a seq is absent (cannot happen
                    // given the dedup above, but never emit a torn line).
                    droppedFrameCount += 1
                    return
                }
                bytes.append(part)
            }
            inboundContinuation.yield(String(decoding: bytes, as: UTF8.self))
        } else {
            reassembly[chunk.lineId] = entry
        }
    }

    private func shutdown() {
        reassembly.removeAll()
        inboundContinuation.finish()
    }

    // MARK: - Frame discrimination

    /// True iff `body` is an ACP frame this transport produced, false for any
    /// plausible chat text. The magic prefix `ACP1|` cannot begin a JSON-RPC line
    /// (those start with `{`); it is a pure, allocation-light prefix check so the
    /// integration can route ACP→`deliverInbound`, chat→the normal path.
    public nonisolated static func isACPFrame(_ body: String) -> Bool {
        body.hasPrefix(Self.magic)
    }

    // MARK: - Envelope constants

    /// Fixed magic prefix (includes the trailing delimiter so a chat line that is
    /// literally "ACP1" without the pipe is NOT mistaken for a frame).
    static let magic = "ACP1|"
    /// Header is `ACP1|<lineId>|<seq>|<total>|`; with a payload of ≥1 base64url
    /// char this is the floor on a viable frame. The salt+seq id and small seq/
    /// total numbers stay well under this in practice; the guard just keeps a
    /// caller-supplied tiny budget from making chunking diverge.
    static let minViableFrameBytes = 64

    // MARK: - Framing internals

    /// Per-line reassembly state: the expected chunk count and the payload bytes
    /// received so far, keyed by 1-based seq (so duplicates overwrite, gaps show).
    private struct Reassembly {
        let total: UInt32
        var chunks: [UInt32: Data] = [:]
    }

    /// A decoded inbound frame chunk.
    private struct FrameChunk {
        let lineId: String
        let seq: UInt32
        let total: UInt32
        let payload: Data

        /// Parse `ACP1|<lineId>|<seq>|<total>|<payloadB64Url>`. The payload may
        /// itself be empty (an empty ACP line is legal) but the four header
        /// fields and all four delimiters must be present and well-formed.
        init?(parsing body: String) {
            guard body.hasPrefix(RelayACPTransport.magic) else { return nil }
            // Split into exactly 5 fields. `omittingEmptySubsequences: false`
            // keeps an empty trailing payload field; capping at 5 keeps any `=`/
            // base64url payload intact (base64url has no `|` so 5 is exact, but
            // the cap is belt-and-suspenders against a malformed payload).
            let parts = body.split(
                separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, parts[0] == "ACP1" else { return nil }
            let lineId = String(parts[1])
            guard !lineId.isEmpty,
                let seq = UInt32(parts[2]), let total = UInt32(parts[3]),
                total >= 1, seq >= 1, seq <= total,
                let payload = RelayACPTransport.base64URLDecode(String(parts[4]))
            else { return nil }
            self.lineId = lineId
            self.seq = seq
            self.total = total
            self.payload = payload
        }
    }

    /// Frame `line` into one-or-more chunks, each ≤ `maxFrameBytes` UTF-8 bytes
    /// INCLUDING the header. The line's **raw UTF-8 bytes** are sliced, and EACH
    /// slice is base64url-encoded independently as that chunk's payload. This is
    /// the key to correct reassembly: every chunk's payload is a self-contained
    /// base64url unit (4-char aligned by construction), so the receiver can decode
    /// each chunk on its own and concatenate the raw bytes — concatenating
    /// per-chunk-DECODED bytes round-trips, whereas slicing one big encoded string
    /// at non-4-aligned boundaries would corrupt every chunk seam. Slicing the raw
    /// bytes never splits a multibyte scalar in a way that breaks the round-trip
    /// (the bytes are reassembled before being interpreted as UTF-8). Always
    /// yields ≥1 chunk (an empty line → one empty-payload chunk).
    static func frameChunks(line: String, lineId: String, maxFrameBytes: Int) -> [String] {
        let rawBytes = [UInt8](Data(line.utf8))

        // The header (sans payload) for a chunk is "ACP1|<lineId>|<seq>|<total>|".
        // `total`'s digit width affects header size, and seq ≤ total, so size the
        // budget with the worst-case (widest) seq width so EVERY chunk fits.
        func headerOverhead(totalDigits: Int) -> Int {
            magic.utf8.count + lineId.utf8.count + 1 + totalDigits + 1 + totalDigits + 1
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
            frames.append("\(magic)\(lineId)|\(seq)|\(chunkCount)|\(slice)")
            index = end
            seq += 1
        } while index < rawBytes.count
        return frames
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

    private static func randomSalt() -> String {
        // 6 random bytes → 12 hex chars: ample to avoid cross-sender id
        // collisions, no `|`, no crypto significance (collision-avoidance only).
        var bytes = [UInt8](repeating: 0, count: 6)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
