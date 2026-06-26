import Foundation

// Phase D3 — the NODE-SIDE MCP client that exposes the PHONE's MCP chat tools to the
// node's ACP coding agent as EXTRA tools. Dependency-free (PQRCACP): it speaks MCP
// JSON-RPC 2.0 over an abstract `MCPLineSeam`, so the relay + crypto layer that
// actually carries those lines (a `RelayMCPTransport` in PQRCNostr) is INJECTED, not
// imported. This keeps PQRCACP free of PQRCMCP/PQRCCore (DEVIATIONS AC24/AC30) while
// still bringing ACP to parity-and-union with MCP.
//
// ## Flow
//
// ```
// node ACPAgent.runTurn  ──merges──▶  toolDefinitions()  (mcp_ prefixed)
//                                          │  (lazy MCP handshake on first use)
//                                          ▼
//   MCPOverRelayClient ──MCP JSON-RPC over MCPLineSeam──▶ (relay: ciphertext only)
//                                          │
//                          PHONE MCPServer(bridge: RuntimeSecureChatBridge)
//                                          │  (redaction + ai_window gate HERE)
//                                          ▼
//                  redacted result ◀──MCP response over the seam◀──┘
// ```
//
// ## Security posture (why the node never sees unredacted chat)
//
// This client NEVER reads a chat store — it has none. Every `tools/call` becomes an
// MCP request the PHONE answers from its redacting/window-gating `MCPServer`. So:
// - reads come back already firewall-redacted (codenames, ≤64 KB) — the phone is the
//   only thing that touches raw chat;
// - a write the agent tries (`send_as_my_ai`) is ai_window-gated phone-side, and a
//   no-window call comes back as an MCP error → surfaced as a tool error here. The
//   node literally cannot make the phone speak outside a human-opened window.
//
// ## Tool-name namespacing
//
// MCP tool names (`read_conversation`, `send_as_my_ai`, …) are PREFIXED with
// `mcp_` before being advertised to the LLM, so they can never collide with the
// agent's built-in `read_file`/`run_shell`/etc. `ACPAgent` routes a `mcp_`-named
// call here; this client strips the prefix before forwarding to the phone.

/// The line-level transport `MCPOverRelayClient` speaks MCP over. A minimal mirror
/// of `ACPTransport` so PQRCACP need not depend on PQRCNostr: `RelayMCPTransport`
/// (PQRCNostr) conforms to it, and tests supply an in-memory pair. Carries whole,
/// newline-free JSON-RPC lines both ways.
public protocol MCPLineSeam: Sendable {
    /// The inbound MCP line stream (the phone's responses). Consume ONCE.
    func inboundLines() -> AsyncStream<String>
    /// Send one MCP JSON-RPC line to the phone. Synchronous + `Sendable` (yield
    /// style), like `ACPTransport.send`.
    func send(_ line: String)
    /// Stop the inbound stream and release the outbound side.
    func close()
}

/// An `ExtraToolProvider` that surfaces the phone's MCP chat tools to the node's ACP
/// agent. Actor: it serializes the JSON-RPC id↔continuation bookkeeping and the
/// one-time handshake without locks.
public actor MCPOverRelayClient: ExtraToolProvider {
    /// MCP revision we request at `initialize` (the phone echoes one it supports).
    static let protocolVersion = "2025-06-18"
    /// Prefix that namespaces phone MCP tools from the agent's built-in tools.
    public static let toolNamePrefix = "mcp_"

    private let seam: any MCPLineSeam
    /// Wall-clock bound on any single MCP round-trip (handshake or tools/call), so a
    /// dropped relay frame surfaces as a tool error instead of hanging the turn.
    private let requestTimeoutSeconds: Double

    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    /// Cached, prefixed tool definitions after a successful handshake; nil until then.
    private var cachedTools: [LLMTool]?
    /// Names (UN-prefixed) the phone actually advertised, so we only forward a call
    /// the phone really owns.
    private var advertisedNames: Set<String> = []
    /// Set once the `initialize` + `tools/list` handshake succeeds; a failed attempt
    /// leaves it false so a later turn can retry (the relay may have just blipped).
    private var handshakeDone = false
    private var closed = false

    public init(seam: any MCPLineSeam, requestTimeoutSeconds: Double = 30) {
        self.seam = seam
        self.requestTimeoutSeconds = requestTimeoutSeconds > 0 ? requestTimeoutSeconds : 30
    }

    // MARK: - ExtraToolProvider

    public func toolDefinitions() async -> [LLMTool] {
        await ensureHandshake()
        return cachedTools ?? []
    }

    public func call(name: String, arguments: JSONValue) async -> ToolResult {
        await ensureHandshake()
        // Strip our advertise-prefix to recover the phone's MCP tool name.
        let mcpName =
            name.hasPrefix(Self.toolNamePrefix) ? String(name.dropFirst(Self.toolNamePrefix.count)) : name
        guard advertisedNames.contains(mcpName) else {
            return ToolResult(
                text: "The chat tool \(name) is not available.", isError: true)
        }
        do {
            let result = try await request(
                method: "tools/call",
                params: .object([
                    "name": .string(mcpName),
                    "arguments": arguments,
                ]))
            return Self.toolResult(from: result)
        } catch {
            // Transport failure / timeout ⇒ a tool error, never a throw (the turn
            // loop reports it and continues). Generic text — never echoes payloads.
            return ToolResult(
                text: "The chat tool \(name) could not be reached over the relay.", isError: true)
        }
    }

    // MARK: - Handshake (lazy, retried on failure)

    /// Run `initialize` + `tools/list` once, populating `cachedTools` /
    /// `advertisedNames`. A failure (relay down at first use) leaves the provider
    /// un-handshaken so the NEXT turn retries — the path is best-effort and never
    /// fails a turn just because chat tools weren't reachable yet.
    private func ensureHandshake() async {
        guard !handshakeDone, !closed else { return }
        startReaderIfNeeded()
        do {
            _ = try await request(
                method: "initialize",
                params: .object([
                    "protocolVersion": .string(Self.protocolVersion),
                    "capabilities": .object([:]),
                    "clientInfo": .object([
                        "name": .string("eldr-acp"), "version": .string("0.1.0"),
                    ]),
                ]))
            // MCP requires a notifications/initialized after initialize.
            notify(method: "notifications/initialized", params: .object([:]))
            let listed = try await request(method: "tools/list", params: .object([:]))
            let (tools, names) = Self.parseTools(listed)
            cachedTools = tools
            advertisedNames = names
            handshakeDone = true
        } catch {
            // Leave handshakeDone false; advertise nothing this turn.
            cachedTools = []
            advertisedNames = []
        }
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil, !closed else { return }
        // `seam` is an immutable `let`, so capture it directly — no need to hop back
        // onto the actor just to read it (which the compiler flags as a no-op await).
        let stream = seam.inboundLines()
        readerTask = Task { [weak self] in
            for await line in stream { await self?.route(line) }
            await self?.failAll(MCPClientError.disconnected)
        }
    }

    /// Route one inbound line. The phone is a pure MCP SERVER over this seam, so
    /// every inbound line is a RESPONSE to one of our requests (it never sends us
    /// requests or notifications); anything without a matching id is ignored.
    private func route(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = JSONValue.parse(trimmed) else { return }
        guard let id = message["id"]?.intValue, let continuation = pending[id] else { return }
        pending[id] = nil
        if let error = message["error"] {
            continuation.resume(
                throwing: MCPClientError.rpc(
                    code: error["code"]?.intValue ?? -32603,
                    message: error["message"]?.stringValue ?? "mcp error"))
        } else {
            continuation.resume(returning: message["result"] ?? .object([:]))
        }
    }

    // MARK: - JSON-RPC plumbing

    /// Send a request and await the phone's response, bounded by `requestTimeoutSeconds`.
    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        if closed { throw MCPClientError.disconnected }
        let id = nextRequestID
        nextRequestID += 1
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        // A watchdog that fails this id if no response arrives in time. Started
        // BEFORE the await so a same-tick reply still cancels it via `route`.
        let watchdog = Task { [weak self, requestTimeoutSeconds] in
            try? await Task.sleep(nanoseconds: UInt64(requestTimeoutSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.dropPending(id: id, error: MCPClientError.timedOut)
        }
        defer { watchdog.cancel() }
        // Register the continuation AND write the line synchronously on the actor
        // (this closure runs in `request`'s actor-isolated context), so a response
        // can never arrive before the id is in `pending` — closing the
        // register-vs-route race. `route`/`dropPending` resolve it later.
        return try await withCheckedThrowingContinuation { continuation in
            guard !closed else {
                continuation.resume(throwing: MCPClientError.disconnected)
                return
            }
            pending[id] = continuation
            seam.send(envelope.serialized())
        }
    }

    /// Resolve-and-remove a still-pending continuation (timeout/cancel cleanup). A
    /// no-op if the response already arrived and cleared it.
    private func dropPending(id: Int, error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    private func notify(method: String, params: JSONValue) {
        guard !closed else { return }
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        seam.send(envelope.serialized())
    }

    private func failAll(_ error: Error) {
        let waiters = pending.values
        pending.removeAll()
        for continuation in waiters { continuation.resume(throwing: error) }
    }

    /// Tear down: stop reading, close the seam, fail anything outstanding.
    public func shutdown() {
        closed = true
        readerTask?.cancel()
        readerTask = nil
        seam.close()
        failAll(MCPClientError.disconnected)
    }

    // MARK: - MCP shape parsing

    /// Map a `tools/list` result into prefixed `LLMTool`s + the set of un-prefixed
    /// names the phone advertised. A tool missing a name is skipped.
    static func parseTools(_ result: JSONValue) -> (tools: [LLMTool], names: Set<String>) {
        guard let entries = result["tools"]?.arrayValue else { return ([], []) }
        var tools: [LLMTool] = []
        var names: Set<String> = []
        for entry in entries {
            guard let name = entry["name"]?.stringValue, !name.isEmpty else { continue }
            names.insert(name)
            let description = entry["description"]?.stringValue ?? ""
            // MCP `inputSchema` IS a JSON-Schema object — exactly the shape an
            // OpenAI tool `parameters` wants — so pass it through. Default to an
            // empty-object schema if absent.
            let schema = entry["inputSchema"] ?? .object([
                "type": .string("object"), "properties": .object([:]),
            ])
            tools.append(
                LLMTool(
                    name: Self.toolNamePrefix + name,
                    description: description.isEmpty ? "Chat tool \(name)." : description,
                    parameters: schema))
        }
        return (tools, names)
    }

    /// Flatten an MCP `tools/call` result into a `ToolResult`. The MCP result is
    /// `{content:[{type:"text",text:…}], isError:Bool}`; we concatenate the text
    /// blocks and carry `isError` through (a window-gated refusal arrives as
    /// `isError:true`, so the agent sees the refusal — invariant 9 surfaced).
    static func toolResult(from result: JSONValue) -> ToolResult {
        let isError = result["isError"]?.boolValue ?? false
        let text = (result["content"]?.arrayValue ?? [])
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n")
        return ToolResult(
            text: text.isEmpty ? (isError ? "The chat tool failed." : "(no result)") : text,
            isError: isError)
    }
}

public enum MCPClientError: Error, Sendable, Equatable {
    case disconnected
    case timedOut
    case rpc(code: Int, message: String)
}
