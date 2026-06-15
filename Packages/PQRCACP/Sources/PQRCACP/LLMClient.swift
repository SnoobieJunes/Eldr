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
}

// MARK: - Config (ENV)

public struct LLMConfig: Sendable {
    public var url: String
    public var token: String
    public var model: String

    public init(url: String, token: String, model: String) {
        self.url = url
        self.token = token
        self.model = model
    }

    /// Read `ELDR_LLM_URL` / `ELDR_LLM_TOKEN` / `ELDR_LLM_MODEL` with the documented
    /// defaults (LM Studio's local OpenAI server).
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> LLMConfig
    {
        LLMConfig(
            url: env["ELDR_LLM_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://127.0.0.1:1337/v1",
            token: env["ELDR_LLM_TOKEN"] ?? "",
            model: env["ELDR_LLM_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "local-model")
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

    public init(config: LLMConfig, session: URLSession = .init(configuration: .ephemeral)) {
        self.config = config
        self.session = session
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
        guard let url = endpoint() else {
            throw LLMError.notConfigured(
                "Set ELDR_LLM_URL (e.g. http://127.0.0.1:1337/v1).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
        if !tools.isEmpty {
            payload["tools"] = .array(tools.map(Self.encode(tool:)))
            payload["tool_choice"] = .string("auto")
        }

        request.httpBody = try JSONSerialization.data(
            withJSONObject: JSONValue.object(payload).foundation)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw LLMError.http(http.statusCode, apiMessage ?? "request rejected")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw LLMError.badResponse("non-JSON response")
        }
        return try Self.decode(JSONValue(foundation: object))
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
