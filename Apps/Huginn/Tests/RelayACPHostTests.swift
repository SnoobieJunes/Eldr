// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr
import Testing

@testable import Huginn

// Phase 3 LIVE node side, CONFIGURATOR proof: the Mac node serves the FULL ACP protocol
// to the OWNER's phone over the relay (so the phone drives the agent REMOTELY), and the
// C-3 gate drops everything that isn't an owner-signed ACP frame.
//
// This adapts `PQRCNostr/.../RelayCarriedACPE2ETests` into the Configurator target, with
// the node end being the SHIPPING `ACPRelayHost` (not an inline `runACPAgent` call). The
// owner↔node pair is wired over one real `LocalRelaySimulator`; every ACP line rides the
// gift-wrapped + Double-Ratcheted message mesh, so the relay only ever sees ciphertext.
//
//   ACPClient (owner) ─prompt→ RelayACPTransport ─frame→ owner.send ─┐
//        ▲                                                            │ LocalRelaySimulator
//        │  owner inbound .message → ownerTap → phoneTransport.deliverInbound
//        └──────────────────────────────────────────────────────────┘
//
//   node messenger.send(framed, to: owner) ◀── ACPRelayHost's RelayACPTransport.send
//        │                                          ▲
//        ▼ node inbound .message → nodeTap (C-3 gate) → host.routeInbound → deliverInbound
//   LocalRelaySimulator                                  serve: runACPAgent (on THIS Mac)
//
// runACPAgent + the agent's file tools are macOS-only; the Configurator is a macOS app,
// so this suite builds for the node. The phone never hosts the agent.
#if os(macOS)
@Suite("Relay-carried ACP host (Phase 3 LIVE node side)")
struct RelayACPHostTests {

    // MARK: - Doubles

    /// A scripted LLM: returns queued responses in order, then a terminal "done".
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    /// Counts agent completions so the C-3 control can assert a dropped frame produces
    /// NO turn vs an owner frame DOES.
    private actor TurnCounter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

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

    // MARK: - Timeout guard (a wiring bug surfaces as a thrown error, not a wedge)

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

    // MARK: - A local persona (public API only — the Configurator can't @testable the pkgs)

    /// Identity + nostr key + prekeys + messenger, built from PUBLIC PQRC API so it works
    /// from the Configurator test target (the package-internal `Persona` helper isn't
    /// reachable here).
    private struct RelayPersona {
        let identity: PQRCIdentity
        let nostrKeypair: NostrKeypair
        let prekeyManager: PrekeyManager
        let messenger: PQRCMessenger
        var identityHex: String { identity.publicKeyData.hexString }

        static func make(
            seedByte: UInt8, seed: UInt64, transports: [any RelayTransport],
            clock: FixedClock
        ) async throws -> RelayPersona {
            let identity = try PQRCIdentity(seed: Data(repeating: seedByte, count: 32))
            let random = SeededRandomSource(seed: seed)
            let nostrKeypair = try NostrKeypair(randomSource: random)
            let identityDH = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: random.bytes(32))
            let prekeyManager = try PrekeyManager(
                identity: identity, randomSource: random, oneTimeCount: 8)
            let messenger = try PQRCMessenger(
                identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
                identityDH: identityDH, transports: transports, clock: clock,
                randomSource: random, nonceSource: SeededRandomSource(seed: seed &+ 77),
                outboundRetryBaseMillis: 2)
            return RelayPersona(
                identity: identity, nostrKeypair: nostrKeypair,
                prekeyManager: prekeyManager, messenger: messenger)
        }

        /// Verified-contact view (as if fetched + binding-verified both ways).
        func asContact() throws -> VerifiedContact {
            let binding = try IdentityBinding.make(
                identity: identity, nostrPubkey: Data(hexString: nostrKeypair.publicKeyHex) ?? Data())
            return VerifiedContact(binding: try BindingVerifier.verify(binding, outerSignatureValid: true))
        }
    }

    /// Drains one messenger's event stream. Records messages (for handshake waits) and —
    /// when an ACP route is wired — forwards ACP frames whose sender passes `acceptFrom`.
    /// The C-3 gate lives on the NODE tap (`acceptFrom == ownerHex`).
    private actor MessengerTap {
        private var texts: [String] = []
        private var task: Task<Void, Never>?
        private var route: (@Sendable (String, String) async -> Void)?

        func attach(_ stream: AsyncStream<MessengerEvent>) {
            task = Task {
                for await event in stream {
                    guard case .message(let m) = event else { continue }
                    await self.handle(sender: m.senderIdentityHex, body: m.body.text)
                }
            }
        }

        /// Wire the route: every received `.message` is handed to `route(sender, body)`.
        /// The route itself applies the C-3 gate (it calls `host.routeInbound`, which
        /// drops non-owner frames), so the tap stays a dumb pump.
        func wireRoute(_ route: @escaping @Sendable (String, String) async -> Void) {
            self.route = route
        }

        private func handle(sender: String, body: String) async {
            texts.append(body)
            if let route { await route(sender, body) }
        }

        func waitForText(_ text: String, timeoutMillis: Int = 10_000) async -> Bool {
            var waited = 0
            while waited < timeoutMillis {
                if texts.contains(text) { return true }
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            return texts.contains(text)
        }

        func stop() { task?.cancel() }
    }

    /// Bumps `sentAt` so each carried frame is a distinct message number for the ratchet.
    private actor Seq {
        private var n: Int64 = 100
        func next() -> Int64 { n += 1; return n }
    }

    /// Drains an `ACPClient.events` stream into an inspectable buffer.
    private actor UIEvents {
        private var events: [ACPUIEvent] = []
        private var task: Task<Void, Never>?
        func attach(_ stream: AsyncStream<ACPUIEvent>) {
            task = Task { for await e in stream { self.append(e) } }
        }
        private func append(_ e: ACPUIEvent) { events.append(e) }
        private func assistantText() -> String {
            events.compactMap { if case .assistantText(let t) = $0 { return t } else { return nil } }
                .joined()
        }
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
    }

    // MARK: - Harness: an owner↔node verified pair over one relay

    /// Stands up OWNER + NODE messengers verified BOTH WAYS over one `LocalRelaySimulator`,
    /// each with one `MessengerTap`. Mirrors the proven e2e handshake.
    private func establishVerifiedPair(seedBase: UInt64) async throws -> (
        owner: RelayPersona, node: RelayPersona, relay: LocalRelaySimulator,
        ownerTap: MessengerTap, nodeTap: MessengerTap
    ) {
        let clock = FixedClock()
        let relay = LocalRelaySimulator()
        let owner = try await RelayPersona.make(
            seedByte: 0x0a, seed: seedBase, transports: [await relay.connect()], clock: clock)
        let node = try await RelayPersona.make(
            seedByte: 0x0b, seed: seedBase &+ 1, transports: [await relay.connect()], clock: clock)
        await owner.messenger.addContact(try node.asContact())
        await node.messenger.addContact(try owner.asContact())

        let ownerTap = MessengerTap()
        let nodeTap = MessengerTap()
        await ownerTap.attach(try await owner.messenger.start())
        await nodeTap.attach(try await node.messenger.start())

        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        #expect(await nodeTap.waitForText("handshake"), "node never received the handshake")

        try await node.messenger.send(MessageBody(text: "ack", sentAt: 2), to: owner.identityHex)
        #expect(await ownerTap.waitForText("ack"), "owner never received the node's ack")

        return (owner, node, relay, ownerTap, nodeTap)
    }

    /// A node working directory (the C-2 jail root), canonicalized so the jail root matches
    /// what the tools resolve (macOS /var path).
    private func makeNodeCwd(_ tag: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-relayhost-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).resolvingSymlinksInPath
    }

    /// The owner side's relay transport, publishing through the owner messenger.
    private func makeOwnerTransport(
        owner: RelayPersona, nodeHex: String, maxFrame: Int, seq: Seq
    ) -> RelayACPTransport {
        RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
    }

    // MARK: - (a)+(b) prompt + a granted jailed write, all over the relay

    @Test func relayACPHost_servesOwnerTurn_promptAndJailedWrite() async throws {
        let pair = try await establishVerifiedPair(seedBase: 6_100)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        let canonicalCwd = try makeNodeCwd("turn")
        defer { try? FileManager.default.removeItem(atPath: canonicalCwd) }
        let writeTarget = (canonicalCwd as NSString).appendingPathComponent("agent-wrote.txt")

        let maxFrame = ACPBridgeService.relayACPMaxFrameBytes
        let seq = Seq()
        let phoneTransport = makeOwnerTransport(
            owner: owner, nodeHex: nodeHex, maxFrame: maxFrame, seq: seq)

        // The SHIPPING node host. Its publish seam → node.messenger.send(framed, to: owner).
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
        let host = await ACPRelayHost(
            ownerIdentityHex: ownerHex, maxFrameBytes: maxFrame, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: canonicalCwd, baseEnvironment: [:]),
            config: .default, streamingEnabled: false,
            publish: { [nodeMessenger = node.messenger] framed in
                try? await nodeMessenger.send(
                    MessageBody(text: framed, sentAt: await seq.next()), to: ownerHex)
            })
        await host.start()
        #expect(await host.currentStatus() == .serving)

        // Owner tap routes the node's ACP frames back into the phone transport.
        await pair.ownerTap.wireRoute { [phoneTransport] sender, body in
            guard sender == nodeHex, RelayACPTransport.isACPFrame(body) else { return }
            await phoneTransport.deliverInbound(body)
        }
        // Node tap → host.routeInbound (the C-3 gate is INSIDE the host).
        await pair.nodeTap.wireRoute { [host] sender, body in
            await host.routeInbound(senderIdentityHex: sender, body: body)
        }

        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        let uiEvents = UIEvents()
        await uiEvents.attach(client.events)
        defer {
            Task { await host.stop(); await pair.ownerTap.stop(); await pair.nodeTap.stop() }
        }

        // ── (a) initialize + session/new + a prompt round-trip THROUGH THE RELAY ──
        let info = try await withTimeout(30, "client.start") { try await client.start(cwd: canonicalCwd) }
        #expect(info.agentName == "eldr-acp", "the node host identified itself over the relay")

        let stop1 = try await withTimeout(30, "prompt #1") { try await client.prompt("say hello") }
        #expect(stop1 == "end_turn")
        let text = await uiEvents.assistantTextJoined(containing: "Hello from the node")
        #expect(
            text.contains("Hello from the node, over the relay."),
            "the host's assistant text must reach the owner via the relay; got: \(text)")

        // ── (b) a granted write_file lands ON THE NODE inside the C-2 jail ──
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
        #expect(await uiEvents.sawToolCall(), "the owner must see the tool-call activity over the relay")

        await client.shutdown()
    }

    // MARK: - (c) C-3: the host drops ACP frames from a non-owner identity

    @Test func relayACPHost_C3_nonOwnerFrameDropped_ownerStillWorks() async throws {
        let pair = try await establishVerifiedPair(seedBase: 6_200)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex
        let relay = pair.relay

        // Mallory: a THIRD party with a verified session WITH THE NODE over the SAME relay —
        // so her chat actually DECRYPTS at the node. The C-3 gate must still refuse to let
        // her ACP frames drive the agent (the only thing stopping her is the sender check).
        let clock = FixedClock()
        let mallory = try await RelayPersona.make(
            seedByte: 0xee, seed: 6_299, transports: [await relay.connect()], clock: clock)
        await node.messenger.addContact(try mallory.asContact())
        await mallory.messenger.addContact(try node.asContact())
        let malloryTap = MessengerTap()
        await malloryTap.attach(try await mallory.messenger.start())
        try await mallory.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "mallory-handshake", sentAt: 1))
        #expect(
            await pair.nodeTap.waitForText("mallory-handshake"),
            "the node must decrypt Mallory's chat (so the only thing stopping her is C-3)")

        let canonicalCwd = try makeNodeCwd("c3")
        defer { try? FileManager.default.removeItem(atPath: canonicalCwd) }
        let malloryTarget = (canonicalCwd as NSString).appendingPathComponent("mallory-pwned.txt")

        let maxFrame = ACPBridgeService.relayACPMaxFrameBytes
        let seq = Seq()
        let counter = TurnCounter()
        // One queued response, reserved for the OWNER's control turn. If a Mallory frame
        // ever reached the agent, her crafted prompt would drive a write + bump the counter.
        let llm = CountingLLM([LLMResponse(content: "owner turn ok")], counter: counter)
        let host = await ACPRelayHost(
            ownerIdentityHex: ownerHex, maxFrameBytes: maxFrame, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: canonicalCwd, baseEnvironment: [:]),
            config: .default, streamingEnabled: false,
            publish: { [nodeMessenger = node.messenger] framed in
                try? await nodeMessenger.send(
                    MessageBody(text: framed, sentAt: await seq.next()), to: ownerHex)
            })
        await host.start()

        let phoneTransport = makeOwnerTransport(
            owner: owner, nodeHex: nodeHex, maxFrame: maxFrame, seq: seq)
        await pair.ownerTap.wireRoute { [phoneTransport] sender, body in
            guard sender == nodeHex, RelayACPTransport.isACPFrame(body) else { return }
            await phoneTransport.deliverInbound(body)
        }
        // The node tap feeds EVERY received frame to the host. The C-3 gate (inside
        // routeInbound) is what admits the owner's and drops Mallory's — exactly the
        // production wiring in `ACPBridgeService.handleMessengerEvent`.
        await pair.nodeTap.wireRoute { [host] sender, body in
            await host.routeInbound(senderIdentityHex: sender, body: body)
        }
        defer {
            Task {
                await host.stop(); await pair.ownerTap.stop()
                await pair.nodeTap.stop(); await malloryTap.stop()
            }
        }

        // ── Attack: Mallory frames a complete, well-formed ACP `session/prompt` line
        //    (byte-identical to what a genuine driver emits) and PUBLISHES it to the node
        //    over the relay as ordinary chat. It IS a valid ACP frame and DOES decrypt at
        //    the node — only the C-3 owner check stops it from reaching the agent. ──
        let pwnPrompt =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/prompt\",\"params\":"
            + "{\"prompt\":[{\"type\":\"text\",\"text\":\"write mallory-pwned.txt\"}]}}"
        let malloryFramer = RelayACPTransport(
            maxFrameBytes: maxFrame, instanceSalt: "mal0ry"
        ) { [malloryMessenger = mallory.messenger] framed in
            try? await malloryMessenger.send(
                MessageBody(text: framed, sentAt: 5_000), to: nodeHex)
        }
        malloryFramer.send(pwnPrompt)

        // Let the relay deliver Mallory's frame + the node tap (correctly) drop it.
        try? await Task.sleep(for: .milliseconds(500))

        let turnsAfterAttack = await counter.count
        #expect(
            turnsAfterAttack == 0,
            "C-3: a non-owner ACP frame must NOT drive the agent (turns ran: \(turnsAfterAttack))")
        #expect(
            !FileManager.default.fileExists(atPath: malloryTarget),
            "C-3: a non-owner frame must not cause any write on the node")

        // ── Control: the OWNER's prompt DOES drive the agent — the gate filters by
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
        #expect(stop == "end_turn", "the owner's prompt completes — the gate passes owner frames")
        #expect(await counter.count >= 1, "the agent ran for the OWNER (control)")
        #expect(
            !FileManager.default.fileExists(atPath: malloryTarget),
            "Mallory's frame still wrote nothing after a successful owner turn")
    }

    // MARK: - (d) Unit: the C-3 gate + ACP-frame discrimination in isolation

    @Test func routeInbound_gate_admitsOwnerACP_dropsEverythingElse() async throws {
        let ownerHex = String(repeating: "ab", count: 32)
        let strangerHex = String(repeating: "cd", count: 32)
        // A well-formed single-chunk frame: `ACP1|<id>|<seq>|<total>|<payloadB64Url>`,
        // payload = base64url("{}") = "e30". Hand-built (no internal encoder) so the unit
        // test exercises only the public discriminator + identity gate.
        let frame = "ACP1|deadbeef-0|1|1|e30"
        #expect(ACPRelayHost.wasACPFrame(frame))
        #expect(!ACPRelayHost.wasACPFrame("{\"jsonrpc\":\"2.0\"}"))  // chat/JSON-RPC ≠ frame
        #expect(!ACPRelayHost.wasACPFrame("just a chat message"))

        let host = await ACPRelayHost(
            ownerIdentityHex: ownerHex, maxFrameBytes: 4 * 1024,
            llm: ScriptedLLM([]), toolEnvironment: ToolEnvironment(workdir: nil, baseEnvironment: [:]),
            publish: { _ in })
        // Not started (no agent loop) — we only assert the gate's admit/drop verdict.
        #expect(
            await host.routeInbound(senderIdentityHex: ownerHex, body: frame),
            "owner-signed ACP frame is admitted")
        #expect(
            !(await host.routeInbound(senderIdentityHex: strangerHex, body: frame)),
            "a non-owner ACP frame is dropped (C-3)")
        #expect(
            !(await host.routeInbound(senderIdentityHex: ownerHex, body: "plain chat")),
            "a non-ACP body is never routed to the agent")
        await host.stop()
    }
}
#endif  // os(macOS)
