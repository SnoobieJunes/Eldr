import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Seam for routing context assembly through an external context manager. The
/// agent depends on this protocol, not the concrete HTTP client, so unit tests
/// inject a deterministic stub and never touch the network (engineering
/// convention: no unit test hits the network/clock).
public protocol ContextGraphAssembling: Sendable {
    /// Whether the service is reachable right now. Failures → false (the caller
    /// falls back to local budgeting), never throws.
    func health() async -> Bool
    /// Ask the service to assemble prior context for `userText` within a token
    /// budget. Returns a rendered context block (possibly empty). Throws on
    /// transport/decoding failure so the caller can fall back for this turn.
    func assemble(userText: String, tokenBudget: Int) async throws -> String
    /// Record a completed turn so the graph learns it. Fire-and-forget: failures
    /// are swallowed (logged by the caller) — ingestion must never fail a turn.
    func ingest(userText: String, assistantText: String, channelLabel: String?) async
}

/// HTTP client for `rdevaul/contextgraph` (graph-based context manager). Talks to
/// its REST service (default `http://localhost:8302`): `GET /health`,
/// `POST /assemble`, `POST /ingest`. Request/response shapes mirror the project's
/// OpenClaw plugin (`plugin/index.ts`). All calls are localhost-only.
public struct ContextGraphClient: ContextGraphAssembling {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: String, timeout: TimeInterval = 4.0) {
        // Fall back to the documented default if the URL is malformed.
        self.baseURL = URL(string: baseURL) ?? URL(string: "http://localhost:8302")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: cfg)
    }

    public func health() async -> Bool {
        guard let url = URL(string: "health", relativeTo: baseURL) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    public func assemble(userText: String, tokenBudget: Int) async throws -> String {
        let body: [String: Any] = [
            "user_text": userText,
            "token_budget": tokenBudget,
            "tool_state": NSNull(),
        ]
        let data = try await post("assemble", body: body)
        let decoded = try JSONDecoder().decode(AssembleResponse.self, from: data)
        return Self.render(decoded)
    }

    public func ingest(userText: String, assistantText: String, channelLabel: String?) async {
        let now = Date().timeIntervalSince1970
        let id = "eldr-\(Int(now * 1000))"
        var body: [String: Any] = [
            "id": id,
            "external_id": id,
            "user_text": userText,
            "assistant_text": assistantText,
            "timestamp": now,
        ]
        if let channelLabel { body["channel_label"] = channelLabel }
        _ = try? await post("ingest", body: body)
    }

    // MARK: - Wire

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ContextGraphError.badURL(path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ContextGraphError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// Render assembled turns into a single context block for the system prompt.
    /// Unknown fields are ignored (forward-compat). Empty when nothing comes back.
    static func render(_ response: AssembleResponse) -> String {
        guard !response.messages.isEmpty else { return "" }
        let turns = response.messages.map { m -> String in
            var s = ""
            if let u = m.user_text, !u.isEmpty { s += "User: \(u)\n" }
            if let a = m.assistant_text, !a.isEmpty { s += "Assistant: \(a)" }
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !turns.isEmpty else { return "" }
        return "Relevant earlier context (assembled by contextgraph):\n\n"
            + turns.joined(separator: "\n\n")
    }

    /// `POST /assemble` response. Only the fields we consume are modeled; the rest
    /// (tags, total_tokens, sticky_count, …) are ignored.
    struct AssembleResponse: Decodable {
        struct Message: Decodable {
            let user_text: String?
            let assistant_text: String?
        }
        let messages: [Message]
    }
}

public enum ContextGraphError: Error, Equatable {
    case badURL(String)
    case badStatus(Int)
}
