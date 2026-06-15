import Foundation

/// A spec-compliant Model Context Protocol server, transport-agnostic: it turns a
/// single JSON-RPC request line into a single response line (or nil for a
/// notification). The executable wraps it in a stdio read/write loop; tests call
/// `handle(line:)` directly. Read-only (Phase 1) — see `SecureChatBridge`.
public struct MCPServer: Sendable {
    public static let serverName = "eldrchat"
    public static let serverVersion = "0.1.0"
    public static let defaultProtocolVersion = "2024-11-05"
    /// MCP revisions we'll echo back if the client requests them; otherwise we
    /// answer with `defaultProtocolVersion` (the broadest-supported revision).
    static let knownVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25",
    ]

    let bridge: any SecureChatBridge
    public init(bridge: any SecureChatBridge) { self.bridge = bridge }

    struct RPCError: Error { let code: Int; let message: String }

    /// Handle one JSON-RPC message line. Returns the response line, or nil for a
    /// notification (no `id`) or unparseable input (per JSON-RPC, a parse error on
    /// a would-be notification gets no reply).
    public func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let id = obj["id"]  // nil → notification; present (incl. NSNull) → request
        guard let method = obj["method"] as? String else {
            return id == nil ? nil : errorResponse(id: id, code: -32600, message: "Invalid Request")
        }
        // Notifications carry no id and get no response (e.g. notifications/initialized).
        if id == nil { return nil }

        let params = obj["params"] as? [String: Any] ?? [:]
        do {
            let result = try await dispatch(method: method, params: params)
            return successResponse(id: id, result: result)
        } catch let e as RPCError {
            return errorResponse(id: id, code: e.code, message: e.message)
        } catch {
            return errorResponse(id: id, code: -32603, message: "Internal error")
        }
    }

    private func dispatch(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize": return initializeResult(params: params)
        case "ping": return [String: Any]()
        case "tools/list": return toolsListResult()
        case "tools/call": return try await toolsCallResult(params: params)
        case "resources/list": return await resourcesListResult()
        case "resources/read": return try await resourcesReadResult(params: params)
        default: throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Lifecycle

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version =
            (requested.flatMap { Self.knownVersions.contains($0) ? $0 : nil })
            ?? Self.defaultProtocolVersion
        return [
            "protocolVersion": version,
            // Advertise only what we serve: read tools + read resources.
            "capabilities": [
                "tools": [String: Any](),
                "resources": [String: Any](),
            ],
            "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
            "instructions":
                "Read-only access to the user's end-to-end-encrypted EldrChat conversations. "
                + "Sender names are local codenames; content is firewall-redacted and byte-bounded. "
                + "There are no write/send tools — you cannot make EldrChat post anything.",
        ]
    }

    // MARK: - Tools

    private func toolsListResult() -> [String: Any] {
        [
            "tools": [
                tool(
                    "list_conversations",
                    "List the user's secure conversations (id, title, recent-activity, unread count).",
                    properties: [:], required: []),
                tool(
                    "read_conversation",
                    "Read recent messages from one conversation. Sender names are local codenames; content is firewall-redacted and byte-bounded.",
                    properties: [
                        "conversationID": ["type": "string", "description": "id from list_conversations"],
                        "limit": ["type": "integer", "description": "max messages (default 20, max 200)"],
                    ], required: ["conversationID"]),
                tool(
                    "search_messages",
                    "Search the user's messages for a query string.",
                    properties: [
                        "query": ["type": "string"],
                        "limit": ["type": "integer", "description": "max results (default 20, max 200)"],
                    ], required: ["query"]),
                tool(
                    "get_context_preview",
                    "Show exactly what the user's AI sees as context for a conversation (the redacted, bounded transcript).",
                    properties: ["conversationID": ["type": "string"]], required: ["conversationID"]),
            ]
        ]
    }

    private func tool(
        _ name: String, _ description: String, properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": [
                "type": "object", "properties": properties, "required": required,
            ],
        ]
    }

    private func toolsCallResult(params: [String: Any]) async throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw RPCError(code: -32602, message: "missing tool name")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        func boundedLimit(_ defaultValue: Int) -> Int {
            max(1, min((args["limit"] as? Int) ?? defaultValue, 200))
        }
        func requireConversationID() throws -> String {
            guard let id = args["conversationID"] as? String, !id.isEmpty else {
                throw RPCError(code: -32602, message: "conversationID is required")
            }
            return id
        }

        let text: String
        switch name {
        case "list_conversations":
            text = render(conversations: await bridge.conversations())
        case "read_conversation":
            let id = try requireConversationID()
            text = render(messages: await bridge.messages(conversationID: id, limit: boundedLimit(20)))
        case "search_messages":
            guard let query = args["query"] as? String, !query.isEmpty else {
                throw RPCError(code: -32602, message: "query is required")
            }
            text = render(messages: await bridge.search(query: query, limit: boundedLimit(20)))
        case "get_context_preview":
            let id = try requireConversationID()
            text = render(messages: await bridge.contextPreview(conversationID: id))
        default:
            throw RPCError(code: -32602, message: "unknown tool: \(name)")
        }
        return ["content": [["type": "text", "text": text]], "isError": false]
    }

    // MARK: - Resources (each conversation is a read-only resource)

    private static let resourceScheme = "eldrchat://conversation/"

    private func resourcesListResult() async -> [String: Any] {
        let resources = await bridge.conversations().map { c in
            [
                "uri": "\(Self.resourceScheme)\(c.id)", "name": c.title,
                "mimeType": "text/plain", "description": "Secure conversation: \(c.title)",
            ]
        }
        return ["resources": resources]
    }

    private func resourcesReadResult(params: [String: Any]) async throws -> [String: Any] {
        guard let uri = params["uri"] as? String, uri.hasPrefix(Self.resourceScheme) else {
            throw RPCError(code: -32602, message: "unknown resource uri")
        }
        let id = String(uri.dropFirst(Self.resourceScheme.count))
        let text = render(messages: await bridge.messages(conversationID: id, limit: 50))
        return ["contents": [["uri": uri, "mimeType": "text/plain", "text": text]]]
    }

    // MARK: - Rendering (human-readable text content for the model)

    private func render(conversations: [MCPConversation]) -> String {
        guard !conversations.isEmpty else { return "(no conversations)" }
        return conversations.map { c in
            let unread = c.unread > 0 ? " · \(c.unread) unread" : ""
            return "- \(c.title)  [id: \(c.id)]\(unread)"
        }.joined(separator: "\n")
    }

    private func render(messages: [MCPMessage]) -> String {
        guard !messages.isEmpty else { return "(no messages)" }
        return messages.map { m in
            let who = m.role == "agent" ? "\(m.sender) (AI)" : m.sender
            return "\(who): \(m.text)"
        }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC envelopes

    private func successResponse(id: Any?, result: Any) -> String {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }
    private func errorResponse(id: Any?, code: Int, message: String) -> String {
        serialize(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }
    private func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let string = String(data: data, encoding: .utf8)
        else {
            return
                #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"serialization failed"}}"#
        }
        return string
    }
}
