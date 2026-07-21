// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Testing

@testable import PQRCAgent

// Proves `ACPAgentProvider` answers the phone's chat by driving a REAL `ACPAgent`
// (the Mac coding harness) over an in-memory transport pair — no stdio, no radios,
// no network — mirroring PQRCACP's `ACPClientRoundTripTests`. Three claims:
//   (a) `draftReply` over ACP returns the harness's assistant text;
//   (b) a tool-call turn surfaces the tool activity as plain text (not dropped);
//   (c) a turn that ends with NO assistant text returns cleanly (no hang).
//
// Every wait is self-bounding: the provider's per-turn timeout plus the suite-level
// `withTimeout` mean a correlation bug fails the test instead of wedging it.

/// A scripted LLM: returns queued responses in order, then a terminal "done".
/// Mirrors the round-trip suite's harness so the agent behaves identically.
private actor ScriptedLLM: LLMClient {
    private var queue: [LLMResponse]
    init(_ responses: [LLMResponse]) { self.queue = responses }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
    }
}

/// Run `body`, but FAIL instead of hanging forever if it doesn't finish in time —
/// so a reintroduced deadlock surfaces as a thrown error, not a wedged suite.
private struct TimedOut: Error {}
@discardableResult
private func withTimeout<T: Sendable>(
    _ seconds: Double, _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimedOut()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite("ACPAgentProvider over ACP (in-memory transport)")
struct ACPAgentProviderTests {

    /// Wire an `ACPAgentProvider` to a real `runACPAgent` over a fresh in-memory
    /// pair with a scripted LLM. Returns the provider and the agent's run Task.
    private func makeProvider(
        llm: any LLMClient, workdir: String,
        permission: @escaping @Sendable (String, String) async -> Bool = { _, _ in true }
    ) -> (ACPAgentProvider, Task<Void, Never>) {
        let (clientSide, agentSide) = InMemoryACPTransport.makePair()
        let agentTask = Task {
            await runACPAgent(
                transport: agentSide, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }
        // Short turn timeout so a correlation bug trips the cap quickly rather than
        // making the suite slow; the happy paths finish in well under this.
        let provider = ACPAgentProvider(
            transport: clientSide, cwd: workdir, turnTimeout: 8, permissionHandler: permission)
        return (provider, agentTask)
    }

    /// A small `AgentContext` with one human turn to render into the prompt.
    private func context(_ text: String) -> AgentContext {
        AgentContext(
            myIdentityHex: "me", myDisplayName: "Alice",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "bob", senderDisplayName: "Bob",
                    participantType: .human, text: text)
            ])
    }

    // (a) draftReply returns the harness's assistant text.
    @Test func draftReplyReturnsAssistantText() async throws {
        try await withTimeout(20) {
            let llm = ScriptedLLM([LLMResponse(content: "Hello from the harness.")])
            let (provider, agentTask) = self.makeProvider(
                llm: llm, workdir: NSTemporaryDirectory())
            defer { agentTask.cancel() }

            let draft = try await provider.draftReply(context: self.context("hi"))
            await provider.shutdown()

            #expect(draft.text.contains("Hello from the harness."))
        }
    }

    // (b) A tool-call turn surfaces the tool activity (plain text), folded with the
    // final assistant prose — the activity is NOT dropped.
    @Test func toolCallTurnSurfacesToolActivity() async throws {
        try await withTimeout(20) {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-acp-prov-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let target = (dir as NSString).appendingPathComponent("out.txt")

            // Turn 1: the model asks to write a file (→ tool-call lifecycle events).
            // Turn 2: it answers in prose (→ assistant text). The fold must contain
            // BOTH.
            let llm = ScriptedLLM([
                LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(
                            id: "w1", name: "write_file",
                            arguments: "{\"path\":\"\(target)\",\"content\":\"hello\"}")
                    ]),
                LLMResponse(content: "Wrote the file."),
            ])
            let (provider, agentTask) = self.makeProvider(
                llm: llm, workdir: dir, permission: { _, _ in true })
            defer { agentTask.cancel() }

            let turn = try await provider.threadTurn(context: self.context("write it"))
            await provider.shutdown()

            // The file was written (proves the tool actually ran on the node).
            #expect(FileManager.default.fileExists(atPath: target))
            let combined = turn?.messages.map(\.text).joined(separator: "\n") ?? ""
            // Assistant prose is present …
            #expect(combined.contains("Wrote the file."))
            // … AND the tool activity was surfaced as plain text (folded in, not a
            // markdown link — P-5), so the user can see what the agent did.
            #expect(combined.contains("[tool"))
            #expect(combined.contains("write_file") || combined.lowercased().contains("write"))
        }
    }

    // (c) A turn that ends with NO assistant text returns cleanly — no hang.
    //
    // The real `runACPAgent` never produces this: it substitutes "(no response)"
    // for empty model content, so there's always ≥1 assistant chunk. So we drive
    // the provider against a HAND-RUN agent side (as the chaos suite does) that
    // completes the handshake and returns `end_turn` with ZERO `session/update`s —
    // the genuine "turn ended, the event stream yielded nothing for it" wire
    // condition. The provider's bounded settle MUST return promptly (empty draft /
    // nil turn). The settle's hard cap is what makes this not hang; the suite-level
    // `withTimeout(20)` makes a regression fail rather than wedge — so the bound is
    // load-bearing, not decorative.
    @Test func turnWithNoAssistantTextReturnsCleanly() async throws {
        try await withTimeout(20) {
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            // Minimal scripted agent: answers initialize / session/new, and ends
            // every prompt with end_turn and NO session/update at all.
            let driver = Task {
                for await line in agentSide.inboundLines() {
                    guard let msg = JSONValue.parse(line), let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    switch method {
                    case "initialize":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"},"agentCapabilities":{}}}"#
                        )
                    case "session/new":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"silent-1"}}"#)
                    case "session/prompt":
                        // No session/update emitted → no assistant text, no tool
                        // activity — just the terminal stop reason.
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                    default:
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                    }
                }
            }
            defer { driver.cancel() }

            let provider = ACPAgentProvider(transport: clientSide, turnTimeout: 8)

            // draftReply must return an EMPTY draft (no text on the wire), NOT hang.
            let draft = try await provider.draftReply(context: self.context("silence"))
            // threadTurn over the same silent turn yields nil (nothing to post),
            // cleanly.
            let turn = try await provider.threadTurn(context: self.context("again"))
            await provider.shutdown()

            #expect(draft.text.isEmpty)
            #expect(turn == nil)
        }
    }

    // (d) Phase D1: the injected event observer receives the node's plan as it
    // arrives. A write-file turn makes the agent emit a `plan` session/update; the
    // observer must see ≥1 `.plan` with the step marked completed by turn's end —
    // proving live events reach the runtime WHILE the turn folds text as before.
    @Test func eventObserverReceivesForwardedPlan() async throws {
        try await withTimeout(20) {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-acp-plan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let target = (dir as NSString).appendingPathComponent("out.txt")

            let llm = ScriptedLLM([
                LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(
                            id: "w1", name: "write_file",
                            arguments: "{\"path\":\"\(target)\",\"content\":\"hello\"}")
                    ]),
                LLMResponse(content: "Wrote it."),
            ])

            // Collect every forwarded plan snapshot in a Sendable box.
            let plans = PlanCollector()
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            let agentTask = Task {
                await runACPAgent(
                    transport: agentSide, llm: llm,
                    toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
                    config: .default, configDir: nil, streamingEnabled: false)
            }
            defer { agentTask.cancel() }
            let provider = ACPAgentProvider(
                transport: clientSide, cwd: dir, turnTimeout: 8,
                permissionHandler: { _, _ in true },
                eventObserver: { event in
                    if case .plan(let entries) = event { plans.append(entries) }
                })

            let turn = try await provider.threadTurn(context: self.context("write it"))
            await provider.shutdown()

            // The reply still folds the prose (unchanged behavior) …
            let combined = turn?.messages.map(\.text).joined(separator: "\n") ?? ""
            #expect(combined.contains("Wrote it."))
            // … AND the observer saw the plan, ending completed.
            let snapshots = plans.value
            #expect(!snapshots.isEmpty)
            let last = try #require(snapshots.last)
            #expect(last.contains { $0.content.contains("Write") })
            #expect(last.allSatisfy { $0.status == "completed" })
        }
    }

    // WS2 — the silent-bypass indicator: a node started with `allowUngatedTools` must
    // forward `.ungatedToolsAdvertised(true)` to the observer on the FIRST call (when
    // `ensureStarted` runs the ACP handshake), so the app can show its banner without
    // waiting on a turn to complete.
    @Test func eventObserverReceivesUngatedToolsAdvertisement() async throws {
        try await withTimeout(20) {
            let llm = ScriptedLLM([LLMResponse(content: "hi")])
            let seen = BoolBox()
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            let agentTask = Task {
                await runACPAgent(
                    transport: agentSide, llm: llm,
                    toolEnvironment: ToolEnvironment(
                        workdir: NSTemporaryDirectory(), baseEnvironment: [:]),
                    config: AgentConfig(allowUngatedTools: true), configDir: nil,
                    streamingEnabled: false)
            }
            defer { agentTask.cancel() }
            let provider = ACPAgentProvider(
                transport: clientSide, turnTimeout: 8, permissionHandler: { _, _ in true },
                eventObserver: { event in
                    if case .ungatedToolsAdvertised(let allowed) = event, allowed {
                        seen.set(true)
                    }
                })

            _ = try await provider.draftReply(context: self.context("hi"))
            await provider.shutdown()

            #expect(seen.value, "the observer must see the node's ungated-tools state")
        }
    }

    // (e) Default (no observer) ⇒ zero behavior change: a plain reply still returns,
    // and nothing about the existing path depends on the observer being set.
    @Test func defaultProviderHasNoObserverAndStillReplies() async throws {
        try await withTimeout(20) {
            let llm = ScriptedLLM([LLMResponse(content: "Hi.")])
            let (provider, agentTask) = self.makeProvider(
                llm: llm, workdir: NSTemporaryDirectory())
            defer { agentTask.cancel() }
            let draft = try await provider.draftReply(context: self.context("hello"))
            await provider.shutdown()
            #expect(draft.text.contains("Hi."))
        }
    }

    // The prompt rendering REUSES the shared transcript renderer + the context's
    // own system prompts — same context every other provider sends, one wire blob.
    @Test func composePromptReusesSharedRendererAndSystemPrompt() {
        // Give the context real instructions so the system prompt is non-empty:
        // EldrChat's conduit default (AC49) makes `draftSystemPrompt()` EMPTY when
        // there are no instructions, and `composePrompt` then sends transcript-only
        // (no "[System]" chaff). This test exercises the labeled-block path, so it
        // needs a non-empty system prompt to assert on.
        let ctx = AgentContext(
            myIdentityHex: "me", myDisplayName: "Alice",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "bob", senderDisplayName: "Bob",
                    participantType: .human, text: "ping"),
                TranscriptEntry(
                    senderIdentityHex: "bob", senderDisplayName: "Bob",
                    participantType: .agent, text: "auto-reply"),
            ],
            instructions: "Be concise.")
        let prompt = ACPAgentProvider.composePrompt(system: ctx.draftSystemPrompt(), context: ctx)
        // System guidance is present as a labeled block …
        #expect(!ctx.draftSystemPrompt().isEmpty)
        #expect(prompt.contains("[System]"))
        #expect(prompt.contains(ctx.draftSystemPrompt()))
        // … above the EXACT shared transcript render (so ACP sends identical
        // context to every other backend).
        #expect(prompt.contains(FoundationModelsAgentProvider.renderTranscript(ctx)))
        // The agent entry is labeled "Bob's AI" by the shared renderer.
        #expect(prompt.contains("Bob's AI: auto-reply"))
        #expect(prompt.contains("Bob: ping"))
    }
}

/// A lock-guarded, Sendable single-bool sink, same justification as `PlanCollector`.
private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ v: Bool) {
        lock.lock(); defer { lock.unlock() }
        flag = v
    }
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}

/// A lock-guarded, Sendable sink for plan snapshots the `@Sendable` event observer
/// pushes from the provider's consumer task. `@unchecked Sendable` is justified: all
/// access goes through `lock`, so there is no data race on `snapshots`.
private final class PlanCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[ACPPlanEntry]] = []
    func append(_ entries: [ACPPlanEntry]) {
        lock.lock(); defer { lock.unlock() }
        snapshots.append(entries)
    }
    var value: [[ACPPlanEntry]] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }
}
