import Foundation
import PQRCACP
import Synchronization

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
///   the counter is unique per line within a sender AND monotonic in send order,
///   so the receiver can restore line order from it (below). Hex/base36 — no `|`.
/// - `seq` — 1-based chunk index (base 10).
/// - `total` — total chunk count for this line (base 10).
/// - `payloadB64Url` — base64url (RFC 4648 §5, no padding) of this chunk's UTF-8
///   bytes. base64url's alphabet (`A–Z a–z 0–9 - _`) contains no `|`, so the
///   delimiter is never ambiguous and the original line round-trips byte-exact.
///
/// Reassembly is keyed by `lineId`; a line is *complete* once all `total`
/// distinct chunks (by `seq`) have arrived — out-of-order and
/// interleaved-with-other-lines chunk delivery both reassemble correctly, and a
/// line missing any chunk never completes.
///
/// ## Line ordering (not just chunk reassembly)
///
/// A relay delivers each line as a SEPARATE gift-wrapped event, so two complete
/// lines can surface in either order — but the ACP line protocol is a stream: a
/// content `session/update` MUST reach the client before the `end_turn` result
/// that ends the turn, or the turn finalizes empty. So a complete line is not
/// emitted on `inboundLines` immediately; it is released in the sender's order
/// using the monotonic index in its `lineId` (lines that complete ahead of a gap
/// wait for the gap to fill). This makes the unordered relay behave like the
/// ordered stdio pipe the protocol assumes. The buffer is bounded
/// (`maxReorderBuffer`): a genuinely lost line is skipped rather than wedging the
/// stream forever.
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
    /// Monotonic per-line index, minted at `send`-CALL time (atomically — `send`
    /// is `nonisolated` + sync per `ACPTransport`, so it cannot hop onto the actor
    /// to bump a counter without losing call order). Its value IS the sender's line
    /// order; the receiver re-sorts by it to undo the relay's unordered delivery.
    private let lineSeqCounter = Atomic<UInt64>(0)

    /// In-flight inbound lines being reassembled, keyed by `lineId`. Bounded by
    /// `RelayFraming.maxPendingReassemblies` (LRU) — an incomplete line must not be
    /// retained forever.
    private var reassembly: [String: RelayFraming.Reassembly] = [:]
    /// Monotonic touch stamp for the reassembly LRU.
    private var reassemblyCounter: UInt64 = 0

    /// Inbound line ordering, per sender `salt`: the next line index to emit, and
    /// the lines that completed reassembly AHEAD of a gap (held until the gap
    /// fills). Keyed by salt so two senders sharing one receiver order
    /// independently. This is what makes the relay (which delivers each line as a
    /// separate, unordered gift-wrapped event) behave like the ordered stdio pipe
    /// the ACP line protocol assumes.
    private var nextEmit: [String: UInt64] = [:]
    private var pendingLines: [String: [UInt64: String]] = [:]

    private let inbound: AsyncStream<String>
    private let inboundContinuation: AsyncStream<String>.Continuation

    /// Frames that failed to parse/decode on the inbound side, for test
    /// introspection. The values themselves are never logged (CLAUDE.md inv. 12).
    public private(set) var droppedFrameCount = 0

    /// Incomplete lines currently held for reassembly, for test introspection — this
    /// is the quantity `RelayFraming.maxPendingReassemblies` bounds.
    public var pendingReassemblyCount: Int { reassembly.count }

    public init(
        maxFrameBytes: Int,
        instanceSalt: String? = nil,
        send: @escaping @Sendable (String) async -> Void
    ) {
        // A frame must hold the header plus at least one payload byte; guard the
        // budget up so chunking always terminates even if the caller passes a
        // pathologically small value.
        self.maxFrameBytes = max(maxFrameBytes, RelayFraming.minViableFrameBytes)
        self.sendChunk = send
        self.instanceSalt = instanceSalt ?? RelayFraming.randomSalt()
        (self.inbound, self.inboundContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: - ACPTransport

    /// Frame + chunk one ACP line and publish each chunk over the relay.
    /// Synchronous + `Sendable` per the `ACPTransport` contract (it may be called
    /// from inside a JSON-RPC continuation without `await`); the framing/sends then
    /// happen on a hop onto this actor.
    ///
    /// The line's order index is minted HERE, at call time, so it reflects the
    /// exact order `send` was invoked even though the per-line framing Tasks (and
    /// the relay's delivery) race afterward. The index rides in the frame's
    /// `lineId`; `deliverInbound` re-sorts by it on the far end. This is the half
    /// that makes "content `session/update` before its `end_turn`" hold over an
    /// unordered relay — a previous version bumped the counter inside the framing
    /// Task, where two `send`s could interleave and swap a turn's content past its
    /// terminator (the turn then finalized empty under load).
    public nonisolated func send(_ line: String) {
        let seq = lineSeqCounter.wrappingAdd(1, ordering: .relaxed).oldValue
        Task { await self.frameAndSend(line, seq: seq) }
    }

    public nonisolated func inboundLines() -> AsyncStream<String> { inbound }

    public nonisolated func close() {
        Task { await self.shutdown() }
    }

    // MARK: - Outbound: frame + chunk

    private func frameAndSend(_ line: String, seq: UInt64) async {
        let lineId = "\(instanceSalt)-\(String(seq, radix: 36))"
        for chunk in RelayFraming.frameChunks(
            line: line, lineId: lineId, maxFrameBytes: maxFrameBytes, magic: Self.magicToken)
        {
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
        guard let chunk = RelayFraming.FrameChunk(parsing: framedBody, magic: Self.magicToken) else {
            droppedFrameCount += 1
            return
        }
        // `total` is a wire value — refuse an absurd one outright (see maxChunksPerLine).
        guard chunk.total <= RelayFraming.maxChunksPerLine else {
            droppedFrameCount += 1
            return
        }
        var entry = reassembly[chunk.lineId] ?? RelayFraming.Reassembly(total: chunk.total)
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
            emitInOrder(lineId: chunk.lineId, line: String(decoding: bytes, as: UTF8.self))
        } else {
            // Incomplete: retain, stamp for LRU, and bound the map. Without the bound a
            // single lost chunk pinned this line's payloads for the process's lifetime.
            reassemblyCounter += 1
            entry.receivedOrder = reassemblyCounter
            reassembly[chunk.lineId] = entry
            RelayFraming.evictStaleReassembliesIfNeeded(&reassembly)
        }
    }

    // MARK: - Inbound: restore sender order

    /// Emit a fully-reassembled line in SENDER order. Every line carries a
    /// per-sender monotonic index in its `lineId` (`<salt>-<base36 seq>`); we
    /// release the contiguous run from the next-expected index and BUFFER any line
    /// that completed ahead of a gap, so the ACP client sees lines exactly as the
    /// agent wrote them (a content `session/update` before the `end_turn` that
    /// follows it). A raw arrival-order emit scrambles that under load — the
    /// terminator overtakes the content and the turn finalizes empty.
    ///
    /// A line whose id has no parsable index (a hand-crafted or legacy frame) is
    /// emitted immediately — never buffered — so foreign/test frames still flow.
    private func emitInOrder(lineId: String, line: String) {
        guard let (salt, seq) = RelayFraming.splitLineId(lineId) else {
            inboundContinuation.yield(line)
            return
        }
        // Already advanced past this index (a duplicate re-completion): never
        // re-emit, and never out of order.
        let expected = nextEmit[salt] ?? 0
        if seq < expected { return }
        pendingLines[salt, default: [:]][seq] = line
        flushReady(salt: salt)
    }

    /// Release every buffered line that extends the contiguous run from
    /// `nextEmit[salt]`. If too many lines pile up behind a still-missing index
    /// (genuine relay loss, or a peer withholding a low index to wedge us), skip to
    /// the lowest buffered index rather than stall forever — bounded degradation,
    /// never an unbounded buffer or a permanent wedge (worst case it degrades to
    /// the old arrival-ish order, which is no worse than having no ordering).
    private func flushReady(salt: String) {
        var expected = nextEmit[salt] ?? 0
        var buffer = pendingLines[salt] ?? [:]
        while let line = buffer.removeValue(forKey: expected) {
            inboundContinuation.yield(line)
            expected &+= 1
        }
        if buffer.count > RelayFraming.maxReorderBuffer, let lowest = buffer.keys.min() {
            expected = lowest
            while let line = buffer.removeValue(forKey: expected) {
                inboundContinuation.yield(line)
                expected &+= 1
            }
        }
        nextEmit[salt] = expected
        pendingLines[salt] = buffer.isEmpty ? nil : buffer
    }

    private func shutdown() {
        reassembly.removeAll()
        pendingLines.removeAll()
        nextEmit.removeAll()
        inboundContinuation.finish()
    }

    // MARK: - Frame discrimination

    /// True iff `body` is an ACP frame this transport produced, false for any
    /// plausible chat text. The magic prefix `ACP1|` cannot begin a JSON-RPC line
    /// (those start with `{`); it is a pure, allocation-light prefix check so the
    /// integration can route ACP→`deliverInbound`, chat→the normal path. It is also
    /// un-confusable with `RelayMCPTransport`'s `MCP1|` magic, so the two relay
    /// transports can share one inbound message stream (route ACP frames here, MCP
    /// frames to `RelayMCPTransport.deliverInbound`, everything else to chat).
    public nonisolated static func isACPFrame(_ body: String) -> Bool {
        body.hasPrefix(Self.magic)
    }

    // MARK: - Envelope constants

    /// The bare magic TOKEN (no delimiter) used inside the shared framing core.
    static let magicToken = "ACP1"
    /// Fixed magic prefix (includes the trailing delimiter so a chat line that is
    /// literally "ACP1" without the pipe is NOT mistaken for a frame).
    static let magic = magicToken + "|"
    /// The shared framing floor, re-exported so existing tests that reference
    /// `RelayACPTransport.minViableFrameBytes` keep working (the value lives once in
    /// `RelayFraming`).
    static let minViableFrameBytes = RelayFraming.minViableFrameBytes
}
