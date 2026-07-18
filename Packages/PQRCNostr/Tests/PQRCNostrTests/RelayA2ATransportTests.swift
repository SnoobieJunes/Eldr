import Foundation
import Testing

@testable import PQRCNostr

/// `RelayA2ATransport` carries the A2A (Agent2Agent) JSON-RPC line protocol over the
/// relay (the gift-wrapped + ratcheted message mesh) per `docs/A2A-PQRC-EXTENSION.md`
/// — the PQRC E2EE transport binding for A2A. This suite proves the framing/chunking
/// envelope, the reassembly machinery, and — load-bearing for routing safety — that an
/// `A2A1|` frame is un-confusable with an `ACP1|` frame, an `MCP1|` frame, and a
/// JSON-RPC `{` line, so all three relay-carried line protocols can share one inbound
/// message stream. No messenger, no relay, no radios: the transport is decoupled
/// behind a `send` closure (which the integration later wires to `messenger.send`) and
/// a `deliverInbound` entry point (which the integration feeds with received
/// A2A-framed bodies). (TEST-PLAN §1.)
@Suite("Relay A2A transport (A2A-over-PQRC extension)", .tags(.transport, .security))
struct RelayA2ATransportTests {
    /// Captures every framed chunk a transport's `send` closure publishes, so a test
    /// can feed them to a second transport's `deliverInbound` and assert the
    /// reassembled line. Order-preserving.
    actor ChunkSink {
        private var chunks: [String] = []
        func record(_ chunk: String) { chunks.append(chunk) }
        func all() -> [String] { chunks }
        func count() -> Int { chunks.count }
    }

    /// A transport plus the sink capturing its outbound chunks.
    static func makeSender(maxFrameBytes: Int, salt: String? = nil) -> (RelayA2ATransport, ChunkSink) {
        let sink = ChunkSink()
        let transport = RelayA2ATransport(
            maxFrameBytes: maxFrameBytes, instanceSalt: salt,
            send: { chunk in await sink.record(chunk) })
        return (transport, sink)
    }

    /// Polls the sink until at least `count` chunks have been captured (the `send`
    /// closure runs on an actor hop off the sync `send`).
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
    /// (`A2A1|<salt>-<base36 seq>|seq|total|payload`). Lets a test deliver complete
    /// lines in a chosen order regardless of which framing Task filled the sink first.
    /// `.max` for an unparsable frame so callers' `== n` checks just miss.
    static func lineIndex(of frame: String) -> UInt64 {
        let parts = frame.split(separator: "|")
        guard parts.count > 1 else { return .max }
        let tail = parts[1].split(separator: "-").last.map(String.init) ?? ""
        return UInt64(tail, radix: 36) ?? .max
    }

    // MARK: - (a) Round trip

    @Test func roundTrip_lineIsByteIdenticalAfterFrameAndReassemble() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayA2ATransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // A realistic A2A v1.0 JSON-RPC request (SendMessage — the proto RPC name,
        // NOT the 0.3-era "message/send" style; see A2AMethod).
        let line =
            #"{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"role":"user","parts":[{"kind":"text","text":"hi"}]}}}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// A line with multibyte UTF-8 (emoji, accents) and JSON-significant chars
    /// (`|`, quotes, backslashes) survives byte-exact — proves the base64url payload
    /// makes the `|` delimiter unambiguous.
    @Test func roundTrip_multibyteAndDelimiterCharsSurvive() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayA2ATransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"text":"a|b|c piñata 🚀 \"quoted\" back\\slash"}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// An empty A2A line still frames to exactly one chunk and reassembles to "".
    @Test func roundTrip_emptyLine() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 256)
        let receiver = RelayA2ATransport(maxFrameBytes: 256, send: { _ in })
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
        let receiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // An `a2a/streamEvent` notification carrying a large streamed artifact chunk.
        let big =
            #"{"jsonrpc":"2.0","method":"a2a/streamEvent","params":{"requestId":1,"event":{"kind":"artifact-update","artifact":{"parts":[{"kind":"text","text":""#
            + String(repeating: "X", count: 20_000) + #""}]}}}}"#
        sender.send(big)

        // Many chunks, EACH framed size ≤ budget.
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        // Settle: ensure no more are still arriving before asserting the count.
        try? await Task.sleep(for: .milliseconds(50))
        let allChunks = await sink.all()
        #expect(allChunks.count > 1, "a 20 KB line must split into multiple chunks under a 256-byte budget")
        for chunk in allChunks {
            #expect(chunk.utf8.count <= maxFrame, "framed chunk \(chunk.prefix(24))… exceeds the \(maxFrame)-byte budget (\(chunk.utf8.count))")
            #expect(RelayA2ATransport.isA2AFrame(chunk))
        }
        _ = chunks

        for chunk in allChunks { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == big)
    }

    /// Chunk-count grows the `total` field's digit width (e.g. crossing 9→10,
    /// 99→100 chunks); every chunk must still fit the budget with the wider header. A
    /// tiny budget + large line drives total into 3+ digits.
    @Test func chunking_widerTotalFieldStillFitsBudget() async throws {
        let maxFrame = 80  // near the minViableFrameBytes floor
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let big = String(repeating: "Z", count: 5_000)
        sender.send(big)
        _ = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(80))
        let allChunks = await sink.all()
        #expect(allChunks.count >= 100, "expected 3-digit chunk count to exercise total-width growth, got \(allChunks.count)")
        for chunk in allChunks {
            #expect(chunk.utf8.count <= maxFrame)
        }
        for chunk in allChunks { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == big)
    }

    // MARK: - (c) isA2AFrame discrimination — the load-bearing routing-safety proof

    @Test func isA2AFrame_trueForA2A_falseForChatAndACPAndMCP() async {
        // Real A2A frames are recognized.
        let (a2aSender, a2aSink) = Self.makeSender(maxFrameBytes: 4096, salt: "deadbeef")
        a2aSender.send(#"{"method":"SendMessage"}"#)
        let a2aChunks = await Self.waitChunks(a2aSink, atLeast: 1)
        #expect(!a2aChunks.isEmpty)
        for chunk in a2aChunks { #expect(RelayA2ATransport.isA2AFrame(chunk)) }

        // CRITICAL: an ACP1| frame must NOT be seen as an A2A frame — the relay-carried
        // transports share one inbound stream; misrouting would feed an agent-control
        // line to the A2A peer, or vice-versa.
        let acpSink = ChunkSink()
        let acpSender = RelayACPTransport(
            maxFrameBytes: 4096, instanceSalt: "feedface",
            send: { chunk in await acpSink.record(chunk) })
        acpSender.send(#"{"method":"session/prompt"}"#)
        let acpChunks = await Self.waitChunks(acpSink, atLeast: 1)
        #expect(!acpChunks.isEmpty)
        for chunk in acpChunks {
            #expect(RelayACPTransport.isACPFrame(chunk), "ACP framer must produce ACP frames")
            #expect(!RelayA2ATransport.isA2AFrame(chunk), "an ACP1| frame is NOT an A2A frame")
        }

        // And an MCP1| frame must NOT be seen as an A2A frame either.
        let mcpSink = ChunkSink()
        let mcpSender = RelayMCPTransport(
            maxFrameBytes: 4096, instanceSalt: "cafebabe",
            send: { chunk in await mcpSink.record(chunk) })
        mcpSender.send(#"{"method":"tools/list"}"#)
        let mcpChunks = await Self.waitChunks(mcpSink, atLeast: 1)
        #expect(!mcpChunks.isEmpty)
        for chunk in mcpChunks {
            #expect(RelayMCPTransport.isMCPFrame(chunk), "MCP framer must produce MCP frames")
            #expect(!RelayA2ATransport.isA2AFrame(chunk), "an MCP1| frame is NOT an A2A frame")
        }

        // And the reverse: an A2A1| frame is neither an ACP frame nor an MCP frame.
        for chunk in a2aChunks {
            #expect(!RelayACPTransport.isACPFrame(chunk), "an A2A1| frame is NOT an ACP frame")
            #expect(!RelayMCPTransport.isMCPFrame(chunk), "an A2A1| frame is NOT an MCP frame")
        }

        // Plausible chat bodies — including near-misses — are none of the three.
        let chatBodies = [
            "hello there",
            #"{"jsonrpc":"2.0"}"#,  // a JSON line begins with '{', never a magic
            "A2A is a cool protocol",
            "A2A1 is the first version",  // 'A2A1' but no trailing '|'
            "A|2|A|1",  // pipe-delimited chat that is not the magic
            "A2A1",  // bare magic-ish, no delimiter
            "",
            "a2a1|lowercase|1|1|x",  // case-sensitive: lowercase magic is chat
            "ACP1|abc-1|1|1|",  // a bare ACP frame
            "MCP1|abc-1|1|1|",  // a bare MCP frame
        ]
        for body in chatBodies {
            #expect(!RelayA2ATransport.isA2AFrame(body), "chat body must not be seen as a frame: \(body)")
        }
    }

    /// ACP1 and A2A1 frames fed INTERLEAVED into a SHARED inbound routing step (each
    /// body routed to whichever transport's predicate claims it) reassemble on the
    /// correct transport ONLY — an A2A frame never completes on the ACP transport
    /// (and vice versa), proving the two relay-carried protocols can share one inbound
    /// message stream without cross-routing.
    @Test func interleavedACPAndA2AFrames_doNotCrossRoute() async throws {
        let maxFrame = 200
        let acpSink = ChunkSink()
        let acpSender = RelayACPTransport(
            maxFrameBytes: maxFrame, instanceSalt: "acp-salt",
            send: { chunk in await acpSink.record(chunk) })
        let (a2aSender, a2aSink) = Self.makeSender(maxFrameBytes: maxFrame, salt: "a2a-salt")

        let acpLine = #"{"id":"ACP","blob":""# + String(repeating: "A", count: 1_500) + #""}"#
        let a2aLine = #"{"id":"A2A","blob":""# + String(repeating: "B", count: 1_500) + #""}"#
        acpSender.send(acpLine)
        a2aSender.send(a2aLine)
        let acpChunks = await Self.waitChunks(acpSink, atLeast: 2)
        let a2aChunks = await Self.waitChunks(a2aSink, atLeast: 2)
        #expect(acpChunks.count > 1 && a2aChunks.count > 1)

        let acpReceiver = RelayACPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let acpReceived = ACPLineCollector()
        await acpReceived.attach(acpReceiver.inboundLines())
        let a2aReceiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let a2aReceived = ACPLineCollector()
        await a2aReceived.attach(a2aReceiver.inboundLines())

        // Route every chunk by its predicate — exactly the shared-inbound-stream
        // integration pattern — INTERLEAVED (A0, B0, A1, B1, …).
        let maxLen = max(acpChunks.count, a2aChunks.count)
        for i in 0..<maxLen {
            if i < acpChunks.count {
                let chunk = acpChunks[i]
                #expect(RelayACPTransport.isACPFrame(chunk))
                #expect(!RelayA2ATransport.isA2AFrame(chunk))
                await acpReceiver.deliverInbound(chunk)
                // A misrouted feed must be dropped, not partially reassembled.
                await a2aReceiver.deliverInbound(chunk)
            }
            if i < a2aChunks.count {
                let chunk = a2aChunks[i]
                #expect(RelayA2ATransport.isA2AFrame(chunk))
                #expect(!RelayACPTransport.isACPFrame(chunk))
                await a2aReceiver.deliverInbound(chunk)
                await acpReceiver.deliverInbound(chunk)
            }
        }

        let gotACP = await acpReceived.waitFor(1)
        let gotA2A = await a2aReceived.waitFor(1)
        #expect(gotACP == [acpLine], "the ACP transport must reassemble only its own line")
        #expect(gotA2A == [a2aLine], "the A2A transport must reassemble only its own line")
        // Cross-fed frames were rejected by the OTHER transport's parser (wrong magic),
        // so each transport's drop count reflects exactly the foreign chunks it saw.
        #expect(await acpReceiver.droppedFrameCount == a2aChunks.count)
        #expect(await a2aReceiver.droppedFrameCount == acpChunks.count)
    }

    // MARK: - (d) Interleaving / out-of-order (same-protocol)

    /// Two A2A lines' chunks delivered fully INTERLEAVED still reassemble to the right
    /// lines (reassembly is keyed by line-id, not arrival order).
    @Test func interleavedTwoLines_reassembleToCorrectLines() async throws {
        let maxFrame = 200
        let (senderA, sinkA) = Self.makeSender(maxFrameBytes: maxFrame, salt: "aaaa")
        let (senderB, sinkB) = Self.makeSender(maxFrameBytes: maxFrame, salt: "bbbb")
        let receiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let lineA = #"{"id":"A","blob":""# + String(repeating: "A", count: 1_500) + #""}"#
        let lineB = #"{"id":"B","blob":""# + String(repeating: "B", count: 1_500) + #""}"#
        senderA.send(lineA)
        senderB.send(lineB)
        let chunksA = await Self.waitChunks(sinkA, atLeast: 2)
        let chunksB = await Self.waitChunks(sinkB, atLeast: 2)
        #expect(chunksA.count > 1 && chunksB.count > 1)

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
        let receiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"method":"a2a/streamEvent","seq-test":""# + String(repeating: "Q", count: 2_000) + #""}"#
        sender.send(line)
        _ = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count > 2)

        for chunk in allChunks.reversed() { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// Two lines from ONE sender whose COMPLETE frames arrive in REVERSE order (the
    /// relay delivers each line as a separate, unordered event) must still emit in
    /// SENDER order — an `a2a/streamEvent` notification before the final JSON-RPC
    /// response that followed it. A raw arrival-order emit surfaces the terminal
    /// response first and a streaming consumer resolves the request before every
    /// event has been observed.
    @Test func twoLinesFromOneSender_emitInSenderOrder_whenDeliveredReversed() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "cccc")
        let receiver = RelayA2ATransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let first = #"{"jsonrpc":"2.0","method":"a2a/streamEvent","params":{"requestId":9,"event":{"kind":"status-update"}}}"#
        let second = #"{"jsonrpc":"2.0","id":9,"result":{"kind":"task","status":{"state":"completed"}}}"#
        sender.send(first)
        sender.send(second)
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        #expect(chunks.count == 2, "each short line frames to a single chunk")

        let firstFrame = chunks.first { Self.lineIndex(of: $0) == 0 }
        let secondFrame = chunks.first { Self.lineIndex(of: $0) == 1 }
        #expect(firstFrame != nil && secondFrame != nil, "indices 0 and 1 must both be present")

        // The relay reordering: the SECOND line (the final response) is delivered FIRST.
        await receiver.deliverInbound(secondFrame!)
        await receiver.deliverInbound(firstFrame!)

        let got = await lines.waitFor(2)
        #expect(
            got == [first, second],
            "lines must emit in SENDER order (event before its final response), not arrival order; got \(got)")
    }

    /// A line that completes while an EARLIER line is still missing is held back,
    /// then both flush in order once the gap fills — the buffering half of the
    /// ordering guarantee (no premature emit, no lost line).
    @Test func laterLineHeldUntilEarlierArrives() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "dddd")
        let receiver = RelayA2ATransport(maxFrameBytes: 4096, send: { _ in })
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
        let receiver = RelayA2ATransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = String(repeating: "P", count: 2_000)
        sender.send(line)
        _ = await Self.waitChunks(sink, atLeast: 3)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count >= 3)

        // Deliver every chunk EXCEPT one (drop the middle one). The line must never
        // appear on inboundLines.
        let dropIndex = allChunks.count / 2
        for (i, chunk) in allChunks.enumerated() where i != dropIndex {
            await receiver.deliverInbound(chunk)
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await lines.all().isEmpty, "a line missing a chunk must never emit")

        // Then delivering the missing chunk completes it — proving the partial was
        // buffered, not discarded.
        await receiver.deliverInbound(allChunks[dropIndex])
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    /// A garbage / non-frame body fed to `deliverInbound` is dropped (counted) and
    /// never emits — the integration only routes `isA2AFrame` bodies here, but the
    /// entry point must be defensive anyway.
    @Test func malformedFrame_isDroppedNotEmitted() async throws {
        let receiver = RelayA2ATransport(maxFrameBytes: 256, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        await receiver.deliverInbound("not a frame at all")
        await receiver.deliverInbound("A2A1|onlyfourfields|1|1")  // missing payload delimiter
        await receiver.deliverInbound("A2A1|id|0|2|AAAA")  // seq 0 invalid
        await receiver.deliverInbound("A2A1|id|3|2|AAAA")  // seq > total
        await receiver.deliverInbound("A2A1|id|1|2|!!!notb64!!!")  // bad payload
        await receiver.deliverInbound("ACP1|id|1|1|AAAA")  // an ACP frame is not ours
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await lines.all().isEmpty)
        #expect(await receiver.droppedFrameCount >= 6)
    }

    // MARK: - Reassembly is bounded (memory safety)

    /// A line missing any chunk never emits — and must never be retained forever.
    ///
    /// `maxReorderBuffer` bounds the ORDER buffer (`pendingLines`); the CHUNK buffer
    /// (`reassembly`) had no bound at all, so on a lossy relay every dropped chunk
    /// permanently pinned the rest of its line, and a peer could grow the map without
    /// limit by sending one `seq` of each of many distinct `lineId`s. Also pins the
    /// `total` cap: `total` is a wire value and the parse admits up to `UInt32.max`.
    @Test func reassembly_boundsIncompleteLines_andRejectsAbsurdTotal() async throws {
        let receiver = RelayA2ATransport(maxFrameBytes: 4096, send: { _ in })
        let payload = RelayFraming.base64URLEncode(Data("x".utf8))

        // An absurd `total` is refused outright — no entry is created for it.
        await receiver.deliverInbound("A2A1|absurd-1|1|999999|\(payload)")
        #expect(await receiver.droppedFrameCount == 1)
        #expect(await receiver.pendingReassemblyCount == 0)

        // Flood with lines that can never complete: each declares 2 chunks, only
        // chunk 1 ever arrives. Unbounded, this would retain every one of them.
        let flood = RelayFraming.maxPendingReassemblies + 50
        for i in 0..<flood {
            await receiver.deliverInbound("A2A1|leak\(i)-1|1|2|\(payload)")
        }
        #expect(await receiver.pendingReassemblyCount <= RelayFraming.maxPendingReassemblies)

        // The bound must not break a legitimate line: a complete 2-chunk line still
        // reassembles byte-exactly after the flood. The lineId's base36 tail is the
        // SENDER-ORDER index and `nextEmit` starts at 0, so this line must be index 0
        // or `emitInOrder` correctly holds it waiting for the gap to fill.
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())
        let a = RelayFraming.base64URLEncode(Data("{\"ok\":".utf8))
        let b = RelayFraming.base64URLEncode(Data("true}".utf8))
        await receiver.deliverInbound("A2A1|good-0|1|2|\(a)")
        await receiver.deliverInbound("A2A1|good-0|2|2|\(b)")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await lines.all() == ["{\"ok\":true}"])
    }
}
