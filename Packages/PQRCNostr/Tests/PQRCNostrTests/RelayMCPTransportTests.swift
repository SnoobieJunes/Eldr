// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Testing

@testable import PQRCNostr

/// Phase D3: `RelayMCPTransport` carries the MCP line protocol over the relay (the
/// gift-wrapped + ratcheted message mesh) so the paired Mac's coding agent can USE
/// the phone's MCP chat tools. This suite proves the framing/chunking envelope, the
/// reassembly machinery, and — load-bearing for routing safety — that an `MCP1|`
/// frame is un-confusable with an `ACP1|` frame and with a JSON-RPC `{` line. No
/// messenger, no relay, no radios: the transport is decoupled behind a `send`
/// closure and a `deliverInbound` entry point. (TEST-PLAN §1.)
@Suite("Relay MCP transport (Phase D3)", .tags(.transport, .security))
struct RelayMCPTransportTests {
    /// Captures every framed chunk a transport's `send` closure publishes.
    actor ChunkSink {
        private var chunks: [String] = []
        func record(_ chunk: String) { chunks.append(chunk) }
        func all() -> [String] { chunks }
        func count() -> Int { chunks.count }
    }

    static func makeSender(maxFrameBytes: Int, salt: String? = nil) -> (RelayMCPTransport, ChunkSink) {
        let sink = ChunkSink()
        let transport = RelayMCPTransport(
            maxFrameBytes: maxFrameBytes, instanceSalt: salt,
            send: { chunk in await sink.record(chunk) })
        return (transport, sink)
    }

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

    static func lineIndex(of frame: String) -> UInt64 {
        let parts = frame.split(separator: "|")
        guard parts.count > 1 else { return .max }
        let tail = parts[1].split(separator: "-").last.map(String.init) ?? ""
        return UInt64(tail, radix: 36) ?? .max
    }

    // MARK: - (a) Round trip

    @Test func roundTrip_lineIsByteIdenticalAfterFrameAndReassemble() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayMCPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // A realistic MCP request (the node→phone tools/call).
        let line =
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_conversation","arguments":{"conversationID":"abc","limit":20}}}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    @Test func roundTrip_multibyteAndDelimiterCharsSurvive() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096)
        let receiver = RelayMCPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"text":"a|b|c piñata 🚀 \"quoted\" back\\slash"}"#
        sender.send(line)
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    @Test func roundTrip_emptyLine() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 256)
        let receiver = RelayMCPTransport(maxFrameBytes: 256, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        sender.send("")
        let chunks = await Self.waitChunks(sink, atLeast: 1)
        #expect(chunks.count == 1)
        for chunk in chunks { await receiver.deliverInbound(chunk) }

        let got = await lines.waitFor(1)
        #expect(got.first == "")
    }

    // MARK: - (b) Chunking (a large redacted transcript result)

    @Test func chunking_largeLineSplitsUnderBudgetAndReassemblesExactly() async throws {
        let maxFrame = 256
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayMCPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        // A tools/call RESULT carrying a large (still ≤64 KB) redacted transcript.
        let big =
            #"{"jsonrpc":"2.0","id":4,"result":{"content":[{"type":"text","text":""#
            + String(repeating: "X", count: 20_000) + #""}],"isError":false}}"#
        sender.send(big)

        let chunks = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(50))
        let allChunks = await sink.all()
        #expect(allChunks.count > 1, "a 20 KB line must split into multiple chunks under a 256-byte budget")
        for chunk in allChunks {
            #expect(chunk.utf8.count <= maxFrame)
            #expect(RelayMCPTransport.isMCPFrame(chunk))
        }
        _ = chunks
        for chunk in allChunks { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == big)
    }

    // MARK: - (c) Frame discrimination — the load-bearing routing-safety proof

    @Test func isMCPFrame_trueForMCP_falseForChatAndACP() async {
        // Real MCP frames are recognized.
        let (mcpSender, mcpSink) = Self.makeSender(maxFrameBytes: 4096, salt: "deadbeef")
        mcpSender.send(#"{"method":"tools/list"}"#)
        let mcpChunks = await Self.waitChunks(mcpSink, atLeast: 1)
        #expect(!mcpChunks.isEmpty)
        for chunk in mcpChunks { #expect(RelayMCPTransport.isMCPFrame(chunk)) }

        // CRITICAL: an ACP1| frame must NOT be seen as an MCP frame (the two relay
        // transports share one inbound stream; misrouting would feed an ACP control
        // line to the MCP server, or vice-versa).
        let acpSink = RelayMCPTransportTests.ChunkSink()
        let acpSender = RelayACPTransport(
            maxFrameBytes: 4096, instanceSalt: "feedface",
            send: { chunk in await acpSink.record(chunk) })
        acpSender.send(#"{"method":"session/prompt"}"#)
        var acpWaited = 0
        while await acpSink.count() < 1 && acpWaited < 5_000 {
            try? await Task.sleep(for: .milliseconds(5))
            acpWaited += 5
        }
        let acpChunks = await acpSink.all()
        #expect(!acpChunks.isEmpty)
        for chunk in acpChunks {
            #expect(RelayACPTransport.isACPFrame(chunk), "ACP framer must produce ACP frames")
            #expect(!RelayMCPTransport.isMCPFrame(chunk), "an ACP1| frame is NOT an MCP frame")
        }
        // And the reverse: an MCP1| frame is not an ACP frame.
        for chunk in mcpChunks {
            #expect(!RelayACPTransport.isACPFrame(chunk), "an MCP1| frame is NOT an ACP frame")
        }

        // Plausible chat bodies — including near-misses — are neither.
        let chatBodies = [
            "hello there",
            #"{"jsonrpc":"2.0"}"#,
            "MCP is a cool protocol",
            "MCP1 is the first version",  // 'MCP1' but no trailing '|'
            "M|C|P|1",
            "MCP1",
            "",
            "mcp1|lowercase|1|1|x",  // case-sensitive
            "ACP1|abc-1|1|1|",  // a bare ACP frame
        ]
        for body in chatBodies {
            #expect(!RelayMCPTransport.isMCPFrame(body), "must not be seen as an MCP frame: \(body)")
        }
    }

    // MARK: - (d) Out-of-order / interleave / partial

    @Test func outOfOrderChunks_reassembleExactly() async throws {
        let maxFrame = 200
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayMCPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = #"{"method":"tools/call","seq-test":""# + String(repeating: "Q", count: 2_000) + #""}"#
        sender.send(line)
        _ = await Self.waitChunks(sink, atLeast: 2)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count > 2)

        for chunk in allChunks.reversed() { await receiver.deliverInbound(chunk) }
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    @Test func twoLinesFromOneSender_emitInSenderOrder_whenDeliveredReversed() async throws {
        let (sender, sink) = Self.makeSender(maxFrameBytes: 4096, salt: "cccc")
        let receiver = RelayMCPTransport(maxFrameBytes: 4096, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let first = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        let second = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        sender.send(first)
        sender.send(second)
        let chunks = await Self.waitChunks(sink, atLeast: 2)
        #expect(chunks.count == 2)

        let firstFrame = chunks.first { Self.lineIndex(of: $0) == 0 }
        let secondFrame = chunks.first { Self.lineIndex(of: $0) == 1 }
        #expect(firstFrame != nil && secondFrame != nil)

        await receiver.deliverInbound(secondFrame!)
        await receiver.deliverInbound(firstFrame!)

        let got = await lines.waitFor(2)
        #expect(got == [first, second], "lines must emit in SENDER order; got \(got)")
    }

    @Test func missingChunk_neverEmits() async throws {
        let maxFrame = 200
        let (sender, sink) = Self.makeSender(maxFrameBytes: maxFrame)
        let receiver = RelayMCPTransport(maxFrameBytes: maxFrame, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        let line = String(repeating: "P", count: 2_000)
        sender.send(line)
        _ = await Self.waitChunks(sink, atLeast: 3)
        try? await Task.sleep(for: .milliseconds(40))
        let allChunks = await sink.all()
        #expect(allChunks.count >= 3)

        let dropIndex = allChunks.count / 2
        for (i, chunk) in allChunks.enumerated() where i != dropIndex {
            await receiver.deliverInbound(chunk)
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await lines.all().isEmpty, "a line missing a chunk must never emit")

        await receiver.deliverInbound(allChunks[dropIndex])
        let got = await lines.waitFor(1)
        #expect(got.first == line)
    }

    @Test func malformedFrame_isDroppedNotEmitted() async throws {
        let receiver = RelayMCPTransport(maxFrameBytes: 256, send: { _ in })
        let lines = ACPLineCollector()
        await lines.attach(receiver.inboundLines())

        await receiver.deliverInbound("not a frame at all")
        await receiver.deliverInbound("MCP1|onlyfourfields|1|1")  // missing payload delimiter
        await receiver.deliverInbound("MCP1|id|0|2|AAAA")  // seq 0 invalid
        await receiver.deliverInbound("MCP1|id|3|2|AAAA")  // seq > total
        await receiver.deliverInbound("ACP1|id|1|1|AAAA")  // an ACP frame is not ours
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await lines.all().isEmpty)
        #expect(await receiver.droppedFrameCount >= 5)
    }
}
