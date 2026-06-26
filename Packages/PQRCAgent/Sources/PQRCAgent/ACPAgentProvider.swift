import Foundation
import PQRCACP

/// Drives an external ACP coding harness (a Mac node speaking Agent Client
/// Protocol) as an `AgentProvider`, so the phone's chat can be answered by a
/// full coding agent behind the same AI abstraction every other backend uses
/// (APP-SPEC §9). The phone is the remote control; the harness does its own
/// file/shell I/O on the node (it advertises no fs/terminal caps — see
/// `ACPClient`).
///
/// One `ACPClient` (one ACP session) is kept alive across every `draftReply` /
/// `threadTurn`: starting a session per call would reset the harness's context
/// each message. Each call renders the `AgentContext` to a prompt and sends it
/// as a SINGLE `session/prompt`; the assistant's reply is returned as a `Draft`
/// / `AgentTurn`.
///
/// Privacy: like every remote backend, decrypted context leaves the device to
/// reach the node, so it gets the same consent/firewall treatment upstream;
/// signing keys never travel (SPEC §13.5). Tool-call activity is folded into the
/// result as PLAIN text — no markdown-link injection (P-5) — so the user sees
/// what the agent did rather than it vanishing silently.
public actor ACPAgentProvider: AgentProvider {
    private let transport: any ACPTransport
    private let permissionHandler: @Sendable (_ title: String, _ kind: String) async -> Bool
    /// Working directory advertised to the node on `session/new` (nil → the
    /// node's own default).
    private let cwd: String?
    /// How long a single turn may run before we stop waiting on the harness.
    /// Self-bounding: a wedged node (or a bug in our event correlation) surfaces
    /// as a thrown error instead of an `await` that never returns.
    private let turnTimeout: Double
    /// Optional live-event observer (Phase D1 — plan/TODO visibility). When set, the
    /// consumer forwards EVERY `ACPUIEvent` to it as it arrives (so the runtime can
    /// surface a plan checklist, tool activity, etc. live), in ADDITION to folding it
    /// into the turn result. Default no-op: existing callers/tests see zero behavior
    /// change. `@Sendable` so it crosses the consumer task boundary cleanly.
    private let eventObserver: @Sendable (ACPUIEvent) -> Void
    /// Phase D3 — advertise the phone's MCP chat tools to the node at `session/new`
    /// (so its coding agent can read/draft/search the owner's chat over the relay).
    /// Default false; set true only when the owner gave the per-node "share chat
    /// context" consent. The phone serves those tool calls back from its redacting,
    /// window-gating MCP server (`RelayMCPHost`).
    private let advertiseChatTools: Bool

    /// The single long-lived client + its event-consumer task, created lazily on
    /// the first call and reused thereafter. `nil` until started; torn down by
    /// `shutdown()`.
    private var live: Live?

    private struct Live {
        let client: ACPClient
        let accumulator: TurnAccumulator
        let consumer: Task<Void, Never>
    }

    public enum ACPProviderError: Error, Equatable, Sendable {
        /// The turn exceeded `turnTimeout` (wedged node or lost correlation).
        case turnTimedOut
        /// `prompt()` / `start()` failed at the ACP layer; carries the reason.
        case acpFailure(String)
    }

    /// - Parameters:
    ///   - transport: the line transport to the node (Multipeer/LAN in the app;
    ///     `InMemoryACPTransport` in tests).
    ///   - cwd: working directory for the node's session (nil → node default).
    ///   - turnTimeout: hard cap per turn (seconds). Default 120.
    ///   - permissionHandler: decides a mutating tool's permission request.
    ///     Default denies — autonomous file/shell mutation must be opted into,
    ///     never the silent default (privacy #1).
    ///   - eventObserver: optional live-event sink (Phase D1). Default no-op, so
    ///     every existing caller is byte-for-byte unchanged; the app sets it to
    ///     forward plan/tool events to the UI.
    public init(
        transport: any ACPTransport,
        cwd: String? = nil,
        turnTimeout: Double = 120,
        permissionHandler: @escaping @Sendable (_ title: String, _ kind: String) async -> Bool = {
            _, _ in false
        },
        eventObserver: @escaping @Sendable (_ event: ACPUIEvent) -> Void = { _ in },
        advertiseChatTools: Bool = false
    ) {
        self.transport = transport
        self.cwd = cwd
        self.turnTimeout = turnTimeout > 0 ? turnTimeout : 120
        self.permissionHandler = permissionHandler
        self.eventObserver = eventObserver
        self.advertiseChatTools = advertiseChatTools
    }

    /// Tear down the live session + consumer. Safe to call when never started.
    public func shutdown() async {
        guard let live else { return }
        self.live = nil
        await live.client.shutdown()  // finishes `events` → the consumer loop ends
        live.consumer.cancel()
    }

    // MARK: Phase D4 — interactive terminal control (phone → node)

    /// Write stdin to a live interactive terminal on the node (the user typing into the
    /// PTY view). No-op if the session isn't started.
    public func sendTerminalInput(terminalId: String, data: String) async {
        await live?.client.terminalInput(terminalId: terminalId, data: data)
    }

    /// KILL a live interactive terminal (the phone's Stop control). Always available —
    /// the node terminates the PTY's child process group and closes its fds. No-op if the
    /// session isn't started (then there's nothing live to kill).
    public func killTerminal(terminalId: String) async {
        await live?.client.terminalKill(terminalId: terminalId)
    }

    // MARK: AgentProvider

    public func draftReply(context: AgentContext) async throws -> Draft {
        let prompt = Self.composePrompt(
            system: context.draftSystemPrompt(), context: context)
        let result = try await runTurn(prompt)
        return Draft(text: Self.foldResult(result))
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        let prompt = Self.composePrompt(
            system: context.turnSystemPrompt(), context: context)
        let result = try await runTurn(prompt)
        let text = Self.foldResult(result).trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty (no assistant text and no tool activity) or an explicit PASS ⇒
        // the agent chose to stay silent; emit nothing rather than a blank turn.
        guard !text.isEmpty, text != "PASS" else { return nil }
        return AgentTurn(messages: [AgentMessage(text: text)])
    }

    // MARK: Turn lifecycle

    /// Send one `session/prompt` over the live (lazily started) session and
    /// return everything the harness produced for that turn. The whole turn is
    /// raced against `turnTimeout` so nothing here can block forever.
    private func runTurn(_ prompt: String) async throws -> TurnResult {
        let live = try await ensureStarted()
        // Mark the start of a new turn: clears the accumulator and bumps the
        // generation the consumer tags events with, so any late straggler from a
        // prior turn can't bleed into this one.
        let generation = await live.accumulator.beginTurn()

        do {
            return try await withThrowingTaskGroup(of: TurnResult.self) { group in
                group.addTask {
                    let stop = try await live.client.prompt(prompt)
                    // `prompt()` returns at end_turn: the turn's `session/update`s
                    // were delivered to the event stream BEFORE the stop-reason line
                    // the driver just resolved on, so they're already buffered. Wait
                    // (bounded) for the consumer to flush them into the accumulator,
                    // then read the correlated result for THIS generation.
                    return await live.accumulator.finish(generation: generation, stopReason: stop)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.turnTimeout * 1_000_000_000))
                    throw ACPProviderError.turnTimedOut
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch let error as ACPProviderError {
            throw error
        } catch let error as ACPClientError {
            throw ACPProviderError.acpFailure("\(error)")
        }
    }

    /// Start the client + consumer once; reuse on every later call.
    private func ensureStarted() async throws -> Live {
        if let live { return live }
        let client = ACPClient(
            transport: transport, permissionHandler: permissionHandler,
            advertiseChatTools: advertiseChatTools)
        let accumulator = TurnAccumulator()
        // ONE continuous consumer for the SINGLE event stream: it folds each
        // event into whatever turn is currently in flight (correlation lives in
        // the accumulator's generation, reset by `beginTurn`) AND forwards it to the
        // live observer (Phase D1) so the UI can show a plan checklist as it streams.
        // The observer is a plain `@Sendable` closure (no `await`), so forwarding can
        // never stall the fold. It ends when `shutdown()` finishes the stream.
        let observer = eventObserver
        let consumer = Task {
            for await event in client.events {
                observer(event)
                await accumulator.ingest(event)
            }
        }
        do {
            _ = try await client.start(cwd: cwd)
        } catch {
            // Started nothing usable — unwind the half-built consumer/client so a
            // retry starts clean.
            await client.shutdown()
            consumer.cancel()
            if let acp = error as? ACPClientError {
                throw ACPProviderError.acpFailure("\(acp)")
            }
            throw ACPProviderError.acpFailure("\(error)")
        }
        let live = Live(client: client, accumulator: accumulator, consumer: consumer)
        self.live = live
        return live
    }

    // MARK: Prompt rendering (REUSED from the other providers)

    /// Combine the per-mode system prompt with the shared transcript renderer.
    /// `ACPClient.prompt` carries a single text blob (no separate system channel),
    /// so the system guidance is prepended as a labeled block above the same
    /// transcript every other provider sends — identical context, one wire shape.
    static func composePrompt(system: String, context: AgentContext) -> String {
        let transcript = FoundationModelsAgentProvider.renderTranscript(context)
        // Conduit default: with no user system prompt, send only the transcript —
        // no empty "[System]" header (chaff the node would otherwise see).
        guard !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "[Conversation]\n\(transcript)"
        }
        return "[System]\n\(system)\n\n[Conversation]\n\(transcript)"
    }

    /// Fold a turn's assistant prose + tool-call activity into one plain string.
    /// Tool activity is appended as plain lines (P-5: never markdown links) so it
    /// is surfaced, not silently dropped, when the turn carried tool work.
    static func foldResult(_ result: TurnResult) -> String {
        let assistant = result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        let activity = result.toolActivity
        if activity.isEmpty { return assistant }
        let activityBlock = activity.joined(separator: "\n")
        if assistant.isEmpty { return activityBlock }
        return assistant + "\n\n" + activityBlock
    }
}

/// One turn's correlated output: the assistant's accumulated prose and a plain
/// list of the tool-call activity the harness reported during the turn.
struct TurnResult: Sendable, Equatable {
    var assistantText: String
    var toolActivity: [String]
    var stopReason: String?
}

/// Correlates the SINGLE continuous `ACPClient.events` stream to the turn that's
/// currently in flight. Every prompt bumps `generation`; the consumer tags each
/// folded event with the live generation, so output from a finished turn cannot
/// leak into the next one. `finish` waits (bounded) for the consumer to drain the
/// events already buffered when `prompt()` returned, then yields the result.
actor TurnAccumulator {
    private var generation = 0
    private var assistant = ""
    private var activity: [String] = []
    /// Bumped every time the consumer folds an event, so `finish` can tell whether
    /// the consumer is still flushing the buffer (count changing) or has gone
    /// quiet (count stable ⇒ everything for the turn is in).
    private var ingestCount = 0

    /// Begin a fresh turn: clear the buffers and return the new generation tag.
    func beginTurn() -> Int {
        generation += 1
        assistant = ""
        activity = []
        ingestCount = 0
        return generation
    }

    /// Fold one UI event into the in-flight turn. Tool-call lifecycle becomes
    /// PLAIN text (no markdown). `assistantText` chunks concatenate in order.
    func ingest(_ event: ACPUIEvent) {
        ingestCount += 1
        switch event {
        case .assistantText(let text):
            assistant += text
        case .toolCall(_, let title, let kind, let status):
            activity.append("[tool: \(title) (\(kind)) — \(status)]")
        case .toolCallUpdate(_, let status, let text, let isError):
            var line = "[tool \(status)"
            if isError { line += " (error)" }
            if let text, !text.isEmpty { line += ": \(text)" }
            line += "]"
            activity.append(line)
        case .availableCommands:
            // Session metadata, not turn output — nothing to fold.
            break
        case .plan:
            // Live UI signal (forwarded to the observer), not turn-fold output — the
            // plan is shown as its own checklist, never inlined into the reply text.
            break
        case .terminalOpened, .terminalOutput, .terminalClosed:
            // Phase D4 — live INTERACTIVE-terminal signals. Forwarded to the observer (the
            // app renders a terminal view + Stop control); NEVER folded into the turn's
            // reply text — the live PTY stream is its own surface, not a chat message.
            break
        }
    }

    /// Settle and read the turn's result. `prompt()` has returned, so the turn's
    /// events are already buffered in the stream; spin (bounded, yielding) until
    /// the consumer's fold count stops moving — i.e. it has flushed them — then
    /// snapshot. The bound (`maxSettleIterations`) guarantees this returns even if
    /// the consumer never runs again (e.g. the stream died), so test (c) — a turn
    /// with no assistant text — returns cleanly instead of hanging.
    func finish(generation turn: Int, stopReason: String) async -> TurnResult {
        // Only settle while WE are still the live turn; a superseded generation
        // returns its (already-final) snapshot immediately.
        guard turn == generation else {
            return TurnResult(
                assistantText: assistant, toolActivity: activity, stopReason: stopReason)
        }
        var lastSeen = -1
        var stableSpins = 0
        let maxSettleIterations = 1000
        for _ in 0..<maxSettleIterations {
            if generation != turn { break }  // a newer turn began under us
            let current = ingestCount
            if current == lastSeen {
                stableSpins += 1
                // Two consecutive quiet observations ⇒ the buffer is drained.
                if stableSpins >= 2 { break }
            } else {
                stableSpins = 0
                lastSeen = current
            }
            await Task.yield()  // let the consumer pull the next buffered event
        }
        return TurnResult(
            assistantText: assistant, toolActivity: activity, stopReason: stopReason)
    }
}
