import Foundation
import Testing

@testable import A2AClient
import A2ACore

/// A canned transport for exercising `A2AClient`'s request-building without any
/// real I/O. An actor: request recording and canned-response lookup are the
/// mutable state, matching house style ("actors for mutable state"). `stream` is
/// `nonisolated` because the protocol requirement is synchronous — it only reads
/// the actor's immutable (`let`) `streamedEvents`, which is safe to touch without
/// isolation.
private actor MockTransport: A2AClientTransport {
    private(set) var recordedRequests: [JSONRPCRequest] = []
    private var sendResponses: [String: JSONRPCResponse] = [:]
    let streamedEvents: [A2AStreamResponse]

    init(streamedEvents: [A2AStreamResponse] = []) {
        self.streamedEvents = streamedEvents
    }

    func setResponse(_ response: JSONRPCResponse, forMethod method: A2AMethod) {
        sendResponses[method.rawValue] = response
    }

    func requests() -> [JSONRPCRequest] { recordedRequests }

    func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse {
        recordedRequests.append(request)
        guard let response = sendResponses[request.method] else {
            throw A2AClientError.transportClosed
        }
        return response
    }

    nonisolated func stream(_ request: JSONRPCRequest) -> AsyncThrowingStream<
        A2AStreamResponse, Error
    > {
        let events = streamedEvents
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

@Suite struct ClientFlowTests {
    @Test func sendMessageBuildsMethodAndInjectsTenant() async throws {
        let transport = MockTransport()
        let task = A2ATask(id: "t1", status: A2ATaskStatus(state: .submitted))
        let response = try JSONRPCResponse(
            id: .int(1), result: A2ASendMessageResponse.task(task))
        await transport.setResponse(response, forMethod: .sendMessage)

        let client = A2AClient(transport: transport, tenant: "tenant-a")
        let message = A2AMessage(role: .user, parts: [.text("hello")])
        let result = try await client.sendMessage(message)

        guard case .task(let returned) = result else {
            Issue.record("expected .task result, got \(result)")
            return
        }
        #expect(returned.id == "t1")

        let requests = await transport.requests()
        #expect(requests.count == 1)
        #expect(requests[0].method == A2AMethod.sendMessage.rawValue)

        let params = try #require(requests[0].params)
        #expect(params["tenant"] == .string("tenant-a"))

        let sentParams = try requests[0].decodeParams(A2ASendMessageRequest.self)
        #expect(sentParams.message == message)
        #expect(sentParams.tenant == "tenant-a")
    }

    @Test func sendMessageOmitsTenantWhenClientTenantIsEmpty() async throws {
        let transport = MockTransport()
        let task = A2ATask(id: "t1", status: A2ATaskStatus(state: .submitted))
        let response = try JSONRPCResponse(
            id: .int(1), result: A2ASendMessageResponse.task(task))
        await transport.setResponse(response, forMethod: .sendMessage)

        let client = A2AClient(transport: transport)
        _ = try await client.sendMessage(A2AMessage(role: .user, parts: [.text("hi")]))

        let requests = await transport.requests()
        let params = try #require(requests[0].params)
        #expect(params["tenant"] == nil)
    }

    @Test func getTaskParamShape() async throws {
        let transport = MockTransport()
        let task = A2ATask(id: "t1", status: A2ATaskStatus(state: .working))
        let response = try JSONRPCResponse(id: .int(1), result: task)
        await transport.setResponse(response, forMethod: .getTask)

        let client = A2AClient(transport: transport)
        let result = try await client.getTask(id: "t1")
        #expect(result.id == "t1")

        let requests = await transport.requests()
        #expect(requests[0].method == A2AMethod.getTask.rawValue)
        let params = try #require(requests[0].params)
        #expect(params == .object(["id": "t1"]))
    }

    @Test func cancelTaskParamShape() async throws {
        let transport = MockTransport()
        let task = A2ATask(id: "t1", status: A2ATaskStatus(state: .canceled))
        let response = try JSONRPCResponse(id: .int(1), result: task)
        await transport.setResponse(response, forMethod: .cancelTask)

        let client = A2AClient(transport: transport)
        let result = try await client.cancelTask(id: "t1")
        #expect(result.status.state == .canceled)

        let requests = await transport.requests()
        #expect(requests[0].method == A2AMethod.cancelTask.rawValue)
        let params = try #require(requests[0].params)
        #expect(params == .object(["id": "t1"]))
    }

    @Test func subscribeToTaskStreamsCannedEventsInOrder() async throws {
        let update1 = A2AStreamResponse.statusUpdate(
            A2ATaskStatusUpdateEvent(taskId: "t1", status: A2ATaskStatus(state: .working)))
        let update2 = A2AStreamResponse.statusUpdate(
            A2ATaskStatusUpdateEvent(taskId: "t1", status: A2ATaskStatus(state: .completed)))
        let transport = MockTransport(streamedEvents: [update1, update2])

        let client = A2AClient(transport: transport)
        var received: [A2AStreamResponse] = []
        for try await event in try await client.subscribeToTask(id: "t1") {
            received.append(event)
        }
        #expect(received == [update1, update2])
    }

    @Test func sendThrowsTransportClosedWhenNoResponseConfigured() async throws {
        let transport = MockTransport()
        let client = A2AClient(transport: transport)
        await #expect(throws: A2AClientError.transportClosed) {
            _ = try await client.getTask(id: "missing")
        }
    }
}
