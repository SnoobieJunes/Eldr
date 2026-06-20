import Crypto
import Foundation
import PQRCACP
import Testing

@testable import PQRCCore
@testable import PQRCNostr

// ACPRouterplan Phase 3 — the FULL relay-carried ACP path, end-to-end, headless.
//
// This is the integration proof the unit suites set up for: the phone (OWNER)
// drives the Mac node's ACP agent REMOTELY over the Nostr relay. Every ACP line
// rides the gift-wrapped + Double-Ratcheted message mesh (`PQRCMessenger`), so the
// relay only ever sees the SAME E2EE ciphertext a normal chat carries.
//
//   ACPClient (phone) ──prompt──▶ RelayACPTransport ──frame──▶ ownerMessenger.send
//        ▲                                                            │
//        │                                                       LocalRelaySimulator (ciphertext only)
//        │                                                            ▼
//   phoneTransport.deliverInbound ◀── owner inbound .message ◀── (gift-wrapped frames)
//
//   nodeMessenger.send ◀──frame── RelayACPTransport ◀──serve── runACPAgent (node)
//        │                              ▲
//        ▼                              │  (C-3 gate: only owner-signed frames in)
//   LocalRelaySimulator ──▶ node inbound .message ──▶ nodeTransport.deliverInbound
//
// Distinct from `RelayACPTransportTests` (which proves the framing in isolation,
// no messenger/relay): here the transports' `send`/`deliverInbound` seams are wired
// to two REAL messengers over one REAL `LocalRelaySimulator`, with a verified
// bidirectional session — the integration the unit transport was decoupled from.
//
// runACPAgent + ToolExecutor (file I/O) are `#if os(macOS)`, so the whole suite is
// macOS-only — the phone never hosts the agent.
#if os(macOS)
@Suite("Relay-carried ACP end-to-end (ACPRouterplan Phase 3)", .tags(.transport, .security))
struct RelayCarriedACPE2ETests {

    /// A scripted LLM: returns queued responses in order, then a terminal "done".
    /// `stream` uses the protocol default (one-shot `complete`), matching the
    /// agent's `streamingEnabled: false` path. Mirrors the PQRCACP harness.
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    /// Counts agent-side completions on the node, so the C-3 control can assert "a
    /// dropped frame produces NO turn" vs "an owner frame DOES".
    private actor TurnCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    /// A scripted LLM that records every completion on a `TurnCounter` — used by
    /// the C-3 test to prove a non-owner frame never reaches the agent's turn loop.
    private actor CountingLLM: LLMClient {
        private var queue: [LLMResponse]
        private let counter: TurnCounter
        init(_ responses: [LLMResponse], counter: TurnCounter) {
            self.queue = responses
            self.counter = counter
        }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            await counter.bump()
            return queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    /// Run `body`, but FAIL (throw `TimedOut`) instead of hanging forever if it
    /// doesn't finish within `seconds`. Every cross-relay await in this suite is
    /// wrapped so a wiring bug surfaces as a thrown error, not a wedged suite.
    struct TimedOut: Error { let what: String }
    @discardableResult
    private func withTimeout<T: Sendable>(
        _ seconds: Double, _ what: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut(what: what)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - One stream consumer per messenger (tap + ACP route)
    //
    // `PQRCMessenger.start()` returns ONE event stream with a single continuation;
    // a second `start()` would orphan the first. So each messenger gets exactly one
    // consumer — a `MessengerTap` — that does double duty: it records every received
    // `.message` (for handshake-completion waits), AND, once an ACP route is wired,
    // forwards each owner/peer-authorized ACP frame into the bound `RelayACPTransport`.
    // The owner-identity gate (C-3) lives here, on the NODE tap.

    /// Drains one messenger's `start()` stream. Records messages for assertions and
    /// — when `route` is set — forwards ACP frames whose sender passes `acceptFrom`.
    actor MessengerTap {
        private var messages: [ReceivedMessage] = []
        private var task: Task<Void, Never>?
        /// Where authorized ACP frames go (the bound transport's `deliverInbound`).
        private var route: (@Sendable (String) async -> Void)?
        /// Sender-identity-hex gate for ACP frames. Default: accept none until wired.
        private var acceptFrom: @Sendable (String) -> Bool = { _ in false }

        func attach(_ stream: AsyncStream<MessengerEvent>) {
            task = Task {
                for await event in stream {
                    guard case .message(let m) = event else { continue }
                    await self.handle(m)
                }
            }
        }

        /// Wire the ACP route + the sender gate. ACP frames from an accepted sender
        /// are forwarded to `route`; everything else stays plain chat (recorded only).
        func wireACPRoute(
            acceptFrom: @escaping @Sendable (String) -> Bool,
            route: @escaping @Sendable (String) async -> Void
        ) {
            self.acceptFrom = acceptFrom
            self.route = route
        }

        private func handle(_ m: ReceivedMessage) async {
            messages.append(m)
            guard RelayACPTransport.isACPFrame(m.body.text) else { return }
            // C-3 gate: only frames from an accepted sender drive the agent.
            guard acceptFrom(m.senderIdentityHex), let route else { return }
            await route(m.body.text)
        }

        func received() -> [ReceivedMessage] { messages }

        /// Poll until ≥`count` plain (non-ACP) messages with the given texts arrived.
        func waitForTexts(_ texts: Set<String>, timeoutMillis: Int = 10_000) async -> Bool {
            var waited = 0
            while waited < timeoutMillis {
                let seen = Set(messages.map(\.body.text))
                if texts.isSubset(of: seen) { return true }
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            return texts.isSubset(of: Set(messages.map(\.body.text)))
        }

        func stop() { task?.cancel() }
    }

    /// Bumps `sentAt` so each carried frame is a distinct message (the ratchet keys
    /// per message number; a monotonic counter keeps the trace legible).
    private actor Seq {
        private var n: Int64 = 100
        func next() -> Int64 { n += 1; return n }
    }

    /// Stands up OWNER + NODE messengers, verified BOTH WAYS over one
    /// `LocalRelaySimulator`, with one `MessengerTap` per side as the sole stream
    /// consumer. Mirrors the persistence suite's handshake:
    ///   1. both add each other as `VerifiedContact`s,
    ///   2. owner `establishSession` (PQXDH) → node builds the responder session,
    ///   3. node replies with `send` → owner builds its reverse session.
    /// After this, `owner.send(_, to: node)` AND `node.send(_, to: owner)` both work.
    private func establishVerifiedPair(seedBase: UInt64) async throws -> (
        owner: Persona, node: Persona, relay: LocalRelaySimulator,
        ownerTap: MessengerTap, nodeTap: MessengerTap
    ) {
        let relay = LocalRelaySimulator()
        let owner = try await Persona.make(
            name: "Owner", seedByte: "0a", seed: seedBase, transports: [await relay.connect()])
        let node = try await Persona.make(
            name: "Node", seedByte: "0b", seed: seedBase &+ 1, transports: [await relay.connect()])
        await owner.messenger.addContact(try node.asContact())
        await node.messenger.addContact(try owner.asContact())

        let ownerTap = MessengerTap()
        let nodeTap = MessengerTap()
        await ownerTap.attach(try await owner.messenger.start())
        await nodeTap.attach(try await node.messenger.start())

        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        #expect(
            await nodeTap.waitForTexts(["handshake"]),
            "node never received the establishing handshake")

        try await node.messenger.send(MessageBody(text: "ack", sentAt: 2), to: owner.identityHex)
        #expect(
            await ownerTap.waitForTexts(["ack"]),
            "owner never received the node's ack (reverse session not built)")

        return (owner, node, relay, ownerTap, nodeTap)
    }

    /// A node working directory (the C-2 jail root), canonicalized so the jail's
    /// `resolvingSymlinksInPath` root matches what tools resolve (macOS /var path).
    private func makeNodeCwd(_ tag: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-relay-acp-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).resolvingSymlinksInPath
    }

    /// Build the two relay-ACP transports for an established pair, with their `send`
    /// closures publishing through the messengers. Caller wires the taps' routes.
    private func makeTransports(
        owner: Persona, node: Persona, ownerHex: String, nodeHex: String, maxFrame: Int, seq: Seq
    ) -> (phone: RelayACPTransport, node: RelayACPTransport) {
        let phone = RelayACPTransport(maxFrameBytes: maxFrame) { framedBody in
            try? await owner.messenger.send(
                MessageBody(text: framedBody, sentAt: await seq.next()), to: nodeHex)
        }
        let nodeT = RelayACPTransport(maxFrameBytes: maxFrame) { framedBody in
            try? await node.messenger.send(
                MessageBody(text: framedBody, sentAt: await seq.next()), to: ownerHex)
        }
        return (phone, nodeT)
    }

    // MARK: - (a)+(b) prompt + a granted tool turn, all over the relay

    @Test func relayCarriedACP_endToEnd_promptAndToolTurn() async throws {
        let pair = try await establishVerifiedPair(seedBase: 5_100)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        let canonicalCwd = try makeNodeCwd("rt")
        defer { try? FileManager.default.removeItem(atPath: canonicalCwd) }
        let writeTarget = (canonicalCwd as NSString).appendingPathComponent("agent-wrote.txt")

        let maxFrame = 16 * 1024
        let seq = Seq()
        let (phoneTransport, nodeTransport) = makeTransports(
            owner: owner, node: node, ownerHex: ownerHex, nodeHex: nodeHex,
            maxFrame: maxFrame, seq: seq)

        // PHONE tap routes the NODE's ACP frames into the phone transport.
        await pair.ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })
        // NODE tap (C-3 gate): ONLY the configured OWNER's ACP frames reach the agent.
        await pair.nodeTap.wireACPRoute(
            acceptFrom: { $0 == ownerHex },
            route: { [nodeTransport] body in await nodeTransport.deliverInbound(body) })

        // Scripted node brain: turn 1 → text; turn 2 → write_file (granted) → close.
        let llm = ScriptedLLM([
            LLMResponse(content: "Hello from the node, over the relay."),
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "w1", name: "write_file",
                        arguments: "{\"path\":\"\(writeTarget)\",\"content\":\"relay-written\"}")
                ]),
            LLMResponse(content: "wrote it"),
        ])
        let agentTask = Task {
            await runACPAgent(
                transport: nodeTransport, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: canonicalCwd, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }
        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        let uiEvents = ACPUIEventCollector()
        await uiEvents.attach(client.events)

        defer {
            agentTask.cancel()
            Task { await pair.ownerTap.stop(); await pair.nodeTap.stop() }
        }

        // ── (a) initialize + session/new + a prompt come back THROUGH THE RELAY ──
        let info = try await withTimeout(30, "client.start") {
            try await client.start(cwd: canonicalCwd)
        }
        #expect(info.agentName == "eldr-acp", "the node's agent identified itself over the relay")

        let stop1 = try await withTimeout(30, "prompt #1") { try await client.prompt("say hello") }
        #expect(stop1 == "end_turn")
        let text = await uiEvents.assistantTextJoined(containing: "Hello from the node")
        #expect(
            text.contains("Hello from the node, over the relay."),
            "the agent's assistant text must arrive on the phone via the relay; got: \(text)")

        // ── (b) a granted write_file turn writes ON THE NODE under the C-2 jail and
        //        the tool-call activity returns to the phone ──
        let stop2 = try await withTimeout(30, "prompt #2 (tool turn)") {
            try await client.prompt("write the file")
        }
        #expect(stop2 == "end_turn")
        #expect(
            FileManager.default.fileExists(atPath: writeTarget),
            "the granted write_file must land on the node inside the cwd jail")
        #expect(
            (try? String(contentsOfFile: writeTarget, encoding: .utf8)) == "relay-written",
            "the file the node wrote must hold the agent's content")
        #expect(
            await uiEvents.sawToolCall(),
            "the phone must see the tool-call activity returned over the relay")
        #expect(
            await uiEvents.sawToolCallCompleted(),
            "the phone must see the tool-call complete over the relay")

        await client.shutdown()
    }

    // MARK: - (c) C-3: the node drops ACP frames from a non-owner identity

    @Test func relayCarriedACP_C3_nonOwnerFrameDropped_ownerStillWorks() async throws {
        let pair = try await establishVerifiedPair(seedBase: 5_200)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex
        let relay = pair.relay

        // A THIRD party (Mallory) with a verified session WITH THE NODE — so her
        // chat actually decrypts at the node. The C-3 gate must still refuse to let
        // her ACP frames drive the agent.
        let mallory = try await Persona.make(
            name: "Mallory", seedByte: "ee", seed: 5_299, transports: [await relay.connect()])
        await node.messenger.addContact(try mallory.asContact())
        await mallory.messenger.addContact(try node.asContact())
        let malloryTap = MessengerTap()
        await malloryTap.attach(try await mallory.messenger.start())
        try await mallory.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "mallory-handshake", sentAt: 1))
        #expect(
            await pair.nodeTap.waitForTexts(["mallory-handshake"]),
            "the node must decrypt Mallory's chat (so the only thing stopping her is C-3)")

        let canonicalCwd = try makeNodeCwd("c3")
        defer { try? FileManager.default.removeItem(atPath: canonicalCwd) }
        let malloryTarget = (canonicalCwd as NSString).appendingPathComponent("mallory-pwned.txt")

        let maxFrame = 16 * 1024
        let seq = Seq()
        let counter = TurnCounter()
        let (phoneTransport, nodeTransport) = makeTransports(
            owner: owner, node: node, ownerHex: ownerHex, nodeHex: nodeHex,
            maxFrame: maxFrame, seq: seq)

        await pair.ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })
        // C-3 gate: ONLY owner-signed ACP frames are admitted. Mallory's ACP frames
        // arrive at the node tap and are dropped (sender ≠ owner).
        await pair.nodeTap.wireACPRoute(
            acceptFrom: { $0 == ownerHex },
            route: { [nodeTransport] body in await nodeTransport.deliverInbound(body) })

        // If a Mallory frame ever reached the agent, her crafted prompt would drive
        // this LLM to write `mallory-pwned.txt` and bump the counter. Neither may
        // happen from her traffic. The single queued response is reserved for the
        // owner's control turn.
        let llm = CountingLLM([LLMResponse(content: "owner turn ok")], counter: counter)
        let agentTask = Task {
            await runACPAgent(
                transport: nodeTransport, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: canonicalCwd, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }

        defer {
            agentTask.cancel()
            Task { await pair.ownerTap.stop(); await pair.nodeTap.stop(); await malloryTap.stop() }
        }

        // ── Attack: Mallory frames a complete, well-formed ACP `session/prompt` line
        //    (byte-identical to what a genuine driver would emit) and publishes it to
        //    the node over the relay as ordinary chat. It IS a valid ACP frame and
        //    DOES decrypt at the node — only the C-3 owner check stops it. ──
        let malloryFramer = RelayACPTransport(maxFrameBytes: maxFrame, instanceSalt: "mal0ry") {
            framedBody in
            try? await mallory.messenger.send(
                MessageBody(text: framedBody, sentAt: 5_000), to: nodeHex)
        }
        let pwnPrompt =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/prompt\",\"params\":"
            + "{\"prompt\":[{\"type\":\"text\",\"text\":\"write mallory-pwned.txt\"}]}}"
        malloryFramer.send(pwnPrompt)

        // Let the relay deliver + the node pump (correctly) drop it.
        try? await Task.sleep(for: .milliseconds(400))

        let turnsAfterAttack = await counter.count
        #expect(
            turnsAfterAttack == 0,
            "C-3: a non-owner ACP frame must NOT drive the agent (turns ran: \(turnsAfterAttack))")
        #expect(
            !FileManager.default.fileExists(atPath: malloryTarget),
            "C-3: a non-owner frame must not cause any write on the node")

        // ── Control: the OWNER's prompt DOES drive the agent — so the gate filters by
        //    identity, not by refusing all traffic. ──
        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        defer { Task { await client.shutdown() } }
        let info = try await withTimeout(30, "owner client.start (control)") {
            try await client.start(cwd: canonicalCwd)
        }
        #expect(info.agentName == "eldr-acp")
        let stop = try await withTimeout(30, "owner prompt (control)") {
            try await client.prompt("hello from the real owner")
        }
        #expect(stop == "end_turn", "the owner's prompt must complete — the gate passes owner frames")
        let turnsAfterOwner = await counter.count
        #expect(
            turnsAfterOwner >= 1,
            "the agent ran for the OWNER (control), proving the gate filters by identity")
        #expect(
            !FileManager.default.fileExists(atPath: malloryTarget),
            "Mallory's frame still wrote nothing after a successful owner turn")
    }

    // MARK: - (d) CANARY (P-8 over the relay): plaintext never hits stored events

    @Test func relayCarriedACP_canary_plaintextNeverInStoredRelayEvents() async throws {
        let pair = try await establishVerifiedPair(seedBase: 5_300)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex
        let relay = pair.relay

        let canonicalCwd = try makeNodeCwd("canary")
        defer { try? FileManager.default.removeItem(atPath: canonicalCwd) }

        let maxFrame = 16 * 1024
        let seq = Seq()
        let (phoneTransport, nodeTransport) = makeTransports(
            owner: owner, node: node, ownerHex: ownerHex, nodeHex: nodeHex,
            maxFrame: maxFrame, seq: seq)
        await pair.ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })
        await pair.nodeTap.wireACPRoute(
            acceptFrom: { $0 == ownerHex },
            route: { [nodeTransport] body in await nodeTransport.deliverInbound(body) })

        // The planted secret travels INSIDE a prompt; the agent echoes it back, so
        // the secret rides the relay in BOTH directions (the canary is not vacuous).
        let canary = "sk-RELAYCANARY123"
        let llm = ScriptedLLM([LLMResponse(content: "the secret was \(canary), now forgotten")])
        let agentTask = Task {
            await runACPAgent(
                transport: nodeTransport, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: canonicalCwd, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }
        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        let uiEvents = ACPUIEventCollector()
        await uiEvents.attach(client.events)

        defer {
            agentTask.cancel()
            Task { await pair.ownerTap.stop(); await pair.nodeTap.stop() }
        }

        _ = try await withTimeout(30, "canary client.start") {
            try await client.start(cwd: canonicalCwd)
        }
        let stop = try await withTimeout(30, "canary prompt") {
            try await client.prompt("remember \(canary) and repeat it")
        }
        #expect(stop == "end_turn")
        let echoed = await uiEvents.assistantTextJoined(containing: canary)
        #expect(echoed.contains(canary), "the canary must have round-tripped through the agent")

        await client.shutdown()

        // ── P-8: inspect the relay's STORED events. Every relay-carried frame is
        //    gift-wrapped (kind-1059) ciphertext; none of the plaintext — not the
        //    secret, not the prompt text, not the ACP method name — may appear in
        //    ANY stored event's bytes. ──
        let stored = await relay.storedEvents()
        #expect(!stored.isEmpty, "the relay must have stored the gift-wrapped traffic")

        let needles = [
            canary,  // the planted secret
            "remember sk-RELAYCANARY123",  // the prompt's plaintext
            "the secret was sk-RELAYCANARY123",  // the assistant reply's plaintext
            "session/prompt",  // an ACP method name that rode the wire
            "session/update",  // another ACP method name
            "jsonrpc",  // the JSON-RPC envelope marker
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for event in stored {
            // Search the ENTIRE serialized event (content + tags + everything),
            // byte-exact, so nothing leaks through any field.
            let raw = (try? encoder.encode(event)) ?? Data(event.content.utf8)
            for needle in needles {
                let leakMessage: Comment = Comment(
                    rawValue: "P-8 LEAK: plaintext \(needle.prefix(12))… found in a stored relay event "
                        + "(kind \(event.kind)) — the relay must hold only ciphertext")
                #expect(!raw.contains(subsequence: Data(needle.utf8)), leakMessage)
            }
        }
        // At least one stored event is a gift wrap (kind-1059), confirming the
        // traffic went through the wrap path we asserted on.
        #expect(
            stored.contains { $0.kind == PQRCConstants.giftWrapEventKind },
            "expected gift-wrapped (kind-1059) envelopes among the stored events")
    }
}

// MARK: - UI-event collector (relay-carried ACP turn introspection)

/// Drains an `ACPClient.events` stream into an inspectable buffer, with helpers the
/// e2e asserts use (assistant text containing a marker, tool-call lifecycle seen).
/// Mirrors `EventCollector`/`ACPLineCollector` but for the typed `ACPUIEvent`s.
actor ACPUIEventCollector {
    private var events: [ACPUIEvent] = []
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncStream<ACPUIEvent>) {
        task = Task { for await event in stream { self.append(event) } }
    }
    private func append(_ event: ACPUIEvent) { events.append(event) }

    func all() -> [ACPUIEvent] { events }

    private func assistantText() -> String {
        events.compactMap {
            if case .assistantText(let t) = $0 { return t } else { return nil }
        }.joined()
    }

    /// Polls until the joined assistant text contains `marker`, then returns it.
    func assistantTextJoined(containing marker: String, timeoutMillis: Int = 5_000) async -> String {
        var waited = 0
        while !assistantText().contains(marker) && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return assistantText()
    }

    func sawToolCall(timeoutMillis: Int = 5_000) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if events.contains(where: { if case .toolCall = $0 { return true } else { return false } }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }

    func sawToolCallCompleted(timeoutMillis: Int = 5_000) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if events.contains(where: {
                if case .toolCallUpdate(_, "completed", _, _) = $0 { return true } else { return false }
            }) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }
}
#endif  // os(macOS)
