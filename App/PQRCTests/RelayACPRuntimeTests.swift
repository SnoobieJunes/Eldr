// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCMCP
import PQRCNostr
import Testing

@testable import EldrChat

/// Runtime-level proof of the LIVE relay-carried ACP path (ACPRouterplan Phase 3,
/// PHONE side). The unit/e2e layers proved `RelayACPTransport` + `ACPAgentProvider`
/// in isolation; here the OWNER is a real `PersonaRuntime` (the system under test)
/// and the only thing simulated is the Mac node — a second `PersonaRuntime` that,
/// reusing the SAME runtime code path, routes the owner's ACP frames to its own
/// `RelayACPTransport`, whose `inboundLines()` a HAND-RUN JSON-RPC agent answers.
///
/// Why a hand-run node agent (not `runACPAgent`): the app test target runs on the
/// iOS Simulator, and `runACPAgent` / the real `ACPAgent` are `#if os(macOS)`. The
/// phone never hosts the agent — it drives a remote one — so a scripted node
/// responder (exactly the `ACPAgentProviderTests` (c) shape) is the faithful stand-in.
///
/// The loopback is symmetric and reuses production code on BOTH sides:
///   owner.PersonaRuntime ──acp frame──▶ owner.RelayACPTransport.send
///        ▲                                      │ messenger.send(framed, to: node)
///        │ handleReceived routes acp frame      ▼
///   owner inbound .message ◀── relay ◀── node inbound .message
///        ▲                                      │ node.handleReceived routes (C-3) to
///        │ node.RelayACPTransport.send          ▼  node.RelayACPTransport.deliverInbound
///   scripted node agent ◀── inboundLines() ◀────┘
///
/// Both sides admit ACP frames ONLY from a CONSENTED `coding_agent` peer (C-3):
/// the owner tags+consents the node; the node tags+consents the owner (so the same
/// `handleReceived` routing fires for it). Nothing is wired until consent is on.
@Suite("Relay-carried ACP — runtime (Phase 3, phone side)", .serialized)
struct RelayACPRuntimeTests {

    // MARK: Harness

    private func makeRuntime(_ name: String, seed: UInt64, relay: LocalRelaySimulator, ais: [TetheredAI])
        async -> PersonaRuntime
    {
        await PersonaRuntime(
            displayName: name, transports: [relay.connect()],
            blobStore: LocalBlossomSimulator(), ais: ais,
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-relayacp-\(name)-\(UUID().uuidString)")
    }

    /// Poll until `condition` holds (or time out) — deterministic readiness instead
    /// of a fixed `sleep`, so the suite doesn't flake under load (e.g. when the
    /// FoundationModels-heavy suites run first and the relay/sim is contended).
    @discardableResult
    private func waitUntil(
        _ what: String, timeoutMillis: Int = 6_000,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return await condition()
    }

    /// True once `runtime` has stored a message with `text` in `conversationID`.
    private func received(
        _ text: String, in conversationID: String, on runtime: PersonaRuntime
    ) async -> Bool {
        await runtime.messages(conversationID: conversationID).contains { $0.text == text }
    }

    /// Run `body`, failing (instead of hanging) if it doesn't finish in time — a
    /// wiring regression surfaces as a thrown error, never a wedged suite.
    private struct TimedOut: Error { let what: String }
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

    /// A scripted ACP agent over the node's `RelayACPTransport.inboundLines()`. It
    /// answers `initialize` / `session/new`, and for each `session/prompt` emits ONE
    /// `agent_message_chunk` `session/update` (from a queued reply, FIFO) then a
    /// terminal `end_turn`. Drives ENTIRELY off the transport — no `runACPAgent`, so
    /// it runs on iOS. `replies` lets a turn echo a marker so the test can prove the
    /// answer round-tripped the relay (not a canned local string).
    private func scriptedNodeAgent(on transport: RelayACPTransport, replies: [String])
        -> (task: Task<Void, Never>, prompts: PromptLog)
    {
        let promptLog = PromptLog()
        let queued = ReplyQueue(replies)
        let task = Task {
            for await line in transport.inboundLines() {
                guard let msg = JSONValue.parse(line), let id = msg["id"]?.intValue,
                    let method = msg["method"]?.stringValue
                else { continue }
                switch method {
                case "initialize":
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"},"agentCapabilities":{}}}"#
                    )
                case "session/new":
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"node-sess-1"}}"#)
                case "session/prompt":
                    let promptText = Self.promptText(of: msg)
                    await promptLog.record(promptText)
                    let reply = await queued.next()
                    // session/update (notification, no id) carrying the assistant chunk.
                    transport.send(
                        JSONValue.object([
                            "jsonrpc": .string("2.0"),
                            "method": .string("session/update"),
                            "params": .object([
                                "sessionId": .string("node-sess-1"),
                                "update": .object([
                                    "sessionUpdate": .string("agent_message_chunk"),
                                    "content": .object([
                                        "type": .string("text"), "text": .string(reply),
                                    ]),
                                ]),
                            ]),
                        ]).serialized())
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                default:
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                }
            }
        }
        return (task, promptLog)
    }

    /// Pull the first prompt text block out of a `session/prompt` request.
    private static func promptText(of message: JSONValue) -> String {
        message["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    }

    /// Records the prompt text the node received, so a test can prove the OWNER's
    /// transcript actually reached the node over the relay.
    private actor PromptLog {
        private(set) var prompts: [String] = []
        func record(_ text: String) { prompts.append(text) }
        func joined() -> String { prompts.joined(separator: "\n") }
        func waitForNonEmpty(timeoutMillis: Int = 5_000) async -> Bool {
            var waited = 0
            while prompts.isEmpty && waited < timeoutMillis {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            return !prompts.isEmpty
        }
    }

    /// FIFO reply queue for the scripted agent; repeats the last reply if drained.
    private actor ReplyQueue {
        private var queue: [String]
        private let fallback: String
        init(_ replies: [String]) {
            self.queue = replies
            self.fallback = replies.last ?? "(no response)"
        }
        func next() -> String { queue.isEmpty ? fallback : queue.removeFirst() }
    }

    /// Stand up owner + node `PersonaRuntime`s over one relay, verify them both ways
    /// (`addVerifiedPeer` + `establishWith`), and mutually tag+consent so the SAME
    /// runtime ACP routing fires on each side. Returns the pair, their hexes, and the
    /// NODE's pre-created transport (with the scripted agent already serving it).
    private func establishConsentedPair(
        seedBase: UInt64, ownerAIs: [TetheredAI], nodeReplies: [String]
    ) async throws -> (
        owner: PersonaRuntime, node: PersonaRuntime, ownerHex: String, nodeHex: String,
        nodeAgent: Task<Void, Never>, nodePrompts: PromptLog
    ) {
        let relay = LocalRelaySimulator()
        let owner = await makeRuntime("Owner", seed: seedBase, relay: relay, ais: ownerAIs)
        // The node's OWN AIs are irrelevant — it never drafts; it hosts the scripted
        // agent. Give it a Demo so the runtime is well-formed.
        let node = await makeRuntime(
            "Node", seed: seedBase &+ 10, relay: relay,
            ais: [TetheredAI(id: "n", name: "node-ai", provider: DemoAgentProvider())])
        await owner.keychain.deleteAll()
        await node.keychain.deleteAll()
        _ = try await owner.bootstrap(inMemoryStore: true)
        _ = try await node.bootstrap(inMemoryStore: true)

        // Mutual verified pairing. Wait on DELIVERED state (not a fixed sleep) so the
        // forward AND reverse ratchet sessions are both up before we drive ACP — the
        // node→owner direction (the agent's replies) exists only after the node's ack
        // lands at the owner.
        let ownerHex = await owner.identityHex
        let nodeHex = await node.identityHex
        try await owner.addVerifiedPeer(node)
        try await node.addVerifiedPeer(owner)
        try await owner.establishWith(node, firstMessage: "pair")
        #expect(
            await waitUntil("node received pair") { await received("pair", in: ownerHex, on: node) },
            "node never received the establishing handshake")
        try await node.sendMessage("ack", conversationID: ownerHex)
        #expect(
            await waitUntil("owner received ack") { await received("ack", in: nodeHex, on: owner) },
            "owner never received the node's ack — the reverse session is not built")

        // C-3: each side treats the OTHER as a consented coding-agent node, so the
        // shared `handleReceived` routing admits its frames. (On a real device only
        // the phone tags the Mac; here the node must also route to drive its agent.)
        await owner.setContactType(nodeHex, type: "coding_agent")
        await node.setContactType(ownerHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        AppSession.setRemoteDevControlConsent(true, nodeID: ownerHex, siloID: "")

        // Pre-create the NODE's transport (so the scripted agent attaches before any
        // owner frame arrives) and serve it. On the node, the "node hex" for its
        // transport is the OWNER's identity (its ACP peer).
        let nodeTransport = await node.ensureRelayACPTransport(nodeHex: ownerHex)
        #expect(nodeTransport != nil, "node must bind a transport for its consented owner")
        let (agentTask, prompts) = scriptedNodeAgent(on: nodeTransport!, replies: nodeReplies)

        // The owner's "acp" provider must be (re)bound now that the node is consented.
        // setAIs re-runs the rebinding with the messenger + node identity available.
        await owner.setAIs(ownerAIs)

        return (owner, node, ownerHex, nodeHex, agentTask, prompts)
    }

    // MARK: - (1) ROUTING: an ACP frame from the node is routed, not stored as chat

    /// The key claim for part #1: when the consented `coding_agent` node sends an ACP
    /// frame, the owner's `handleReceived` routes it to the transport and RETURNS —
    /// it is NEVER persisted/rendered as a chat message. A NON-ACP message from the
    /// same node still renders normally (the gate is the frame magic, not the sender).
    @Test func acpFrameFromNode_isRoutedToTransport_notStoredAsChat() async throws {
        let relay = LocalRelaySimulator()
        let owner = await makeRuntime(
            "Owner", seed: 7_100, relay: relay,
            ais: [TetheredAI(id: "a", name: "ai", provider: DemoAgentProvider())])
        let node = await makeRuntime(
            "Node", seed: 7_110, relay: relay,
            ais: [TetheredAI(id: "n", name: "node-ai", provider: DemoAgentProvider())])
        await owner.keychain.deleteAll()
        await node.keychain.deleteAll()
        _ = try await owner.bootstrap(inMemoryStore: true)
        _ = try await node.bootstrap(inMemoryStore: true)
        try await owner.addVerifiedPeer(node)
        try await node.addVerifiedPeer(owner)
        try await owner.establishWith(node, firstMessage: "pair")
        try await Task.sleep(for: .milliseconds(300))
        try await node.sendMessage("ack", conversationID: await owner.identityHex)
        try await Task.sleep(for: .milliseconds(250))
        let ownerHex = await owner.identityHex
        let nodeHex = await node.identityHex

        // Owner consents to drive the node; node will frame an ACP line to the owner.
        await owner.setContactType(nodeHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        defer { AppSession.setRemoteDevControlConsent(false, nodeID: nodeHex, siloID: "") }

        // Baseline: a NON-ACP chat message from the node renders as chat.
        try await node.sendMessage("hello owner", conversationID: ownerHex)
        try await Task.sleep(for: .milliseconds(300))
        let beforeFrame = await owner.messages(conversationID: nodeHex)
        #expect(
            beforeFrame.contains { $0.text == "hello owner" },
            "a normal (non-ACP) message from the node renders as chat")
        let chatCountBefore = beforeFrame.count

        // The node frames a well-formed ACP line (via the SAME production framing) and
        // publishes each chunk to the owner as an ordinary message through the node's
        // own messenger. The owner must ROUTE the framed body, not store it.
        let acpLine =
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#
        let framer = RelayACPTransport(maxFrameBytes: 16 * 1024) { framed in
            // Deliver the framed chunk to the owner as a normal agent-typed message.
            try? await node.sendMessage(framed, conversationID: ownerHex, participantType: .agent)
        }
        framer.send(acpLine)
        try await Task.sleep(for: .milliseconds(500))

        let afterFrame = await owner.messages(conversationID: nodeHex)
        #expect(
            afterFrame.count == chatCountBefore,
            "the ACP frame must NOT add a chat message — it is routed, not stored (added: \(afterFrame.count - chatCountBefore))")
        #expect(
            !afterFrame.contains { RelayACPTransport.isACPFrame($0.text) },
            "no stored message may be a raw ACP frame")

        await owner.shutdown()
        await node.shutdown()
    }

    // MARK: - (2) LIVE PROVIDER: an enabled+consented `acp` AI drives the node

    /// The enabled+consented "acp" backend drives the node's real ACP agent over the
    /// relay loopback: the owner's `draftReply` (primary AI = acp) ships the transcript
    /// to the node as a `session/prompt`, and the node's scripted assistant text comes
    /// BACK to the owner as the draft. Proves the runtime substituted a relay-backed
    /// `ACPAgentProvider` for the Demo stub the static factory hands out.
    @Test func consentedACPProvider_drivesNodeOverRelay_andReturnsItsAnswer() async throws {
        let marker = "NODE-OVER-RELAY-\(UUID().uuidString.prefix(6))"
        let acpAI = TetheredAI(
            id: "acp", name: "mac-harness", provider: DemoAgentProvider(),
            kind: "acp", isRemote: true, appliesEgressFirewall: true)
        let pair = try await establishConsentedPair(
            seedBase: 7_200, ownerAIs: [acpAI], nodeReplies: ["Hello from the node: \(marker)"])
        defer {
            pair.nodeAgent.cancel()
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.nodeHex, siloID: "")
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.ownerHex, siloID: "")
        }

        // Draft against the acp primary → the owner drives the node over the relay.
        let draft = try await withTimeout(30, "owner draftReply over relay-acp") {
            try await pair.owner.draftReply(conversationID: pair.nodeHex)
        }
        #expect(
            draft.text.contains(marker),
            "the draft must carry the NODE's scripted answer, proving the acp provider drove the node over the relay; got: \(draft.text)")

        // The node actually received a prompt (the transcript reached it over the relay).
        #expect(
            await pair.nodePrompts.waitForNonEmpty(),
            "the node's ACP agent must have received a session/prompt from the owner")

        await pair.owner.shutdown()
        await pair.node.shutdown()
    }

    /// Without consent the "acp" backend stays INERT: the static factory's Demo stub
    /// is NOT replaced, so a draft returns the Demo provider's canned reply (never the
    /// node's). The relay-ACP path must not engage until the owner opts in (privacy #1).
    @Test func unconsentedACP_staysInert_demoStubNotReplaced() async throws {
        let relay = LocalRelaySimulator()
        // Mirror the static factory: an enabled "acp" config yields a Demo stub.
        let acpAI = TetheredAI(
            id: "acp", name: "mac-harness", provider: DemoAgentProvider(),
            kind: "acp", isRemote: true, appliesEgressFirewall: true)
        let owner = await makeRuntime("Owner", seed: 7_300, relay: relay, ais: [acpAI])
        let node = await makeRuntime(
            "Node", seed: 7_310, relay: relay,
            ais: [TetheredAI(id: "n", name: "node-ai", provider: DemoAgentProvider())])
        await owner.keychain.deleteAll()
        await node.keychain.deleteAll()
        _ = try await owner.bootstrap(inMemoryStore: true)
        _ = try await node.bootstrap(inMemoryStore: true)
        try await owner.addVerifiedPeer(node)
        try await node.addVerifiedPeer(owner)
        try await owner.establishWith(node, firstMessage: "pair")
        try await Task.sleep(for: .milliseconds(250))
        let nodeHex = await node.identityHex

        // Tag as coding_agent but DO NOT consent — the path must stay inert.
        await owner.setContactType(nodeHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(false, nodeID: nodeHex, siloID: "")
        await owner.setAIs([acpAI])  // re-run rebinding; must NOT bind a live provider

        // No node transport should exist (nothing to drive); the draft uses the Demo
        // stub and returns promptly with Demo's canned text, not a node answer.
        let draft = try await withTimeout(20, "unconsented draft (Demo stub)") {
            try await owner.draftReply(conversationID: nodeHex)
        }
        #expect(
            !draft.text.isEmpty,
            "the Demo stub still answers so the backend stays visibly responsive while inert")
        // The node never got a prompt: there is no live ACP session at all.
        #expect(
            await node.messages(conversationID: await owner.identityHex)
                .allSatisfy { !RelayACPTransport.isACPFrame($0.text) },
            "no ACP frame may reach the node while consent is off")

        await owner.shutdown()
        await node.shutdown()
    }
}

// MARK: - Phase D3: phone-side MCP serving gates (the consent + C-3 enforcement)

/// The PHONE-side proof for MCP passthrough over the relay (Phase D3). The system
/// under test is the OWNER's real `PersonaRuntime` acting as the MCP SERVER: a node
/// asks for chat tools, and the phone must service them ONLY when (a) the node is the
/// owner's paired `coding_agent` with remote-dev-control AND (b) the per-node "share
/// chat context" consent is on AND (c) a redacting bridge is injected. Any miss ⇒ no
/// host (`ensureRelayMCPHost` returns nil), so the node's `MCP1|` frame is dropped and
/// the phone serves nothing.
///
/// This is the phone-side complement to EldrNode's end-to-end matrix (which models the
/// phone); here the REAL runtime gate (`isMCPSharingNode` → `ensureRelayMCPHost`) is
/// exercised, including that redaction is delegated to the injected bridge and never
/// bypassed.
@Suite("Relay-carried MCP — phone-side gates (Phase D3)", .serialized)
struct RelayMCPRuntimeTests {

    /// A trivial redacting bridge (codename-only, window-gated) — the stand-in for
    /// `RuntimeSecureChatBridge`. Records whether it was ever asked, so a test can
    /// prove a non-consented node never reaches it.
    final class RecordingBridge: SecureChatBridge, @unchecked Sendable {
        // @unchecked Sendable: `asked` is only mutated from the actor-serialized host
        // pump in these single-threaded tests; the box keeps the conformance simple.
        final class Box: @unchecked Sendable { var asked = false }
        let box = Box()
        func conversations() async -> [MCPConversation] { box.asked = true; return [] }
        func messages(conversationID: String, limit: Int) async -> [MCPMessage] {
            box.asked = true
            return [MCPMessage(conversationID: conversationID, sender: "a contact", role: "human", text: "hi", sentAt: 1)]
        }
        func search(query: String, limit: Int) async -> [MCPMessage] { box.asked = true; return [] }
        func contextPreview(conversationID: String) async -> [MCPMessage] { box.asked = true; return [] }
        func draftReply(conversationID: String, text: String) async -> MCPWriteResult {
            box.asked = true; return .ok(detail: "drafted")
        }
        func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async -> MCPWriteResult {
            box.asked = true; return .ok(detail: "marked")
        }
        func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult {
            box.asked = true; return .failedClosed(reason: "no window")
        }
    }

    private func makeRuntime(_ name: String, seed: UInt64) async -> PersonaRuntime {
        let runtime = await PersonaRuntime(
            displayName: name, transports: [LocalRelaySimulator().connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: "a", name: "ai", provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-relaymcp-\(name)-\(UUID().uuidString)")
        await runtime.keychain.deleteAll()
        _ = try? await runtime.bootstrap(inMemoryStore: true)
        return runtime
    }

    /// Make an owner + a REAL verified node contact, returning (owner, node hex). A
    /// `ContactRecord` requires a real identity binding, so `setContactType` only sticks
    /// for a contact that ACTUALLY EXISTS — these gate tests must pair a real node
    /// (mirrors the ACP suite), not invent a hex. The node runtime is torn down right
    /// after pairing; its binding now lives in the owner's contactRecords.
    private func makePairedNode(_ ownerName: String, seed: UInt64) async throws
        -> (owner: PersonaRuntime, nodeHex: String)
    {
        let owner = await makeRuntime(ownerName, seed: seed)
        let node = await makeRuntime("\(ownerName)Node", seed: seed &+ 500)
        try await owner.addVerifiedPeer(node)
        let nodeHex = await node.identityHex
        await node.shutdown()
        return (owner, nodeHex)
    }

    private func reset(_ nodeHex: String) {
        AppSession.setRemoteDevControlConsent(false, nodeID: nodeHex, siloID: "")
        AppSession.setShareChatContextConsent(false, nodeID: nodeHex, siloID: "")
    }

    // MARK: (1) consent OFF ⇒ no host

    @Test func noHost_whenShareChatContextOff() async throws {
        let (owner, nodeHex) = try await makePairedNode("Owner1", seed: 8_100)
        reset(nodeHex)
        await owner.setSecureChatBridge(RecordingBridge())
        // Coding agent + dev-control ON, but share-chat-context OFF.
        await owner.setContactType(nodeHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        let host = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host == nil, "share-chat-context OFF ⇒ the phone serves NO MCP host for the node")
        reset(nodeHex)
        await owner.shutdown()
    }

    // MARK: (2) not a coding agent ⇒ no host (even with the chat-context flag set)

    @Test func noHost_whenNotACodingAgent() async throws {
        let (owner, nodeHex) = try await makePairedNode("Owner2", seed: 8_200)
        reset(nodeHex)
        await owner.setSecureChatBridge(RecordingBridge())
        // Both consents flipped on, but the contact is NOT a coding_agent node.
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        AppSession.setShareChatContextConsent(true, nodeID: nodeHex, siloID: "")
        let host = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host == nil, "a non-coding-agent contact never gets chat tools served (C-3)")
        reset(nodeHex)
        await owner.shutdown()
    }

    // MARK: (3) no redacting bridge injected ⇒ no host (fail-closed)

    @Test func noHost_whenNoBridgeInjected() async throws {
        let (owner, nodeHex) = try await makePairedNode("Owner3", seed: 8_300)
        reset(nodeHex)
        // Fully consented, but NO bridge injected → no redacting source → no host.
        await owner.setContactType(nodeHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        AppSession.setShareChatContextConsent(true, nodeID: nodeHex, siloID: "")
        let host = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host == nil, "no redacting bridge ⇒ fail closed (never serve raw chat)")
        reset(nodeHex)
        await owner.shutdown()
    }

    // MARK: (4) fully consented ⇒ a host IS created (and is the serving point)

    @Test func host_createdAndReused_whenFullyConsented() async throws {
        let (owner, nodeHex) = try await makePairedNode("Owner4", seed: 8_400)
        reset(nodeHex)
        await owner.setSecureChatBridge(RecordingBridge())
        await owner.setContactType(nodeHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        AppSession.setShareChatContextConsent(true, nodeID: nodeHex, siloID: "")
        let host1 = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host1 != nil, "fully consented ⇒ the phone serves an MCP host for the node")
        // Idempotent — the same host is reused (reassembly/session coherence).
        let host2 = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host2 === host1, "the host is reused across frames, not rebuilt")
        // Revoking share-chat-context tears it down; a later ensure refuses (nil).
        AppSession.setShareChatContextConsent(false, nodeID: nodeHex, siloID: "")
        await owner.teardownRelayMCPHost(nodeHex: nodeHex)
        let host3 = await owner.ensureRelayMCPHost(nodeHex: nodeHex)
        #expect(host3 == nil, "after revoke, the phone refuses to serve the node again")
        reset(nodeHex)
        await owner.shutdown()
    }
}
