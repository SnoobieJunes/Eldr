import Foundation

// Phase 1 (docs/ACPRouterplan.md §5 step 2): the phone-facing ACP client. Wraps the now
// transport-agnostic `ACPClientDriver` over an `ACPTransport` and surfaces a TYPED
// AsyncStream of UI events (assistant text, tool-call lifecycle, available commands) for
// the chat UI, plus `prompt(...)` and an injected permission handler. The phone advertises
// NO fs/terminal capabilities, so the agent does its own file/shell I/O on the Mac node —
// the phone is the remote control, not the worker.

/// Phase D4 — iOS-available constants for the interactive PTY terminal. Lives here (not
/// on the macOS-only `ToolExecutor`) because the PHONE — which compiles PQRCACP for iOS
/// and never hosts the agent — must recognize an interactive-terminal permission request
/// to apply its stronger gate. The node's `ToolExecutor` reuses the same prefix so the two
/// sides agree by construction.
public enum ACPTerminal {
    /// The stable title prefix every `open_terminal` permission request carries. The ACP
    /// ToolKind (`execute`) is too coarse to distinguish an open-ended interactive shell
    /// from a one-shot `run_shell`, so the phone keys its stronger gate (standing
    /// autonomous-changes consent, no allow-once) off this title prefix.
    public static let interactiveTerminalTitlePrefix = "Open interactive terminal"
}

/// One step of the agent's plan (an ACP `PlanEntry`), as the phone consumes it.
/// Display-only: `content` is agent output and gets the same hygiene as an agent
/// bubble (no special trust). `priority` is dropped — the phone's checklist keys
/// solely off `status` (pending|in_progress|completed).
public struct ACPPlanEntry: Sendable, Equatable {
    public let content: String
    public let status: String
    public init(content: String, status: String) {
        self.content = content
        self.status = status
    }
}

/// A typed slice of an ACP turn, for the chat UI to render.
public enum ACPUIEvent: Sendable, Equatable {
    /// A streamed piece of the assistant's prose (`agent_message_chunk`).
    case assistantText(String)
    /// A tool call entered `pending` (about to run).
    case toolCall(id: String, title: String, kind: String, status: String)
    /// A tool call advanced (`in_progress`/`completed`/`failed`) with any result text.
    case toolCallUpdate(id: String, status: String, text: String?, isError: Bool)
    /// The agent advertised its slash-commands for the session.
    case availableCommands([String])
    /// The agent reported its plan for the turn (a checklist). Re-sent in full on
    /// each change, so the latest `.plan` is the current state of every step.
    case plan([ACPPlanEntry])
    /// Phase D4 — a live INTERACTIVE terminal was opened on the node (a persistent PTY,
    /// distinct from one-shot `run_shell`). The phone surfaces a terminal view + a Stop
    /// control keyed off `terminalId`. `title` is a short human label (e.g. the shell).
    case terminalOpened(terminalId: String, title: String)
    /// Phase D4 — a streamed chunk of an interactive terminal's combined stdout+stderr,
    /// delivered incrementally as the child produces it (NOT buffered to EOF). Display
    /// text only — agent output, trusted no further than an agent bubble.
    case terminalOutput(terminalId: String, chunk: String)
    /// Phase D4 — an interactive terminal ended (the child exited, or it was killed via
    /// the phone's Stop / a fail-closed teardown). The phone removes its terminal view.
    case terminalClosed(terminalId: String, exitCode: Int?)
}

public actor ACPClient {
    private let driver: ACPClientDriver
    private let eventContinuation: AsyncStream<ACPUIEvent>.Continuation
    /// The typed UI-event stream. Iterate it to render a turn; finishes on `shutdown()`.
    public nonisolated let events: AsyncStream<ACPUIEvent>

    /// - Parameters:
    ///   - transport: the line transport to the agent (in-memory for tests; Multipeer/LAN
    ///     for the phone→node link).
    ///   - permissionHandler: decides a mutating tool's permission request. The plan
    ///     surfaces this to the node owner; default allows (tests / trusted local).
    /// - Parameters:
    ///   - advertiseChatTools: Phase D3 — advertise a non-empty `mcpServers` at
    ///     `session/new`, so the node wires its MCP-over-relay chat tools (the phone
    ///     serves them back). Set true only when the owner consented to share chat
    ///     context with this node; default false (the path stays inert).
    public init(
        transport: any ACPTransport,
        permissionHandler: @escaping @Sendable (_ title: String, _ kind: String) async -> Bool = {
            _, _ in false  // fail closed by default; see ACPClientHandler.requestPermission
        },
        advertiseChatTools: Bool = false
    ) {
        var continuation: AsyncStream<ACPUIEvent>.Continuation!
        let stream = AsyncStream<ACPUIEvent> { continuation = $0 }
        self.events = stream
        self.eventContinuation = continuation
        let emit = continuation!
        let handler = ACPClientHandler(
            onAgentMessageChunk: { text in emit.yield(.assistantText(text)) },
            onToolCall: { id, title, kind, status in
                emit.yield(.toolCall(id: id, title: title, kind: kind, status: status))
            },
            onToolCallUpdate: { id, status, content, isError in
                emit.yield(
                    .toolCallUpdate(id: id, status: status, text: content, isError: isError))
            },
            onAvailableCommands: { names in emit.yield(.availableCommands(names)) },
            onPlan: { entries in emit.yield(.plan(entries)) },
            onTerminalOpened: { id, title in
                emit.yield(.terminalOpened(terminalId: id, title: title))
            },
            onTerminalOutput: { id, chunk in
                emit.yield(.terminalOutput(terminalId: id, chunk: chunk))
            },
            onTerminalClosed: { id, code in
                emit.yield(.terminalClosed(terminalId: id, exitCode: code))
            },
            requestPermission: permissionHandler)
        // The phone advertises no fs/terminal caps → the agent uses its own I/O on the Mac.
        self.driver = ACPClientDriver(
            transport: transport, handler: handler, capabilities: ClientCapabilities(),
            advertiseChatTools: advertiseChatTools)
    }

    /// `initialize` + `session/new`. Returns the live session to prompt.
    @discardableResult
    public func start(cwd: String? = nil) async throws -> ACPSessionInfo {
        try await driver.start(cwd: cwd)
    }

    /// Send a prompt; `session/update`s stream to `events` meanwhile. Returns the
    /// `stopReason` (`end_turn`, `cancelled`, …).
    @discardableResult
    public func prompt(_ text: String) async throws -> String {
        try await driver.prompt(text)
    }

    /// Cancel the in-flight turn (fire-and-forget).
    public func cancel() async { await driver.cancel() }

    /// Phase D4 — write stdin to a live interactive terminal (PTY) on the node.
    public func terminalInput(terminalId: String, data: String) async {
        await driver.terminalInput(terminalId: terminalId, data: data)
    }

    /// Phase D4 / feature 9 — resize a live terminal's window (TIOCSWINSZ on the node).
    public func terminalResize(terminalId: String, cols: Int, rows: Int) async {
        await driver.terminalResize(terminalId: terminalId, cols: cols, rows: rows)
    }

    /// Phase D4 — KILL a live interactive terminal (the Stop control). Always available.
    public func terminalKill(terminalId: String) async {
        await driver.terminalKill(terminalId: terminalId)
    }

    /// Tear down the transport + reader and finish the event stream.
    public func shutdown() async {
        await driver.shutdown()
        eventContinuation.finish()
    }
}
