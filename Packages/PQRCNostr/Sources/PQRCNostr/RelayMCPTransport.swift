// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Synchronization

/// Phase D3 — the SIBLING of `RelayACPTransport` that carries the **MCP** line
/// protocol over the relay (the gift-wrapped + Double-Ratcheted message mesh), so the
/// paired Mac's ACP coding agent can USE the phone's MCP chat tools. The phone serves
/// MCP from its redacting/window-gating `MCPServer`; the node drives those tools via
/// an `MCPOverRelayClient` whose injected line seam is one of these. Same E2EE
/// ciphertext the relay already carries for chat (SPEC §2 — no new crypto here).
///
/// ## Why a separate transport (not the ACP one)
///
/// MCP and ACP are two distinct JSON-RPC streams that can ride the SAME pair of PQRC
/// identities at the same time (the node both drives ACP turns AND serves the phone's
/// chat tools back). They MUST be un-confusable on the shared inbound message stream.
/// The magic prefix is the discriminator:
/// - `ACP1|` → `RelayACPTransport` (the agent control channel),
/// - `MCP1|` → `RelayMCPTransport` (this — the chat-tool channel),
/// - `{`    → ordinary chat (a JSON-RPC line never begins with either magic).
///
/// `MCP1|` and `ACP1|` differ in the first character, so `isMCPFrame`/`isACPFrame`
/// are mutually exclusive on any body. Everything else — chunking under a byte
/// budget, out-of-order/interleaved reassembly keyed by `lineId`, and sender-order
/// restoration — is the shared `RelayFraming` core, identical to the ACP transport.
///
/// Conforms to PQRCACP's `MCPLineSeam` so `MCPOverRelayClient` can speak MCP over it
/// without PQRCACP depending on PQRCNostr (the dependency edge stays PQRCNostr →
/// PQRCACP only; AC24/AC30 — PQRCACP is deliberately dependency-free).
public actor RelayMCPTransport: MCPLineSeam {
    /// The relay's per-message byte budget. Every FRAMED chunk handed to `send` is
    /// ≤ this many UTF-8 bytes (header + payload), so it fits one relay event.
    private let maxFrameBytes: Int
    /// Publishes one framed chunk to the peer over the relay. Wired by the integration
    /// to `messenger.send(_, to: peerIdentityHex)`.
    private let sendChunk: @Sendable (String) async -> Void

    /// Per-instance random salt prefixing every `lineId` this transport mints, so ids
    /// from two different senders can never collide in a shared receiver's reassembly
    /// table. Hex, so it never contains the `|` delimiter.
    private let instanceSalt: String
    /// Monotonic per-line index, minted at `send`-CALL time (atomically — `send` is
    /// `nonisolated` + sync per `MCPLineSeam`, so it cannot hop onto the actor to bump
    /// a counter without losing call order). Its value IS the sender's line order; the
    /// receiver re-sorts by it to undo the relay's unordered delivery.
    private let lineSeqCounter = Atomic<UInt64>(0)

    /// In-flight inbound lines being reassembled, keyed by `lineId`. Bounded by
    /// `RelayFraming.maxPendingReassemblies` (LRU) — an incomplete line must not be
    /// retained forever.
    private var reassembly: [String: RelayFraming.Reassembly] = [:]
    /// Monotonic touch stamp for the reassembly LRU.
    private var reassemblyCounter: UInt64 = 0

    /// Inbound line ordering, per sender `salt`: the next line index to emit, and the
    /// lines that completed reassembly AHEAD of a gap (held until the gap fills).
    private var nextEmit: [String: UInt64] = [:]
    private var pendingLines: [String: [UInt64: String]] = [:]

    private let inbound: AsyncStream<String>
    private let inboundContinuation: AsyncStream<String>.Continuation

    /// Frames that failed to parse/decode on the inbound side, for test introspection.
    /// The values themselves are never logged (CLAUDE.md inv. 12).
    public private(set) var droppedFrameCount = 0

    public init(
        maxFrameBytes: Int,
        instanceSalt: String? = nil,
        send: @escaping @Sendable (String) async -> Void
    ) {
        self.maxFrameBytes = max(maxFrameBytes, RelayFraming.minViableFrameBytes)
        self.sendChunk = send
        self.instanceSalt = instanceSalt ?? RelayFraming.randomSalt()
        (self.inbound, self.inboundContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: - MCPLineSeam

    /// Frame + chunk one MCP line and publish each chunk over the relay. The line's
    /// order index is minted HERE, at call time, so it reflects the exact order `send`
    /// was invoked even though the per-line framing Tasks (and the relay's delivery)
    /// race afterward. The index rides in the frame's `lineId`; `deliverInbound`
    /// re-sorts by it on the far end — so the phone's MCP server sees responses in the
    /// order the node sent its requests, and vice versa.
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

    /// The integration calls this for each MCP-framed body received FROM the peer over
    /// the relay. Decodes the chunk, files it under its `lineId`, and — once every
    /// chunk of that line has arrived — emits the byte-identical original MCP line on
    /// `inboundLines`. Tolerant of out-of-order and interleaved chunks; a line missing
    /// any chunk never emits.
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
        // A conflicting `total` for the same id is a corrupt/forged frame stream; drop
        // the offending chunk rather than reassemble garbage.
        guard entry.total == chunk.total, chunk.seq >= 1, chunk.seq <= chunk.total else {
            droppedFrameCount += 1
            return
        }
        entry.chunks[chunk.seq] = chunk.payload
        if entry.chunks.count == Int(chunk.total) {
            reassembly[chunk.lineId] = nil
            var bytes = Data()
            for seq in 1...chunk.total {
                guard let part = entry.chunks[seq] else {
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

    /// Emit a fully-reassembled line in SENDER order, using the per-sender monotonic
    /// index in its `lineId`. A line with no parsable index is emitted immediately
    /// (foreign/test frames keep flowing).
    private func emitInOrder(lineId: String, line: String) {
        guard let (salt, seq) = RelayFraming.splitLineId(lineId) else {
            inboundContinuation.yield(line)
            return
        }
        let expected = nextEmit[salt] ?? 0
        if seq < expected { return }
        pendingLines[salt, default: [:]][seq] = line
        flushReady(salt: salt)
    }

    /// Release every buffered line that extends the contiguous run from
    /// `nextEmit[salt]`; if too many pile up behind a still-missing index, skip to the
    /// lowest buffered index rather than stall forever (bounded degradation).
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

    /// True iff `body` is an MCP frame this transport produced, false for any
    /// plausible chat text AND for an `ACP1|` frame. The magic prefix `MCP1|` cannot
    /// begin a JSON-RPC line (those start with `{`) and differs from `ACP1|` in the
    /// first byte, so the integration can split the shared inbound stream three ways:
    /// MCP→`deliverInbound`, ACP→`RelayACPTransport.deliverInbound`, chat→normal.
    public nonisolated static func isMCPFrame(_ body: String) -> Bool {
        body.hasPrefix(Self.magic)
    }

    // MARK: - Envelope constants

    /// The bare magic TOKEN (no delimiter) used inside the shared framing core.
    static let magicToken = "MCP1"
    /// Fixed magic prefix (includes the trailing delimiter so a chat line that is
    /// literally "MCP1" without the pipe is NOT mistaken for a frame).
    static let magic = magicToken + "|"
}
