import Foundation

/// A minimal client for **sybilclaw's (OpenClaw's) Gateway** — the Node daemon that runs
/// the user's *own* assistant (its model, persona/SOUL.md, per-user memory, and tools).
/// This is what lets an EldrChat phone "chat commands to sybilclaw and get a reply": the
/// phone's message rides the E2EE relay to Huginn, Huginn hands it to this client, the
/// client asks sybilclaw's assistant, and the reply goes back over the relay. `eldr-acp`
/// and its LLM are NOT in this path.
///
/// The Gateway speaks **WebSocket JSON-RPC (protocol v4)** on `:18789` by default. The
/// transport, framing, request/response correlation, auth header, timeout, and error
/// surfacing here are correct and compile-verified.
///
/// ⚠️ **VERIFY ON THE RUNNING SYBILCLAW (the one protocol detail I could not confirm
/// headlessly):** the exact *method name* and *params* that run an agent turn, and the
/// *shape of the reply frames*. The OpenClaw Gateway exposes ~200 RPC methods; the
/// agent-driving ones are documented as `agent` / `send` (side-effecting, needing an
/// idempotency key) at `docs.openclaw.ai/gateway/protocol` and `/reference/rpc`. The
/// request method/params and the reply extraction are isolated below (`requestMethod`,
/// `makeParams`, `extractText`) so they can be adjusted in one place once confirmed. The
/// reply extractor already tries the common shapes; if the cofounder's gateway uses
/// different field names, only those two helpers change.
struct SybilclawGatewayClient: Sendable {
    let host: String
    let port: Int
    /// Optional bearer token if the gateway requires auth (sent on the WS upgrade as
    /// `Authorization: Bearer …`). `nil` = no auth (typical for a localhost gateway).
    let token: String?
    /// Overall wall-clock cap for one ask (connect + send + read). `handleInboundPrompt`
    /// also wraps the run, but `agentRunTimeout` defaults to 0 (unlimited), so this is the
    /// backstop that keeps a silent gateway from hanging a turn forever.
    var overallTimeout: TimeInterval = 90

    init(host: String = "127.0.0.1", port: Int, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == false) ? token : nil
    }

    // MARK: Protocol specifics — VERIFY against the running sybilclaw (see header).

    /// The JSON-RPC method that runs one agent turn. Documented as `agent`; confirm.
    private var requestMethod: String { "agent" }

    /// Build the params for `requestMethod`. A fresh idempotency key per call (the
    /// side-effecting Gateway methods require one). Confirm the param key name(s).
    private func makeParams(prompt: String) -> [String: Any] {
        ["message": prompt, "idempotencyKey": UUID().uuidString]
    }

    /// Pull assistant text out of a Gateway frame. Tries the common shapes (a JSON-RPC
    /// `result`, or a streamed event's `params`) across the field names gateways use for
    /// reply text. Returns nil if this frame carries no text. Adjust here if needed.
    private func extractText(from obj: [String: Any]) -> String? {
        // result: String, or result.{text|message|content|output|reply}
        if let result = obj["result"] {
            if let s = result as? String, !s.isEmpty { return s }
            if let d = result as? [String: Any], let s = Self.firstText(d) { return s }
        }
        // streamed event: params.{text|delta|message|content|chunk}
        if let params = obj["params"] as? [String: Any], let s = Self.firstText(params) { return s }
        // bare top-level text/message
        return Self.firstText(obj)
    }

    private static func firstText(_ d: [String: Any]) -> String? {
        for key in ["text", "message", "content", "delta", "output", "reply", "chunk"] {
            if let s = d[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    // MARK: Ask

    enum GatewayError: LocalizedError {
        case badURL
        case rpc(String)
        case timeout(lastFrame: String?)
        case closed(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad sybilclaw gateway URL."
            case .rpc(let m): return "sybilclaw gateway error: \(m)"
            case .timeout(let f):
                return "sybilclaw gateway didn't reply in time."
                    + (f.map { " Last frame: \($0.prefix(200))" } ?? "")
                    + " (Confirm the gateway is running and the agent method/params match its protocol.)"
            case .closed(let m): return "sybilclaw gateway connection closed: \(m)"
            }
        }
    }

    /// Send `prompt` to sybilclaw's assistant and return its complete reply text. Races the
    /// whole exchange against `overallTimeout` so a silent gateway can't hang the turn.
    func ask(_ prompt: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.askImpl(prompt) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.overallTimeout * 1_000_000_000))
                throw GatewayError.timeout(lastFrame: nil)
            }
            guard let result = try await group.next() else { throw GatewayError.timeout(lastFrame: nil) }
            group.cancelAll()
            return result
        }
    }

    private func askImpl(_ prompt: String) async throws -> String {
        guard let url = URL(string: "ws://\(host):\(port)/") else { throw GatewayError.badURL }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Send the agent request.
        let requestId = UUID().uuidString
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": requestId,
            "method": requestMethod, "params": makeParams(prompt: prompt),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))

        // Read frames until the terminal reply for our id (or an error). Streamed text
        // chunks are accumulated; a `result` for our id (or a stream-end) finalizes.
        var assembled = ""
        var lastFrame: String?
        while !Task.isCancelled {
            let message = try await task.receive()
            let frame: String
            switch message {
            case .string(let s): frame = s
            case .data(let d): frame = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            lastFrame = frame
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any]
            else { continue }

            if let error = obj["error"] as? [String: Any] {
                let msg = (error["message"] as? String) ?? String(describing: error)
                throw GatewayError.rpc(msg)
            }
            if let chunk = extractText(from: obj) { assembled += chunk }

            // Terminal: a JSON-RPC response carrying our id (result present), or an event
            // flagged final/done. Either ends the turn.
            let isOurResult = (obj["id"].map { String(describing: $0) } == requestId) && obj["result"] != nil
            let isDone = (obj["params"] as? [String: Any])?["done"] as? Bool == true
                || obj["done"] as? Bool == true
            if isOurResult || isDone {
                return assembled.isEmpty ? "(sybilclaw returned no text)" : assembled
            }
        }
        if !assembled.isEmpty { return assembled }
        throw GatewayError.timeout(lastFrame: lastFrame)
    }
}

/// `BridgeAgentRunner` backed by sybilclaw's Gateway. Drop-in alternative to
/// `ACPDriverAgentRunner`: the owner's inbound chat (already C-3-gated + redaction-wrapped
/// by `handleInboundPrompt`) is answered by sybilclaw's own assistant instead of `eldr-acp`.
/// `workdir` is ignored — sybilclaw owns its own workspace.
struct SybilclawAgentRunner: BridgeAgentRunner {
    let client: SybilclawGatewayClient
    func run(prompt: String, workdir: String?) async throws -> String {
        try await client.ask(prompt)
    }
}
