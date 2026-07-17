import Foundation
import PQRCACP

/// What the in-process agent surfaces to the test-chat UI.
enum TestChatEvent: Sendable {
    case userMessage(String)
    case toolCall(name: String, args: JSONValue)
    case toolResult(String, isError: Bool)
    case assistantMessage(String)
    /// The agent is waiting on a `session/request_permission` answer. Only fired
    /// when auto-approve is OFF — the UI renders it as a `PendingToolApproval` the
    /// user can Approve/Deny. `requestID` is the JSON-RPC request id, echoed back
    /// verbatim so `ClientConnection` can match the reply to the awaiting call.
    case permissionRequested(requestID: JSONValue, toolCallId: String, title: String, kind: String)
    /// A transcript annotation recording WHO/WHAT resolved a permission gate: a tool
    /// was auto-approved (config on), the user approved/denied one, or a pending
    /// request timed out (denied). Never a substitute for the real
    /// `tool_call`/`tool_call_update` rows — just a visible audit note.
    case approvalNote(String)
}

/// A flattened, identifiable chat row for SwiftUI.
struct TestChatItem: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, toolCall, toolResult, approvalNote }
    let id: Int
    var role: Role
    var text: String
    var toolName: String?
    var argsJSON: String?
    var isError: Bool = false
}

/// Drives a real `ACPAgent` in-process so the user can exercise their LLM + tools
/// without Xcode. A `NullClientConnection` sink captures the agent's `session/update`
/// notifications as `TestChatEvent`s (rather than writing stdio). Tools run in a
/// user-configurable workspace (`ConfigurationStore.testChatWorkspacePath`, seeded
/// from the Bridge's "Agent project folder" if one is already set); with nothing
/// configured, a throwaway scratch dir is minted on demand (stale ones left by
/// earlier sessions are swept on init — nothing used to clean them up). Tool
/// permission requests either auto-grant (visibly annotated in the transcript) or
/// wait for an explicit Approve/Deny, per `ConfigurationStore.testChatAutoApprove` —
/// see `EventSink`.
@MainActor
final class TestChatSession: ObservableObject {

    /// One outstanding `session/request_permission` the agent is waiting on,
    /// surfaced to the UI instead of being silently auto-granted.
    struct PendingToolApproval: Identifiable, Equatable {
        let id: UUID
        let requestID: JSONValue
        let toolCallId: String
        let title: String
        let kind: String
    }

    @Published private(set) var items: [TestChatItem] = []
    @Published private(set) var isResponding = false
    /// Force the built-in echo "LLM" (offline). The UI sets this when the health
    /// check is red so the chat still demonstrates the tool loop.
    @Published var useFakeLLM = false
    /// Show the RAW model stream (pre reasoning-trace stripping) in the chat. OFF by
    /// default. When ON, the next bootstrap attaches a `rawObserver` to the real LLM
    /// client so a reasoning model's chain-of-thought (`<think>…`, `<|channel>thought…`)
    /// is captured into `rawStream` for display. Toggling `reset()`s the session so the
    /// observer is attached/detached on the rebuilt client (no capture cost when off).
    @Published var showRawStream = false
    /// The raw, pre-strip model output captured for the LAST turn, accumulated as it
    /// streams. Empty until a turn runs with `showRawStream` on. Reset at the start of
    /// each turn so the disclosure shows only the most recent reply's raw trace.
    @Published private(set) var rawStream = ""
    /// The folder the agent's tools currently operate in — either the configured
    /// workspace or (if none is set) a throwaway scratch dir. Published so the
    /// header can show it before the first message is ever sent.
    @Published private(set) var workdir = ""
    /// Tool-permission requests waiting on the user (empty when auto-approve is on,
    /// or when nothing is pending).
    @Published private(set) var pendingApprovals: [PendingToolApproval] = []

    /// Pulled fresh each bootstrap so config edits take effect after `reset()`.
    /// `@MainActor`-isolated because the UI wires these to MainActor store state.
    var llmConfigProvider: @MainActor () -> LLMConfig = { LLMConfig.fromEnvironment([:]) }
    var agentConfigProvider: @MainActor () -> AgentConfig = { .default }
    /// The configured Test Chat workspace path (`ConfigurationStore.testChatWorkspacePath`).
    /// Empty ⇒ fall back to a throwaway scratch dir. Wired by `TestChatView`.
    var workspaceProvider: @MainActor () -> String = { "" }
    /// Whether to auto-grant tool permission requests
    /// (`ConfigurationStore.testChatAutoApprove`). Wired by `TestChatView`.
    var autoApproveProvider: @MainActor () -> Bool = { false }

    private var agent: ACPAgent?
    private var connection: ClientConnection?
    private var sink: EventSink?
    private var sessionId: String?
    private var consumeTask: Task<Void, Never>?
    /// Closes the current event stream so a torn-down/rebuilt session's consumer
    /// task actually exits its `for await` (cancellation alone doesn't end the
    /// stream). Without this, every reset()/rebootstrap leaked a consumer.
    private var streamContinuation: AsyncStream<TestChatEvent>.Continuation?
    private var nextItemID = 0
    private var rpcID = 100
    /// A scratch dir minted on demand when no workspace is configured, reused for
    /// the rest of THIS session object's life so the folder doesn't change out from
    /// under a running tool loop; cleared on `reset()` so the next session mints its
    /// own (mirrors the old per-`init()` UUID dir, just deferred until it's needed).
    private var fallbackWorkdir: String?
    /// Per-approval deny-on-timeout tasks, mirroring `ClientConnection.request(timeout:)`'s
    /// own fail-closed bound — this one just keeps the UI honest (removes a stale
    /// "pending" card once the agent side has already denied it on the same clock).
    private var approvalTimeoutTasks: [UUID: Task<Void, Never>] = [:]

    init() {
        Self.cleanupStaleWorkspaces()
    }

    // MARK: - Public

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        // Claim the turn BEFORE the first `await` (bootstrap) so a second `send`
        // call arriving while one is already in flight bails at the guard above
        // instead of racing a second, concurrent session/prompt on the same agent
        // actor.
        isResponding = true
        // Start a fresh raw capture for this turn (the disclosure shows the LAST turn).
        rawStream = ""
        await bootstrap()
        guard let agent, let sid = sessionId else {
            append(.assistantMessage("Could not start the agent session."))
            isResponding = false
            return
        }
        append(.userMessage(trimmed))
        _ = await agent.handle(line: promptLine(sid: sid, text: trimmed))
        isResponding = false
    }

    /// The user approved a pending tool call. Delivers `allow_once` back to the
    /// agent and drops a visible transcript note. No-op if the request already
    /// resolved (a timeout beat the click, or `reset()` tore the session down).
    func approve(_ approval: PendingToolApproval) async {
        await resolvePendingApproval(
            approval, optionId: "allow_once", note: "Approved: \(approval.title)")
    }

    /// The user denied a pending tool call. Delivers `reject_once`; the tool call's
    /// own `tool_call_update` then renders as failed.
    func deny(_ approval: PendingToolApproval) async {
        await resolvePendingApproval(
            approval, optionId: "reject_once", note: "Denied: \(approval.title)")
    }

    /// Recompute the displayed workspace path from the current `workspaceProvider`
    /// WITHOUT bootstrapping the agent, so the header shows the right folder before
    /// the first message is sent (and immediately after the user changes it).
    func refreshWorkdirDisplay() {
        workdir = resolvedWorkdir()
    }

    /// Tear down so the next `send` rebuilds with current config (e.g. after the user
    /// edits the LLM URL, changes the workspace, or toggles echo/auto-approve).
    func reset() {
        // Finish the stream FIRST so the consumer's `for await` returns, then cancel
        // (cancellation alone doesn't terminate an AsyncStream loop). Otherwise each
        // reset leaked a live consumer task bound to the MainActor.
        streamContinuation?.finish()
        streamContinuation = nil
        consumeTask?.cancel()
        consumeTask = nil
        // Fail-closed teardown: any permission request still in flight on the OLD
        // connection is answered with an error rather than silently dropped —
        // `ACPAgent.requestPermission` treats any thrown error as a denial, so a
        // reset mid-request never leaves a mutating tool defaulting to allow.
        if let oldConnection = connection {
            Task { await oldConnection.failAll(SessionTornDown()) }
        }
        agent = nil
        connection = nil
        sink = nil
        sessionId = nil
        isResponding = false
        items.removeAll()
        rawStream = ""
        for task in approvalTimeoutTasks.values { task.cancel() }
        approvalTimeoutTasks.removeAll()
        pendingApprovals.removeAll()
        fallbackWorkdir = nil
        workdir = resolvedWorkdir()
    }

    // MARK: - Agent bootstrap

    private func bootstrap() async {
        guard agent == nil else { return }
        let workdir = resolvedWorkdir()
        self.workdir = workdir
        let (stream, continuation) = AsyncStream<TestChatEvent>.makeStream()
        let sink = EventSink(continuation, autoApprove: autoApproveProvider())
        let connection = ClientConnection(sink: sink)
        await sink.attach(connection)

        let llmConfig = llmConfigProvider()
        // Only build a raw tap when the toggle is on — when off, `rawObserver` stays nil
        // so the client does ZERO raw capture (same path as the relay host / CLI).
        // `@Sendable`: the SSE read invokes this off the MainActor, so it hops back to
        // append into the published `rawStream` (and drops a diagnostics breadcrumb).
        var rawObserver: (@Sendable (String) -> Void)?
        if showRawStream {
            rawObserver = { [weak self] piece in
                Task { @MainActor in self?.rawStream += piece }
                DiagnosticsLog.shared.post(.llm, .info, "raw", String(piece.prefix(200)))
            }
        }
        let llm: any LLMClient =
            (useFakeLLM || llmConfig.url.isEmpty)
            ? EchoLLMClient()
            : InspectingLLMClient(
                wrapping: OpenAICompatibleLLMClient(config: llmConfig, rawObserver: rawObserver),
                model: llmConfig.model)
        // One snapshot of the config so the maxIterations cap matches the `config` we
        // pass (and we don't evaluate the provider twice).
        let agentConfig = agentConfigProvider()
        let agent = ACPAgent(
            connection: connection, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: workdir),
            config: agentConfig, configDir: nil,
            maxIterations: agentConfig.maxIterations)

        self.sink = sink
        self.connection = connection
        self.agent = agent
        self.streamContinuation = continuation
        consumeTask = Task { [weak self] in
            for await event in stream { self?.append(event) }
        }

        _ = await agent.handle(
            line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let response = await agent.handle(line: sessionNewLine())
        sessionId = JSONValue.parse(response ?? "")?["result"]?["sessionId"]?.stringValue
    }

    private func append(_ event: TestChatEvent) {
        let id = nextItemID
        nextItemID += 1
        switch event {
        case .userMessage(let text):
            items.append(TestChatItem(id: id, role: .user, text: text))
        case .assistantMessage(let text):
            items.append(TestChatItem(id: id, role: .assistant, text: text))
        case .toolCall(let name, let args):
            items.append(
                TestChatItem(
                    id: id, role: .toolCall, text: name, toolName: name,
                    argsJSON: prettyJSON(args)))
        case .toolResult(let text, let isError):
            items.append(TestChatItem(id: id, role: .toolResult, text: text, isError: isError))
        case .approvalNote(let text):
            items.append(TestChatItem(id: id, role: .approvalNote, text: text))
        case .permissionRequested(let requestID, let toolCallId, let title, let kind):
            let approval = PendingToolApproval(
                id: UUID(), requestID: requestID, toolCallId: toolCallId, title: title, kind: kind)
            pendingApprovals.append(approval)
            scheduleApprovalTimeout(approval)
        }
    }

    // MARK: - Permission approvals

    private func resolvePendingApproval(
        _ approval: PendingToolApproval, optionId: String, note: String
    ) async {
        guard pendingApprovals.contains(where: { $0.id == approval.id }) else { return }
        pendingApprovals.removeAll { $0.id == approval.id }
        approvalTimeoutTasks[approval.id]?.cancel()
        approvalTimeoutTasks[approval.id] = nil
        await connection?.deliver(
            response: Self.permissionResponse(id: approval.requestID, optionId: optionId))
        append(.approvalNote(note))
    }

    /// Client-side mirror of `ClientConnection.request(timeout:)`'s own deny-on-timeout
    /// (`ACPAgent.requestPermission` already fails closed there on its own clock) —
    /// this just keeps the UI honest: without it, a request the agent side already
    /// denied on timeout would still show as "pending" forever, inviting a click that
    /// no longer does anything.
    private func scheduleApprovalTimeout(_ approval: PendingToolApproval) {
        let seconds = agentConfigProvider().permissionTimeoutSeconds
        guard seconds > 0 else { return }
        approvalTimeoutTasks[approval.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.expirePendingApproval(approval)
        }
    }

    private func expirePendingApproval(_ approval: PendingToolApproval) {
        guard pendingApprovals.contains(where: { $0.id == approval.id }) else { return }
        pendingApprovals.removeAll { $0.id == approval.id }
        approvalTimeoutTasks[approval.id] = nil
        append(.approvalNote("Timed out — denied: \(approval.title)"))
        // Best-effort nudge in case ours fires marginally before the agent's own
        // timeout; a no-op (guarded by the connection's own pending-id table) if the
        // agent already resolved this request itself.
        let response = Self.permissionResponse(id: approval.requestID, optionId: "reject_once")
        let connection = self.connection
        Task { await connection?.deliver(response: response) }
    }

    private static func permissionResponse(id: JSONValue, optionId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "result": .object([
                "outcome": .object([
                    "outcome": .string("selected"), "optionId": .string(optionId),
                ])
            ]),
        ])
    }

    // MARK: - Workspace

    /// Resolve the folder the NEXT bootstrap's tools should operate in: the
    /// configured workspace if one is set, else a throwaway scratch dir — minted
    /// once and reused for the rest of this session object's life.
    private func resolvedWorkdir() -> String {
        let configured = workspaceProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        if let fallbackWorkdir { return fallbackWorkdir }
        let fresh = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-testchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        fallbackWorkdir = fresh
        return fresh
    }

    /// Best-effort sweep of scratch dirs earlier sessions left behind — nothing ever
    /// removed them, so they accumulated in `$TMPDIR` indefinitely. Runs once per
    /// session start; a locked/in-use leftover is simply skipped and swept next time.
    /// Only ever touches its own "eldr-acp-testchat-*" prefix.
    private static func cleanupStaleWorkspaces() {
        let fm = FileManager.default
        let tmp = NSTemporaryDirectory()
        guard let entries = try? fm.contentsOfDirectory(atPath: tmp) else { return }
        for name in entries where name.hasPrefix("eldr-acp-testchat-") {
            try? fm.removeItem(atPath: (tmp as NSString).appendingPathComponent(name))
        }
    }

    // MARK: - Wire helpers

    private func sessionNewLine() -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("session/new"),
            "params": .object(["cwd": .string(workdir)]),
        ]).serialized()
    }

    private func promptLine(sid: String, text: String) -> String {
        rpcID += 1
        return JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(rpcID), "method": .string("session/prompt"),
            "params": .object([
                "sessionId": .string(sid),
                "prompt": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]).serialized()
    }

    private func prettyJSON(_ value: JSONValue) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value.foundation,
                options: [.prettyPrinted, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return value.serialized() }
        return text
    }
}

/// Resumes an in-flight `session/request_permission` when the session is torn down
/// (`reset()`) mid-request — `ClientConnection.failAll` resumes it with this error,
/// and `ACPAgent.requestPermission` treats ANY thrown error as a denial, so a torn-
/// down session never leaves (or defaults) a mutating tool call open.
private struct SessionTornDown: Error, Sendable {}

/// A `NullClientConnection` sink: instead of writing JSON-RPC to stdio it parses the
/// agent's outbound `session/update` notifications into `TestChatEvent`s. Permission
/// requests either auto-grant (when `autoApprove` is set, visibly annotated in the
/// transcript) or are forwarded to the UI as a `permissionRequested` event for an
/// explicit Approve/Deny — `TestChatSession` holds the `ClientConnection` directly
/// and delivers that decision itself once the user answers.
private actor EventSink: OutputSink {
    private let continuation: AsyncStream<TestChatEvent>.Continuation
    private var connection: ClientConnection?
    /// Fixed for this sink's lifetime — read once from config at bootstrap; toggling
    /// the setting rebuilds the session (`TestChatView`'s `.onChange`), which
    /// constructs a fresh sink with the new value.
    private let autoApprove: Bool

    init(_ continuation: AsyncStream<TestChatEvent>.Continuation, autoApprove: Bool) {
        self.continuation = continuation
        self.autoApprove = autoApprove
    }
    func attach(_ connection: ClientConnection) { self.connection = connection }

    func write(line: String) async {
        guard let message = JSONValue.parse(line) else { return }

        if message["method"]?.stringValue == "session/request_permission",
            let id = message["id"]
        {
            let toolCall = message["params"]?["toolCall"]
            let title = toolCall?["title"]?.stringValue ?? "tool"
            let kind = toolCall?["kind"]?.stringValue ?? ""
            let toolCallId = toolCall?["toolCallId"]?.stringValue ?? ""
            if autoApprove {
                await connection?.deliver(response: Self.grantResponse(id: id))
                continuation.yield(.approvalNote("Auto-approved: \(title)"))
            } else {
                continuation.yield(
                    .permissionRequested(
                        requestID: id, toolCallId: toolCallId, title: title, kind: kind))
            }
            return
        }

        guard message["method"]?.stringValue == "session/update",
            let update = message["params"]?["update"]
        else { return }

        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let text = update["content"]?["text"]?.stringValue {
                continuation.yield(.assistantMessage(text))
            }
        case "tool_call":
            let name = update["title"]?.stringValue ?? "tool"
            continuation.yield(.toolCall(name: name, args: update["rawInput"] ?? .object([:])))
        case "tool_call_update":
            let status = update["status"]?.stringValue
            if status == "completed" || status == "failed",
                let block = update["content"]?.arrayValue?.first
            {
                let text =
                    block["content"]?["text"]?.stringValue ?? block["error"]?.stringValue ?? ""
                continuation.yield(.toolResult(text, isError: status == "failed"))
            }
        default:
            break
        }
    }

    private static func grantResponse(id: JSONValue) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "result": .object([
                "outcome": .object([
                    "outcome": .string("selected"), "optionId": .string("allow_once"),
                ])
            ]),
        ])
    }
}
