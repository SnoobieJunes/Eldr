import Foundation
import os

// WS-B5: the ONE OpenClaw / sybilclaw Gateway WebSocket client. Previously this type was
// hand-duplicated — Apps/Huginn/Sources/Services/SybilclawGatewayClient.swift (the chat
// bridge's copy) and Packages/EldrNode/Sources/eldr-node/SybilclawGatewayClient.swift (the
// headless node's copy) — and the two drifted at least once (the node copy kept an
// off-allowlist handshake after the app's was fixed, breaking that path silently until a
// parity test caught it). Both call sites (`ACPBridgeService.applyProductionRunner` in
// Huginn, `EldrNodeMain`'s `--responder sybilclaw` wiring) now depend on THIS type, so a
// protocol fix only has to happen once. The wrapper that adapts this client to each host's
// OWN agent-runner abstraction stays local to that host (Huginn's `SybilclawAgentRunner:
// BridgeAgentRunner` in ACPBridgeService.swift; the node's `SybilclawLLMClient: LLMClient`)
// since those protocols are host-specific — this type carries no app/SwiftUI dependency
// (PQRCACP's zero-dependency promise), only Foundation + os.

/// A client for the **OpenClaw / sybilclaw Gateway** — the local Node daemon that runs a
/// user's *own* assistant (its model, persona/SOUL.md, per-user memory, and tools). A
/// PQRC phone's message rides the E2EE relay to a Mac (Huginn, tethered) or a headless
/// `eldr-node`; the host hands the turn to this client, which asks sybilclaw's agent over
/// its local Gateway, and the reply goes back over the relay. `eldr-acp` and its own LLM
/// are NOT in this path.
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
///    (docs/gateway/protocol.md). The gateway services no method before it. `client.id`/
///    `client.mode` MUST come from the gateway's compiled allowlists (13 ids / 7 modes,
///    `.../protocol/client-info.ts) — an off-list value is schema-rejected with "must be
///    equal to constant; must match a schema in anyOf". `"openclaw-macos"` is the macOS
///    identity; `"backend"` (NOT `"ui"`) is deliberate — there's no role↔mode check
///    (role-policy.ts authorizes by role alone), and `"ui"` can trip the gateway's
///    browser-origin check, which a native `URLSession` socket would fail (it sends no
///    `Origin` header). `"backend"` skips that path entirely. The protocol range `[3,4]`
///    brackets the cofounder's fork (rdevaul/sybilclaw, v3) AND upstream openclaw (v4) —
///    verified: `src/gateway/server/ws-connection/message-handler.ts` rejects only when
///    `maxProtocol < server || minProtocol > server`.
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
///
/// **Session scoping (WS-B5 fix):** `ask(_:sessionKey:)` takes the gateway session key as a
/// per-call parameter — the caller decides what "one conversation" means. Huginn scopes it
/// per `BridgeConversation`/thread (`ACPBridgeService.gatewaySessionKey(for:)`); `eldr-node`
/// must scope it per ACP session (see `SybilclawLLMClient`) rather than reuse one process-
/// lifetime key for every conversation — the earlier node copy's `sessionBase`, generated
/// once at construction and reused for EVERY turn regardless of which ACP session/`prompt`
/// it belonged to, bled one project/thread's context into another's the moment the owner had
/// more than one live ACP session against the same node process.
public struct SybilclawGatewayClient: Sendable {
    public let host: String
    public let port: Int
    /// Optional bearer token, sent as `connect.params.auth.token`. `nil` = no auth (typical
    /// for a localhost gateway with `auth.mode: "none"`).
    public let token: String?
    /// Optional gateway agent id to target up front. `nil` ⇒ let the gateway pick its default
    /// agent, and only name one explicitly (discovered via `agents.list`) if that's rejected.
    public let agentId: String?
    /// Overall wall-clock cap for one ask (connect + create + send + read, incl. the retry).
    public var overallTimeout: TimeInterval = 90
    /// Opt-in raw-frame diagnostics (default off). When on, the `connect` handshake (with the
    /// auth token redacted) and the gateway's raw `res` replies are logged to this client's
    /// own OSLog `Logger` — protocol metadata only, never the user's prompt/reply (`chat.send`/
    /// `chat` frames are never logged). A host app that wants these surfaced in its own UI
    /// (Huginn's Agent Inspector) does so through `onEvent` below, not by parsing OSLog.
    public var diagnostics: Bool = false
    /// Identifies this HOST on the wire (`connect.params.userAgent`) — free text, not
    /// allowlist-checked. Each host names itself (`"huginn-eldr/<version>"`,
    /// `"eldr-node/<version>"`) so gateway-side logs can tell the callers apart; nil falls
    /// back to a generic `"pqrcacp-gateway-client/<version>"`.
    public var userAgent: String?
    /// Optional lifecycle hook: connect/disconnect/turn-start/turn-end/error, invariant-12
    /// clean (NEVER the prompt or the reply text — only protocol-level state and short,
    /// non-payload error descriptions, same class of string `GatewayError.errorDescription`
    /// already produces). A host forwards these into its own diagnostics surface (Huginn →
    /// `DiagnosticsLog`); a headless host (`eldr-node`) may fold them into its own OSLog line
    /// or leave this `nil` to ignore them entirely — the client works identically either way.
    public var onEvent: (@Sendable (SybilclawGatewayEvent) -> Void)?

    /// Handshake/protocol diagnostics only — never message content (see `diagnostics`).
    private static let log = Logger(subsystem: "chat.eldr.pqrcacp", category: "gateway")

    public init(
        host: String = "127.0.0.1", port: Int, token: String? = nil, agentId: String? = nil,
        overallTimeout: TimeInterval = 90, diagnostics: Bool = false, userAgent: String? = nil,
        onEvent: (@Sendable (SybilclawGatewayEvent) -> Void)? = nil
    ) {
        self.host = host
        self.port = port
        self.token = (token?.isEmpty == false) ? token : nil
        self.agentId = (agentId?.isEmpty == false) ? agentId : nil
        self.overallTimeout = overallTimeout
        self.diagnostics = diagnostics
        self.userAgent = (userAgent?.isEmpty == false) ? userAgent : nil
        self.onEvent = onEvent
    }

    // MARK: Errors

    public enum GatewayError: LocalizedError, Sendable {
        case badURL
        case handshake(String)
        case rpc(String)
        case timeout(lastFrame: String?)
        case closed(String)

        public var errorDescription: String? {
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
    /// and stays separate from every other conversation (and from Discord). Callers MUST
    /// scope this per logical conversation/session on THEIR side (see the type doc's
    /// "Session scoping" note) — this client applies no scoping of its own.
    public func ask(_ prompt: String, sessionKey: String) async throws -> String {
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

    private func emit(_ event: SybilclawGatewayEvent) {
        onEvent?(event)
    }

    private func askImpl(_ prompt: String, sessionKey: String) async throws -> String {
        guard let url = URL(string: "ws://\(host):\(port)/") else { throw GatewayError.badURL }
        emit(.connecting(host: host, port: port))
        let session = URLSession(configuration: .ephemeral)
        // Release the per-`ask()` ephemeral session (and its operation queue) promptly instead of
        // leaving it to ARC's discretion. Declared BEFORE the task defer so it runs AFTER the
        // graceful `task.cancel` (defers are LIFO); `finishTasksAndInvalidate` lets that close
        // settle first.
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
        }
        do {
            try await send(task, ["type": "req", "id": connectID, "method": "connect", "params": connectParams()])
            _ = try await awaitResponse(task, id: connectID, context: "connect", logRaw: diagnostics)
        } catch let error as GatewayError {
            emit(.disconnected(reason: error.errorDescription))
            throw error  // a real handshake rejection (schema/protocol) — keep its detail
        } catch {
            // Socket-level failure before the handshake landed (refused / timed out / DNS) — the
            // gateway almost certainly isn't running. Say so, instead of leaking a raw URLError.
            let wrapped = GatewayError.handshake(
                "couldn't reach \(host):\(port) — \(error.localizedDescription)")
            emit(.disconnected(reason: wrapped.errorDescription))
            throw wrapped
        }
        emit(.connected)
        emit(.turnStarted)

        // Attempt 1: the configured agent (nil ⇒ the gateway's default).
        do {
            let reply = try await runTurn(task, prompt: prompt, sessionKey: sessionKey, agentId: agentId)
            emit(.turnSucceeded)
            return reply
        } catch {
            // Self-heal: the gateway wants an explicit agent/session ("choose a session" /
            // UNAVAILABLE). Discover its default agent and retry ONCE, naming it explicitly.
            guard Self.isSelectionError(error),
                let discovered = try? await discoverDefaultAgent(task),
                discovered != agentId
            else {
                emit(.turnFailed(reason: error.localizedDescription))
                throw error
            }
            do {
                let reply = try await runTurn(task, prompt: prompt, sessionKey: sessionKey, agentId: discovered)
                emit(.turnSucceeded)
                return reply
            } catch {
                emit(.turnFailed(reason: error.localizedDescription))
                throw error
            }
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
    /// Non-`private` so the framing/handshake tests can lock the id/mode/version against a
    /// blind edit.
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
            "userAgent": userAgent ?? "pqrcacp-gateway-client/\(Self.appVersion)",
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
                Self.log.debug("\(context) ← \(frame, privacy: .public)")
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
    /// variant that emits no agent frames). Pure + non-private so the reply-selection tests can
    /// lock it.
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

/// Lifecycle diagnostics for one `ask()` call — protocol/connection state ONLY. **Never**
/// carries the prompt or the assistant's reply (invariant 12: no payload-adjacent value ever
/// crosses this seam); `reason`/`errorDescription` strings are the same short, non-payload
/// protocol/transport detail `GatewayError.errorDescription` already produces (a handshake
/// rejection detail, an RPC error code, a timeout note) — never message content.
public enum SybilclawGatewayEvent: Sendable, Equatable {
    /// Dialing the gateway's WebSocket for one turn.
    case connecting(host: String, port: Int)
    /// The `connect` handshake succeeded.
    case connected
    /// The handshake failed, or the socket tore down before/after a turn. `reason` is a
    /// short protocol/transport detail, never prompt/reply content.
    case disconnected(reason: String?)
    /// `chat.send` was accepted and a turn is now running.
    case turnStarted
    /// The turn completed and produced a reply (the reply text itself is never included).
    case turnSucceeded
    /// The turn failed. `reason` mirrors `GatewayError.errorDescription`.
    case turnFailed(reason: String)
}
