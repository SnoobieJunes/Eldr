// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import A2AClient

@Suite struct SSEParserTests {
    @Test func singleEvent() {
        var parser = SSEParser()
        let bytes = Array("data: hello\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [SSEEvent(event: nil, data: "hello", id: nil)])
    }

    @Test func multipleEventsOneChunk() {
        var parser = SSEParser()
        let bytes = Array("data: first\n\ndata: second\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [
            SSEEvent(data: "first"),
            SSEEvent(data: "second"),
        ])
    }

    @Test func eventSplitAcrossChunksMidLine() {
        let full = "event: update\ndata: hello world\nid: 42\n\n"
        var parser = SSEParser()
        var events: [SSEEvent] = []
        // Split in the middle of "data: hello world" and other lines.
        let splitPoint = full.utf8.count / 2
        let bytes = Array(full.utf8)
        events += parser.feed(bytes[0..<splitPoint])
        events += parser.feed(bytes[splitPoint...])
        #expect(events == [SSEEvent(event: "update", data: "hello world", id: "42")])
    }

    @Test func eventSplitAcrossChunksMidCRLF() {
        let full = "data: hello\r\n\r\n"
        let bytes = Array(full.utf8)
        // Find the \r\n\r\n and split right between the first \r and \n.
        guard let crIndex = bytes.firstIndex(of: UInt8(ascii: "\r")) else {
            Issue.record("fixture missing \\r")
            return
        }
        var parser = SSEParser()
        var events: [SSEEvent] = []
        events += parser.feed(bytes[0...crIndex])
        events += parser.feed(bytes[(crIndex + 1)...])
        #expect(events == [SSEEvent(data: "hello")])
    }

    @Test func byteByByteFeedMatchesWholeChunkFeed() {
        let full = "event: update\r\ndata: line one\r\ndata: line two\r\nid: 7\r\n\r\n"
        let bytes = Array(full.utf8)

        var wholeParser = SSEParser()
        let wholeEvents = wholeParser.feed(bytes)

        var byteParser = SSEParser()
        var byteEvents: [SSEEvent] = []
        for byte in bytes {
            byteEvents += byteParser.feed([byte])
        }

        #expect(wholeEvents == byteEvents)
        #expect(wholeEvents == [SSEEvent(event: "update", data: "line one\nline two", id: "7")])
    }

    @Test func multiLineDataJoinedWithNewline() {
        var parser = SSEParser()
        let bytes = Array("data: line1\ndata: line2\ndata: line3\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [SSEEvent(data: "line1\nline2\nline3")])
    }

    @Test func commentLinesIgnored() {
        var parser = SSEParser()
        let bytes = Array(": this is a comment\ndata: real\n: another comment\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [SSEEvent(data: "real")])
    }

    @Test func dataFieldWithAndWithoutSpaceAfterColon() {
        var parser = SSEParser()
        let bytes = Array("data:no-space\n\ndata: with-space\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [
            SSEEvent(data: "no-space"),
            SSEEvent(data: "with-space"),
        ])
    }

    @Test func flushEmitsTrailingRecordWithoutBlankLine() {
        var parser = SSEParser()
        let mid = parser.feed(Array("data: unterminated".utf8))
        #expect(mid.isEmpty)
        let flushed = parser.flush()
        #expect(flushed == [SSEEvent(data: "unterminated")])
    }

    @Test func flushEmitsNothingWhenNoPendingData() {
        var parser = SSEParser()
        _ = parser.feed(Array("data: complete\n\n".utf8))
        let flushed = parser.flush()
        #expect(flushed.isEmpty)
    }

    @Test func crlfLineEndings() {
        var parser = SSEParser()
        let bytes = Array("event: ping\r\ndata: payload\r\n\r\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [SSEEvent(event: "ping", data: "payload")])
    }

    @Test func eventWithEmptyDataAndNoNameIsNotEmitted() {
        var parser = SSEParser()
        // A lone comment/blank record: nothing to dispatch.
        let bytes = Array(": keepalive\n\n".utf8)
        let events = parser.feed(bytes)
        #expect(events.isEmpty)
    }
}
