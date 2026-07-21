// SPDX-License-Identifier: Apache-2.0
#if os(macOS)

import A2ACore
import A2AHTTPServer
import A2AServer
import Foundation
import Testing

// Loopback smoke tests: a real `A2AHTTPServer` on an ephemeral port, driven with
// `URLSession` from inside the test process. This is the one place in the suite
// that touches real sockets — acceptable per the task brief, since it's exercising
// the actual macOS Network.framework binding end to end, not core protocol logic
// (that's `A2AServerTests`, which drives `A2AServer.handle` directly, no sockets).

private actor TrivialExecutor: AgentExecutor {
    func execute(
        task: A2ATask, request: A2ASendMessageRequest, events: any TaskEventSink
    ) async throws -> A2ATaskStatus {
        await events.status(A2ATaskStatus(state: .working))
        return A2ATaskStatus(state: .completed)
    }

    func cancel(taskId: String) async {}
}

private func makeCard() -> A2AAgentCard {
    A2AAgentCard(
        name: "HTTP Test Agent", description: "loopback smoke test",
        supportedInterfaces: [], version: "1.0",
        capabilities: A2AAgentCapabilities(streaming: true))
}

@Suite struct A2AHTTPServerTests {
    private static let token = "s3cr3t-test-token"

    private func startServer() async throws -> (server: A2AHTTPServer, port: UInt16) {
        let core = A2AServer(card: makeCard(), executor: TrivialExecutor())
        let http = A2AHTTPServer(
            server: core, card: makeCard(),
            authenticator: BearerAuthenticator(token: Self.token), port: 0)
        let port = try await http.start()
        return (http, port)
    }

    private func cardURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/.well-known/agent-card.json")!
    }

    private func rpcURL(port: UInt16) -> URL {
        URL(string: "http://127.0.0.1:\(port)/a2a")!
    }

    @Test func cardFetchWithoutTokenIs401() async throws {
        let (server, port) = try await startServer()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: cardURL(port: port))
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 401)
    }

    @Test func cardFetchWithTokenReturnsDecodableCard() async throws {
        let (server, port) = try await startServer()
        defer { Task { await server.stop() } }

        var request = URLRequest(url: cardURL(port: port))
        request.httpMethod = "GET"
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let card = try A2AWireCodec.decode(A2AAgentCard.self, from: data)
        #expect(card.name == "HTTP Test Agent")
    }

    @Test func sendMessageOverHTTPReturnsCompletedTask() async throws {
        let (server, port) = try await startServer()
        defer { Task { await server.stop() } }

        let params = A2ASendMessageRequest(message: A2AMessage(role: .user, parts: [.text("hi")]))
        let rpcRequest = try JSONRPCRequest(id: .int(1), method: .sendMessage, params: params)
        var request = URLRequest(url: rpcURL(port: port))
        request.httpMethod = "POST"
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.setValue(A2AVersion.current, forHTTPHeaderField: A2AVersion.headerName)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try A2AWireCodec.encode(rpcRequest)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        let rpcResponse = try A2AWireCodec.decode(JSONRPCResponse.self, from: data)
        let result = try rpcResponse.decodeResult(A2ASendMessageResponse.self)
        guard case .task(let task) = result else {
            Issue.record("expected .task result")
            return
        }
        #expect(task.status.state == .completed)
    }

    @Test func missingVersionHeaderIsVersionNotSupported() async throws {
        let (server, port) = try await startServer()
        defer { Task { await server.stop() } }

        let params = A2ASendMessageRequest(message: A2AMessage(role: .user, parts: [.text("hi")]))
        let rpcRequest = try JSONRPCRequest(id: .int(1), method: .sendMessage, params: params)
        var request = URLRequest(url: rpcURL(port: port))
        request.httpMethod = "POST"
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        // Deliberately omit A2A-Version.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try A2AWireCodec.encode(rpcRequest)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)  // JSON-RPC errors ride on 200 in this binding
        let rpcResponse = try A2AWireCodec.decode(JSONRPCResponse.self, from: data)
        #expect(rpcResponse.error?.code.rawValue == -32009)
    }

    @Test func streamingRequestProducesParseableSSEFrames() async throws {
        let (server, port) = try await startServer()
        defer { Task { await server.stop() } }

        let params = A2ASendMessageRequest(message: A2AMessage(role: .user, parts: [.text("hi")]))
        let rpcRequest = try JSONRPCRequest(
            id: .int(1), method: .sendStreamingMessage, params: params)
        var request = URLRequest(url: rpcURL(port: port))
        request.httpMethod = "POST"
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")
        request.setValue(A2AVersion.current, forHTTPHeaderField: A2AVersion.headerName)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try A2AWireCodec.encode(rpcRequest)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")

        var raw = Data()
        for try await byte in bytes {
            raw.append(byte)
        }
        let text = String(decoding: raw, as: UTF8.self)
        // Not reusing `A2AClient`'s `SSEParser` on purpose (`A2AHTTPServerTests`
        // doesn't depend on `A2AClient`) — a plain split on the blank-line record
        // separator is enough to prove the wire shape is right.
        let frames = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        #expect(!frames.isEmpty)
        var sawTerminal = false
        for frame in frames {
            #expect(frame.hasPrefix("data: "))
            let jsonLine = String(frame.dropFirst("data: ".count))
            let decoded = try A2AWireCodec.decode(JSONRPCResponse.self, from: jsonLine)
            let payload = try decoded.decodeResult(A2AStreamResponse.self)
            if case .statusUpdate(let update) = payload, update.status.state == .completed {
                sawTerminal = true
            }
        }
        #expect(sawTerminal)
    }
}

#endif
