// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCACP
import Testing

@testable import EldrNodeCore
@testable import PQRCCore
@testable import PQRCNostr

// ACPRouterplan Phase 4 — the STANDALONE HEADLESS node, end-to-end, headless.
//
// Drives `EldrNodeCore.serve` over a `LocalRelaySimulator` with a scripted OWNER
// messenger (mirrors `RelayCarriedACPE2ETests`). `serve` is the node's SOLE stream
// consumer (and where the C-3 gate runs), so the node needs NO separate tap — the owner
// establishes the session, the node's serve loop receives the handshake (and ignores it,
// because it is not an ACP frame), and the owner's `OwnerTap` routes the node's ACP reply
// frames back into the phone's `RelayACPTransport`.
//
// `runACPAgent` + ToolExecutor (file I/O) are `#if os(macOS)`, so the whole suite is
// macOS-only — the node hosts the agent only where `Foundation.Process` exists.
#if os(macOS)
@Suite("EldrNode standalone serve loop (ACPRouterplan Phase 4)", .tags(.transport, .security))
struct EldrNodeServeTests {

    /// The relay's per-message byte budget for framing ACP lines (matches the proven e2e
    /// + the Configurator's `relayACPMaxFrameBytes`).
    private let maxFrame = 16 * 1024

    /// Stand up OWNER + NODE messengers over one `LocalRelaySimulator`, with both added as
    /// each other's verified contacts. The NODE messenger is handed to `serve`; the OWNER
    /// messenger gets an `OwnerTap` (its single stream consumer) that routes the node's
    /// ACP reply frames into the phone transport. Returns the pieces the tests wire.
    private func makePair(seedBase: UInt64) async throws -> (
        owner: NodePersona, node: NodePersona, relay: LocalRelaySimulator
    ) {
        let relay = LocalRelaySimulator()
        let owner = try await NodePersona.make(
            name: "Owner", seedByte: "0a", seed: seedBase, transports: [await relay.connect()])
        let node = try await NodePersona.make(
            name: "Node", seedByte: "0b", seed: seedBase &+ 1, transports: [await relay.connect()])
        await owner.messenger.addContact(try node.asContact())
        await node.messenger.addContact(try owner.asContact())
        return (owner, node, relay)
    }

    // MARK: - (a) the owner's ACP prompt round-trips + a write_file stays in the C-2 jail

    @Test func serve_ownerPromptAndJailedWriteRoundTrip() async throws {
        let pair = try await makePair(seedBase: 7_100)
        let owner = pair.owner, node = pair.node
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        let workdir = try makeNodeWorkdir("a")
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let writeTarget = (workdir as NSString).appendingPathComponent("agent-wrote.txt")
        // An ABSOLUTE path OUTSIDE the jail the agent must NOT be able to escape to.
        let escapeTarget = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-node-escape-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(atPath: escapeTarget) }

        // Scripted node brain: turn 1 → text; turn 2 → write_file (granted) → close.
        let llm = ScriptedLLM([
            LLMResponse(content: "Hello from the standalone node, over the relay."),
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "w1", name: "write_file",
                        arguments: "{\"path\":\"\(writeTarget)\",\"content\":\"node-written\"}")
                ]),
            LLMResponse(content: "wrote it"),
        ])

        // The phone's end of the relay-ACP transport — its send publishes framed chunks to
        // the NODE over the relay; the OwnerTap routes the node's reply frames back in.
        let seq = NodeSeq()
        let phoneTransport = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        let ownerTap = OwnerTap()
        await ownerTap.attach(try await owner.messenger.start())
        await ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })

        // Launch the headless serve loop — the NODE's SOLE stream consumer (it calls
        // node.messenger.start()). The C-2 jail is `workdir`; config is `.default`
        // (allowUngatedTools stays false — fail-closed permission gate).
        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex,
                maxFrameBytes: maxFrame,
                llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false)
        }
        defer {
            serveTask.cancel()
            Task { await ownerTap.stop() }
        }

        // Establish the owner→node session (PQXDH handshake). The node's serve loop
        // receives it as a `.message` and (correctly) ignores it — it is not an ACP frame.
        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        // Give the relay a beat to deliver the handshake so the node builds its responder
        // session before the ACP client drives the first turn through it.
        #expect(
            await ownerTap.waitForHandshakeSettled(),
            "let the node build its responder session from the handshake")

        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        let uiEvents = NodeUIEventCollector()
        await uiEvents.attach(client.events)
        defer { Task { await uiEvents.stop() } }

        // ── (a) initialize + session/new + a prompt come back THROUGH THE RELAY ──
        let info = try await withNodeTimeout(30, "client.start") {
            try await client.start(cwd: workdir)
        }
        #expect(info.agentName == "eldr-acp", "the standalone node's agent identified itself over the relay")

        let stop1 = try await withNodeTimeout(30, "prompt #1") { try await client.prompt("say hello") }
        #expect(stop1 == "end_turn")
        let text = await uiEvents.assistantTextJoined(containing: "Hello from the standalone node")
        #expect(
            text.contains("Hello from the standalone node, over the relay."),
            "the agent's assistant text must arrive on the phone via the relay; got: \(text)")

        // ── (b) a granted write_file turn writes ON THE NODE under the C-2 jail ──
        let stop2 = try await withNodeTimeout(30, "prompt #2 (tool turn)") {
            try await client.prompt("write the file")
        }
        #expect(stop2 == "end_turn")
        #expect(
            FileManager.default.fileExists(atPath: writeTarget),
            "the granted write_file must land on the node INSIDE the cwd jail")
        #expect(
            (try? String(contentsOfFile: writeTarget, encoding: .utf8)) == "node-written",
            "the file the node wrote must hold the agent's content")
        #expect(
            !FileManager.default.fileExists(atPath: escapeTarget),
            "nothing should have been written outside the jail")
        #expect(
            await uiEvents.sawToolCall(),
            "the phone must see the tool-call activity returned over the relay")

        await client.shutdown()
    }

    // MARK: - (b) C-3: the node DROPS ACP frames from a non-owner (even a verified contact)

    @Test func serve_C3_nonOwnerFrameDropped_ownerStillWorks() async throws {
        let pair = try await makePair(seedBase: 7_200)
        let owner = pair.owner, node = pair.node
        let relay = pair.relay
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        // A THIRD party (Mallory) with a VERIFIED session WITH THE NODE — so her ACP frame
        // actually decrypts at the node. The C-3 gate must STILL refuse to let her drive
        // the agent: the only thing stopping her is the owner-identity check.
        let mallory = try await NodePersona.make(
            name: "Mallory", seedByte: "ee", seed: 7_299, transports: [await relay.connect()])
        await node.messenger.addContact(try mallory.asContact())
        await mallory.messenger.addContact(try node.asContact())

        let workdir = try makeNodeWorkdir("c3")
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let malloryTarget = (workdir as NSString).appendingPathComponent("mallory-pwned.txt")

        // The single queued response is reserved for the OWNER's control turn. If a Mallory
        // frame ever reached the agent, her crafted prompt would drive a write + bump the
        // counter — neither may happen from her traffic.
        let counter = TurnCounter()
        let llm = CountingLLM([LLMResponse(content: "owner turn ok")], counter: counter)

        let seq = NodeSeq()
        let phoneTransport = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        let ownerTap = OwnerTap()
        await ownerTap.attach(try await owner.messenger.start())
        await ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })

        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex,  // C-3 gate target: ONLY the owner
                maxFrameBytes: maxFrame,
                llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false)
        }
        defer {
            serveTask.cancel()
            Task { await ownerTap.stop() }
        }

        // Owner establishes first (the node's serve loop ignores the non-ACP handshake but
        // builds its responder session). Wait until the node has actually consumed the
        // owner's one-time prekey + built that session BEFORE Mallory fetches her own
        // bundle — otherwise both initiators could pick the SAME unused one-time prekey and
        // Mallory's handshake would fail to consume it at the node (a prekey race, not the
        // C-3 gate). This sequencing mirrors `RelayCarriedACPE2ETests`.
        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        var ownerSessionAtNode = false
        for _ in 0..<300 {  // up to ~3s
            if await node.messenger.hasSession(peerIdentityHex: ownerHex) {
                ownerSessionAtNode = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ownerSessionAtNode, "the node must build the owner's responder session first")

        // Now Mallory establishes with a FRESH bundle (the owner's OTP already consumed at
        // the node, so she picks a different one).
        try await mallory.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "mallory-handshake", sentAt: 1))
        // Prove the drop is NOT vacuous: poll until the node has actually built a responder
        // session for Mallory (it decrypted her handshake). Only then does her subsequent
        // ACP frame DECRYPT and reach serve's C-3 gate — so the only thing that stops it is
        // the owner check, not a silent delivery/decrypt failure.
        var malloryDecrypted = false
        for _ in 0..<300 {  // up to ~3s
            if await node.messenger.hasSession(peerIdentityHex: mallory.identityHex) {
                malloryDecrypted = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            malloryDecrypted,
            "the node must have decrypted Mallory's handshake (so only C-3 stops her ACP frame)")

        // ── Attack: Mallory frames a complete, well-formed ACP `session/prompt` line
        //    (byte-identical to what a genuine driver emits) and publishes it to the node
        //    over the relay as ordinary chat. It IS a valid ACP frame and DOES decrypt at
        //    the node — only the C-3 owner check stops it. ──
        let malloryFramer = RelayACPTransport(maxFrameBytes: maxFrame, instanceSalt: "mal0ry") { framed in
            try? await mallory.messenger.send(
                MessageBody(text: framed, sentAt: 5_000), to: nodeHex)
        }
        let pwnPrompt =
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/prompt\",\"params\":"
            + "{\"prompt\":[{\"type\":\"text\",\"text\":\"write mallory-pwned.txt\"}]}}"
        malloryFramer.send(pwnPrompt)

        // Let the relay deliver + the node's serve loop (correctly) DROP it.
        try? await Task.sleep(for: .milliseconds(500))

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
        let info = try await withNodeTimeout(30, "owner client.start (control)") {
            try await client.start(cwd: workdir)
        }
        #expect(info.agentName == "eldr-acp")
        let stop = try await withNodeTimeout(30, "owner prompt (control)") {
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

    // MARK: - (c2) the owner is bootstrapped from a message-request (no manual pairing)

    /// The AC35 follow-up: a freshly-started daemon has an EMPTY contact table, so the
    /// owner's opening handshake arrives as a `.messageRequest` — which the serve loop must
    /// bootstrap into a verified contact, or the node serves no one. Here the node does NOT
    /// pre-add the owner (unlike `makePair`); the owner only `announce`s its keys. Proves
    /// `serve` accepts the owner's request, builds the session, and the owner then drives a
    /// full ACP turn through it.
    @Test func serve_bootstrapsOwnerFromMessageRequest_thenOwnerDrivesAgent() async throws {
        let relay = LocalRelaySimulator()
        let owner = try await NodePersona.make(
            name: "Owner", seedByte: "0a", seed: 7_300, transports: [await relay.connect()])
        let node = try await NodePersona.make(
            name: "Node", seedByte: "0b", seed: 7_301, transports: [await relay.connect()])
        let ownerHex = owner.identityHex, nodeHex = node.identityHex

        // The owner publishes 10420/10421 so the node's accept can fetch + verify it.
        // CRUCIALLY: the node does NOT addContact(owner) — the daemon never does either.
        // The node IS added on the owner side so the node's reply frames decrypt there.
        try await owner.messenger.announce(relayURLs: ["local://relay"])
        await owner.messenger.addContact(try node.asContact())

        let workdir = try makeNodeWorkdir("bootstrap")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let llm = ScriptedLLM([
            LLMResponse(content: "Hello from a node the owner never manually paired.")
        ])

        let seq = NodeSeq()
        let phoneTransport = RelayACPTransport(maxFrameBytes: maxFrame) { framed in
            try? await owner.messenger.send(
                MessageBody(text: framed, sentAt: await seq.next()), to: nodeHex)
        }
        let ownerTap = OwnerTap()
        await ownerTap.attach(try await owner.messenger.start())
        await ownerTap.wireACPRoute(
            acceptFrom: { $0 == nodeHex },
            route: { [phoneTransport] body in await phoneTransport.deliverInbound(body) })

        let serveTask = Task {
            let core = EldrNodeCore()
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: ownerHex,
                maxFrameBytes: maxFrame,
                llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false)
        }
        defer {
            serveTask.cancel()
            Task { await ownerTap.stop() }
        }

        // The owner establishes — to the node this is an UNKNOWN sender, so the messenger
        // emits `.messageRequest`; `serve` bootstraps the owner contact + replays the held
        // handshake, building the responder session. Poll until that session exists.
        try await owner.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        var ownerBootstrapped = false
        for _ in 0..<500 {  // up to ~5s (accept does a relay fetch+verify)
            if await node.messenger.hasSession(peerIdentityHex: ownerHex) {
                ownerBootstrapped = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            ownerBootstrapped,
            "serve must bootstrap the owner from the message-request (no manual addContact)")

        // Now the owner can actually drive the agent over the freshly-bootstrapped session.
        let client = ACPClient(transport: phoneTransport, permissionHandler: { _, _ in true })
        defer { Task { await client.shutdown() } }
        let info = try await withNodeTimeout(30, "client.start (bootstrapped)") {
            try await client.start(cwd: workdir)
        }
        #expect(info.agentName == "eldr-acp", "the auto-bootstrapped node served the owner over the relay")
        let uiEvents = NodeUIEventCollector()
        await uiEvents.attach(client.events)
        defer { Task { await uiEvents.stop() } }
        let stop = try await withNodeTimeout(30, "owner prompt (bootstrapped)") {
            try await client.prompt("say hello")
        }
        #expect(stop == "end_turn")
        let text = await uiEvents.assistantTextJoined(containing: "never manually paired")
        #expect(
            text.contains("Hello from a node the owner never manually paired."),
            "the owner drives the agent through the auto-bootstrapped session; got: \(text)")
    }

    // MARK: - (c3) the owner-bootstrap policy in isolation (pure, scripted messenger)

    @Test func bootstrapOwnerFromRequest_keepsOwner_rejectsNonOwnerAndFailures() async throws {
        let ownerHex = String(repeating: "11", count: 32)
        let strangerHex = String(repeating: "22", count: 32)
        let ownerPub = "owner-nostr-pub"
        let strangerPub = "stranger-nostr-pub"
        let unverifiablePub = "ghost-nostr-pub"  // not in the accept map ⇒ accept throws

        let messenger = ScriptedNodeMessenger(acceptIdentityByPubkey: [
            ownerPub: ownerHex,
            strangerPub: strangerHex,
        ])

        // The pinned owner's request → bootstrapped (true).
        let ownerBootstrapped = await EldrNodeCore.bootstrapOwnerFromRequest(
            senderNostrPubkeyHex: ownerPub, ownerIdentityHex: ownerHex, messenger: messenger)
        #expect(ownerBootstrapped, "the pinned owner's request is bootstrapped into a contact")

        // A verified NON-owner's request → not reported paired (C-3 keeps them undrivable).
        let strangerBootstrapped = await EldrNodeCore.bootstrapOwnerFromRequest(
            senderNostrPubkeyHex: strangerPub, ownerIdentityHex: ownerHex, messenger: messenger)
        #expect(!strangerBootstrapped, "a non-owner request is not reported as the owner")

        // An unverifiable/unreachable sender → accept throws → declined, not paired.
        let ghostBootstrapped = await EldrNodeCore.bootstrapOwnerFromRequest(
            senderNostrPubkeyHex: unverifiablePub, ownerIdentityHex: ownerHex, messenger: messenger)
        #expect(!ghostBootstrapped, "an unverifiable sender is dropped (accept failed)")
        #expect(
            await messenger.declined == [unverifiablePub],
            "only the failed-accept sender is declined; verified ones are not re-declined")
    }

    // MARK: - (c) the C-3 gate predicate in isolation (pure, no relay)

    @Test func routeInbound_gate_dropsNonOwnerAndNonACP() async throws {
        let ownerHex = String(repeating: "11", count: 32)
        let strangerHex = String(repeating: "22", count: 32)
        // A well-formed ACP frame (the magic prefix is all `isACPFrame` checks).
        let acpFrame = "ACP1|abc-1|1|1|"

        // Owner-signed ACP frame → admitted (forwarded to the transport).
        let admitTransport = RelayACPTransport(maxFrameBytes: maxFrame) { _ in }
        let admitted = await EldrNodeCore.routeInbound(
            senderIdentityHex: ownerHex, body: acpFrame, ownerIdentityHex: ownerHex,
            transport: admitTransport)
        #expect(admitted, "an owner-signed ACP frame is admitted")
        admitTransport.close()

        // Non-owner ACP frame → DROPPED.
        let dropTransport = RelayACPTransport(maxFrameBytes: maxFrame) { _ in }
        let droppedNonOwner = await EldrNodeCore.routeInbound(
            senderIdentityHex: strangerHex, body: acpFrame, ownerIdentityHex: ownerHex,
            transport: dropTransport)
        #expect(!droppedNonOwner, "C-3: a non-owner ACP frame is dropped")

        // Owner, but NOT an ACP frame → dropped (the node has no chat surface).
        let droppedChat = await EldrNodeCore.routeInbound(
            senderIdentityHex: ownerHex, body: "{\"hello\":\"world\"}", ownerIdentityHex: ownerHex,
            transport: dropTransport)
        #expect(!droppedChat, "a non-ACP line from the owner is ignored")
        dropTransport.close()
    }
}
#endif  // os(macOS)
