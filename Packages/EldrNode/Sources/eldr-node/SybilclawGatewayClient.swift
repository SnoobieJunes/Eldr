import Foundation

// Port of Huginn's `SybilclawGatewayClient` (Apps/Huginn/Sources/Services), trimmed to
// the `ask()` surface the headless node needs — the `SybilclawAgentRunner: BridgeAgentRunner`
// half stays in the app (the node bridges via an `LLMClient` adapter instead, see
// `SybilclawLLMClient`). Kept as its own copy here for the same reason `NodeKeychain`
// duplicates the app's `KeychainBox`: the daemon target stays self-contained and the
// reusable `EldrNodeCore` stays free of a URLSession gateway dependency.
//
// ⚠️ Stage 2 (DEMO-SYBILCLAW.md): this speaks the OpenClaw/sybilclaw Gateway protocol,
// aligned field-for-field with the fork's own reference clients (rdevaul/sybilclaw apps/ios
// + apps/android) — connect handshake, chat.send, and the agent/chat event stream. The
// live-gateway round-trip is still UNVERIFIED on real hardware; `--responder sybilclaw`
// inherits that caveat until exercised against a running gateway. `--responder eldr-acp` is
// the proven fallback. KEEP THIS IN SYNC with Apps/Huginn's copy — they drifted once (this
// copy kept an off-allowlist handshake after the app's was fixed) and that broke this path.

/// A client for the local OpenClaw / sybilclaw Gateway — the Node daemon that runs the
/// user's *own* assistant (its model, persona, memory, tools). The phone's message rides
/// the E2EE relay to this node; `SybilclawLLMClient` hands the turn to this client; the
/// reply goes back over the relay. The node's own `eldr-acp` LLM is NOT in this path.
///
/// Protocol facts (grounded in the OpenClaw source, not inferred):
///  • Frames are discriminated by `type` (no `jsonrpc` field): `req` / `res` / `event`.
///  • The FIRST frame MUST be a `connect` request declaring `role` + `scopes`.
///  • A turn runs via `chat.send` {sessionKey, message, idempotencyKey}; the `res` only acks
///    with `{ runId, status:"in_flight" }`. No separate session-create step (the gateway
///    resolves/creates the session from `sessionKey`). Target an agent via the key
///    `agent:<id>:<base>` — `agentId` is not a `chat.send` field.
///  • The reply streams as events correlated by `runId`: assistant text on `event:"agent"`
///    (stream "assistant", cumulative `payload.data.text`), terminating on an `event:"chat"`
///    whose `payload.state` is `final` (or `error`/`aborted`).
///  • `agents.list` → `{ agents:[{id,…}], defaultId, mainKey }` for self-healing target
///    selection when the gateway demands an explicit agent/session.
struct SybilclawGatewayClient: Sendable {
    let host: String
    let port: Int
    let token: String?
    let agentId: String?
    var overallTimeout: TimeInterval = 90
    /// A1: the stable gateway session key for THIS client instance — generated ONCE at
    /// construction and reused for every turn, so the gateway buckets the node's turns under one
    /// session and keeps cross-turn memory. Previously `runTurn` minted a fresh random key per
    /// call, so every message opened an empty session (the exact "random-UUID-per-message" bug
    /// 4c78d88 killed on the app side) — and `SybilclawLLMClient` deliberately sends only the
    /// last user turn *because* it assumes server-side memory, so a per-call key meant NO memory.
    /// The node serves a single owner (C-3), so one session per process is the node's conversation
    /// scope; per-*conversation* scoping like the app's would need a session id threaded through
    /// `LLMClient` (follow-up).
    let sessionBase: String

    init(host: String = "127.0.0.1", port: Int, token: String? = nil, agentId: String? = nil) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == false) ? token : nil
        self.agentId = (agentId?.isEmpty == false) ? agentId : nil
        self.sessionBase = "eldr-" + UUID().uuidString
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
        // Release the per-`ask()` ephemeral session (and its operation queue) promptly instead of
        // leaving it to ARC's discretion. Declared BEFORE the task defer so it runs AFTER the
        // graceful `task.cancel` (defers are LIFO); `finishTasksAndInvalidate` lets that close
        // settle first. Keep this identical to the Huginn copy.
        defer { session.finishTasksAndInvalidate() }
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let connectID = UUID().uuidString
        do {
            try await send(task, ["type": "req", "id": connectID, "method": "connect", "params": connectParams()])
            _ = try await awaitResponse(task, id: connectID, context: "connect")
        } catch let error as GatewayError {
            throw error
        } catch {
            throw GatewayError.handshake("couldn't reach \(host):\(port) — \(error.localizedDescription)")
        }

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
        // A1: reuse the instance-stable session base (see `sessionBase`) so consecutive turns —
        // and the self-heal retry with a discovered agentId — continue the SAME gateway session.
        let sessionKey = agentId.map { "agent:\($0):\(sessionBase)" } ?? sessionBase

        let sendID = UUID().uuidString
        let sendParams: [String: Any] = [
            "sessionKey": sessionKey,
            "message": prompt,
            "idempotencyKey": UUID().uuidString,
        ]
        try await send(task, ["type": "req", "id": sendID, "method": "chat.send", "params": sendParams])

        // chat.send acks with { runId, status:"in_flight" }; the reply streams as events,
        // correlated by runId. Assistant text on event:"agent" (stream "assistant", cumulative
        // data.text); the turn ends on event:"chat" with a terminal state.
        var runID: String?
        var assembled = ""
        var finalMessage: String?
        var lastFrame: String?
        while !Task.isCancelled {
            let frame: String
            do {
                frame = try await receive(task)
            } catch {
                // A3: the gateway can stream the whole assistant reply on `agent` frames and then
                // CLOSE the socket without a terminal `chat:final` — `receive` throws. Don't discard
                // a complete reply: return what streamed, and surface the error only when nothing did.
                if !assembled.isEmpty { return assembled }
                throw error
            }
            lastFrame = frame
            guard let obj = Self.json(frame) else { continue }
            switch obj["type"] as? String {
            case "res":
                guard obj["id"] as? String == sendID else { continue }
                if (obj["ok"] as? Bool) == false {
                    throw GatewayError.rpc(Self.errorText(obj) ?? "chat.send was rejected")
                }
                runID = (obj["payload"] as? [String: Any])?["runId"] as? String
            case "event":
                guard let payload = obj["payload"] as? [String: Any],
                    Self.frame(payload, belongsTo: runID, sessionKey: sessionKey)
                else { continue }
                switch obj["event"] as? String {
                case "agent":
                    if (payload["stream"] as? String) == "assistant",
                        let data = payload["data"] as? [String: Any],
                        let text = data["text"] as? String
                    {
                        assembled = text  // cumulative snapshot, not a delta
                    }
                case "chat":
                    if let m = payload["message"] as? String, !m.isEmpty { finalMessage = m }
                    switch payload["state"] as? String {
                    case "final":
                        return Self.chooseReply(assembled: assembled, chatMessage: finalMessage)
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
            default:
                break
            }
        }
        if !assembled.isEmpty { return assembled }
        throw GatewayError.timeout(lastFrame: lastFrame)
    }

    /// Whether a streamed event frame belongs to this turn — correlate strictly on `runId` once
    /// known: after the chat.send ack, a runId-bearing frame must match this turn's `runId` (a
    /// differing runId is another run's — reject it); before the ack (`runID` nil) accept it (one
    /// turn/socket). `sessionKey` correlates only runId-less frames; neither ⇒ ours on this socket.
    private static func frame(
        _ payload: [String: Any], belongsTo runID: String?, sessionKey: String
    ) -> Bool {
        // A6: once we've captured this turn's runId from the chat.send ack, a frame that declares a
        // DIFFERENT runId is another run's — reject it. Any frame that carries a runId is matched on it
        // (before the ack, runID is nil ⇒ accept: exactly one turn runs per socket). Only a frame with
        // NO runId falls back to sessionKey correlation (chat frames carry both; agent frames carry the
        // runId, handled above), and a frame with neither is ours only on that single-turn socket.
        if let frameRun = payload["runId"] as? String { return runID == nil || frameRun == runID }
        if let frameSession = payload["sessionKey"] as? String { return frameSession == sessionKey }
        return runID == nil
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

    // Internal (not private) so `SybilclawGatewayFramingTests` can pin these protocol-critical
    // literals to the same spec Apps/Huginn's GatewayHandshakeTests pins for the app copy — the
    // mechanical guard against the silent re-drift this file's banner warns about.
    func connectParams() -> [String: Any] {
        // Mirror Apps/Huginn's SybilclawGatewayClient.connectParams(). The previous values
        // ("eldr-node" / "operator") were OFF the gateway's id/mode allowlists and schema-
        // rejected EVERY connect on this path. id/mode come from .../protocol/client-info.ts;
        // "backend" (not "ui") avoids the browser-origin check this native socket would fail;
        // [3,4] brackets the fork's protocol v3 (and upstream v4).
        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 4,
            "client": [
                "id": "openclaw-macos", "version": Self.appVersion,
                "platform": "macos", "mode": "backend",
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write", "operator.talk.secrets"],
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

    /// A2: choose the turn's reply. The assistant text is the cumulative agent-stream snapshot
    /// (`assembled`, from `event:agent` `data.text`); the terminal `chat:final` frame's `message`
    /// is NOT guaranteed to be that text (it can be an echo/status/routing note), so prefer the
    /// streamed text and fall back to the chat `message` only when nothing streamed. Mirrors the
    /// Huginn copy (GatewayReplyTests locks the behavior there).
    static func chooseReply(assembled: String, chatMessage: String?) -> String {
        let reply = assembled.isEmpty ? (chatMessage ?? "") : assembled
        return reply.isEmpty ? "(sybilclaw returned no text)" : reply
    }

    private static func errorText(_ obj: [String: Any]) -> String? {
        guard let e = obj["error"] as? [String: Any] else { return obj["error"] as? String }
        var parts: [String] = []
        if let m = e["message"] as? String { parts.append(m) }
        else if let code = e["code"] { parts.append("\(code)") }
        // A5: schema (AJV/TypeBox) rejections — the connect-handshake case — name the offending
        // field in `errors[]`. Surface a compact summary so "must match a schema in anyOf" isn't
        // all the operator sees (e.g. ".../client/mode must be equal to constant"). Mirrors the
        // Huginn copy so this path can tell you WHY a handshake was rejected.
        if let errs = e["errors"] as? [[String: Any]] {
            let detail = errs.compactMap { err -> String? in
                let path = (err["instancePath"] as? String) ?? (err["dataPath"] as? String) ?? ""
                let msg = (err["message"] as? String) ?? ""
                let joined = [path, msg].filter { !$0.isEmpty }.joined(separator: " ")
                return joined.isEmpty ? nil : joined
            }.joined(separator: "; ")
            if !detail.isEmpty { parts.append("(\(detail))") }
        }
        let combined = parts.joined(separator: " ")
        return combined.isEmpty ? nil : combined
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
