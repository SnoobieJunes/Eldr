// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import A2AClient
import A2ACore

/// A `URLProtocol` stub that lets tests script an HTTP response (status, headers)
/// plus an ordered sequence of body chunks delivered across multiple
/// `urlProtocol(_:didLoad:)` calls, so streaming (SSE) responses can be exercised
/// with awkward chunk boundaries.
final class StubURLProtocol: URLProtocol {
    struct Response {
        var statusCode: Int
        var headers: [String: String] = [:]
        var chunks: [Data]
    }

    /// Not actor-isolated: tests set this once, serially, before making requests.
    /// `URLProtocol`'s class-side hooks are called by the URL loading system off
    /// the calling thread, so this needs to be readable there.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Response)?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let response = try handler(request)
            guard let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let httpResponse = HTTPURLResponse(
                url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1",
                headerFields: response.headers)!
            client?.urlProtocol(
                self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in response.chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite(.serialized) struct HTTPTransportTests {
    @Test func unarySendPostsHeadersAndDecodesResult() async throws {
        nonisolated(unsafe) var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let body = try A2AWireCodec.encode(
                JSONRPCResponse(id: .int(1), result: A2AJSONValue.object(["ok": true])))
            return StubURLProtocol.Response(statusCode: 200, chunks: [body])
        }
        defer { StubURLProtocol.handler = nil }

        let transport = HTTPJSONRPCTransport(
            endpoint: URL(string: "https://agent.example/rpc")!,
            session: stubSession(),
            auth: A2ABearerAuth(token: "secret-token"))

        let request = try JSONRPCRequest(
            id: .int(1), method: A2AMethod.getTask,
            params: A2AGetTaskRequest(id: "t1"))
        let response = try await transport.send(request)

        #expect(response.result == .object(["ok": true]))

        let sent = try #require(capturedRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "A2A-Version") == A2AVersion.current)
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    @Test func unaryJSONRPCErrorInHTTP200SurfacesAsEndpointError() async throws {
        StubURLProtocol.handler = { _ in
            let body = try A2AWireCodec.encode(
                JSONRPCResponse(
                    id: .int(1),
                    error: A2AErrorObject(code: .taskNotFound, message: "no such task")))
            return StubURLProtocol.Response(statusCode: 200, chunks: [body])
        }
        defer { StubURLProtocol.handler = nil }

        let transport = HTTPJSONRPCTransport(
            endpoint: URL(string: "https://agent.example/rpc")!, session: stubSession())
        let request = try JSONRPCRequest(
            id: .int(1), method: A2AMethod.getTask, params: A2AGetTaskRequest(id: "missing"))
        let response = try await transport.send(request)

        #expect(throws: A2AClientError.endpoint(
            A2AErrorObject(code: .taskNotFound, message: "no such task"))
        ) {
            _ = try response.decodeResult(A2ATask.self)
        }
    }

    @Test func nonJSONBodyOnNon2xxSurfacesHTTPStatus() async throws {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(
                statusCode: 503, chunks: [Data("service unavailable".utf8)])
        }
        defer { StubURLProtocol.handler = nil }

        let transport = HTTPJSONRPCTransport(
            endpoint: URL(string: "https://agent.example/rpc")!, session: stubSession())
        let request = try JSONRPCRequest(
            id: .int(1), method: A2AMethod.getTask, params: A2AGetTaskRequest(id: "t1"))

        await #expect(throws: A2AClientError.httpStatus(503)) {
            _ = try await transport.send(request)
        }
    }

    @Test func streamDeliversEventsAcrossAwkwardChunkBoundaries() async throws {
        let workingFrame = """
            {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t1","contextId":"c1","status":{"state":"TASK_STATE_WORKING"}}}}
            """
        let completedFrame = """
            {"jsonrpc":"2.0","id":1,"result":{"statusUpdate":{"taskId":"t1","contextId":"c1","status":{"state":"TASK_STATE_COMPLETED"}}}}
            """
        let sseBody = "data: \(workingFrame)\n\ndata: \(completedFrame)\n\n"
        let bytes = Array(sseBody.utf8)

        // Split into 3 chunks at awkward (mid-line) boundaries.
        let cut1 = bytes.count / 3
        let cut2 = (2 * bytes.count) / 3
        let chunks = [
            Data(bytes[0..<cut1]),
            Data(bytes[cut1..<cut2]),
            Data(bytes[cut2...]),
        ]

        StubURLProtocol.handler = { _ in
            StubURLProtocol.Response(
                statusCode: 200, headers: ["Content-Type": "text/event-stream"],
                chunks: chunks)
        }
        defer { StubURLProtocol.handler = nil }

        let transport = HTTPJSONRPCTransport(
            endpoint: URL(string: "https://agent.example/rpc")!, session: stubSession())
        let request = try JSONRPCRequest(
            id: .int(1), method: A2AMethod.subscribeToTask,
            params: A2ASubscribeToTaskRequest(id: "t1"))

        var states: [A2ATaskState] = []
        for try await event in transport.stream(request) {
            guard case .statusUpdate(let update) = event else {
                Issue.record("expected a statusUpdate event, got \(event)")
                continue
            }
            states.append(update.status.state)
        }

        #expect(states == [.working, .completed])
    }
}
