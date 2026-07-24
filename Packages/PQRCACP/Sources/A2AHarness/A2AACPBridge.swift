// SPDX-License-Identifier: Apache-2.0
// A2ACore/A2AClient carry URLSession-based A2A-over-HTTP and are linked on Apple
// platforms only (see PQRCACP/Package.swift); this whole bridge is `#if os(macOS)`
// below, so the imports are gated to match — on Linux A2AHarness compiles to nothing.
#if os(macOS)
import A2ACore
import A2AClient
#endif
import Foundation
import PQRCACP

// The `.a2aRemote` half of the drop-in harness seam (docs/ACPRouterplan.md): an ACP CLIENT
// (`runHarness`/`ACPAgent.delegateToCloudAgent`, via `ACPClientDriver`) must be able to
// drive a real Agent2Agent (A2A) v1.0 agent EXACTLY as it drives a spawned `.stdioSpawn`
// harness — same `ACPTransport`, same `initialize → session/new → session/prompt` shape.
// `A2AACPBridge` is that translation: it plays the ACP AGENT role over one end of an
// in-memory `ACPTransport` pair, and turns each `session/prompt` into A2A
// `message/send`/`message/stream` calls (`A2AClient`) against the descriptor's card URL,
// folding the remote's messages/artifacts back into ACP `session/update` chunks.
//
// macOS-gated for the same reason as `ACPAgent`/`StdioHarnessTransport`: this is a
// node-side (harness) implementation, never something the phone (the ACP client) runs.

#if os(macOS)
/// An ACP-agent facade over a remote A2A agent. `makeTransport(descriptor:)` returns the
/// half of an `InMemoryACPTransport` pair an ACP client drives; the bridge itself owns the
/// other half and answers requests on it — from the client's perspective this is
/// indistinguishable from a spawned harness's stdio transport.
public actor A2AACPBridge {
    /// Resolves `descriptor` to a connected `A2AClient` + its agent card. Production uses
    /// `defaultClientFactory` (`A2AClient.connecting(cardURL:)`, a real HTTPS fetch); tests
    /// inject a factory backed by a mock `A2AClientTransport` so no test touches the
    /// network (CLAUDE.md: "No unit test touches the network or the real clock").
    public typealias ClientFactory = @Sendable (HarnessDescriptor) async throws -> (
        A2AClient, A2AAgentCard
    )

    /// Above this, an inbound `raw`/`data`/binary A2A part is reported as skipped rather
    /// than rendered — text-only product, and a bound keeps one oversized part from
    /// dominating a turn's output (CLAUDE.md §0: privacy/product scope, not a wire limit).
    static let maxRenderedPartBytes = 32 * 1024

    private let descriptor: HarnessDescriptor
    /// OUR end of the pair: the bridge's inbound is what the ACP client sent us, and
    /// `transport.send` is how we answer/notify it. The client-facing end is returned by
    /// `makeTransport` and never touched again here.
    private let transport: any ACPTransport
    private let clientFactory: ClientFactory

    /// Lazily built on the FIRST `session/prompt` (never at `initialize`) so `initialize`
    /// stays fast and offline-safe even if the remote agent is unreachable.
    private var client: A2AClient?
    private var card: A2AAgentCard?
    /// A2A session continuity: the `contextId` the remote assigns on first contact is
    /// carried on every subsequent message so the remote can correlate the conversation.
    private var contextId = ""
    /// The remote task id currently in flight, if any — what `session/cancel` targets.
    private var liveTaskId: String?
    private var sessionId: String?
    /// Set by `session/cancel`; the in-flight prompt's streaming/polling loop checks this
    /// between events/polls and bails promptly rather than riding the turn out.
    private var cancelRequested = false

    private init(
        descriptor: HarnessDescriptor, transport: any ACPTransport,
        clientFactory: @escaping ClientFactory
    ) {
        self.descriptor = descriptor
        self.transport = transport
        self.clientFactory = clientFactory
    }

    /// The production entry point — `A2AHarnessFactory` calls this for `.a2aRemote`
    /// descriptors. Throws `HarnessTransportError.unsupportedKind` for any other kind
    /// (mirrors `StdioHarnessTransport`/`DefaultHarnessTransportFactory`'s own guard).
    public static func makeTransport(descriptor: HarnessDescriptor) throws -> any ACPTransport {
        try makeTransport(descriptor: descriptor, clientFactory: defaultClientFactory)
    }

    /// Test seam: build with an injected `clientFactory` so no test performs real network
    /// I/O. `internal` (not `public`) — production code never needs to override this, only
    /// `A2AHarnessTests` (via `@testable import`).
    static func makeTransport(
        descriptor: HarnessDescriptor, clientFactory: @escaping ClientFactory
    ) throws -> any ACPTransport {
        guard descriptor.kind == .a2aRemote else {
            throw HarnessTransportError.unsupportedKind(descriptor.kind)
        }
        let (clientSide, bridgeSide) = InMemoryACPTransport.makePair()
        let bridge = A2AACPBridge(
            descriptor: descriptor, transport: bridgeSide, clientFactory: clientFactory)
        Task { await bridge.run() }
        return clientSide
    }

    private static func defaultClientFactory(_ descriptor: HarnessDescriptor) async throws -> (
        A2AClient, A2AAgentCard
    ) {
        guard let urlString = descriptor.a2aCardURL, let url = URL(string: urlString) else {
            throw A2AACPBridgeError.missingCardURL
        }
        let auth: (any A2AAuthProvider)? = descriptor.a2aBearerToken.map { A2ABearerAuth(token: $0) }
        return try await A2AClient.connecting(cardURL: url, auth: auth)
    }

    // MARK: - Bridge loop

    /// Read our end's inbound lines and dispatch. `session/prompt` runs on its OWN `Task`
    /// so this loop keeps consuming lines while a turn is in flight — otherwise a
    /// `session/cancel` sent mid-turn would sit unread until the turn finished, defeating
    /// the whole point of cancelling. Mirrors `runACPAgent`'s identical dispatch split
    /// (ACPTransport.swift) for the identical reason.
    private func run() async {
        for await line in transport.inboundLines() {
            guard let message = JSONValue.parse(line), let method = message["method"]?.stringValue
            else { continue }
            let id = message["id"]
            let params = message["params"] ?? .object([:])
            if method == "session/prompt" {
                Task { await self.handlePrompt(id: id, params: params) }
            } else {
                await dispatch(method: method, id: id, params: params)
            }
        }
        await client?.shutdown()
    }

    private func dispatch(method: String, id: JSONValue?, params: JSONValue) async {
        switch method {
        case "initialize":
            handleInitialize(id: id)
        case "session/new":
            handleSessionNew(id: id)
        case "session/cancel":
            await handleCancel()
        default:
            if let id { respondError(id: id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    // MARK: - initialize / session/new / session/cancel

    /// A minimal, well-formed ACP `initialize` result. No A2A network call here — the card
    /// fetch is deferred to the first prompt (see `handlePrompt`) so a client can always
    /// complete the handshake, even against an unreachable remote agent.
    private func handleInitialize(id: JSONValue?) {
        guard let id else { return }
        respond(
            id: id,
            result: .object([
                "protocolVersion": .int(ACPClientDriver.acpProtocolVersion),
                "agentInfo": .object([
                    "name": .string("a2a-bridge/\(descriptor.id)"),
                    "version": .string("0.1.0"),
                ]),
                "agentCapabilities": .object([
                    "loadSession": .bool(false),
                    "promptCapabilities": .object([
                        "image": .bool(false), "audio": .bool(false),
                        "embeddedContext": .bool(false),
                    ]),
                ]),
                "authMethods": .array([]),
            ]))
    }

    private func handleSessionNew(id: JSONValue?) {
        guard let id else { return }
        let sid = "a2a-session-1"
        sessionId = sid
        respond(id: id, result: .object(["sessionId": .string(sid)]))
    }

    /// Fire-and-forget: ask the remote to cancel the live task and flag the local
    /// streaming/polling loop to stop. Errors are swallowed — a cancel that fails to reach
    /// an already-finished/unreachable remote is not actionable and, per the at-rest/log
    /// redaction rule, is not worth surfacing a raw error for.
    private func handleCancel() async {
        cancelRequested = true
        guard let client, let taskId = liveTaskId else { return }
        _ = try? await client.cancelTask(id: taskId)
    }

    // MARK: - session/prompt

    private func handlePrompt(id: JSONValue?, params: JSONValue) async {
        guard let id else { return }
        cancelRequested = false
        let sid = params["sessionId"]?.stringValue ?? sessionId ?? ""
        guard let promptText = Self.extractPromptText(params["prompt"]) else {
            respondError(id: id, code: -32602, message: "session/prompt: no text content in prompt")
            return
        }

        if client == nil {
            do {
                let (resolvedClient, resolvedCard) = try await clientFactory(descriptor)
                client = resolvedClient
                card = resolvedCard
            } catch {
                emitChunk(
                    sessionId: sid,
                    text: "[a2a] could not connect to \(descriptor.displayName): \(error)")
                respond(id: id, result: .object(["stopReason": .string("end_turn")]))
                return
            }
        }
        guard let client else { return }

        let message = A2AMessage(
            messageId: UUID().uuidString, contextId: contextId, role: .user,
            parts: [.text(promptText)])

        let stopReason =
            card?.capabilities.streaming == true
            ? await runStreaming(client: client, message: message, sessionId: sid)
            : await runUnary(client: client, message: message, sessionId: sid)
        respond(id: id, result: .object(["stopReason": .string(stopReason)]))
    }

    /// Concatenate every `text` content block in an ACP `prompt` array. Non-text blocks
    /// (image/audio/resource) are dropped — the text-only product never sends them, and a
    /// client that does gets no round-trip rather than a confusing partial one.
    private static func extractPromptText(_ prompt: JSONValue?) -> String? {
        guard let blocks = prompt?.arrayValue else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"]?.stringValue == "text" else { return nil }
            return block["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    // MARK: - Streaming turn (card.capabilities.streaming == true)

    private func runStreaming(client: A2AClient, message: A2AMessage, sessionId: String) async -> String
    {
        var finalState = A2ATaskState.unspecified
        var finalStatusMessage: String?
        // Per-artifact accumulation: `append` events build up an artifact's text across
        // multiple updates; we only emit once (`lastChunk`, or flushed at stream end).
        var artifactText: [String: String] = [:]
        do {
            let stream = try await client.streamMessage(message)
            for try await event in stream {
                if cancelRequested { break }
                switch event {
                case .task(let task):
                    liveTaskId = task.id
                    if !task.contextId.isEmpty { contextId = task.contextId }
                    finalState = task.status.state
                    finalStatusMessage = Self.textFromMessage(task.status.message)
                case .message(let responseMessage):
                    if !responseMessage.contextId.isEmpty { contextId = responseMessage.contextId }
                    emitPartsAsChunks(responseMessage.parts, sessionId: sessionId)
                case .statusUpdate(let update):
                    if !update.taskId.isEmpty { liveTaskId = update.taskId }
                    if !update.contextId.isEmpty { contextId = update.contextId }
                    finalState = update.status.state
                    finalStatusMessage = Self.textFromMessage(update.status.message)
                    // Only the status MESSAGE text is forwarded here — the state itself is
                    // reflected in the eventual stopReason, not as a separate chunk.
                    if let text = finalStatusMessage, !text.isEmpty {
                        emitChunk(sessionId: sessionId, text: text)
                    }
                case .artifactUpdate(let update):
                    if !update.contextId.isEmpty { contextId = update.contextId }
                    let artifactId = update.artifact.artifactId
                    let text = Self.textFromParts(update.artifact.parts).joined()
                    artifactText[artifactId] =
                        update.append ? (artifactText[artifactId] ?? "") + text : text
                    if update.lastChunk, let full = artifactText.removeValue(forKey: artifactId),
                        !full.isEmpty
                    {
                        emitChunk(sessionId: sessionId, text: full)
                    }
                }
                if finalState.isTerminal || finalState.isInterrupted { break }
            }
        } catch {
            liveTaskId = nil
            emitChunk(sessionId: sessionId, text: "[a2a] task failed: \(error)")
            return cancelRequested ? "cancelled" : "end_turn"
        }
        // Flush any artifact that never got an explicit `lastChunk` (stream ended anyway).
        for (_, text) in artifactText where !text.isEmpty {
            emitChunk(sessionId: sessionId, text: text)
        }
        if finalState.isTerminal { liveTaskId = nil }
        return finalize(state: finalState, statusMessage: finalStatusMessage, sessionId: sessionId)
    }

    // MARK: - Unary turn (card.capabilities.streaming != true)

    /// `sendMessage` then poll `getTask` every 500ms until terminal/interrupted, bounded to
    /// ~120s so an agent that never finishes can't wedge the delegating turn forever (the
    /// same fail-closed spirit as `delegateToCloudAgent`'s own cancel-race bound).
    private func runUnary(client: A2AClient, message: A2AMessage, sessionId: String) async -> String {
        do {
            let response = try await client.sendMessage(message)
            var task: A2ATask
            switch response {
            case .message(let responseMessage):
                if !responseMessage.contextId.isEmpty { contextId = responseMessage.contextId }
                emitPartsAsChunks(responseMessage.parts, sessionId: sessionId)
                return "end_turn"
            case .task(let returnedTask):
                task = returnedTask
            }
            liveTaskId = task.id
            if !task.contextId.isEmpty { contextId = task.contextId }

            let deadline = Date().addingTimeInterval(120)
            while !task.status.state.isTerminal && !task.status.state.isInterrupted {
                if cancelRequested || Date() >= deadline { break }
                try await Task.sleep(nanoseconds: 500_000_000)
                task = try await client.getTask(id: task.id)
            }
            for text in task.artifacts.map({ Self.textFromParts($0.parts).joined() })
            where !text.isEmpty {
                emitChunk(sessionId: sessionId, text: text)
            }
            if task.status.state.isTerminal { liveTaskId = nil }
            return finalize(
                state: task.status.state, statusMessage: Self.textFromMessage(task.status.message),
                sessionId: sessionId)
        } catch {
            liveTaskId = nil
            emitChunk(sessionId: sessionId, text: "[a2a] task failed: \(error)")
            return cancelRequested ? "cancelled" : "end_turn"
        }
    }

    // MARK: - Terminal-state → ACP stopReason

    /// A cancel that raced the turn always wins, regardless of what state the remote
    /// reports (it may not have observed the cancel yet).
    private func finalize(state: A2ATaskState, statusMessage: String?, sessionId: String) -> String {
        if cancelRequested { return "cancelled" }
        let detail = statusMessage?.isEmpty == false ? statusMessage! : "no further detail provided"
        switch state {
        case .completed:
            return "end_turn"
        case .canceled:
            return "cancelled"
        case .failed, .rejected:
            emitChunk(sessionId: sessionId, text: "[a2a] task failed: \(detail)")
            return "end_turn"
        case .inputRequired:
            emitChunk(
                sessionId: sessionId,
                text:
                    "[a2a] the remote agent requires additional input: \(detail). Re-delegate with more context."
            )
            return "end_turn"
        case .authRequired:
            emitChunk(
                sessionId: sessionId,
                text:
                    "[a2a] the remote agent requires authentication: \(detail). Configure a credential for this harness and re-delegate."
            )
            return "end_turn"
        case .unspecified, .submitted, .working, .unknown:
            return "end_turn"
        }
    }

    // MARK: - Part → text rendering (privacy: text-only product, never fetch a URL)

    private static func textFromMessage(_ message: A2AMessage?) -> String? {
        guard let message else { return nil }
        let text = textFromParts(message.parts).joined()
        return text.isEmpty ? nil : text
    }

    /// Render each `A2APart` as ACP-chunk text, one string per part:
    ///   - `.text`  → the text verbatim.
    ///   - `.url`   → the literal URL string. NEVER fetched — a remote agent handing back a
    ///     URL is not license to make an outbound request on the user's behalf.
    ///   - `.data`  → compact (non-pretty-printed) JSON text.
    ///   - `.raw`   → never rendered as content (text-only product); reported as skipped,
    ///     with a distinct message when it exceeds `maxRenderedPartBytes`.
    private static func textFromParts(_ parts: [A2APart]) -> [String] {
        parts.map { part in
            switch part.content {
            case .text(let text):
                return text
            case .url(let url):
                return url
            case .data(let json):
                return compactJSONString(json)
            case .raw(let base64):
                return base64.utf8.count > maxRenderedPartBytes
                    ? "[a2a] skipped an oversized binary part"
                    : "[a2a] skipped a binary part"
            }
        }
    }

    private static func compactJSONString(_ value: A2AJSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }

    // MARK: - Emit / respond plumbing

    private func emitPartsAsChunks(_ parts: [A2APart], sessionId: String) {
        for text in Self.textFromParts(parts) where !text.isEmpty {
            emitChunk(sessionId: sessionId, text: text)
        }
    }

    private func emitChunk(sessionId: String, text: String) {
        transport.send(
            JSONValue.object([
                "jsonrpc": .string("2.0"),
                "method": .string("session/update"),
                "params": ACPWire.agentMessageChunk(sessionId: sessionId, text: text),
            ]).serialized())
    }

    private func respond(id: JSONValue, result: JSONValue) {
        transport.send(
            JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).serialized())
    }

    private func respondError(id: JSONValue, code: Int, message: String) {
        transport.send(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .int(code), "message": .string(message)]),
            ]).serialized())
    }
}

/// Failures raised by the default (production) `A2AACPBridge.ClientFactory`.
enum A2AACPBridgeError: Error, Sendable {
    /// The descriptor is `.a2aRemote` but carries no `a2aCardURL` to resolve.
    case missingCardURL
}
#endif  // os(macOS) — A2AACPBridge is a node-side harness implementation
