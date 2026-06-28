import Foundation
import os

/// A client for the **OpenClaw / sybilclaw Gateway** — the local Node daemon that runs the
/// user's *own* assistant (its model, persona/SOUL.md, per-user memory, and tools). This is
/// what lets an EldrChat phone "chat to sybilclaw and get a reply": the phone's message rides
/// the E2EE relay to Huginn, Huginn hands it to this client, the client asks sybilclaw's
/// agent over its local Gateway, and the reply goes back over the relay. `eldr-acp` and its
/// LLM are NOT in this path.
///
/// The protocol below is grounded in the OpenClaw source (github.com/openclaw/openclaw), not
/// inferred. An earlier draft spoke JSON-RPC 2.0 with a `"agent"` method and a guessed reply
/// shape; against a live gateway that produced `errorCode=UNAVAILABLE … "Pass --to <E.164>,
/// --session-id, or --agent to choose a session"` — i.e. the `agent` method exists but needs a
/// target selector, and it routes to a CHANNEL (Discord/Signal), not back inline. The facts,
/// each from a named source file:
///
///  • **Frame envelope** — `apps/shared/OpenClawKit/Sources/OpenClawProtocol/GatewayModels.swift`
///    (generated from `packages/gateway-protocol/src/schema/frames.ts`). Three frame types,
///    discriminated by `type` — there is NO `"jsonrpc"` field:
///      - request : `{"type":"req",   "id":…, "method":…, "params":…}`
///      - response: `{"type":"res",   "id":…, "ok":Bool, "payload":…, "error":…}`
///      - event   : `{"type":"event", "event":…, "payload":…, "seq":…}`
///  • **Handshake** — the FIRST frame MUST be a `connect` request declaring `role` + `scopes`
///    (docs/gateway/protocol.md). The gateway services no method before it.
///  • **Run a turn** — `chat.send` (`schema/logs-chat.ts` `ChatSendParamsSchema`). The user's
///    prompt goes in `message`; the call targets a `sessionKey`. We use `chat.send` (NOT the
///    `agent` method) precisely because it returns the reply INLINE over the WS as `chat`
///    events — which is what we relay back to EldrChat — instead of delivering out-of-band.
///  • **Session** — `sessions.create` (`schema/sessions.ts` `SessionsCreateParamsSchema`); the
///    session is identified by `key`, passed to `chat.send` as `sessionKey`. The session is
///    the `--session-id` selector the gateway demanded.
///  • **Reply** — streams as `chat` events whose `payload` carries `deltaText` (incremental)
///    and `message` (the cumulative snapshot); the turn ends when `payload.state` becomes
///    `final` (or `error` / `aborted`).
///  • **Agent discovery** — `agents.list` (`schema/agents-models-skills.ts`
///    `AgentsListResultSchema`) returns `{ agents: [{ id, … }], defaultId, mainKey }`.
///
/// Self-healing target selection: we first run the turn with the configured agent (default
/// `nil` = let the gateway pick). If that fails with a "must choose an agent/session" error,
/// we call `agents.list`, take `defaultId` (or the first agent's `id`), and retry ONCE with
/// it named explicitly — so we never hard-code which agent is the user's, and we don't need
/// the operator to configure one.
struct SybilclawGatewayClient: Sendable {
    let host: String
    let port: Int
    /// Optional bearer token, sent as `connect.params.auth.token`. `nil` = no auth (typical
    /// for a localhost gateway with `auth.mode: "none"`).
    let token: String?
    /// Optional gateway agent id to target up front. `nil` ⇒ let the gateway pick its default
    /// agent, and only name one explicitly (discovered via `agents.list`) if that's rejected.
    let agentId: String?
    /// Overall wall-clock cap for one ask (connect + create + send + read, incl. the retry).
    /// `handleInboundPrompt` also wraps the run, but `agentRunTimeout` defaults to 0
    /// (unlimited), so this is the backstop that keeps a silent gateway from hanging a turn.
    var overallTimeout: TimeInterval = 90
    /// Opt-in raw-frame diagnostics (default off). When on, the `connect` handshake (with the
    /// auth token redacted) and the gateway's raw `connect` reply are logged to OSLog and the
    /// Agent Inspector, so a handshake rejection produces EVIDENCE (the offending field, the
    /// protocol-version error) instead of a reverse-engineered theory. Logs protocol metadata
    /// only — never the user's prompt/reply (`chat.send`/`chat` frames are never logged).
    var diagnostics: Bool = false

    /// Handshake/protocol diagnostics only — never message content (see `diagnostics`).
    private static let log = Logger(subsystem: "chat.eldr.huginn", category: "gateway")

    init(
        host: String = "127.0.0.1", port: Int, token: String? = nil, agentId: String? = nil,
        diagnostics: Bool = false
    ) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == false) ? token : nil
        self.agentId = (agentId?.isEmpty == false) ? agentId : nil
        self.diagnostics = diagnostics
    }

    // MARK: Errors

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

    // MARK: Ask

    /// Send `prompt` to sybilclaw's assistant and return its complete reply text. Races the
    /// whole exchange against `overallTimeout` so a silent gateway can't hang the turn.
    /// `sessionKey` is the stable, opaque per-conversation session id the gateway buckets
    /// history under — supplied by the caller so a conversation keeps context across turns
    /// and stays separate from every other conversation (and from Discord).
    func ask(_ prompt: String, sessionKey: String) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.askImpl(prompt, sessionKey: sessionKey) }
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

    private func askImpl(_ prompt: String, sessionKey: String) async throws -> String {
        guard let url = URL(string: "ws://\(host):\(port)/") else { throw GatewayError.badURL }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        // Mandatory connect handshake — the gateway services no method until it lands.
        let connectID = UUID().uuidString
        if diagnostics {
            let sent = redactedConnectParamsJSON()
            // `.public`: the redacted handshake is protocol metadata (no message content, token
            // stripped), and the whole point is for the operator to actually read it in `log show`.
            Self.log.debug("connect → \(sent, privacy: .public)")
            DiagnosticsLog.shared.post(.acp, .info, "Gateway connect sent", sent)
        }
        try await send(task, ["type": "req", "id": connectID, "method": "connect", "params": connectParams()])
        _ = try await awaitResponse(task, id: connectID, context: "connect", logRaw: diagnostics)

        // Attempt 1: the configured agent (nil ⇒ the gateway's default).
        do {
            return try await runTurn(task, prompt: prompt, sessionKey: sessionKey, agentId: agentId)
        } catch {
            // Self-heal: the gateway wants an explicit agent/session ("choose a session" /
            // UNAVAILABLE). Discover its default agent and retry ONCE, naming it explicitly.
            guard Self.isSelectionError(error),
                let discovered = try? await discoverDefaultAgent(task),
                discovered != agentId
            else { throw error }
            return try await runTurn(task, prompt: prompt, sessionKey: sessionKey, agentId: discovered)
        }
    }

    /// One full turn on an already-connected socket: create a session (the `--session-id`
    /// selector), send the prompt, and assemble the reply from `chat` events until the run
    /// reaches a terminal `state`. `agentId` binds the session/turn to a specific agent.
    private func runTurn(
        _ task: URLSessionWebSocketTask, prompt: String, sessionKey: String, agentId: String?
    ) async throws -> String {
        // Create the session under the caller's STABLE per-conversation `key` (so the
        // gateway keeps this conversation's history together across turns). Tolerate
        // gateways that reject create and auto-create on the first `chat.send` instead
        // (try?), so the real error (if any) surfaces at chat.send where the retry logic
        // can act on it.
        let createID = UUID().uuidString
        var createParams: [String: Any] = ["key": sessionKey]
        if let agentId { createParams["agentId"] = agentId }
        try await send(task, ["type": "req", "id": createID, "method": "sessions.create", "params": createParams])
        _ = try? await awaitResponse(task, id: createID, context: "sessions.create")

        // Send the prompt. `message` carries the user text (ChatSendParamsSchema).
        let sendID = UUID().uuidString
        var sendParams: [String: Any] = [
            "sessionKey": sessionKey,
            "message": prompt,
            "idempotencyKey": UUID().uuidString,
        ]
        if let agentId { sendParams["agentId"] = agentId }
        try await send(task, ["type": "req", "id": sendID, "method": "chat.send", "params": sendParams])

        // Assemble from `chat` events until the run reaches a terminal `state`.
        var assembled = ""
        var lastFrame: String?
        while !Task.isCancelled {
            let frame = try await receive(task)
            lastFrame = frame
            guard let obj = Self.json(frame) else { continue }
            switch obj["type"] as? String {
            case "res":
                // The only response we still care about is a rejection of OUR chat.send.
                if obj["id"] as? String == sendID, (obj["ok"] as? Bool) == false {
                    throw GatewayError.rpc(Self.errorText(obj) ?? "chat.send was rejected")
                }
            case "event":
                guard let payload = obj["payload"] as? [String: Any],
                    (payload["sessionKey"] as? String) == sessionKey
                else { continue }  // an event for some other session — ignore
                if let message = payload["message"] as? String {
                    assembled = message  // cumulative snapshot
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
                    break  // a non-terminal delta — keep reading
                }
            default:
                break
            }
        }
        if !assembled.isEmpty { return assembled }
        throw GatewayError.timeout(lastFrame: lastFrame)
    }

    /// Ask the gateway for its agents and return the default agent id (`defaultId`, or the
    /// first agent's `id`). nil if the list is empty/unavailable. (`agents.list` →
    /// `AgentsListResultSchema`.)
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

    // MARK: Frame helpers

    /// The `connect` params (docs/gateway/protocol.md handshake). Declares an `operator`
    /// role with read+write scope; `auth.token` only when one is configured.
    /// Non-`private` so `GatewayHandshakeTests` can lock the id/mode/version against a blind edit.
    func connectParams() -> [String: Any] {
        var params: [String: Any] = [
            "minProtocol": 3,
            "maxProtocol": 3,
            "client": [
                // id/mode MUST come from the gateway's compiled allowlists (13 ids / 7 modes,
                // packages/gateway-protocol/src/client-info.ts) — an off-list value is rejected with
                // "must be equal to constant; must match a schema in anyOf". "openclaw-macos" is the
                // normal macOS-app identity (full agent/streaming access); "backend" is a valid mode.
                // The cofounder's fork (rdevaul/sybilclaw) speaks protocol v3, so pin the range to [3,3].
                "id": "openclaw-macos", "version": Self.appVersion,
                "platform": "macos", "mode": "backend",
            ],
            "role": "operator",
            "scopes": ["operator.read", "operator.write"],
            "caps": [String](),
            "commands": [String](),
            "permissions": [String: Any](),
            "locale": "en-US",
            "userAgent": "huginn-eldr/\(Self.appVersion)",
        ]
        if let token { params["auth"] = ["token": token] }
        return params
    }

    /// The connect params as JSON, safe to log: the auth token (the only secret in the
    /// handshake) is replaced with a placeholder. The handshake carries NO user message
    /// content — that lives only in `chat.send`, which is never logged.
    private func redactedConnectParamsJSON() -> String {
        var p = connectParams()
        if p["auth"] != nil { p["auth"] = ["token": "<redacted>"] }
        let data = (try? JSONSerialization.data(withJSONObject: p, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
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

    /// Read frames until the `res` correlated to `id` arrives. Returns its `payload` on
    /// `ok:true`; throws on `ok:false`. Non-matching frames (events, other responses) are
    /// skipped. `connect` failures surface as `.handshake` (with the "is it running?" hint);
    /// everything else as `.rpc`.
    @discardableResult
    private func awaitResponse(
        _ task: URLSessionWebSocketTask, id: String, context: String, logRaw: Bool = false
    ) async throws -> [String: Any]? {
        while !Task.isCancelled {
            let frame = try await receive(task)
            guard let obj = Self.json(frame) else { continue }
            guard obj["type"] as? String == "res", obj["id"] as? String == id else { continue }
            if logRaw {
                // The raw `res` frame is protocol metadata (ok/error/version) — no user content.
                // It carries `error.code` and the AJV `errors[]` detail that `errorText` distills.
                let ok = (obj["ok"] as? Bool) == true
                Self.log.debug("\(context) ← \(frame, privacy: .public)")
                DiagnosticsLog.shared.post(.acp, ok ? .success : .error, "Gateway \(context) reply", frame)
            }
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
        guard let e = obj["error"] as? [String: Any] else { return obj["error"] as? String }
        var parts: [String] = []
        if let m = e["message"] as? String { parts.append(m) }
        else if let code = e["code"] { parts.append("\(code)") }
        // Schema (AJV/TypeBox) rejections — the connect-handshake case — name the offending
        // field in `errors[]`. Surface a compact summary so "must match a schema in anyOf"
        // isn't all the operator sees (e.g. ".../client/mode must be equal to constant").
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

    /// Whether an error reads like the gateway demanding an explicit agent/session selector
    /// (the `UNAVAILABLE … "choose a session"` case) — the only failure worth a retry with a
    /// discovered agent id.
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

/// `BridgeAgentRunner` backed by sybilclaw's Gateway. Drop-in alternative to
/// `ACPDriverAgentRunner`: the owner's inbound chat (already C-3-gated + redaction-wrapped by
/// `handleInboundPrompt`) is answered by sybilclaw's own assistant instead of `eldr-acp`.
/// `workdir` is ignored — sybilclaw owns its own workspace.
struct SybilclawAgentRunner: BridgeAgentRunner {
    let client: SybilclawGatewayClient
    /// The gateway keeps this conversation's history under the session key (server-side), so
    /// Huginn records its own encrypted canonical copy but must NOT re-inject prior context —
    /// the gateway would otherwise see the history twice.
    var selfPersistsHistory: Bool { true }
    func run(prompt: String, workdir: String?, context: ConversationContext) async throws -> String {
        try await client.ask(prompt, sessionKey: context.sessionKey)
    }
}
