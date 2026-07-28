// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// The BRAIN. An OpenAI-compatible Chat Completions client WITH tool/function
// calling, behind a protocol so tests inject a mock (no network in tests) and the
// executable can run against a built-in echo LLM. Config is read from the
// environment by `LLMConfig`. Self-hosted models (LM Studio / Ollama / vLLM) speak
// this shape.

// MARK: - Message & tool model (provider-agnostic, OpenAI-shaped)

/// D2 (node-side image input): one image attached to a multimodal `user` message.
/// Carries the raw base64 bytes + the MIME type from a node-side ACP `image` content
/// block, encoded into the OpenAI vision `image_url` data-URI at request time. NOT
/// free text and NEVER credential-scrubbed (a base64 image is high-entropy and the
/// entropy redactor would mangle it — and an image isn't a credential). Node-side
/// only: the phone product is text-only (CLAUDE.md) and never produces these.
public struct LLMImagePart: Sendable, Equatable {
    /// The image MIME type (e.g. `image/png`, `image/jpeg`) — the `mimeType` of the
    /// ACP image content block.
    public var mimeType: String
    /// The image bytes, base64-encoded — the `data` of the ACP image content block.
    public var base64Data: String
    public init(mimeType: String, base64Data: String) {
        self.mimeType = mimeType
        self.base64Data = base64Data
    }
}

/// One chat message in the running conversation the agent maintains across a turn.
public struct LLMMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    /// Assistant/user/system text. May be empty for an assistant turn that only
    /// emits tool calls.
    public var content: String
    /// Present only on `assistant` messages that requested tools — echoed back so
    /// the model sees its own calls alongside the `tool` results.
    public var toolCalls: [LLMToolCall]
    /// Present only on `tool` messages — which call this result answers.
    public var toolCallId: String?
    /// D2: images attached to a `user` turn (node-side vision). Default empty, so the
    /// common text-only path is byte-for-byte unchanged; when non-empty the OpenAI
    /// client emits the multimodal `content` ARRAY shape instead of the plain string.
    public var imageParts: [LLMImagePart]

    public init(
        role: Role, content: String, toolCalls: [LLMToolCall] = [], toolCallId: String? = nil,
        imageParts: [LLMImagePart] = []
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.imageParts = imageParts
    }
}

/// A function/tool the agent advertises to the model (OpenAI `tools[]` entry,
/// `type:"function"`). `parameters` is a JSON-Schema object.
public struct LLMTool: Sendable {
    public var name: String
    public var description: String
    public var parameters: JSONValue
    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A tool call the model asked for (OpenAI `tool_calls[]` entry). `arguments` is the
/// raw JSON string the model produced; callers decode it.
public struct LLMToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// Decode `arguments` (a JSON string) into a JSONValue object; empty/invalid → `{}`.
    public var argumentsJSON: JSONValue {
        JSONValue.parse(arguments) ?? .object([:])
    }
}

/// One model response: either final assistant text, or a set of tool calls to run.
public struct LLMResponse: Sendable, Equatable {
    public var content: String
    public var toolCalls: [LLMToolCall]
    public init(content: String, toolCalls: [LLMToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
    public var wantsTools: Bool { !toolCalls.isEmpty }
}

public enum LLMError: Error, Sendable, Equatable {
    case notConfigured(String)
    case http(Int, String)
    case badResponse(String)
}

/// Token usage as reported by an OpenAI-compatible endpoint's `usage` object
/// (the MLX/LM Studio/vLLM servers all include it). All fields optional — a
/// server that omits `usage` yields all-nil, which callers MUST NOT record as
/// zero (NIP-AM §Numeric validity). Surfaced via `usageObserver` so callers
/// like the Buzz gateway can emit honest NIP-AM turn metrics with REAL counts.
public struct LLMUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, totalTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }
    public var hasAnyCount: Bool {
        promptTokens != nil || completionTokens != nil || totalTokens != nil
    }
}

/// The seam the agent talks to. Production: `OpenAICompatibleLLMClient`. Tests:
/// `MockLLMClient`. Executable smoke test: `EchoLLMClient`.
public protocol LLMClient: Sendable {
    /// Run one chat completion. `tools` may be empty (no tools advertised).
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse

    /// Run one chat completion, delivering the FINAL answer incrementally via
    /// `onDelta` (each call a newly-produced slice of visible text, reasoning trace
    /// already stripped), and returning the assembled response. Clients that don't
    /// implement streaming get the default below: call `complete` and emit the whole
    /// answer once — so mocks/tests need no change and a tool-call turn (non-empty
    /// `toolCalls`) is never streamed.
    func stream(
        messages: [LLMMessage], tools: [LLMTool], onDelta: @Sendable (String) async -> Void
    ) async throws -> LLMResponse
}

extension LLMClient {
    /// Default streaming = one-shot complete, then emit the final text once. A
    /// response that wants tools emits nothing (the agent doesn't stream tool turns).
    public func stream(
        messages: [LLMMessage], tools: [LLMTool], onDelta: @Sendable (String) async -> Void
    ) async throws -> LLMResponse {
        let response = try await complete(messages: messages, tools: tools)
        if !response.wantsTools, !response.content.isEmpty {
            await onDelta(response.content)
        }
        return response
    }
}

/// WS-B5: a refinement of `LLMClient` for a backend that keeps its OWN server-side
/// conversation state, bucketed by a session key it does NOT get from `LLMMessage`/
/// `LLMTool` (e.g. `SybilclawLLMClient`, whose turns ride the sybilclaw Gateway's
/// `chat.send sessionKey`). `ACPAgent.runModelCall` checks for this conformance via
/// `as?` before falling back to the plain `complete(messages:tools:)`, so every OTHER
/// `LLMClient` (`OpenAICompatibleLLMClient`, `EchoLLMClient`, test mocks, Huginn's
/// `InspectingLLMClient`) is completely unaffected — this is purely additive.
///
/// Passing the ACP `sessionId` through lets a session-scoped backend give each ACP
/// `session/new` (i.e. each distinct conversation/project thread the agent serves)
/// its OWN backend session, instead of bucketing every session under one shared key —
/// the fix for the cross-conversation bleed a single process-lifetime session key caused
/// (see `SybilclawGatewayClient`'s "Session scoping" doc and `SybilclawLLMClient`).
public protocol SessionScopedLLMClient: LLMClient {
    /// Same contract as `LLMClient.complete`, but scoped to `sessionId` — the caller's
    /// ACP session id. Two different `sessionId`s MUST resolve to two independent
    /// backend sessions (no shared state, no bleed).
    func complete(messages: [LLMMessage], tools: [LLMTool], sessionId: String) async throws
        -> LLMResponse
}

// MARK: - Config (ENV)

public struct LLMConfig: Sendable {
    public var url: String
    public var token: String
    public var model: String
    /// Per-request timeout. A self-hosted model that wedges (stuck decode, swapped-out
    /// weights, a peer that stopped responding mid-stream) would otherwise hang the
    /// whole turn forever — `runTurn` races every completion against this so a stalled
    /// model surfaces as a failure instead of a deadlock. Applied to both the
    /// `URLRequest` and the `URLSession` resource timeout. Env:
    /// `ELDR_LLM_TIMEOUT_SECONDS` (default 120).
    public var requestTimeoutSeconds: Double

    public init(url: String, token: String, model: String, requestTimeoutSeconds: Double = 0) {
        self.url = url
        self.token = token
        self.model = model
        // 0 (default) = unlimited; a positive value bounds a single request.
        self.requestTimeoutSeconds = max(0, requestTimeoutSeconds)
    }

    /// Read `ELDR_LLM_URL` / `ELDR_LLM_TOKEN` / `ELDR_LLM_MODEL` /
    /// `ELDR_LLM_TIMEOUT_SECONDS` with the documented defaults (LM Studio's local
    /// OpenAI server).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> LLMConfig
    {
        let timeout = env["ELDR_LLM_TIMEOUT_SECONDS"]
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { max(0, $0) } ?? 0  // unset ⇒ 0 = unlimited
        return LLMConfig(
            url: env["ELDR_LLM_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:1337/v1",
            token: env["ELDR_LLM_TOKEN"] ?? "",
            model: env["ELDR_LLM_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "local-model",
            requestTimeoutSeconds: timeout)
    }
}

// MARK: - OpenAI-compatible HTTP client

/// Talks Chat Completions to any OpenAI-shaped endpoint (LM Studio / Ollama / vLLM /
/// a vendor). The token is OPTIONAL — local servers usually have none, so no
/// `Authorization` header is sent on an empty token. Strips the reasoning trace
/// from final assistant text.
public struct OpenAICompatibleLLMClient: LLMClient {
    public let config: LLMConfig
    private let session: URLSession
    /// Optional tap on the model's RAW output, BEFORE reasoning-trace stripping. When
    /// non-nil it is called with each raw `delta.content` slice as it streams in
    /// (`stream`) and with the full raw `message.content` of a one-shot reply
    /// (`complete`) — so a debugging UI can show a reasoning model's chain-of-thought
    /// (`<think>…`, `<|channel>thought…`) that the chat itself never sees. Default nil
    /// ⇒ NO observation and ZERO behavior change for every existing caller (the relay
    /// host, the node, the CLI): the stripped `LLMResponse`/`onDelta` path is identical.
    /// Must be `@Sendable` (the SSE read runs off the caller's actor).
    private let rawObserver: (@Sendable (String) -> Void)?
    /// Optional tap on the response `usage` object (token counts). Called once
    /// per non-streamed `complete` when the endpoint reports usage. Default nil
    /// ⇒ no observation and zero behavior change for every existing caller.
    private let usageObserver: (@Sendable (LLMUsage) -> Void)?

    public init(
        config: LLMConfig, session: URLSession? = nil,
        rawObserver: (@Sendable (String) -> Void)? = nil,
        usageObserver: (@Sendable (LLMUsage) -> Void)? = nil
    ) {
        self.config = config
        self.session = session ?? Self.makeSession(timeout: config.requestTimeoutSeconds)
        self.rawObserver = rawObserver
        self.usageObserver = usageObserver
    }

    /// An ephemeral session whose request/resource timeouts match the configured
    /// per-request budget, so a wedged server can't hold a socket open forever.
    private static func makeSession(timeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // ≤0 ⇒ effectively unlimited (one year): a slow local model generating a long
        // answer must not be cut off; a positive value opts into a bound.
        let t = timeout > 0 ? timeout : 31_536_000
        configuration.timeoutIntervalForRequest = t
        configuration.timeoutIntervalForResource = t
        return URLSession(configuration: configuration)
    }

    /// Normalize whatever slice of the OpenAI path the user typed to a full
    /// `/chat/completions` URL (mirrors CustomOpenAIProvider.endpoint()).
    func endpoint() -> URL? {
        var base = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if base.hasSuffix("/v1") { return URL(string: base + "/chat/completions") }
        if let u = URL(string: base), u.path.isEmpty || u.path == "/" {
            return URL(string: base + "/v1/chat/completions")
        }
        return URL(string: base + "/chat/completions")
    }

    /// G4 (statusreport §2.4): is the configured LLM endpoint on the loopback
    /// interface — i.e. an on-device model server (LM Studio / Ollama / vLLM)? Only
    /// `127.0.0.1`, `localhost`, and IPv6 `::1` count; anything else (a LAN IP, a
    /// hostname, a cloud vendor) is treated as a real network target. Used to decide
    /// whether outgoing prompts must be credential-scrubbed before egress: loopback
    /// stays on-device, so it keeps full fidelity; non-loopback leaves the device, so
    /// it gets scrubbed. Delegates the host classification (and its conservative
    /// nil/unparseable → NOT-loopback fallback) to the shared `isLoopbackHost` below.
    func isLoopbackEndpoint() -> Bool {
        Self.isLoopbackHost(endpoint()?.host)
    }

    /// G4 (statusreport §2.4): the single source of truth for "is this host the loopback
    /// interface?" — shared by the LLM endpoint check above and `ContextGraphClient`'s
    /// egress gate so the on-device hostname set is defined exactly once. Only
    /// `127.0.0.1`, `localhost`, and IPv6 `::1` count. Conservative on ambiguity: a nil or
    /// empty host is NOT loopback (so the caller scrubs — the privacy-maximizing default,
    /// SPEC §0). Case-insensitive; strips an IPv6 literal's brackets (`URL.host` already
    /// removes them, but we normalize defensively).
    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            !host.isEmpty
        else { return false }
        switch host.lowercased() {
        case "127.0.0.1", "localhost", "::1": return true
        default: return false
        }
    }

    public func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        let request = try makeRequest(messages: messages, tools: tools, stream: false)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, Self.apiErrorMessage(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw LLMError.badResponse("non-JSON response")
        }
        let json = JSONValue(foundation: object)
        // RAW tap (pre-strip): hand the unmodified assistant text to the observer so a
        // debugging UI can show the model's reasoning trace. No-op when unset.
        if let rawObserver,
            let raw = json["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue,
            !raw.isEmpty
        {
            rawObserver(raw)
        }
        // Usage tap: surface the endpoint's token counts (NIP-AM honesty). Only
        // fires when a `usage` object is present with at least one count.
        if let usageObserver, let usage = json["usage"] {
            let parsed = LLMUsage(
                promptTokens: usage["prompt_tokens"]?.intValue,
                completionTokens: usage["completion_tokens"]?.intValue,
                totalTokens: usage["total_tokens"]?.intValue)
            if parsed.hasAnyCount { usageObserver(parsed) }
        }
        return try Self.decode(json)
    }

    /// Streaming completion over SSE (`"stream": true`). Reads the chunked `data:`
    /// lines, accumulates `choices[0].delta.content` and any tool-call deltas, and
    /// forwards each NEW slice of VISIBLE final text to `onDelta`. Reasoning is never
    /// streamed: text is buffered until the reasoning trace closes (`</think>`), so a
    /// reasoning model's chain-of-thought is stripped before any delta is emitted —
    /// the same guarantee `complete` gives for a one-shot response.
    public func stream(
        messages: [LLMMessage], tools: [LLMTool], onDelta: @Sendable (String) async -> Void
    ) async throws -> LLMResponse {
        #if canImport(Darwin)
        let request = try makeRequest(messages: messages, tools: tools, stream: true)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Drain the (small) error body so we can surface the server's message.
            var body = Data()
            for try await byte in bytes { body.append(byte); if body.count > 64 * 1024 { break } }
            throw LLMError.http(http.statusCode, Self.apiErrorMessage(body))
        }

        var assembler = StreamAssembler()
        for try await line in bytes.lines {
            // SSE framing: `data: {json}` per event, terminated by `data: [DONE]`.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let json = JSONValue.parse(payload) else { continue }
            // RAW tap (pre-strip): forward the unmodified `delta.content` slice — incl.
            // any in-progress reasoning trace — to the observer BEFORE the assembler
            // strips it. No-op when unset, so the relay/node/CLI path is untouched.
            if let rawObserver,
                let rawPiece = json["choices"]?.arrayValue?.first?["delta"]?["content"]?
                    .stringValue, !rawPiece.isEmpty
            {
                rawObserver(rawPiece)
            }
            if let emit = assembler.consume(json), !emit.isEmpty { await onDelta(emit) }
        }
        return assembler.finish()
        #else
        // Linux (swift-corelibs-foundation): URLSession has no async `bytes(for:)`/AsyncBytes,
        // so SSE token streaming isn't available. Fall back to a single non-streamed
        // completion and emit the whole visible text as one delta — a headless Linux node
        // loses token-by-token display, not correctness (real Linux streaming is a follow-up).
        let response = try await complete(messages: messages, tools: tools)
        if !response.content.isEmpty { await onDelta(response.content) }
        return response
        #endif
    }

    /// Build the POST request for one completion. `stream` flips SSE on.
    private func makeRequest(messages: [LLMMessage], tools: [LLMTool], stream: Bool) throws
        -> URLRequest
    {
        guard let url = endpoint() else {
            throw LLMError.notConfigured(
                "Set ELDR_LLM_URL (e.g. http://127.0.0.1:1337/v1).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.requestTimeoutSeconds > 0 ? config.requestTimeoutSeconds : 31_536_000
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // G4 (statusreport §2.4): cloud-egress credential scrub. When the endpoint is
        // NON-loopback the prompt is about to leave the device for a real network /
        // cloud target, so scrub each outgoing message's free-text `content` (incl.
        // `tool` result content) with the vendored redactor before it hits the wire —
        // a secret pasted into a prompt must not egress in cleartext. An on-device
        // (loopback) model server keeps full fidelity: no scrub, identical to before.
        // This is the single choke point for both `complete` and `stream` (both build
        // their request here). NOTE: the `rawObserver` debug tap fires later, in
        // `complete`/`stream` on the model's RESPONSE, so it is unaffected; the request
        // body is what we harden here. `toolCalls`/`tool_call_id`/role are control
        // plane, not free text, and are left as-is.
        let outgoing = Self.coalescingLeadingSystem(
            isLoopbackEndpoint() ? messages : messages.map(Self.scrubbed))
        var payload: [String: JSONValue] = [
            "model": .string(config.model),
            // Coding agents loop tool calls; give reasoning models room before the
            // trace is stripped.
            "max_tokens": .int(2048),
            "messages": .array(outgoing.map(Self.encode(message:))),
        ]
        if stream { payload["stream"] = .bool(true) }
        if !tools.isEmpty {
            payload["tools"] = .array(tools.map(Self.encode(tool:)))
            payload["tool_choice"] = .string("auto")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: JSONValue.object(payload).foundation)
        return request
    }

    /// Join the LEADING run of `system` messages into a single one.
    ///
    /// `ACPAgent` deliberately builds that run as separate messages — project
    /// context, then the operating prompt, then the read-only note, then any
    /// contextgraph assembly — because `ContextBudget.trim` anchors on them
    /// individually. That is fine for OpenAI itself, but `mlx_lm.server` (the
    /// on-device MLX backend) accepts exactly ONE system message and rejects a
    /// second one with **HTTP 404 `"System message must be at the beginning."`** —
    /// a status that reads like a bad URL or a missing model and sent a real
    /// debugging session chasing both. Several other OpenAI-compatible servers
    /// (llama.cpp, some vLLM builds) have the same one-system-message rule.
    ///
    /// Joining here, at the encode boundary, keeps the agent's message model and
    /// `trim`'s anchoring untouched while putting exactly one system message on the
    /// wire. Blank sections are dropped so the join never emits stray separators,
    /// and only the LEADING run is touched — a later system message (none today)
    /// would be left alone rather than silently reordered into the preamble.
    static func coalescingLeadingSystem(_ messages: [LLMMessage]) -> [LLMMessage] {
        let run = messages.prefix { $0.role == .system }
        guard run.count > 1 else { return messages }
        let joined =
            run
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let rest = Array(messages.dropFirst(run.count))
        // An all-blank run carries nothing; emitting one empty system message instead
        // would just hand the server a second thing to have an opinion about.
        guard !joined.isEmpty else { return rest }
        return [LLMMessage(role: .system, content: joined)] + rest
    }

    /// Pull the server's explanation out of an error body, else a generic note.
    ///
    /// Two shapes, because the on-device servers disagree with OpenAI: the OpenAI
    /// shape nests it (`{"error":{"message":…}}`), while `mlx_lm.server` puts a bare
    /// string there (`{"error":"System message must be at the beginning."}`). Only
    /// the nested form was read, so every MLX-side rejection surfaced as the useless
    /// "HTTP 404: request rejected" — the server had said exactly what was wrong and
    /// we threw it away. Read both.
    static func apiErrorMessage(_ data: Data) -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"]
        let message =
            (error as? [String: Any])?["message"] as? String
            ?? error as? String
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? "request rejected" : trimmed!
    }

    // MARK: Encoding (OpenAI request shape)

    /// G4 (statusreport §2.4): return a copy of `m` with its free-text fields
    /// credential-scrubbed via the vendored `ACPLogRedactor` (which mirrors
    /// `PQRCCore.CredentialRedactor` — PQRCACP is zero-dependency and can't import the
    /// canonical one). Applied to EVERY role's `content`, which covers a secret pasted
    /// into a `user` turn AND one captured in a `tool` result's content — AND to each
    /// assistant `toolCall.arguments`. The arguments are the model-produced JSON string
    /// for a call (`write_file` content, `run_shell` command, …); an assistant tool-call
    /// turn is re-sent every loop iteration (`ACPAgent` rebuilds the running transcript),
    /// so a credential echoed inside those arguments would otherwise egress in cleartext
    /// on each iteration. The redactor is conservative and string-safe, so scrubbing the
    /// raw JSON string is fine (a marker only ever replaces a key-shaped run). `toolCall.id`,
    /// `toolCall.name`, and `toolCallId` are control-plane identifiers, not free text, so
    /// they pass through unchanged. Caller gates this on a non-loopback endpoint.
    static func scrubbed(_ m: LLMMessage) -> LLMMessage {
        let scrubbedCalls = m.toolCalls.map { call in
            call.arguments.isEmpty
                ? call
                : LLMToolCall(
                    id: call.id, name: call.name,
                    arguments: ACPLogRedactor.scrub(call.arguments))
        }
        let scrubbedContent = m.content.isEmpty ? m.content : ACPLogRedactor.scrub(m.content)
        // D2: imageParts pass through VERBATIM. A base64 image is a long high-entropy
        // run the entropy redactor would shred — and an image is not a credential — so
        // the scrub MUST skip it. Only `content` text and tool `arguments` are scrubbed.
        return LLMMessage(
            role: m.role, content: scrubbedContent,
            toolCalls: scrubbedCalls, toolCallId: m.toolCallId, imageParts: m.imageParts)
    }

    static func encode(message m: LLMMessage) -> JSONValue {
        var obj: [String: JSONValue] = [
            "role": .string(m.role.rawValue),
            // D2: a message carrying image parts uses the OpenAI multimodal `content`
            // ARRAY (text part + one image_url data-URI per image); a message with no
            // images keeps the plain STRING content — byte-for-byte the prior shape, so
            // the overwhelmingly-common text path is completely unchanged.
            "content": m.imageParts.isEmpty
                ? .string(m.content) : encodeMultimodalContent(m),
        ]
        if !m.toolCalls.isEmpty {
            obj["tool_calls"] = .array(
                m.toolCalls.map { call in
                    .object([
                        "id": .string(call.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(call.name),
                            "arguments": .string(call.arguments),
                        ]),
                    ])
                })
        }
        if let id = m.toolCallId { obj["tool_call_id"] = .string(id) }
        return .object(obj)
    }

    /// D2: the OpenAI vision `content` ARRAY for a message that has image parts — a
    /// leading `{type:"text"}` part (omitted only when the text is empty, so an
    /// image-only turn still produces a valid non-empty array) followed by one
    /// `{type:"image_url", image_url:{url:"data:<mime>;base64,<data>"}}` per image.
    /// This is the shape OpenAI/LM Studio/vLLM accept for vision; the base64 bytes go
    /// out exactly as received (never scrubbed — see `scrubbed`).
    static func encodeMultimodalContent(_ m: LLMMessage) -> JSONValue {
        var parts: [JSONValue] = []
        if !m.content.isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(m.content)]))
        }
        for image in m.imageParts {
            parts.append(
                .object([
                    "type": .string("image_url"),
                    "image_url": .object([
                        "url": .string("data:\(image.mimeType);base64,\(image.base64Data)")
                    ]),
                ]))
        }
        return .array(parts)
    }

    static func encode(tool t: LLMTool) -> JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(t.name),
                "description": .string(t.description),
                "parameters": t.parameters,
            ]),
        ])
    }

    // MARK: Decoding (OpenAI response shape)

    static func decode(_ json: JSONValue) throws -> LLMResponse {
        guard let choice = json["choices"]?.arrayValue?.first,
            let message = choice["message"]
        else { throw LLMError.badResponse("missing choices[0].message") }

        let rawContent = message["content"]?.stringValue ?? ""
        let content = rawContent.strippingReasoningTrace()

        var calls: [LLMToolCall] = []
        if let toolCalls = message["tool_calls"]?.arrayValue {
            for tc in toolCalls {
                guard let fn = tc["function"] else { continue }
                let id = tc["id"]?.stringValue ?? "call_\(calls.count)"
                let name = fn["name"]?.stringValue ?? ""
                // `arguments` is a JSON STRING in OpenAI's shape; some servers emit
                // an object — accept either.
                let args: String
                if let s = fn["arguments"]?.stringValue {
                    args = s
                } else if let argObj = fn["arguments"] {
                    args = argObj.serialized()
                } else {
                    args = "{}"
                }
                if !name.isEmpty { calls.append(LLMToolCall(id: id, name: name, arguments: args)) }
            }
        }
        return LLMResponse(content: content, toolCalls: calls)
    }
}

// MARK: - SSE stream assembler

/// Accumulates an OpenAI streaming completion across `data:` events into a final
/// `LLMResponse`, emitting only the VISIBLE answer incrementally. Two rules keep
/// chain-of-thought off the wire:
///  - any `delta.reasoning_content` (a separate reasoning channel some servers use)
///    is dropped outright — it's never visible answer text;
///  - `delta.content` is accumulated raw, then run through `strippingReasoningTrace`
///    before emitting, so an inline `<think>…</think>` block is buffered (the stripper
///    yields nothing usable while the tag is open) and only the answer after it
///    streams out. Emission is monotonic: each `consume` returns just the newly-
///    revealed suffix of the cleaned text.
struct StreamAssembler {
    private var rawContent = ""
    /// Accumulated tool calls keyed by their streaming `index` (arguments arrive in
    /// fragments and must be concatenated per index).
    private var toolCallsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
    private var toolCallOrder: [Int] = []
    /// Count of characters of cleaned text already handed to `onDelta`.
    private var emittedChars = 0

    /// Fold one parsed SSE event; returns the new slice of visible text to emit (nil
    /// when nothing new is visible yet — e.g. still inside a reasoning trace).
    mutating func consume(_ json: JSONValue) -> String? {
        guard let delta = json["choices"]?.arrayValue?.first?["delta"] else { return nil }

        if let toolCalls = delta["tool_calls"]?.arrayValue {
            for (offset, tc) in toolCalls.enumerated() {
                let index = tc["index"]?.intValue ?? offset
                var entry = toolCallsByIndex[index] ?? (id: "", name: "", arguments: "")
                if toolCallsByIndex[index] == nil { toolCallOrder.append(index) }
                if let id = tc["id"]?.stringValue, !id.isEmpty { entry.id = id }
                if let fn = tc["function"] {
                    if let name = fn["name"]?.stringValue, !name.isEmpty { entry.name = name }
                    if let args = fn["arguments"]?.stringValue { entry.arguments += args }
                }
                toolCallsByIndex[index] = entry
            }
        }

        guard let piece = delta["content"]?.stringValue, !piece.isEmpty else { return nil }
        rawContent += piece
        let clean = rawContent.strippingReasoningTrace()
        guard clean.count > emittedChars else { return nil }
        // Only emit if the prefix is stable (it is, once the reasoning trace closed);
        // otherwise wait for the trace to settle rather than print garbled text.
        let cleanChars = Array(clean)
        guard cleanChars.count > emittedChars else { return nil }
        let slice = String(cleanChars[emittedChars...])
        emittedChars = cleanChars.count
        return slice
    }

    /// The assembled final response after the stream ends.
    func finish() -> LLMResponse {
        let calls = toolCallOrder.compactMap { index -> LLMToolCall? in
            guard let entry = toolCallsByIndex[index], !entry.name.isEmpty else { return nil }
            let id = entry.id.isEmpty ? "call_\(index)" : entry.id
            let arguments = entry.arguments.isEmpty ? "{}" : entry.arguments
            return LLMToolCall(id: id, name: entry.name, arguments: arguments)
        }
        return LLMResponse(content: rawContent.strippingReasoningTrace(), toolCalls: calls)
    }
}

// MARK: - Built-in echo LLM (executable smoke test; ELDR_ACP_FAKE_LLM=1)

/// A zero-dependency "LLM" that never calls a tool and just echoes the last user
/// message back as the final answer, so `eldr-acp` can be exercised end-to-end with
/// no model server running. Used by the executable when `ELDR_ACP_FAKE_LLM=1`.
public struct EchoLLMClient: LLMClient {
    public init() {}
    public func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        let lastUser = messages.last { $0.role == .user }?.content ?? ""
        return LLMResponse(content: "Echo: \(lastUser)")
    }
}
