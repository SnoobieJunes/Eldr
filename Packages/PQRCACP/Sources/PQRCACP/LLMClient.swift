import Foundation

// The BRAIN. An OpenAI-compatible Chat Completions client WITH tool/function
// calling, behind a protocol so tests inject a mock (no network in tests) and the
// executable can run against a built-in echo LLM. Config is read from the
// environment by `LLMConfig`. Self-hosted models (LM Studio / Ollama / vLLM) speak
// this shape.

// MARK: - Message & tool model (provider-agnostic, OpenAI-shaped)

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

    public init(
        role: Role, content: String, toolCalls: [LLMToolCall] = [], toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
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

    public init(url: String, token: String, model: String, requestTimeoutSeconds: Double = 120) {
        self.url = url
        self.token = token
        self.model = model
        // A non-positive timeout would fire instantly; treat ≤0 as the default.
        self.requestTimeoutSeconds = requestTimeoutSeconds > 0 ? requestTimeoutSeconds : 120
    }

    /// Read `ELDR_LLM_URL` / `ELDR_LLM_TOKEN` / `ELDR_LLM_MODEL` /
    /// `ELDR_LLM_TIMEOUT_SECONDS` with the documented defaults (LM Studio's local
    /// OpenAI server).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> LLMConfig
    {
        let timeout = env["ELDR_LLM_TIMEOUT_SECONDS"]
            .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 > 0 ? $0 : nil } ?? 120
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

    public init(config: LLMConfig, session: URLSession? = nil) {
        self.config = config
        self.session = session ?? Self.makeSession(timeout: config.requestTimeoutSeconds)
    }

    /// An ephemeral session whose request/resource timeouts match the configured
    /// per-request budget, so a wedged server can't hold a socket open forever.
    private static func makeSession(timeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
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

    public func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        let request = try makeRequest(messages: messages, tools: tools, stream: false)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, Self.apiErrorMessage(data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw LLMError.badResponse("non-JSON response")
        }
        return try Self.decode(JSONValue(foundation: object))
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
            if let emit = assembler.consume(json), !emit.isEmpty { await onDelta(emit) }
        }
        return assembler.finish()
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
        request.timeoutInterval = config.requestTimeoutSeconds
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var payload: [String: JSONValue] = [
            "model": .string(config.model),
            // Coding agents loop tool calls; give reasoning models room before the
            // trace is stripped.
            "max_tokens": .int(2048),
            "messages": .array(messages.map(Self.encode(message:))),
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

    /// Pull `error.message` out of an OpenAI-shaped error body, else a generic note.
    static func apiErrorMessage(_ data: Data) -> String {
        let message =
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
        return message ?? "request rejected"
    }

    // MARK: Encoding (OpenAI request shape)

    static func encode(message m: LLMMessage) -> JSONValue {
        var obj: [String: JSONValue] = [
            "role": .string(m.role.rawValue),
            "content": .string(m.content),
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
