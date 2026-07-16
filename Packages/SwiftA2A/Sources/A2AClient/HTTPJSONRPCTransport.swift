import A2ACore
import Foundation

/// The standard A2A HTTP(S) JSON-RPC 1.0 binding (docs/specification.md §9): a POST
/// of the JSON-RPC envelope to a single endpoint URL, unary responses as
/// `application/json`, streaming responses as `text/event-stream`.
///
/// A plain `struct` — it holds no mutable state (`URLSession` is itself `Sendable`),
/// so no actor is needed here; the mutable request-id counter lives in `A2AClient`.
public struct HTTPJSONRPCTransport: A2AClientTransport {
    private let endpoint: URL
    private let session: URLSession
    private let auth: (any A2AAuthProvider)?
    private let activeExtensions: [String]

    public init(
        endpoint: URL, session: URLSession = .shared, auth: (any A2AAuthProvider)? = nil,
        activeExtensions: [String] = []
    ) {
        self.endpoint = endpoint
        self.session = session
        self.auth = auth
        self.activeExtensions = activeExtensions
    }

    /// Maximum bytes read from a non-2xx streaming response while probing for a
    /// JSON-RPC error envelope.
    private static let errorBodySampleLimit = 64 * 1024
    /// Maximum characters of a malformed body echoed back in an error message.
    private static let malformedBodyPreviewLimit = 200

    private func makeRequest(for rpcRequest: JSONRPCRequest, streaming: Bool) async throws
        -> URLRequest
    {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try A2AWireCodec.encode(rpcRequest)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(A2AVersion.current, forHTTPHeaderField: A2AVersion.headerName)
        urlRequest.setValue(
            streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept")
        if !activeExtensions.isEmpty {
            urlRequest.setValue(
                activeExtensions.joined(separator: ","),
                forHTTPHeaderField: A2AVersion.extensionsHeaderName)
        }
        if let auth, let header = try await auth.authorizationHeader() {
            urlRequest.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return urlRequest
    }

    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        let urlRequest = try await makeRequest(for: request, streaming: false)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw A2AClientError.malformedResponse("response is not an HTTP response")
        }

        // JSON-RPC errors may legitimately ride on a non-2xx HTTP status, so try
        // decoding the envelope before consulting the status code.
        if let decoded = try? A2AWireCodec.decode(JSONRPCResponse.self, from: data) {
            return decoded
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw A2AClientError.httpStatus(httpResponse.statusCode)
        }
        let preview = String(decoding: data, as: UTF8.self)
            .prefix(Self.malformedBodyPreviewLimit)
        throw A2AClientError.malformedResponse(
            "2xx response is not valid JSON-RPC: \(preview)")
    }

    public func stream(_ request: JSONRPCRequest) -> AsyncThrowingStream<
        A2AStreamResponse, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try await makeRequest(for: request, streaming: true)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw A2AClientError.malformedResponse(
                            "response is not an HTTP response")
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        try await Self.throwStreamOpenError(
                            status: httpResponse.statusCode, bytes: bytes)
                        return
                    }

                    var parser = SSEParser()
                    var batch: [UInt8] = []
                    batch.reserveCapacity(1024)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        batch.append(byte)
                        if batch.count >= 1024 {
                            for event in parser.feed(batch) {
                                try Self.yield(event, to: continuation)
                            }
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                    if !batch.isEmpty {
                        for event in parser.feed(batch) {
                            try Self.yield(event, to: continuation)
                        }
                    }
                    for event in parser.flush() {
                        try Self.yield(event, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func yield(
        _ event: SSEEvent, to continuation: AsyncThrowingStream<A2AStreamResponse, Error>
            .Continuation
    ) throws {
        let response = try A2AWireCodec.decode(JSONRPCResponse.self, from: event.data)
        let payload = try response.decodeResult(A2AStreamResponse.self)
        continuation.yield(payload)
    }

    /// A non-2xx status on the initial streaming response: try to recover a
    /// JSON-RPC error envelope from the (bounded) body, else surface the raw
    /// HTTP status.
    private static func throwStreamOpenError(
        status: Int, bytes: URLSession.AsyncBytes
    ) async throws {
        var sample: [UInt8] = []
        sample.reserveCapacity(min(errorBodySampleLimit, 4096))
        for try await byte in bytes {
            sample.append(byte)
            if sample.count >= errorBodySampleLimit { break }
        }
        if let decoded = try? A2AWireCodec.decode(
            JSONRPCResponse.self, from: Data(sample)),
            let error = decoded.error
        {
            throw A2AClientError.endpoint(error)
        }
        throw A2AClientError.httpStatus(status)
    }

    public func close() async {
        // URLSession (including `.shared`) needs no explicit teardown here.
    }
}
