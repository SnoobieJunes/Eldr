import Foundation

// Phase 1 (docs/ACPRouterplan.md §5): decouple ACP from stdio. The agent was already
// transport-agnostic (`OutputSink` out, `handle(line:)` in); the CLIENT half
// (`ACPClientDriver`) was hardcoded to FileHandle pipes. `ACPTransport` is the seam that
// lets the SAME client + agent protocol logic run over Multipeer / LAN / in-memory. The
// only thing a transport does is carry whole, newline-framed JSON-RPC lines both ways.

/// The line-level transport beneath an ACP client or agent.
public protocol ACPTransport: Sendable {
    /// The inbound line stream. Consume ONCE; it finishes when the peer closes / EOF.
    func inboundLines() -> AsyncStream<String>
    /// Send one JSON-RPC line to the peer. Synchronous + Sendable (continuation-yield
    /// style) so it can be called from inside a request's continuation without `await`,
    /// and so ordering is whatever the caller's call order is.
    func send(_ line: String)
    /// Stop the inbound stream and release the outbound side.
    func close()
}

/// An in-memory `ACPTransport` PAIR: whatever one side `send`s arrives on the other's
/// `inboundLines()`. This is both the headless test harness (an `ACPClient ↔ ACPAgent`
/// round-trip with no stdio and no radios) and the concrete shape the eventual
/// Multipeer/LAN transports implement.
public struct InMemoryACPTransport: ACPTransport {
    private let inbound: AsyncStream<String>
    private let outbound: AsyncStream<String>.Continuation

    private init(inbound: AsyncStream<String>, outbound: AsyncStream<String>.Continuation) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// Two cross-wired ends: `side1.send(_:)` arrives on `side2.inboundLines()`, and the
    /// reverse. Hand one end to an `ACPClient` and the other to `runACPAgent`.
    public static func makePair() -> (InMemoryACPTransport, InMemoryACPTransport) {
        var aContinuation: AsyncStream<String>.Continuation!
        let aStream = AsyncStream<String> { aContinuation = $0 }
        var bContinuation: AsyncStream<String>.Continuation!
        let bStream = AsyncStream<String> { bContinuation = $0 }
        // side1 reads A, writes B;  side2 reads B, writes A.
        return (
            InMemoryACPTransport(inbound: aStream, outbound: bContinuation),
            InMemoryACPTransport(inbound: bStream, outbound: aContinuation)
        )
    }

    public func inboundLines() -> AsyncStream<String> { inbound }
    public func send(_ line: String) { outbound.yield(line) }
    public func close() { outbound.finish() }
}

// NODE-SIDE (macOS only): `runACPAgent` and its output bridge run the AGENT half over a
// transport, constructing `ACPAgent` (macOS-only). The phone speaks ACP as the CLIENT
// (`ACPClient`) and never hosts the agent, so this is guarded off iOS. The `ACPTransport`
// protocol + `InMemoryACPTransport` above stay iOS-available (the phone implements/uses
// them).
#if os(macOS)
/// Bridges an `ACPTransport`'s outbound side to the agent's `OutputSink` (the thing
/// `ClientConnection` writes its notifications/requests through).
struct TransportOutputSink: OutputSink {
    let transport: any ACPTransport
    func write(line: String) async { transport.send(line) }
}

/// Run an `ACPAgent` over an `ACPTransport` — the transport-agnostic agent driver the
/// plan calls `runACPAgent`. The agent's outbound goes out via the transport; each
/// inbound line is routed: a response to one of the agent's OWN outbound requests (a
/// permission answer, an `fs/*` result) is delivered to the connection, while everything
/// else is a client request/notification the agent handles (its response line, if any, is
/// written back). Returns when the inbound stream finishes (transport closed).
///
/// Each line is handled on its own `Task` on purpose: a long `session/prompt` turn must
/// not block the read loop, because the client's permission answer arrives as a LATER
/// inbound line that the agent's in-flight turn is awaiting (otherwise: deadlock).
/// Ordering of the client's own requests is preserved because the client awaits each
/// response before sending the next.
public func runACPAgent(
    transport: any ACPTransport,
    llm: any LLMClient,
    toolEnvironment: ToolEnvironment = .fromEnvironment(),
    config: AgentConfig = .fromEnvironment(),
    configDir: String? = nil,
    streamingEnabled: Bool = true
) async {
    let sink = TransportOutputSink(transport: transport)
    let connection = ClientConnection(sink: sink)
    let agent = ACPAgent(
        connection: connection, llm: llm, toolEnvironment: toolEnvironment,
        config: config, configDir: configDir, streamingEnabled: streamingEnabled)
    for await line in transport.inboundLines() {
        Task {
            guard let message = JSONValue.parse(line) else { return }
            if message["method"] == nil, message["id"] != nil {
                await connection.deliver(response: message)
            } else if let response = await agent.handle(line: line) {
                await sink.write(line: response)
            }
        }
    }
}
#endif  // os(macOS) — runACPAgent + TransportOutputSink (node-side: hosts ACPAgent)
