#if os(macOS)
import A2ACore
import A2AClient
import Foundation
import Testing

@testable import A2AHarness
import PQRCACP

// Network-free bridge checks (CLAUDE.md: "No unit test touches the network or the real
// clock"): `MockA2ATransport` cans every A2A JSON-RPC response/stream the bridge could see,
// and `A2AACPBridge`'s package-internal `makeTransport(descriptor:clientFactory:)` seam
// injects a client built directly on that mock — `AgentCardResolver`'s real HTTPS fetch
// (`A2AClient.connecting(cardURL:)`) is never reached. Everything drives the bridge through
// its PUBLIC face: the `ACPTransport` a real `ACPClientDriver` (PQRCACP) speaks, exactly
// like `runHarness`/`delegateToCloudAgent` do in production.

/// Bounded wait so a stuck bridge fails the test instead of hanging the suite.
private func withTimeout<T: Sendable>(
    _ seconds: Double, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
private struct TimedOutError: Error {}

/// Collects `onAgentMessageChunk` deliveries in arrival order — the thing every happy-path
/// test asserts on.
private actor ChunkCollector {
    private(set) var chunks: [String] = []
    func append(_ text: String) { chunks.append(text) }
}

/// A canned `A2AClientTransport`: `send` replies per-method from `setResponse`, `stream`
/// replays `streamedEvents` in order. Mirrors SwiftA2A's own `ClientFlowTests.MockTransport`
/// house style (an actor; `stream` is `nonisolated` since it only touches the immutable
/// `streamedEvents` synchronously) with one addition — an optional MID-STREAM GATE so
/// `cancelMidStreamCallsCancelTask` can deterministically inject a `session/cancel` between
/// two streamed events instead of racing a fixed delay.
private actor MockA2ATransport: A2AClientTransport {
    private(set) var recordedRequests: [JSONRPCRequest] = []
    private var sendResponses: [String: JSONRPCResponse] = [:]
    private let streamedEvents: [A2AStreamResponse]
    /// When true, the stream yields event 0, then SUSPENDS until `openGate()` is called
    /// before yielding the rest.
    private var gateArmed: Bool
    private var gateContinuation: CheckedContinuation<Void, Never>?

    init(streamedEvents: [A2AStreamResponse] = [], gateAfterFirstEvent: Bool = false) {
        self.streamedEvents = streamedEvents
        self.gateArmed = gateAfterFirstEvent
    }

    func setResponse(_ response: JSONRPCResponse, forMethod method: A2AMethod) {
        sendResponses[method.rawValue] = response
    }

    func requests() -> [JSONRPCRequest] { recordedRequests }

    /// The task ids `CancelTask` requests were sent for, in order.
    func canceledTaskIds() -> [String] {
        recordedRequests
            .filter { $0.method == A2AMethod.cancelTask.rawValue }
            .compactMap { $0.params?["id"]?.stringValue }
    }

    func openGate() {
        gateContinuation?.resume()
        gateContinuation = nil
    }

    private func awaitGateIfArmed() async {
        guard gateArmed else { return }
        gateArmed = false
        await withCheckedContinuation { continuation in gateContinuation = continuation }
    }

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
            Task {
                for (index, event) in events.enumerated() {
                    if index == 1 { await self.awaitGateIfArmed() }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

@Suite("A2AACPBridge — ACP-agent facade over a mocked A2A backend")
struct A2AACPBridgeTests {

    private func descriptor(id: String = "a2a-test") -> HarnessDescriptor {
        HarnessDescriptor(
            id: id, displayName: "A2A Test Agent", kind: .a2aRemote,
            a2aCardURL: "https://example.invalid/.well-known/agent-card.json")
    }

    private func streamingCard() -> A2AAgentCard {
        A2AAgentCard(
            name: "mock-agent", description: "", supportedInterfaces: [], version: "1.0",
            capabilities: A2AAgentCapabilities(streaming: true))
    }

    private func unaryCard() -> A2AAgentCard {
        A2AAgentCard(
            name: "mock-agent", description: "", supportedInterfaces: [], version: "1.0",
            capabilities: A2AAgentCapabilities(streaming: false))
    }

    private func clientFactory(_ transport: MockA2ATransport, card: A2AAgentCard)
        -> A2AACPBridge.ClientFactory
    {
        { _ in (A2AClient(transport: transport), card) }
    }

    private func makeTransport(
        streamedEvents: [A2AStreamResponse], card: A2AAgentCard, gateAfterFirstEvent: Bool = false
    ) throws -> (any ACPTransport, MockA2ATransport) {
        let mock = MockA2ATransport(streamedEvents: streamedEvents, gateAfterFirstEvent: gateAfterFirstEvent)
        let transport = try A2AACPBridge.makeTransport(
            descriptor: descriptor(), clientFactory: clientFactory(mock, card: card))
        return (transport, mock)
    }

    // MARK: (a) happy path, streaming card

    @Test func streamingHappyPath_chunksArriveInOrder_endTurnOnCompleted() async throws {
        let events: [A2AStreamResponse] = [
            .message(A2AMessage(contextId: "ctx-1", role: .agent, parts: [.text("first ")])),
            .message(A2AMessage(contextId: "ctx-1", role: .agent, parts: [.text("second")])),
            .task(A2ATask(id: "t1", contextId: "ctx-1", status: A2ATaskStatus(state: .completed))),
        ]
        let (transport, _) = try makeTransport(streamedEvents: events, card: streamingCard())

        let collector = ChunkCollector()
        let handler = ACPClientHandler(onAgentMessageChunk: { text in await collector.append(text) })
        let driver = ACPClientDriver(transport: transport, handler: handler)

        let info = try await withTimeout(5) { try await driver.start() }
        #expect(info.agentName == "a2a-bridge/a2a-test")
        #expect(info.sessionId == "a2a-session-1")

        let stopReason = try await withTimeout(5) { try await driver.prompt("hello there") }
        #expect(stopReason == "end_turn")
        #expect(await collector.chunks == ["first ", "second"])
    }

    // MARK: (b) cancel mid-stream

    @Test func cancelMidStreamCallsCancelTaskAndReportsCancelled() async throws {
        let events: [A2AStreamResponse] = [
            .statusUpdate(
                A2ATaskStatusUpdateEvent(
                    taskId: "t-cancel", contextId: "ctx-2", status: A2ATaskStatus(state: .working))),
            .task(A2ATask(id: "t-cancel", contextId: "ctx-2", status: A2ATaskStatus(state: .completed))),
        ]
        let (transport, mock) = try makeTransport(
            streamedEvents: events, card: streamingCard(), gateAfterFirstEvent: true)

        let driver = ACPClientDriver(transport: transport)
        _ = try await withTimeout(5) { try await driver.start() }

        // Fire the prompt but don't await it yet — it's parked at the mid-stream gate.
        let promptTask = Task { try await driver.prompt("go") }
        // Give the bridge a moment to observe the first event and record the live task id,
        // then cancel — the bridge must forward this to `cancelTask` on the SAME id.
        try await Task.sleep(nanoseconds: 200_000_000)
        await driver.cancel()
        try await Task.sleep(nanoseconds: 200_000_000)
        await mock.openGate()

        let stopReason = try await withTimeout(5) { try await promptTask.value }
        #expect(stopReason == "cancelled")
        #expect(await mock.canceledTaskIds() == ["t-cancel"])
    }

    // MARK: (c) inputRequired

    @Test func inputRequiredEmitsExplanatoryChunkThenEndTurn() async throws {
        let events: [A2AStreamResponse] = [
            .task(
                A2ATask(
                    id: "t3", contextId: "ctx-3",
                    status: A2ATaskStatus(
                        state: .inputRequired,
                        message: A2AMessage(role: .agent, parts: [.text("which repo?")]))))
        ]
        let (transport, _) = try makeTransport(streamedEvents: events, card: streamingCard())

        let collector = ChunkCollector()
        let handler = ACPClientHandler(onAgentMessageChunk: { text in await collector.append(text) })
        let driver = ACPClientDriver(transport: transport, handler: handler)
        _ = try await withTimeout(5) { try await driver.start() }

        let stopReason = try await withTimeout(5) { try await driver.prompt("do the thing") }
        #expect(stopReason == "end_turn")
        let chunks = await collector.chunks
        #expect(chunks.contains { $0.contains("requires additional input") && $0.contains("which repo?") })
    }

    // MARK: (d) url part → literal text, never fetched

    @Test func urlPartRendersAsLiteralTextNeverFetched() async throws {
        let events: [A2AStreamResponse] = [
            .message(
                A2AMessage(
                    contextId: "ctx-4", role: .agent,
                    parts: [A2APart(content: .url("https://example.invalid/report.txt"))])),
            .task(A2ATask(id: "t4", contextId: "ctx-4", status: A2ATaskStatus(state: .completed))),
        ]
        let (transport, _) = try makeTransport(streamedEvents: events, card: streamingCard())

        let collector = ChunkCollector()
        let handler = ACPClientHandler(onAgentMessageChunk: { text in await collector.append(text) })
        let driver = ACPClientDriver(transport: transport, handler: handler)
        _ = try await withTimeout(5) { try await driver.start() }
        _ = try await withTimeout(5) { try await driver.prompt("fetch me something") }

        // The literal URL string, verbatim — never resolved to fetched content (there is no
        // URLSession anywhere in this test, so a fetch attempt would have no way to succeed).
        #expect(await collector.chunks == ["https://example.invalid/report.txt"])
    }

    // MARK: (e) factory seam

    @Test func defaultHarnessTransportFactoryThrowsOnA2ARemote() {
        #expect(throws: HarnessTransportError.unsupportedKind(.a2aRemote)) {
            _ = try DefaultHarnessTransportFactory().makeTransport(for: descriptor())
        }
    }

    @Test func a2aHarnessFactoryCompletesAnInitializeRoundTrip() async throws {
        let transport = try A2AHarnessFactory().makeTransport(for: descriptor())
        let driver = ACPClientDriver(transport: transport)
        let info = try await withTimeout(5) { try await driver.start() }
        #expect(info.agentName == "a2a-bridge/a2a-test")
        #expect(info.sessionId == "a2a-session-1")
    }

    @Test func a2aHarnessFactoryThrowsOnBuiltIn() {
        #expect(throws: HarnessTransportError.unsupportedKind(.builtIn)) {
            _ = try A2AHarnessFactory().makeTransport(for: .builtIn)
        }
    }

    // MARK: unary (non-streaming) card

    @Test func unaryCardPollsGetTaskUntilTerminal() async throws {
        let mock = MockA2ATransport()
        let task = A2ATask(id: "t5", contextId: "ctx-5", status: A2ATaskStatus(state: .working))
        let completed = A2ATask(
            id: "t5", contextId: "ctx-5", status: A2ATaskStatus(state: .completed),
            artifacts: [A2AArtifact(artifactId: "a1", parts: [.text("the answer")])])
        try await mock.setResponse(JSONRPCResponse(id: .int(1), result: A2ASendMessageResponse.task(task)), forMethod: .sendMessage)
        try await mock.setResponse(JSONRPCResponse(id: .int(2), result: completed), forMethod: .getTask)

        let transport = try A2AACPBridge.makeTransport(
            descriptor: descriptor(), clientFactory: clientFactory(mock, card: unaryCard()))

        let collector = ChunkCollector()
        let handler = ACPClientHandler(onAgentMessageChunk: { text in await collector.append(text) })
        let driver = ACPClientDriver(transport: transport, handler: handler)
        _ = try await withTimeout(5) { try await driver.start() }

        let stopReason = try await withTimeout(5) { try await driver.prompt("answer this") }
        #expect(stopReason == "end_turn")
        #expect(await collector.chunks == ["the answer"])
    }
}
#endif  // os(macOS)
