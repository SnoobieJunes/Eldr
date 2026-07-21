// SPDX-License-Identifier: Apache-2.0
import Foundation

// An incremental `text/event-stream` (SSE) parser, per the WHATWG HTML spec §9.2
// ("Server-Sent Events"). Used to decode the A2A streaming JSON-RPC binding
// (SendStreamingMessage / SubscribeToTask) over `text/event-stream` bodies.
//
// The parser never logs event payloads (PRIVACY RULE) — it only shuttles bytes.

/// A single parsed SSE event: the optional `event:` name, the accumulated `data:`
/// payload (multiple `data:` lines join with `\n`), and the optional `id:`.
public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental SSE parser: feed it arbitrary byte chunks (which may split a record
/// or even a line ending at any boundary) and it yields complete events as they
/// close out on a blank line.
public struct SSEParser: Sendable {
    /// Bytes carried over from a previous `feed` call that have not yet formed a
    /// complete line.
    private var pendingBytes: [UInt8] = []
    /// Fields accumulated for the record currently being parsed.
    private var currentEvent: String?
    private var currentData: String?
    private var currentID: String?
    /// True right after we consumed a `\r` and are waiting to see whether the next
    /// byte is its paired `\n` (so a `\r\n` split across chunks isn't seen as two
    /// line breaks).
    private var sawCarriageReturn = false

    public init() {}

    /// Feed a chunk of raw bytes from the wire. Returns any events completed by
    /// this chunk (a chunk may complete zero, one, or several events).
    public mutating func feed(_ chunk: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if sawCarriageReturn {
                sawCarriageReturn = false
                if byte == UInt8(ascii: "\n") {
                    // Completed a \r\n pair; the line itself already broke on \r.
                    continue
                }
                // Bare \r line ending; fall through and process `byte` normally.
            }
            if byte == UInt8(ascii: "\r") {
                sawCarriageReturn = true
                completeLine(&events)
                continue
            }
            if byte == UInt8(ascii: "\n") {
                completeLine(&events)
                continue
            }
            pendingBytes.append(byte)
        }
        return events
    }

    /// Emit a final, un-terminated record (some servers close the connection
    /// without a trailing blank line). Only emits if there is pending data.
    public mutating func flush() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !pendingBytes.isEmpty {
            completeLine(&events)
        }
        if let event = finishRecord() {
            events.append(event)
        }
        return events
    }

    /// Process `pendingBytes` as one completed line, then reset the byte buffer.
    private mutating func completeLine(_ events: inout [SSEEvent]) {
        let line = String(decoding: pendingBytes, as: UTF8.self)
        pendingBytes.removeAll(keepingCapacity: true)

        if line.isEmpty {
            // Blank line: dispatch the accumulated record, if any.
            if let event = finishRecord() {
                events.append(event)
            }
            return
        }
        parseField(line)
    }

    /// Parse one non-blank SSE line into the in-progress record's fields.
    private mutating func parseField(_ line: String) {
        if line.hasPrefix(":") {
            // Comment line; ignored.
            return
        }
        let field: Substring
        let value: Substring
        if let colonIndex = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colonIndex]
            var rest = line[line.index(after: colonIndex)...]
            if rest.first == " " {
                rest = rest.dropFirst()
            }
            value = rest
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "event":
            currentEvent = String(value)
        case "data":
            if let existing = currentData {
                currentData = existing + "\n" + value
            } else {
                currentData = String(value)
            }
        case "id":
            currentID = String(value)
        default:
            // Unknown fields (and "retry") are ignored.
            break
        }
    }

    /// Build and reset the in-progress record. An event with no data and no event
    /// name is dropped per the spec (a blank record dispatches nothing useful).
    private mutating func finishRecord() -> SSEEvent? {
        defer {
            currentEvent = nil
            currentData = nil
            currentID = nil
        }
        guard currentData != nil || currentEvent != nil else { return nil }
        let data = currentData ?? ""
        guard !data.isEmpty || currentEvent != nil else { return nil }
        return SSEEvent(event: currentEvent, data: data, id: currentID)
    }
}
