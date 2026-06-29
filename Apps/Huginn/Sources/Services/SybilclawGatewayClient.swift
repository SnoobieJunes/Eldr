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
///  • **Run a turn** — `chat.send` (`schema/logs-chat.ts` `ChatSendParamsSchema`): the prompt
///    goes in `message`, the conversation in `sessionKey`, plus a required `idempotencyKey`.
///    The `res` does NOT carry the reply — it acks immediately with `{ runId, status:"in_flight" }`.
///    There is NO separate session-create step: the gateway resolves/creates the session from
///    `sessionKey`. To target a specific agent, encode it in the key as `agent:<id>:<base>`
///    (`SessionKey.makeAgentSessionKey`) — `agentId` is NOT a `chat.send` field (the schema is
///    `additionalProperties:false` and would reject it).
///  • **Reply** — streams as `event` frames correlated by `runId`: the assistant text arrives on
///    `event:"agent"` with `stream:"assistant"`, the cumulative text-so-far in `payload.data.text`
///    (assign, don't append); the turn ends on an `event:"chat"` whose `payload.state` is
///    `final` (or `error`/`aborted`, carrying `errorMessage`). `agent` frames carry no
///    `sessionKey`, so correlation is by `runId`. (Verified field-for-field against the fork's
///    own reference clients, rdevaul/sybilclaw apps/ios + apps/android.)
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
        // Release the per-`ask()` ephemeral session (and its operation queue) promptly instead of
        // leaving it to ARC's discretion. Declared BEFORE the task defer so it runs AFTER the
        // graceful `task.cancel` (defers are LIFO); `finishTasksAndInvalidate` lets that close
        // settle first. Keep this identical to the eldr-node copy.
        defer { session.finishTasksAndInvalidate() }
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
        do {
            try await send(task, ["type": "req", "id": connectID, "method": "connect", "params": connectParams()])
            _ = try await awaitResponse(task, id: connectID, context: "connect", logRaw: diagnostics)
        } catch let error as GatewayError {
            throw error  // a real handshake rejection (schema/protocol) — keep its detail
        } catch {
            // Socket-level failure before the handshake landed (refused / timed out / DNS) — the
            // gateway almost certainly isn't running. Say so, instead of leaking a raw URLError.
            throw GatewayError.handshake("couldn't reach \(host):\(port) — \(error.localizedDescription)")
        }

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

    /// One full turn on an already-connected socket: send the prompt with `chat.send` and
    /// assemble the streamed reply. The gateway resolves/creates the session from `sessionKey`
    /// (no separate create step). `agentId`, when set, is encoded into the key as
    /// `agent:<id>:<base>` — the only way `chat.send` targets a specific agent.
    private func runTurn(
        _ task: URLSessionWebSocketTask, prompt: String, sessionKey baseKey: String, agentId: String?
    ) async throws -> String {
        let sessionKey = agentId.map { "agent:\($0):\(baseKey)" } ?? baseKey

        let sendID = UUID().uuidString
        let sendParams: [String: Any] = [
            "sessionKey": sessionKey,
            "message": prompt,
            "idempotencyKey": UUID().uuidString,
        ]
        try await send(task, ["type": "req", "id": sendID, "method": "chat.send", "params": sendParams])

        // `chat.send` acks immediately with `{ runId, status:"in_flight" }`; the reply then
        // streams as events. Assistant text arrives on `event:"agent"` (stream "assistant",
        // cumulative text in `data.text`); the turn ends on an `event:"chat"` with a terminal
        // `state`. Frames are correlated by `runId` — `agent` frames carry no `sessionKey`.
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
                else { continue }  // a frame for some other run/session — ignore
                switch obj["event"] as? String {
                case "agent":
                    // The live assistant text. `data.text` is the cumulative snapshot — assign,
                    // never append (appending would duplicate the whole reply on every frame).
                    if (payload["stream"] as? String) == "assistant",
                        let data = payload["data"] as? [String: Any],
                        let text = data["text"] as? String
                    {
                        assembled = text
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
                        break  // a non-terminal "delta" — keep reading
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

    /// Whether a streamed event frame belongs to this turn. Correlate strictly on `runId` once
    /// it's known: after we capture this turn's `runId` from the `chat.send` ack, any frame that
    /// carries a `runId` must match it (a differing `runId` is another run's — reject it). Before
    /// the ack `runID` is nil, so a runId-bearing frame is accepted (exactly one turn runs per
    /// socket). `sessionKey` is used only for frames that carry NO `runId`; a frame with neither
    /// is ours only on that single-turn socket. (`agent` frames carry `runId` but no `sessionKey`;
    /// `chat` frames carry both.)
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
            // The fork's gateway runs protocol v3; upstream openclaw is v4. The server accepts a
            // client iff its advertised [min,max] BRACKETS the server's version (verified:
            // src/gateway/server/ws-connection/message-handler.ts rejects only when
            // maxProtocol < server || minProtocol > server). [3,4] works against both, and
            // future-proofs an upstream bump — pinning [3,3] would break the day he updates.
            "maxProtocol": 4,
            "client": [
                // id/mode MUST come from the gateway's compiled allowlists (13 ids / 7 modes,
                // .../protocol/client-info.ts) — an off-list value is schema-rejected with
                // "must be equal to constant; must match a schema in anyOf". "openclaw-macos" is
                // the macOS identity. "backend" (NOT "ui") is deliberate: there's no role↔mode
                // check (role-policy.ts authorizes by role alone), and "ui" can trip the gateway's
                // browser-origin check — which this native URLSession socket would fail (it sends
                // no Origin header). "backend" skips that path entirely.
                "id": "openclaw-macos", "version": Self.appVersion,
                "platform": "macos", "mode": "backend",
            ],
            "role": "operator",
            // operator.write is what authorizes chat.send; operator.talk.secrets mirrors the
            // fork's reference operator client (only needed for Talk secrets, harmless to
            // request on a no-auth loopback gateway).
            "scopes": ["operator.read", "operator.write", "operator.talk.secrets"],
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

    /// A2: choose the turn's reply. The assistant text is the cumulative agent-stream snapshot
    /// (`assembled`, from `event:agent` `data.text`); the terminal `chat:final` frame's `message`
    /// is NOT guaranteed to be that text (it can be an echo/status/routing note), so prefer the
    /// streamed text and fall back to the chat `message` only when nothing streamed (a gateway
    /// variant that emits no agent frames). Pure + non-private so `GatewayReplyTests` can lock it.
    static func chooseReply(assembled: String, chatMessage: String?) -> String {
        let reply = assembled.isEmpty ? (chatMessage ?? "") : assembled
        return reply.isEmpty ? "(sybilclaw returned no text)" : reply
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
