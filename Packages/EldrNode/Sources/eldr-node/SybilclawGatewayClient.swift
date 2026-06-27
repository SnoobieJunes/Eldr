import Foundation

// Port of Huginn's `SybilclawGatewayClient` (Apps/Huginn/Sources/Services), trimmed to
// the `ask()` surface the headless node needs — the `SybilclawAgentRunner: BridgeAgentRunner`
// half stays in the app (the node bridges via an `LLMClient` adapter instead, see
// `SybilclawLLMClient`). Kept as its own copy here for the same reason `NodeKeychain`
// duplicates the app's `KeychainBox`: the daemon target stays self-contained and the
// reusable `EldrNodeCore` stays free of a URLSession gateway dependency.
//
// ⚠️ Stage 2 (DEMO-SYBILCLAW.md): this speaks the OpenClaw/sybilclaw Gateway protocol as
// documented from its source, but the live-gateway round-trip is UNVERIFIED on real
// hardware. The `--responder sybilclaw` path inherits that caveat until exercised against
// a running gateway. `--responder eldr-acp` is the proven fallback.

/// A client for the local OpenClaw / sybilclaw Gateway — the Node daemon that runs the
/// user's *own* assistant (its model, persona, memory, tools). The phone's message rides
/// the E2EE relay to this node; `SybilclawLLMClient` hands the turn to this client; the
/// reply goes back over the relay. The node's own `eldr-acp` LLM is NOT in this path.
///
/// Protocol facts (grounded in the OpenClaw source, not inferred):
///  • Frames are discriminated by `type` (no `jsonrpc` field): `req` / `res` / `event`.
///  • The FIRST frame MUST be a `connect` request declaring `role` + `scopes`.
///  • A turn runs via `chat.send` (returns the reply INLINE as `chat` events), targeting a
///    `sessionKey` created by `sessions.create`.
///  • Replies stream as `chat` events carrying `deltaText` (incremental) / `message`
///    (cumulative); the turn ends when `payload.state` is `final` (or `error`/`aborted`).
///  • `agents.list` → `{ agents:[{id,…}], defaultId, mainKey }` for self-healing target
///    selection when the gateway demands an explicit agent/session.
struct SybilclawGatewayClient: Sendable {
    let host: String
    let port: Int
    let token: String?
    let agentId: String?
    var overallTimeout: TimeInterval = 90

    init(host: String = "127.0.0.1", port: Int, token: String? = nil, agentId: String? = nil) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == false) ? token : nil
        self.agentId = (agentId?.isEmpty == false) ? agentId : nil
    }

    enum GatewayError: LocalizedError {
        case badURL
        case handshake(String)
        case rpc(String)
        case timeout(lastFrame: String?)
        case closed(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Bad sybilclaw gateway URL."
            case .handshake(let m):
                return "sybilclaw gateway handshake failed: \(m). "
                    + "Confirm the gateway is running and the port is right."
            case .rpc(let m): return "sybilclaw gateway error: \(m)"
            case .timeout(let f):
                return "sybilclaw gateway didn't reply in time."
                    + (f.map { " Last frame: \($0.prefix(200))" } ?? "")
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
            guard let result = try await group.next() else {
                throw GatewayError.timeout(lastFrame: nil)
            }
            group.cancelAll()
            return result
        }
    }

    private func askImpl(_ prompt: String) async throws -> String {
        guard let url = URL(string: "ws://\(host):\(port)/") else { throw GatewayError.badURL }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let connectID = UUID().uuidString
        try await send(task, ["type": "req", "id": connectID, "method": "connect", "params": connectParams()])
        _ = try await awaitResponse(task, id: connectID, context: "connect")

        do {
            return try await runTurn(task, prompt: prompt, agentId: agentId)
        } catch {
            guard Self.isSelectionError(error),
                let discovered = try? await discoverDefaultAgent(task),
                discovered != agentId
            else { throw error }
            return try await runTurn(task, prompt: prompt, agentId: discovered)
        }
    }

    private func runTurn(
        _ task: URLSessionWebSocketTask, prompt: String, agentId: String?
    ) async throws -> String {
        let sessionKey = "eldr-" + UUID().uuidString
        let createID = UUID().uuidString
        var createParams: [String: Any] = ["key": sessionKey]
        if let agentId { createParams["agentId"] = agentId }
        try await send(task, ["type": "req", "id": createID, "method": "sessions.create", "params": createParams])
        _ = try? await awaitResponse(task, id: createID, context: "sessions.create")

        let sendID = UUID().uuidString
        var sendParams: [String: Any] = [
            "sessionKey": sessionKey,
            "message": prompt,
            "idempotencyKey": UUID().uuidString,
        ]
        if let agentId { sendParams["agentId"] = agentId }
        try await send(task, ["type": "req", "id": sendID, "method": "chat.send", "params": sendParams])

        var assembled = ""
        var lastFrame: String?
        while !Task.isCancelled {
            let frame = try await receive(task)
            lastFrame = frame
            guard let obj = Self.json(frame) else { continue }
            switch obj["type"] as? String {
            case "res":
                if obj["id"] as? String == sendID, (obj["ok"] as? Bool) == false {
                    throw GatewayError.rpc(Self.errorText(obj) ?? "chat.send was rejected")
                }
            case "event":
                guard let payload = obj["payload"] as? [String: Any],
                    (payload["sessionKey"] as? String) == sessionKey
                else { continue }
                if let message = payload["message"] as? String {
                    assembled = message
                } else if let delta = payload["deltaText"] as? String {
                    if (payload["replace"] as? Bool) == true { assembled = delta }
                    else { assembled += delta }
                }
                switch payload["state"] as? String {
                case "final":
                    return assembled.isEmpty ? "(sybilclaw returned no text)" : assembled
                case "error":
                    throw GatewayError.rpc((payload["errorMessage"] as? String) ?? "agent run failed")
                case "aborted":
                    throw GatewayError.rpc("agent run was aborted")
                default:
                    break
                }
            default:
                break
            }
        }
        if !assembled.isEmpty { return assembled }
        throw GatewayError.timeout(lastFrame: lastFrame)
    }

    private func discoverDefaultAgent(_ task: URLSessionWebSocketTask) async throws -> String? {
        let listID = UUID().uuidString
        try await send(task, ["type": "req", "id": listID, "method": "agents.list", "params": [String: Any]()])
        let payload = try await awaitResponse(task, id: listID, context: "agents.list")
        if let defaultID = payload?["defaultId"] as? String, !defaultID.isEmpty { return defaultID }
        if let agents = payload?["agents"] as? [[String: Any]],
            let first = agents.first?["id"] as? String, !first.isEmpty
        { return first }
        return nil
    }

    private func connectParams() -> [String: Any] {
        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 4,
            "client": [
                "id": "eldr-node", "version": Self.appVersion,
                "platform": "macos", "mode": "operator",
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write"],
            "caps": [String](),
            "commands": [String](),
            "permissions": [String: Any](),
            "locale": "en-US",
            "userAgent": "eldr-node/\(Self.appVersion)",
        ]
        if let token { params["auth"] = ["token": token] }
        return params
    }

    private static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    private func send(_ task: URLSessionWebSocketTask, _ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ task: URLSessionWebSocketTask) async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: return ""
        }
    }

    @discardableResult
    private func awaitResponse(
        _ task: URLSessionWebSocketTask, id: String, context: String
    ) async throws -> [String: Any]? {
        while !Task.isCancelled {
            let frame = try await receive(task)
            guard let obj = Self.json(frame) else { continue }
            guard obj["type"] as? String == "res", obj["id"] as? String == id else { continue }
            if (obj["ok"] as? Bool) == true { return obj["payload"] as? [String: Any] }
            let message = Self.errorText(obj) ?? "rejected"
            throw context == "connect"
                ? GatewayError.handshake(message) : GatewayError.rpc("\(context): \(message)")
        }
        throw GatewayError.closed("closed during \(context)")
    }

    private static func json(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    private static func errorText(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] {
            return (e["message"] as? String) ?? (e["code"].map { "\($0)" })
        }
        return obj["error"] as? String
    }

    private static func isSelectionError(_ error: Error) -> Bool {
        guard let gw = error as? GatewayError else { return false }
        let text: String
        switch gw {
        case .rpc(let m), .handshake(let m): text = m.lowercased()
        case .timeout, .closed, .badURL: return false
        }
        return text.contains("agent") || text.contains("session")
            || text.contains("unavailable") || text.contains("choose")
    }
}
