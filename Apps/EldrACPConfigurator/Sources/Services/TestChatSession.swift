import Foundation
import PQRCACP

/// What the in-process agent surfaces to the test-chat UI.
enum TestChatEvent: Sendable {
    case userMessage(String)
    case toolCall(name: String, args: JSONValue)
    case toolResult(String, isError: Bool)
    case assistantMessage(String)
}

/// A flattened, identifiable chat row for SwiftUI.
struct TestChatItem: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant, toolCall, toolResult }
    let id: Int
    var role: Role
    var text: String
    var toolName: String?
    var argsJSON: String?
    var isError: Bool = false
}

/// Drives a real `ACPAgent` in-process so the user can exercise their LLM + tools
/// without Xcode. A `NullClientConnection` sink captures the agent's `session/update`
/// notifications as `TestChatEvent`s (rather than writing stdio) and auto-grants
/// permission requests (there's no editor to prompt). Tools run in a throwaway
/// scratch dir so the test chat never touches a real project.
@MainActor
final class TestChatSession: ObservableObject {

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

    /// Pulled fresh each bootstrap so config edits take effect after `reset()`.
    /// `@MainActor`-isolated because the UI wires these to MainActor store state.
    var llmConfigProvider: @MainActor () -> LLMConfig = { LLMConfig.fromEnvironment([:]) }
    var agentConfigProvider: @MainActor () -> AgentConfig = { .default }

    private let workdir: String
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

    init() {
        workdir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-testchat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            atPath: workdir, withIntermediateDirectories: true)
    }

    // MARK: - Public

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        // Claim the turn BEFORE the first `await` (bootstrap). The composer fires
        // BOTH the TextField's `.onSubmit` AND the send button's
        // `keyboardShortcut(.return)` on a single Return press, so two `send` tasks
        // can arrive together; setting the flag here (not after bootstrap) makes the
        // second one bail at the guard instead of running a second, concurrent
        // session/prompt on the same agent actor — which duplicated every tool call
        // and flooded the UI (the reported "blew up / froze").
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

    /// Tear down so the next `send` rebuilds with current config (e.g. after the user
    /// edits the LLM URL or toggles echo).
    func reset() {
        // Finish the stream FIRST so the consumer's `for await` returns, then cancel
        // (cancellation alone doesn't terminate an AsyncStream loop). Otherwise each
        // reset leaked a live consumer task bound to the MainActor.
        streamContinuation?.finish()
        streamContinuation = nil
        consumeTask?.cancel()
        consumeTask = nil
        agent = nil
        connection = nil
        sink = nil
        sessionId = nil
        isResponding = false
        items.removeAll()
        rawStream = ""
    }

    // MARK: - Agent bootstrap

    private func bootstrap() async {
        guard agent == nil else { return }
        let (stream, continuation) = AsyncStream<TestChatEvent>.makeStream()
        let sink = EventSink(continuation)
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
        let agent = ACPAgent(
            connection: connection, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: workdir),
            config: agentConfigProvider(), configDir: nil)

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

/// A `NullClientConnection` sink: instead of writing JSON-RPC to stdio it parses the
/// agent's outbound `session/update` notifications into `TestChatEvent`s and
/// auto-grants any `session/request_permission` (no editor exists to prompt the user).
private actor EventSink: OutputSink {
    private let continuation: AsyncStream<TestChatEvent>.Continuation
    private var connection: ClientConnection?

    init(_ continuation: AsyncStream<TestChatEvent>.Continuation) {
        self.continuation = continuation
    }
    func attach(_ connection: ClientConnection) { self.connection = connection }

    func write(line: String) async {
        guard let message = JSONValue.parse(line) else { return }

        // Auto-grant permission requests so mutating tools don't hang the turn.
        if message["method"]?.stringValue == "session/request_permission",
            let id = message["id"]
        {
            await connection?.deliver(
                response: .object([
                    "jsonrpc": .string("2.0"), "id": id,
                    "result": .object([
                        "outcome": .object([
                            "outcome": .string("selected"), "optionId": .string("allow_once"),
                        ])
                    ]),
                ]))
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
}
