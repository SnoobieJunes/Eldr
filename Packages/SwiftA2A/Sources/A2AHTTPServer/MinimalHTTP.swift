// SPDX-License-Identifier: Apache-2.0
#if os(macOS)

import Foundation

// A deliberately minimal HTTP/1.1 request parser + response writer for the loopback
// A2A HTTP binding. Not a general-purpose HTTP server: no chunked transfer-encoding,
// no keep-alive, no pipelining, no TLS (loopback-only traffic never leaves the
// device — see `A2AHTTPServer`). One request per connection is enough for a v1.0
// SDK server surface that only ever talks to `A2AClient`-shaped callers on the same
// machine.

/// A fully-parsed HTTP/1.1 request (request line + headers + body).
struct MinimalHTTPRequest: Sendable {
    var method: String
    var target: String
    /// Header names are lowercased for case-insensitive lookup.
    var headers: [String: String]
    var body: Data
}

enum MinimalHTTPParseError: Error, Sendable, Equatable {
    case headerTooLarge
    case malformedRequestLine
    case unsupportedMethod
    case bodyTooLarge
}

enum MinimalHTTP {
    /// Hard cap on request bodies (PRIVACY/SAFETY: an unbounded body from a
    /// loopback-only server is still a local-DoS vector worth bounding).
    static let maxBodyBytes = 1 * 1024 * 1024
    /// Hard cap on the header block, applied before we've even parsed
    /// `Content-Length`, so a client can't hang the parser with an endless header
    /// stream.
    private static let maxHeaderBytes = 32 * 1024
    private static let headerTerminator = Data([13, 10, 13, 10])  // "\r\n\r\n"

    /// Attempt to parse a complete request out of everything received so far.
    /// Returns `nil` when more bytes are needed (the caller should `receive` again);
    /// throws when the bytes received so far can never form a valid request the
    /// server accepts, so the caller can answer 400 and close.
    static func parse(buffer: Data) throws -> MinimalHTTPRequest? {
        guard let headerRange = buffer.range(of: headerTerminator) else {
            if buffer.count > maxHeaderBytes { throw MinimalHTTPParseError.headerTooLarge }
            return nil
        }

        let headerText = String(
            decoding: buffer[buffer.startIndex..<headerRange.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw MinimalHTTPParseError.malformedRequestLine }
        let requestLine = lines.removeFirst()
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else { throw MinimalHTTPParseError.malformedRequestLine }
        let method = String(requestParts[0])
        let target = String(requestParts[1])
        guard method == "GET" || method == "POST" else {
            throw MinimalHTTPParseError.unsupportedMethod
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard contentLength >= 0, contentLength <= maxBodyBytes else {
            throw MinimalHTTPParseError.bodyTooLarge
        }
        guard buffer.count >= bodyStart + contentLength else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        return MinimalHTTPRequest(method: method, target: target, headers: headers, body: body)
    }

    // MARK: - Response writers

    /// A unary response: a full status line, `Content-Length`, `Connection: close`,
    /// any extra headers, then the body.
    static func response(
        status: Int, reason: String, headers: [(String, String)] = [], body: Data = Data()
    ) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    /// The head of an SSE response — no `Content-Length` (the body is a stream);
    /// the connection close on stream end is what tells the client the response is
    /// complete.
    static func sseHead(status: Int = 200, reason: String = "OK") -> Data {
        let head =
            "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/event-stream\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8)
    }

    /// One SSE `data:` frame for a single-line payload (our JSON-RPC lines never
    /// contain embedded newlines — `A2AWireCodec` encodes without pretty-printing).
    static func sseFrame(_ line: String) -> Data {
        Data("data: \(line)\n\n".utf8)
    }
}

#endif
