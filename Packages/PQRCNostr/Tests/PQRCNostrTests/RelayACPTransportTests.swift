import Foundation
import PQRCACP
import Testing

@testable import PQRCNostr

/// ACPRouterplan Phase 3: `RelayACPTransport` carries the ACP line protocol over
/// the relay (the gift-wrapped + ratcheted message mesh) so the phone can drive
/// the Mac node REMOTELY. This suite proves the framing/chunking envelope and the
/// reassembly machinery headlessly — no messenger, no relay, no radios: the
/// transport is decoupled behind a `send` closure (which the integration later
/// wires to `messenger.send`) and a `deliverInbound` entry point (which the
/// integration feeds with received ACP-framed bodies). (TEST-PLAN §1.)
@Suite("Relay ACP transport (ACPRouterplan Phase 3)", .tags(.transport, .security))
struct RelayACPTransportTests {
    /// Captures every framed chunk a transport's `send` closure publishes, so a
    /// test can feed them to a second transport's `deliverInbound` and assert the
    /// reassembled line. Order-preserving.
    actor ChunkSink {
        private var chunks: [String] = []
        func record(_ chunk: String) { chunks.append(chunk) }
        func all() -> [String] { chunks }
        func count() -> Int { chunks.count }
    }

    /// A transport plus the sink capturing its outbound chunks.
    static func makeSender(maxFrameBytes: Int, salt: String? = nil) -> (RelayACPTransport, ChunkSink) {
        let sink = ChunkSink()
        let transport = RelayACPTransport(
            maxFrameBytes: maxFrameBytes, instanceSalt: salt,
            send: { chunk in await sink.record(chunk) })
        return (transport, sink)
    }

    /// Polls the sink until at least `count` chunks have been captured (the
    /// `send` closure runs on an actor hop off the sync `send`).
    static func waitChunks(_ sink: ChunkSink, atLeast count: Int, timeoutMillis: Int = 5_000)
        async -> [String]
    {
        var waited = 0
        while await sink.count() < count && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return await sink.all()
    }

    /// The sender's line-order index parsed out of a frame's `lineId`
    /// (`ACP1|<salt>-<base36 seq>|seq|total|payload`). Lets a test deliver complete
    /// lines in a chosen order regardless of which framing Task filled the sink
    /// first. `.max` for an unparsable frame so callers' `== n` checks just miss.
    static func lineIndex(of frame: String) -> UInt64 {
        let parts = frame.split(separator: "|")
        guard parts.count > 1 else { return .max }
        let tail = parts[1].split(separator: "-").last.map(String.init) ?? ""
        return UInt64(tail, radix: 36) ?? .max
    }

    // MARK: - (a) Round trip

    @Test func roundTrip_lineIsByteIdenticalAfterFrameAndReassemble() async throws {
        // Sender frames; receiver reassembles. A small budget forces ≥1 chunk for
        // a typical line; this case stays single-chunk for the simplest path.
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayACPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"text":"hi"}}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// A line with multibyte UTF-8 (emoji, accents) and JSON-significant chars
    /// (`|`, quotes, backslashes) survives byte-exact — proves the base64url
    /// payload makes the `|` delimiter unambiguous.
    @Test func roundTrip_multibyteAndDelimiterCharsSurvive() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayACPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"text":"a|b|c piñata 🚀 \"quoted\" back\\slash"}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// An empty ACP line still frames to exactly one chunk and reassembles to "".
    @Test func roundTrip_emptyLine() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 256)
        let receiver = RelayACPTransport(maxFrameBytes: 256, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        sender.send("")
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        #expect(chunks.count == 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == "")
    }

    // MARK: - (b) Chunking

    @Test func chunking_largeLineSplitsUnderBudgetAndReassemblesExactly() async throws {
        let maxFrame = 256
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // A tool-output line far larger than one frame (e.g. a long fs/read).
        let big = #"{"method":"session/update","params":{"output":""# + String(repeating: "X", count: 20_000) + #""}}"#
        sender.send(big)

        // Many chunks, EACH framed size ≤ budget.
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        // Settle: ensure no more are still arriving before asserting the count.
        try? await Task.sleep(for: .milliseconds(50))
        let allChunks = await sink.all()
        #expect(allChunks.count > 1, "a 20 KB line must split into multiple chunks under a 256-byte budget")
        for chunk in allChunks {
            #expect(chunk.utf8.count <= maxFrame, "framed chunk \(chunk.prefix(24))… exceeds the \(maxFrame)-byte budget (\(chunk.utf8.count))")
            #expect(RelayACPTransport.isACPFrame(chunk))
        }
        _ = chunks

        for chunk in allChunks { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == big)
    }

    /// Chunk-count grows the `total` field's digit width (e.g. crossing 9→10,
    /// 99→100 chunks); every chunk must still fit the budget with the wider
    /// header. A tiny budget + large line drives total into 3+ digits.
    @Test func chunking_widerTotalFieldStillFitsBudget() async throws {
        let maxFrame = 80  // near the minViableFrameBytes floor
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let big = String(repeating: "Z", count: 5_000)
        sender.send(big)
        _ = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(80))
        let allChunks = await sink.all()
        #expect(allChunks.count >= 100, "expected 3-digit chunk count to exercise total-width growth, got \(allChunks.count)")
        let effectiveBudget = max(maxFrame, RelayACPTransport.minViableFrameBytes)
        for chunk in allChunks {
            #expect(chunk.utf8.count <= effectiveBudget)
        }
        for chunk in allChunks { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == big)
    }

    // MARK: - (c) isACPFrame discrimination

    @Test func isACPFrame_trueForFrames_falseForChat() async {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "deadbeef")
        sender.send(#"{"method":"session/prompt"}"#)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        #expect(!chunks.isEmpty)
        for chunk in chunks { #expect(RelayACPTransport.isACPFrame(chunk)) }

        // Plausible chat bodies — including text that coincidentally starts with
        // similar characters — must NOT be mistaken for frames.
        let chatBodies = [
            "hello there",
            #"{"jsonrpc":"2.0"}"#,  // a JSON line begins with '{', never the magic
            "ACP is a cool protocol",
            "ACP1 is the first version",  // 'ACP1' but no trailing '|'
            "A|B|C|D|E",  // pipe-delimited chat that is not the magic
            "ACP1",  // bare magic-ish, no delimiter
            "",
            "acp1|lowercase|1|1|x",  // case-sensitive: lowercase magic is chat
        ]
        for body in chatBodies {
            #expect(!RelayACPTransport.isACPFrame(body), "chat body must not be seen as a frame: \(body)")
        }
    }

    // MARK: - (d) Interleaving / out-of-order

    /// Two lines' chunks delivered fully INTERLEAVED still reassemble to the right
    /// lines (reassembly is keyed by line-id, not arrival order).
    @Test func interleavedTwoLines_reassembleToCorrectLines() async throws {
        let maxFrame = 200
        let (senderA, sinkA) = Self.makeSender(maxFrameBytes: maxFrame, salt: "aaaa")
        let (senderB, sinkB) = Self.makeSender(maxFrameBytes: maxFrame, salt: "bbbb")
        let receiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let lineA = #"{"id":"A","blob":""# + String(repeating: "A", count: 1_500) + #""}"#
        let lineB = #"{"id":"B","blob":""# + String(repeating: "B", count: 1_500) + #""}"#
        senderA.send(lineA)
        senderB.send(lineB)
        let chunksA = await Self.waitChunks(sinkA, atLeast: 2)
        let chunksB = await Self.waitChunks(sinkB, atLeast: 2)
        #expect(chunksA.count > 1 && chunksB.count > 1)

        // Interleave: A0, B0, A1, B1, … (zip then flatten), delivering whatever
        // remains of the longer one after the shorter runs out.
        let maxLen = max(chunksA.count, chunksB.count)
        for i in 0..<maxLen {
            if i < chunksA.count { await receiver.deliverInbound(chunksA[i]) }
            if i < chunksB.count { await receiver.deliverInbound(chunksB[i]) }
        }

        let got = await lines.waitFor(2)
        #expect(Set(got) == Set([lineA, lineB]))
    }

    /// One line's chunks delivered fully OUT OF ORDER (reversed) still reassemble
    /// exactly — concatenation is by seq, not arrival.
    @Test func outOfOrderChunks_reassembleExactly() async throws {
        let maxFrame = 200
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"method":"session/update","seq-test":""# + String(repeating: "Q", count: 2_000) + #""}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count > 2)

        // Deliver reversed (last chunk first).
        for chunk in allChunks.reversed() { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// Two lines from ONE sender whose COMPLETE frames arrive in REVERSE order
    /// (the relay delivers each line as a separate, unordered event) must still
    /// emit in SENDER order — the content line before the `end_turn` line that
    /// followed it. This is the exact Phase-3 failure mode: a raw arrival-order
    /// emit surfaces `end_turn` first and the ACP client finalizes the turn empty.
    @Test func twoLinesFromOneSender_emitInSenderOrder_whenDeliveredReversed() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "cccc")
        let receiver = RelayACPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // Short lines → one chunk each. `first` is sent before `second`, so it gets
        // the lower index even though the two framing Tasks race afterward.
        let first = #"{"jsonrpc":"2.0","method":"session/update","params":{"text":"CONTENT"}}"#
        let second = #"{"jsonrpc":"2.0","id":9,"result":{"stopReason":"end_turn"}}"#
        sender.send(first)
        sender.send(second)
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        #expect(chunks.count == 2, "each short line frames to a single chunk")

        let firstFrame = chunks.first { Self.lineIndex(of: $0) == 0 }
        let secondFrame = chunks.first { Self.lineIndex(of: $0) == 1 }
        #expect(firstFrame != nil && secondFrame != nil, "indices 0 and 1 must both be present")

        // The relay reordering: the SECOND line (end_turn) is delivered FIRST.
        await receiver.deliverInbound(secondFrame!)
        await receiver.deliverInbound(firstFrame!)

        let got = await lines.waitFor(2)
        #expect(
            got == [first, second],
            "lines must emit in SENDER order (content before its end_turn), not arrival order; got \(got)")
    }

    /// A line that completes while an EARLIER line is still missing is held back,
    /// then both flush in order once the gap fills — the buffering half of the
    /// ordering guarantee (no premature emit, no lost line).
    @Test func laterLineHeldUntilEarlierArrives() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "dddd")
        let receiver = RelayACPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let l0 = #"{"i":0}"#
        let l1 = #"{"i":1}"#
        sender.send(l0)
        sender.send(l1)
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        let f0 = chunks.first { Self.lineIndex(of: $0) == 0 }
        let f1 = chunks.first { Self.lineIndex(of: $0) == 1 }
        #expect(f0 != nil && f1 != nil, "indices 0 and 1 must both be present")

        // Deliver ONLY the later line. It must NOT emit — index 0 is still a gap.
        await receiver.deliverInbound(f1!)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await lines.all().isEmpty, "a line ahead of a gap must wait, not emit early")

        // Fill the gap → both flush, in order.
        await receiver.deliverInbound(f0!)
        let got = await lines.waitFor(2)
        #expect(got == [l0, l1], "filling the gap releases both in order; got \(got)")
    }

    // MARK: - (e) Partial line never emits

    @Test func missingChunk_neverEmits() async throws {
        let maxFrame = 200
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = String(repeating: "P", count: 2_000)
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 3)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count >= 3)

        // Deliver every chunk EXCEPT one (drop the middle one). The line must
        // never appear on inboundLines.
        let dropIndex = allChunks.count / 2
        for (i, chunk) in allChunks.enumerated() where i != dropIndex {
            await receiver.deliverInbound(chunk)
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await lines.all().isEmpty, "a line missing a chunk must never emit")

        // Then delivering the missing chunk completes it — proving the partial
        // was buffered, not discarded.
        await receiver.deliverInbound(allChunks[dropIndex])
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// A garbage / non-frame body fed to `deliverInbound` is dropped (counted) and
    /// never emits — the integration only routes `isACPFrame` bodies here, but the
    /// entry point must be defensive anyway.
    @Test func malformedFrame_isDroppedNotEmitted() async throws {
        let receiver = RelayACPTransport(maxFrameBytes: 256, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        await receiver.deliverInbound("not a frame at all")
        await receiver.deliverInbound("ACP1|onlyfourfields|1|1")  // missing payload delimiter
        await receiver.deliverInbound("ACP1|id|0|2|AAAA")  // seq 0 invalid
        await receiver.deliverInbound("ACP1|id|3|2|AAAA")  // seq > total
        await receiver.deliverInbound("ACP1|id|1|2|!!!notb64!!!")  // bad payload
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await lines.all().isEmpty)
        #expect(await receiver.droppedFrameCount >= 5)
    }
}
