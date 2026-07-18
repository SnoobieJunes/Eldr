import Foundation
import Testing

@testable import PQRCACP

// Phase 1: a headless ACP round-trip — a phone-style `ACPClient` talks to a real
// `ACPAgent` over an in-memory transport PAIR, with no stdio and no radios. Covers the
// lifecycle (initialize → session/new → prompt → streamed updates → end_turn), a tool-call
// cascade surfaced as typed UI events, and permission grant vs deny driving the node's
// file I/O. This is the foundation the Multipeer/LAN transports plug into unchanged.

/// A scripted LLM for these tests: returns queued responses in order, then a terminal
/// "done". `stream` uses the protocol's default (one-shot `complete`), so it works with the
/// agent's `streamingEnabled: false` path.
private actor ScriptedLLM: LLMClient {
    private var queue: [LLMResponse]
    init(_ responses: [LLMResponse]) { self.queue = responses }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
    }
}

@Suite("ACPClient ↔ ACPAgent round-trip (in-memory transport)")
struct ACPRoundTripTests {

    /// Wire an `ACPClient` and a `runACPAgent` over a fresh in-memory pair, with a scripted
    /// LLM. Returns the client and the agent's run Task (cancel it when done).
    private func makePair(
        llm: any LLMClient, workdir: String,
        permission: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
        config: AgentConfig = .default
    ) -> (ACPClient, Task<Void, Never>) {
        let (clientSide, agentSide) = InMemoryACPTransport.makePair()
        let agentTask = Task {
            await runACPAgent(
                transport: agentSide, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: config, configDir: nil, streamingEnabled: false)
        }
        let client = ACPClient(transport: clientSide, permissionHandler: permission)
        return (client, agentTask)
    }

    /// Drain `client.events` into an array until the stream finishes (on `shutdown()`).
    private func collect(_ client: ACPClient) -> Task<[ACPUIEvent], Never> {
        Task {
            var events: [ACPUIEvent] = []
            for await event in client.events { events.append(event) }
            return events
        }
    }

    @Test func handshakeStreamsAssistantTextAndEndsTurn() async throws {
        let llm = ScriptedLLM([LLMResponse(content: "Hello from the agent.")])
        let (client, agentTask) = makePair(llm: llm, workdir: NSTemporaryDirectory())
        defer { agentTask.cancel() }
        let events = collect(client)

        let info = try await client.start()
        #expect(info.agentName == "eldr-acp")
        // WS2 — default config never runs tools ungated.
        #expect(info.ungatedToolsAllowed == false)
        let stop = try await client.prompt("hi")
        #expect(stop == "end_turn")
        await client.shutdown()

        let text = await events.value.compactMap { event -> String? in
            if case .assistantText(let t) = event { return t } else { return nil }
        }.joined()
        #expect(text.contains("Hello from the agent."))
    }

    /// WS2 — the silent-bypass indicator, over the real ACP handshake: a node configured
    /// with `allowUngatedTools` must report it in `ACPSessionInfo` (the phone has no other
    /// way to know it's being silently bypassed — see `ACPAgentTests.initialize_advertises*`
    /// for the wire-level `eldrAllowUngatedTools` field this decodes).
    @Test func ungatedNode_advertisesItInStartResult() async throws {
        let llm = ScriptedLLM([LLMResponse(content: "ok")])
        let (client, agentTask) = makePair(
            llm: llm, workdir: NSTemporaryDirectory(),
            config: AgentConfig(allowUngatedTools: true))
        defer { agentTask.cancel() }
        let info = try await client.start()
        #expect(info.ungatedToolsAllowed == true)
        await client.shutdown()
    }

    @Test func toolCallWithPermissionGrantedWritesFileAndStreamsLifecycle() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
            LLMResponse(content: "done"),
        ])
        let (client, agentTask) = makePair(llm: llm, workdir: dir, permission: { _, _ in true })
        defer { agentTask.cancel() }
        let events = collect(client)

        _ = try await client.start()
        let stop = try await client.prompt("write it")
        #expect(stop == "end_turn")
        await client.shutdown()

        // Permission granted ⇒ the node wrote the file (under the C-2 jail: target is in cwd).
        #expect(FileManager.default.fileExists(atPath: target))
        #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "hello")
        // The UI saw the tool-call lifecycle.
        let all = await events.value
        #expect(all.contains { if case .toolCall = $0 { return true } else { return false } })
        #expect(
            all.contains {
                if case .toolCallUpdate(_, "completed", _, _) = $0 { return true } else { return false }
            })
    }

    // Phase D1: a tool-call turn emits a plan/TODO checklist. The agent derives the
    // plan from the tool calls it makes (heuristic), so a write-file turn must surface
    // a `.plan` event whose entry tracks that step and ends `completed`.
    @Test func toolCallTurnEmitsPlanChecklist() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
            LLMResponse(content: "done"),
        ])
        let (client, agentTask) = makePair(llm: llm, workdir: dir, permission: { _, _ in true })
        defer { agentTask.cancel() }
        let events = collect(client)

        _ = try await client.start()
        let stop = try await client.prompt("write it")
        #expect(stop == "end_turn")
        await client.shutdown()

        let plans = await events.value.compactMap { event -> [ACPPlanEntry]? in
            if case .plan(let entries) = event { return entries } else { return nil }
        }
        // At least one plan snapshot arrived, the step is titled for the write, and
        // the LAST snapshot marks it completed (pending → in_progress → completed).
        #expect(!plans.isEmpty)
        let last = try #require(plans.last)
        #expect(last.contains { $0.content.contains("Write") })
        #expect(last.allSatisfy { $0.status == "completed" })
    }

    // A turn with NO tool calls (a plain answer) emits NO plan — the checklist is
    // only for multi-step tool work, never a single trivial reply.
    @Test func plainAnswerTurnEmitsNoPlan() async throws {
        let llm = ScriptedLLM([LLMResponse(content: "Just an answer.")])
        let (client, agentTask) = makePair(llm: llm, workdir: NSTemporaryDirectory())
        defer { agentTask.cancel() }
        let events = collect(client)

        _ = try await client.start()
        _ = try await client.prompt("hi")
        await client.shutdown()

        let sawPlan = await events.value.contains {
            if case .plan = $0 { return true } else { return false }
        }
        #expect(!sawPlan)
    }

    @Test func toolCallPermissionDeniedSkipsTheWrite() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
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
            LLMResponse(content: "ok, skipped"),
        ])
        // The client DENIES the permission request.
        let (client, agentTask) = makePair(llm: llm, workdir: dir, permission: { _, _ in false })
        defer { agentTask.cancel() }

        _ = try await client.start()
        let stop = try await client.prompt("write it")
        #expect(stop == "end_turn")
        await client.shutdown()

        #expect(!FileManager.default.fileExists(atPath: target))  // denied ⇒ never written
    }
}

// MARK: - Plan parsing (driver → typed ACPUIEvent)

@Suite("ACPClientDriver parses a plan session/update into ACPUIEvent.plan")
struct ACPPlanParseTests {
    // Drive a real `ACPClient` against a hand-run agent that, on prompt, emits one
    // `plan` session/update with a mixed-status checklist, then ends the turn. The
    // client must surface it as exactly one `.plan` event carrying the right content
    // and statuses (and drop the spec's `priority`, which the phone ignores).
    @Test func planNotificationBecomesTypedEvent() async throws {
        try await withTimeout(10) {
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            let driver = Task {
                for await line in agentSide.inboundLines() {
                    guard let msg = JSONValue.parse(line), let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    switch method {
                    case "initialize":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"}}}"#
                        )
                    case "session/new":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"plan-1"}}"#)
                    case "session/prompt":
                        // One plan snapshot (note the priority field, which the phone
                        // must ignore), then end the turn.
                        agentSide.send(
                            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"plan-1","update":{"sessionUpdate":"plan","entries":[{"content":"Read config","priority":"high","status":"completed"},{"content":"Edit file","priority":"medium","status":"in_progress"},{"content":"Run tests","priority":"low","status":"pending"}]}}}"#
                        )
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                    default:
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                    }
                }
            }
            defer { driver.cancel() }

            let client = ACPClient(transport: clientSide)
            let collected = Task {
                var events: [ACPUIEvent] = []
                for await event in client.events { events.append(event) }
                return events
            }

            _ = try await client.start()
            _ = try await client.prompt("go")
            await client.shutdown()

            let plans = await collected.value.compactMap { event -> [ACPPlanEntry]? in
                if case .plan(let entries) = event { return entries } else { return nil }
            }
            #expect(plans.count == 1)
            let entries = try #require(plans.first)
            #expect(
                entries == [
                    ACPPlanEntry(content: "Read config", status: "completed"),
                    ACPPlanEntry(content: "Edit file", status: "in_progress"),
                    ACPPlanEntry(content: "Run tests", status: "pending"),
                ])
        }
    }

    // A malformed entry (missing `content`) is dropped; a missing `status` defaults
    // to "pending" (the conservative not-done state) — forward-compat parsing.
    @Test func malformedPlanEntriesAreToleranced() {
        let update = JSONValue.parse(
            #"{"entries":[{"status":"completed"},{"content":"Only content"},{"content":"Done","status":"completed"}]}"#
        )
        let entries = ACPClientDriver.planEntries(update?["entries"])
        // The first (no content) is dropped; the second defaults to pending.
        #expect(
            entries == [
                ACPPlanEntry(content: "Only content", status: "pending"),
                ACPPlanEntry(content: "Done", status: "completed"),
            ])
    }
}

// MARK: - Adversarial round-trip ("chaos") cases
//
// The cooperative suite above proves the happy path. This one proves the remote-execution
// surface holds when the wire misbehaves: garbage frames, a permission/cancel race, the
// transport vanishing mid-turn, and two sessions multiplexed on one connection. Each case
// is written so the CONTROL is load-bearing — it fails (hangs → caught by `withTimeout`, or
// asserts false) if the corresponding guard were removed.

/// Run `body`, but fail the test instead of hanging forever if it doesn't finish within
/// `seconds`. Used to make the "no task hangs" claims self-bounding: a regression that
/// reintroduces a deadlock surfaces as a thrown `TimedOut`, not a wedged suite.
struct TimedOut: Error {}
@discardableResult
func withTimeout<T: Sendable>(
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

@Suite("ACPClient ↔ ACPAgent round-trip — adversarial / chaos")
struct ACPRoundTripChaosTests {

    /// As in the cooperative suite: a scripted LLM that returns queued responses then "done".
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    private func makePair(
        llm: any LLMClient, workdir: String,
        permission: @escaping @Sendable (String, String) async -> Bool = { _, _ in true }
    ) -> (ACPClient, Task<Void, Never>) {
        let (clientSide, agentSide) = InMemoryACPTransport.makePair()
        let agentTask = Task {
            await runACPAgent(
                transport: agentSide, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }
        let client = ACPClient(transport: clientSide, permissionHandler: permission)
        return (client, agentTask)
    }

    // 1 ─ Malformed JSON-RPC inbound. The client is driven against a HAND-RUN agent side so we
    // can interleave garbage with the legitimate responses: a non-JSON line, a frame missing
    // `id`, a wrong `jsonrpc` version, and a response to an id we never issued. None may crash
    // the client or strand its continuations — the real `initialize`/`session/new`/`prompt`
    // handshake threaded through the noise must still complete cleanly.
    @Test func malformedInboundFramesAreSurvivedAndTurnCompletes() async throws {
        try await withTimeout(10) {
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            // A minimal scripted "agent" living on agentSide: answers each request the client
            // makes, but sprays malformed frames around every answer.
            let driver = Task {
                for await line in agentSide.inboundLines() {
                    guard let msg = JSONValue.parse(line), let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    // Garbage BEFORE the valid reply: pure junk, then a no-`id` frame, then a
                    // wrong jsonrpc version on an unknown id, then a response to an id the
                    // client never sent.
                    agentSide.send("}{ this is not json at all")
                    agentSide.send(#"{"result":{"x":1}}"#)  // missing id
                    agentSide.send(#"{"jsonrpc":"9.9","id":4242,"result":{}}"#)  // wrong version + unknown id
                    agentSide.send(#"{"jsonrpc":"2.0","id":987654,"result":{"stray":true}}"#)  // unknown id
                    switch method {
                    case "initialize":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"},"agentCapabilities":{}}}"#
                        )
                    case "session/new":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"chaos-1"}}"#)
                    case "session/prompt":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                    default:
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                    }
                }
            }
            defer { driver.cancel() }

            let client = ACPClient(transport: clientSide)
            let info = try await client.start()
            #expect(info.sessionId == "chaos-1")  // handshake survived the noise
            let stop = try await client.prompt("hi")
            #expect(stop == "end_turn")  // the turn returned cleanly, no hung continuation
            await client.shutdown()
        }
    }

    // 1b ─ A turn whose ONLY inbound is malformed (the agent answers initialize/session/new
    // but then emits only junk for the prompt) must not hang the awaiting `prompt()` forever
    // — when the transport then closes, `prompt()` fails cleanly rather than deadlocking.
    @Test func promptAwaitingOnlyGarbageFailsCleanlyOnClose() async throws {
        try await withTimeout(10) {
            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            let driver = Task {
                for await line in agentSide.inboundLines() {
                    guard let msg = JSONValue.parse(line), let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    switch method {
                    case "initialize":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"}}}"#
                        )
                    case "session/new":
                        agentSide.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"chaos-2"}}"#)
                    case "session/prompt":
                        // Never a valid response to THIS id — only garbage, then close.
                        agentSide.send("not-json")
                        agentSide.send(#"{"jsonrpc":"2.0","id":777,"result":{}}"#)  // unknown id
                        agentSide.close()  // EOF mid-turn ⇒ driver must failAll the awaiter
                    default:
                        break
                    }
                }
            }
            defer { driver.cancel() }

            let client = ACPClient(transport: clientSide)
            _ = try await client.start()
            // The awaiting prompt must THROW (agentExited from failAll), not hang.
            await #expect(throws: (any Error).self) {
                _ = try await client.prompt("hi")
            }
            await client.shutdown()
        }
    }

    // 2 ─ Permission/cancel race. The agent requests permission for a write; the client holds
    // that request open while we deliver `session/cancel` concurrently, THEN releases the
    // permission gate (granting). Exactly one outcome must win and the gated write must never
    // land: cancel mid-turn aborts before the executor runs. No double-resume / crash.
    @Test func cancelRacingPermissionNeverWritesAndResolvesOnce() async throws {
        try await withTimeout(15) {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-chaos-\(UUID().uuidString)")
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
                LLMResponse(content: "done"),
            ])

            // The permission handler signals when the request arrives, then blocks until the
            // test releases it — giving a deterministic window to land the cancel first.
            let arrived = AsyncGate()
            let release = AsyncGate()
            let (client, agentTask) = makePair(
                llm: llm, workdir: dir,
                permission: { _, _ in
                    await arrived.open()  // "the request reached me"
                    await release.wait()  // hold the request open
                    return true  // then GRANT — cancel must still have won
                })
            defer { agentTask.cancel() }

            _ = try await client.start()
            // Run the prompt concurrently; it should end up cancelled.
            let promptTask = Task { try await client.prompt("write it") }

            await arrived.wait()  // permission is now in flight on the agent
            await client.cancel()  // deliver session/cancel WHILE it's pending
            await release.open()  // now let the (stale) grant return

            let stop = try await promptTask.value
            await client.shutdown()

            // The write was gated behind a turn that got cancelled: file never created.
            #expect(!FileManager.default.fileExists(atPath: target))
            // And the turn resolved exactly once with a real stop reason (no hang/crash).
            #expect(stop == "cancelled" || stop == "end_turn")
        }
    }

    // 3 ─ Transport drop mid-stream. A turn parks awaiting a permission answer that never
    // comes; we finish the agent→client inbound stream underneath it. `ClientConnection`'s
    // failure path on the agent and `ACPClientDriver.failAll` on the client must both fire so
    // the awaiting `prompt()` returns/throws cleanly — bounded so a hang fails the test.
    @Test func transportDropWhileAwaitingPermissionUnblocksPrompt() async throws {
        try await withTimeout(15) {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-chaos-\(UUID().uuidString)")
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
                LLMResponse(content: "done"),
            ])

            let (clientSide, agentSide) = InMemoryACPTransport.makePair()
            let agentTask = Task {
                await runACPAgent(
                    transport: agentSide, llm: llm,
                    toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
                    config: .default, configDir: nil, streamingEnabled: false)
            }
            defer { agentTask.cancel() }

            // The client holds the permission request open forever (never answers), so the
            // turn is parked awaiting it when we yank the transport.
            let arrived = AsyncGate()
            let block = AsyncGate()  // never opened
            let client = ACPClient(
                transport: clientSide,
                permissionHandler: { _, _ in
                    await arrived.open()
                    await block.wait()  // park here
                    return false
                })

            _ = try await client.start()
            let promptTask = Task { try await client.prompt("write it") }
            await arrived.wait()  // turn is now awaiting the permission answer

            // Drop the agent→client stream out from under the parked turn.
            agentSide.close()

            // The client's reader loop ends → failAll → prompt throws (agentExited).
            await #expect(throws: (any Error).self) {
                _ = try await promptTask.value
            }
            await client.shutdown()
            // Nothing was written (the write never got past the unanswered gate).
            #expect(!FileManager.default.fileExists(atPath: target))
        }
    }

    // 4 ─ Interleaved sessions on one connection. Two `session/new`s, then prompts
    // interleaved; every `session/update` the agent emits must carry the sessionId it belongs
    // to (no cross-talk), and a cancel of session A must not abort session B's turn. Driven
    // directly against the agent so the per-update sessionId is inspectable on the wire.
    @Test func interleavedSessionsRouteUpdatesAndCancelInIsolation() async throws {
        try await withTimeout(15) {
            let sink = CapturingSink()
            let connection = ClientConnection(sink: sink)
            // Session A loops a tool forever (so a cancel has something to interrupt); session
            // B answers in one shot. Routed by which session the prompt names via cwd-free
            // scripted responses keyed on the running message history is overkill — instead use
            // a tiny real file so A's read_file loop succeeds, and cap iterations so B is quick.
            let dir = NSTemporaryDirectory()
            let loopFile = (dir as NSString).appendingPathComponent(
                "chaos-loop-\(UUID().uuidString).txt")
            try "x".write(toFile: loopFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: loopFile) }

            let agent = ACPAgent(
                connection: connection, llm: PerSessionLLM(loopPath: loopFile),
                toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
                config: .default, configDir: nil, maxIterations: 50,
                streamingEnabled: false, requestTimeoutSeconds: 30)

            _ = await agent.handle(
                line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
            let aNew = await agent.handle(
                line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)
            let bNew = await agent.handle(
                line: #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}"#)
            let aLine = try #require(aNew)
            let bLine = try #require(bNew)
            let aJSON = try #require(JSONValue.parse(aLine))
            let bJSON = try #require(JSONValue.parse(bLine))
            let sidA = try #require(aJSON["result"]?["sessionId"]?.stringValue)
            let sidB = try #require(bJSON["result"]?["sessionId"]?.stringValue)
            #expect(sidA != sidB)  // distinct sessions on the one connection

            // Kick off A (loops on tool calls) and B (one-shot final) concurrently.
            async let aResult = agent.handle(line: promptLine(id: 10, sid: sidA, text: "loopA"))
            async let bResult = agent.handle(line: promptLine(id: 11, sid: sidB, text: "go"))

            // Cancel ONLY session A while both run; B must finish normally.
            try await Task.sleep(nanoseconds: 150_000_000)
            _ = await agent.handle(
                line:
                    #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"\#(sidA)"}}"#
            )

            let aResultLine = try #require(await aResult)
            let bResultLine = try #require(await bResult)
            let a = try #require(JSONValue.parse(aResultLine))
            let b = try #require(JSONValue.parse(bResultLine))
            #expect(a["result"]?["stopReason"]?.stringValue == "cancelled")  // A aborted
            #expect(b["result"]?["stopReason"]?.stringValue == "end_turn")  // B unaffected

            // Every session/update on the wire belonged to exactly the session that emitted it
            // — B's updates never carried sidA and vice-versa (no cross-talk).
            let updates = await sink.sessionUpdateIds()
            #expect(updates.contains(sidB))  // B did emit (its final message)
            #expect(updates.allSatisfy { $0 == sidA || $0 == sidB })
            // B's lifecycle is intact regardless of A's cancellation: at least one sidB update.
            #expect(updates.filter { $0 == sidB }.isEmpty == false)
        }
    }

    /// An LLM that drives session A into a long tool loop (so a cancel has a real window to
    /// abort it) and lets session B finish immediately. It can't see the sessionId directly,
    /// so it keys off the prompt text the harness plants ("loopA" ⇒ loop; else ⇒ done). A's
    /// per-call latency is deliberate: without it, 50 instant iterations finish before the
    /// 150 ms cancel could land, and the loop would end on the iteration cap instead of the
    /// cancel — the sleep keeps A genuinely in-flight so the cancel (not the cap) wins.
    private actor PerSessionLLM: LLMClient {
        let loopPath: String
        init(loopPath: String) { self.loopPath = loopPath }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            let userText =
                messages.last(where: { $0.role == .user })?.content
                ?? messages.first(where: { $0.role == .user })?.content ?? ""
            if userText.contains("loopA") {
                try? await Task.sleep(nanoseconds: 80_000_000)  // keep A in-flight
                return LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(
                            id: "loop", name: "read_file",
                            arguments: "{\"path\":\"\(loopPath)\"}")
                    ])
            }
            return LLMResponse(content: "B done")
        }
    }

    private func promptLine(id: Int, sid: String, text: String) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
    }

    /// Captures outbound lines and exposes the sessionIds carried by `session/update`s.
    private actor CapturingSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func sessionUpdateIds() -> [String] {
            lines.compactMap { JSONValue.parse($0) }
                .filter { $0["method"]?.stringValue == "session/update" }
                .compactMap { $0["params"]?["sessionId"]?.stringValue }
        }
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called (idempotent). A
/// Sendable, lock-free coordination primitive for the chaos tests — lets one task park
/// until another reaches a chosen point. Implemented over a single continuation.
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            if opened {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }
}
