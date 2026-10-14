// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP

public enum TestChatEvent: Sendable {
    case userMessage(String)
    case toolCall(name: String, args: JSONValue)
    case toolResult(String, isError: Bool)
    case assistantMessage(String)
    case permissionRequested(requestID: JSONValue, toolCallId: String, title: String, kind: String)
    case approvalNote(String)
}

public struct TestChatItem: Sendable, Equatable, Identifiable {
    public enum Role: Sendable, Equatable { case user, assistant, toolCall, toolResult, approvalNote }
    public let id: Int
    public var role: Role
    public var text: String
    public var toolName: String?
    public var argsJSON: String?
    public var isError: Bool = false
}

public struct PendingToolApproval: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let requestID: JSONValue
    public let toolCallId: String
    public let title: String
    public let kind: String
}

/// Port of the macOS `TestChatSession`: drives the REAL `ACPAgent` in-process over a
/// `ClientConnection` whose sink turns the agent's JSON-RPC notifications into chat
/// items. Mutating tools ask for permission; the UI answers Approve/Deny (or the
/// session auto-approves when configured, annotated in the transcript). A request left
/// unanswered past the permission timeout is DENIED (fail closed), and `reset()` fails
/// every in-flight request so a torn-down session never leaves a tool allowed.
public actor TestChatSession {
    public struct Options: Sendable {
        public var llm: LLMConfig
        public var agent: AgentConfig
        public var workdir: String
        public var autoApprove: Bool
        public var useFakeLLM: Bool
        public var captureRaw: Bool
        public init(llm: LLMConfig, agent: AgentConfig, workdir: String, autoApprove: Bool = false,
                    useFakeLLM: Bool = false, captureRaw: Bool = false) {
            self.llm = llm; self.agent = agent; self.workdir = workdir
            self.autoApprove = autoApprove; self.useFakeLLM = useFakeLLM; self.captureRaw = captureRaw
        }
    }

    public private(set) var items: [TestChatItem] = []
    public private(set) var isResponding = false
    public private(set) var pendingApprovals: [PendingToolApproval] = []
    public private(set) var rawStream = ""
    public private(set) var workdir = ""

    private var options: Options
    private let onChange: @Sendable () -> Void
    private var agent: ACPAgent?
    private var connection: ClientConnection?
    private var sessionId: String?
    private var consumeTask: Task<Void, Never>?
    private var continuation: AsyncStream<TestChatEvent>.Continuation?
    private var nextItemID = 0
    private var rpcID = 100
    private var fallbackWorkdir: String?
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    /// Injectable LLM (tests). nil ⇒ built from `options`.
    private let llmOverride: (any LLMClient)?

    public init(options: Options, llm: (any LLMClient)? = nil, onChange: @escaping @Sendable () -> Void = {}) {
        self.options = options
        self.llmOverride = llm
        self.onChange = onChange
    }

    public func setOptions(_ o: Options) {
        options = o
        reset()
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        isResponding = true  // claim the turn before any await
        rawStream = ""
        onChange()
        await bootstrap()
        guard let agent, let sid = sessionId else {
            append(.assistantMessage("Could not start the agent session."))
            isResponding = false
            onChange()
            return
        }
        append(.userMessage(trimmed))
        _ = await agent.handle(line: promptLine(sid: sid, text: trimmed))
        // Let the consumer drain the last notifications before we report done.
        await Task.yield()
        isResponding = false
        onChange()
    }

    public func approve(_ a: PendingToolApproval) async {
        await resolve(a, optionId: "allow_once", note: "Approved: \(a.title)")
    }

    public func deny(_ a: PendingToolApproval) async {
        await resolve(a, optionId: "reject_once", note: "Denied: \(a.title)")
    }

    public func reset() {
        continuation?.finish()
        continuation = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let old = connection { Task { await old.failAll(SessionTornDown()) } }
        agent = nil
        connection = nil
        sessionId = nil
        isResponding = false
        items.removeAll()
        rawStream = ""
        for t in timeouts.values { t.cancel() }
        timeouts.removeAll()
        pendingApprovals.removeAll()
        onChange()
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        guard agent == nil else { return }
        let dir = resolvedWorkdir()
        workdir = dir
        let (stream, cont) = AsyncStream<TestChatEvent>.makeStream()
        let sink = EventSink(cont, autoApprove: options.autoApprove)
        let connection = ClientConnection(sink: sink)
        await sink.attach(connection)
        let llm: any LLMClient
        if let llmOverride {
            llm = llmOverride
        } else if options.useFakeLLM || options.llm.url.isEmpty {
            llm = EchoLLMClient()
        } else {
            var raw: (@Sendable (String) -> Void)?
            if options.captureRaw {
                raw = { [weak self] piece in Task { await self?.appendRaw(piece) } }
            }
            llm = OpenAICompatibleLLMClient(config: options.llm, rawObserver: raw)
        }
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: ToolEnvironment(workdir: dir),
            config: options.agent, configDir: nil, maxIterations: options.agent.maxIterations)
        self.connection = connection
        self.agent = agent
        self.continuation = cont
        consumeTask = Task { [weak self] in
            for await event in stream { await self?.append(event) }
        }
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let resp = await agent.handle(line: sessionNewLine(dir))
        sessionId = JSONValue.parse(resp ?? "")?["result"]?["sessionId"]?.stringValue
    }

    private func appendRaw(_ s: String) { rawStream += s; onChange() }

    private func append(_ event: TestChatEvent) {
        let id = nextItemID
        nextItemID += 1
        switch event {
        case .userMessage(let t): items.append(TestChatItem(id: id, role: .user, text: t))
        case .assistantMessage(let t):
            // Streaming chunks extend the previous assistant bubble.
            if let last = items.last, last.role == .assistant {
                items[items.count - 1].text += t
            } else {
                items.append(TestChatItem(id: id, role: .assistant, text: t))
            }
        case .toolCall(let name, let args):
            items.append(TestChatItem(id: id, role: .toolCall, text: name, toolName: name, argsJSON: args.serialized()))
        case .toolResult(let t, let err):
            items.append(TestChatItem(id: id, role: .toolResult, text: t, isError: err))
        case .approvalNote(let t): items.append(TestChatItem(id: id, role: .approvalNote, text: t))
        case .permissionRequested(let rid, let tcid, let title, let kind):
            let a = PendingToolApproval(id: UUID(), requestID: rid, toolCallId: tcid, title: title, kind: kind)
            pendingApprovals.append(a)
            scheduleTimeout(a)
        }
        onChange()
    }

    private func resolve(_ a: PendingToolApproval, optionId: String, note: String) async {
        guard pendingApprovals.contains(where: { $0.id == a.id }) else { return }
        pendingApprovals.removeAll { $0.id == a.id }
        timeouts[a.id]?.cancel()
        timeouts[a.id] = nil
        _ = await connection?.deliver(response: Self.permissionResponse(id: a.requestID, optionId: optionId))
        append(.approvalNote(note))
    }

    private func scheduleTimeout(_ a: PendingToolApproval) {
        let seconds = options.agent.permissionTimeoutSeconds
        guard seconds > 0 else { return }
        timeouts[a.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expire(a)
        }
    }

    private func expire(_ a: PendingToolApproval) async {
        guard pendingApprovals.contains(where: { $0.id == a.id }) else { return }
        pendingApprovals.removeAll { $0.id == a.id }
        timeouts[a.id] = nil
        append(.approvalNote("Timed out — denied: \(a.title)"))
        _ = await connection?.deliver(response: Self.permissionResponse(id: a.requestID, optionId: "reject_once"))
    }

    static func permissionResponse(id: JSONValue, optionId: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"), "id": id,
            "result": .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionId)])]),
        ])
    }

    private func resolvedWorkdir() -> String {
        let configured = options.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty { return configured }
        if let fallbackWorkdir { return fallbackWorkdir }
        let fresh = (NSTemporaryDirectory() as NSString).appendingPathComponent("eldr-acp-testchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        fallbackWorkdir = fresh
        return fresh
    }

    /// Remove scratch dirs earlier sessions left in $TMPDIR (prefix-scoped).
    public static func cleanupStaleWorkspaces() {
        let tmp = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("eldr-acp-testchat-") {
            try? FileManager.default.removeItem(atPath: (tmp as NSString).appendingPathComponent(name))
        }
    }

    private func sessionNewLine(_ dir: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(1), "method": .string("session/new"),
            "params": .object(["cwd": .string(dir)]),
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
}

struct SessionTornDown: Error, Sendable {}

/// Parses the agent's outbound JSON-RPC into `TestChatEvent`s (Mac `EventSink`, verbatim logic).
actor EventSink: OutputSink {
    private let continuation: AsyncStream<TestChatEvent>.Continuation
    private var connection: ClientConnection?
    private let autoApprove: Bool

    init(_ c: AsyncStream<TestChatEvent>.Continuation, autoApprove: Bool) {
        continuation = c
        self.autoApprove = autoApprove
    }
    func attach(_ c: ClientConnection) { connection = c }

    func write(line: String) async {
        guard let message = JSONValue.parse(line) else { return }
        if message["method"]?.stringValue == "session/request_permission", let id = message["id"] {
            let tc = message["params"]?["toolCall"]
            let title = tc?["title"]?.stringValue ?? "tool"
            let kind = tc?["kind"]?.stringValue ?? ""
            let tcid = tc?["toolCallId"]?.stringValue ?? ""
            if autoApprove {
                _ = await connection?.deliver(response: TestChatSession.permissionResponse(id: id, optionId: "allow_once"))
                continuation.yield(.approvalNote("Auto-approved: \(title)"))
            } else {
                continuation.yield(.permissionRequested(requestID: id, toolCallId: tcid, title: title, kind: kind))
            }
            return
        }
        guard message["method"]?.stringValue == "session/update", let update = message["params"]?["update"] else { return }
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let t = update["content"]?["text"]?.stringValue { continuation.yield(.assistantMessage(t)) }
        case "tool_call":
            continuation.yield(.toolCall(name: update["title"]?.stringValue ?? "tool", args: update["rawInput"] ?? .object([:])))
        case "tool_call_update":
            let status = update["status"]?.stringValue
            if status == "completed" || status == "failed", let block = update["content"]?.arrayValue?.first {
                let t = block["content"]?["text"]?.stringValue ?? block["error"]?.stringValue ?? ""
                continuation.yield(.toolResult(t, isError: status == "failed"))
            }
        default: break
        }
    }
}
