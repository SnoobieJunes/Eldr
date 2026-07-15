import CryptoKit
import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrChat

/// Phase D4 / feature 9 — the PHONE-SIDE gate for the interactive PTY terminal, the
/// project's highest-risk surface (a persistent interactive shell on the user's Mac,
/// driven from the phone). Decision D6 added an ALLOW-ONCE path: standing
/// `autonomousChangesConsent` still skips the prompt, but without it the human is asked
/// (Allow once / Always / Deny) like any mutating tool — and FAILS CLOSED when there is
/// no UI to ask (headless / locked). "Allow once" opens the one shell without flipping
/// the standing consent.
///
/// Two layers: (1) the pure decision logic (fast, exact), and (2) an end-to-end proof
/// over the real relay-ACP path — a scripted node issues an interactive-terminal
/// `session/request_permission` and the owner's `PersonaRuntime` must deny it without
/// consent and allow it with consent. Plus the fail-closed teardown (tearing the
/// transport down — which on a real device terminates the node's PTY).
@Suite("Phase D4 — interactive terminal gate (phone side)", .serialized)
struct ACPInteractiveTerminalGateTests {

    // MARK: - End-to-end over the real relay-ACP path

    private func makeRuntime(_ name: String, seed: UInt64, relay: LocalRelaySimulator, ais: [TetheredAI])
        async -> PersonaRuntime
    {
        await PersonaRuntime(
            displayName: name, transports: [relay.connect()],
            blobStore: LocalBlossomSimulator(), ais: ais,
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-ptygate-\(name)-\(UUID().uuidString)")
    }

    @discardableResult
    private func waitUntil(
        _ what: String, timeoutMillis: Int = 6_000, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return await condition()
    }

    private func received(
        _ text: String, in conversationID: String, on runtime: PersonaRuntime
    ) async -> Bool {
        await runtime.messages(conversationID: conversationID).contains { $0.text == text }
    }

    /// Records the permission OUTCOMES the owner sent back, so a test can prove the gate's
    /// decision without depending on a turn completing.
    private actor PermissionOutcomes {
        private(set) var granted: [Bool] = []
        func record(_ ok: Bool) { granted.append(ok) }
        func waitForOne(timeoutMillis: Int = 5_000) async -> Bool {
            var waited = 0
            while granted.isEmpty && waited < timeoutMillis {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            return !granted.isEmpty
        }
    }

    /// A scripted node that, on each `session/prompt`, issues ONE
    /// `session/request_permission` carrying the INTERACTIVE-TERMINAL title (as the real
    /// node does for `open_terminal`), records the owner's outcome, then ends the turn.
    /// Drives entirely off the node's `RelayACPTransport` (no `runACPAgent`, so it runs on
    /// iOS — the same stand-in `RelayACPRuntimeTests` uses).
    private func scriptedTerminalRequestingNode(
        on transport: RelayACPTransport, outcomes: PermissionOutcomes
    ) -> Task<Void, Never> {
        Task {
            for await line in transport.inboundLines() {
                guard let msg = JSONValue.parse(line) else { continue }
                let method = msg["method"]?.stringValue
                // A RESPONSE to our outbound request (the owner's permission answer).
                if method == nil, msg["id"] != nil {
                    let granted = ACPWirePermissionGranted(msg["result"])
                    await outcomes.record(granted)
                    continue
                }
                guard let id = msg["id"]?.intValue, let method else { continue }
                switch method {
                case "initialize":
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"eldr-acp","version":"0.1.0"},"agentCapabilities":{}}}"#
                    )
                case "session/new":
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"node-sess-1"}}"#)
                case "session/prompt":
                    // Issue an OUTBOUND interactive-terminal permission request (the node's
                    // outbound ids are negative, so they never collide with the owner's).
                    let title = ACPTerminal.interactiveTerminalTitlePrefix
                    transport.send(
                        JSONValue.object([
                            "jsonrpc": .string("2.0"),
                            "id": .int(-1),
                            "method": .string("session/request_permission"),
                            "params": .object([
                                "sessionId": .string("node-sess-1"),
                                "toolCall": .object([
                                    "toolCallId": .string("tc-1"),
                                    "title": .string(title),
                                    "kind": .string("execute"),
                                    "status": .string("pending"),
                                ]),
                                "options": .array([]),
                            ]),
                        ]).serialized())
                    // End the turn (the owner's provider awaits this).
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                default:
                    transport.send(
                        #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                }
            }
        }
    }

    /// Mirror of `ACPWire.permissionGranted` (which is internal to PQRCACP): the owner
    /// answers `{outcome:{outcome:"selected",optionId:"allow_once"|"reject_once"}}`.
    private func ACPWirePermissionGranted(_ result: JSONValue?) -> Bool {
        guard let outcome = result?["outcome"] else { return false }
        guard outcome["outcome"]?.stringValue == "selected" else { return false }
        return (outcome["optionId"]?.stringValue ?? "").hasPrefix("allow")
    }

    /// Build owner+node, verify+consent (C-3) both ways, pre-create the node's transport
    /// with the scripted terminal-requesting agent, and bind the owner's acp provider.
    private func establishPair(
        seedBase: UInt64, ownerAIs: [TetheredAI]
    ) async throws -> (
        owner: PersonaRuntime, node: PersonaRuntime, ownerHex: String, nodeHex: String,
        nodeAgent: Task<Void, Never>, outcomes: PermissionOutcomes
    ) {
        let relay = LocalRelaySimulator()
        let owner = await makeRuntime("Owner", seed: seedBase, relay: relay, ais: ownerAIs)
        let node = await makeRuntime(
            "Node", seed: seedBase &+ 10, relay: relay,
            ais: [TetheredAI(id: "n", name: "node-ai", provider: DemoAgentProvider())])
        await owner.keychain.deleteAll()
        await node.keychain.deleteAll()
        _ = try await owner.bootstrap(inMemoryStore: true)
        _ = try await node.bootstrap(inMemoryStore: true)

        let ownerHex = await owner.identityHex
        let nodeHex = await node.identityHex
        try await owner.addVerifiedPeer(node)
        try await node.addVerifiedPeer(owner)
        try await owner.establishWith(node, firstMessage: "pair")
        #expect(await waitUntil("node received pair") { await received("pair", in: ownerHex, on: node) })
        try await node.sendMessage("ack", conversationID: ownerHex)
        #expect(await waitUntil("owner received ack") { await received("ack", in: nodeHex, on: owner) })

        await owner.setContactType(nodeHex, type: "coding_agent")
        await node.setContactType(ownerHex, type: "coding_agent")
        AppSession.setRemoteDevControlConsent(true, nodeID: nodeHex, siloID: "")
        AppSession.setRemoteDevControlConsent(true, nodeID: ownerHex, siloID: "")

        let nodeTransport = await node.ensureRelayACPTransport(nodeHex: ownerHex)
        #expect(nodeTransport != nil)
        let outcomes = PermissionOutcomes()
        let agentTask = scriptedTerminalRequestingNode(on: nodeTransport!, outcomes: outcomes)

        await owner.setAIs(ownerAIs)
        return (owner, node, ownerHex, nodeHex, agentTask, outcomes)
    }

    private func acpAI() -> TetheredAI {
        TetheredAI(
            id: "acp", name: "mac-harness", provider: DemoAgentProvider(),
            kind: "acp", isRemote: true, appliesEgressFirewall: true)
    }

    /// CONSENT OFF + a permission UI wired ⇒ the interactive terminal may be approved
    /// ONCE via the prompt (feature 9, decision D6). The asker IS consulted, and an
    /// "allow once" answer opens the shell WITHOUT flipping the standing consent.
    @Test func interactiveTerminal_allowOnceViaUI_withoutStandingConsent() async throws {
        let pair = try await establishPair(seedBase: 9_100, ownerAIs: [acpAI()])
        defer {
            pair.nodeAgent.cancel()
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.nodeHex, siloID: "")
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.ownerHex, siloID: "")
            AppSession.setAutonomousChangesConsent(false, nodeID: pair.nodeHex, siloID: "")
        }
        let asker = AllowingAsker()
        await pair.owner.setPermissionAsker(asker)
        // Standing autonomous-changes consent is OFF — the prompt is the path.
        AppSession.setAutonomousChangesConsent(false, nodeID: pair.nodeHex, siloID: "")

        // Drive a turn → the node requests interactive-terminal permission.
        _ = try? await pair.owner.draftReply(conversationID: pair.nodeHex)

        #expect(await pair.outcomes.waitForOne(), "the node must have received a permission outcome")
        let granted = await pair.outcomes.granted
        #expect(
            granted.contains(true),
            "interactive-terminal permission may be allowed ONCE via the prompt (got \(granted))")
        #expect(
            await asker.requestCount() >= 1,
            "the interactive-PTY gate now consults the prompt for an allow-once decision")
        // Allow-once must NOT flip the standing consent (that's "Always").
        #expect(
            AppSession.autonomousChangesConsent(nodeID: pair.nodeHex, siloID: "") == false,
            "an allow-once must not silently grant standing autonomous-changes consent")

        await pair.owner.shutdown()
        await pair.node.shutdown()
    }

    /// CONSENT OFF + NO permission UI (headless / locked) ⇒ FAIL CLOSED: with nothing
    /// to ask, the interactive terminal is denied (the node's C-1 timeout agrees).
    @Test func interactiveTerminal_deniedWithoutConsentAndNoUI() async throws {
        let pair = try await establishPair(seedBase: 9_150, ownerAIs: [acpAI()])
        defer {
            pair.nodeAgent.cancel()
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.nodeHex, siloID: "")
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.ownerHex, siloID: "")
            AppSession.setAutonomousChangesConsent(false, nodeID: pair.nodeHex, siloID: "")
        }
        // No asker wired AND consent OFF → decidePermission fails closed.
        AppSession.setAutonomousChangesConsent(false, nodeID: pair.nodeHex, siloID: "")

        _ = try? await pair.owner.draftReply(conversationID: pair.nodeHex)

        #expect(await pair.outcomes.waitForOne(), "the node must have received a permission outcome")
        let granted = await pair.outcomes.granted
        #expect(
            granted.allSatisfy { $0 == false },
            "with no UI and no standing consent, the interactive terminal fails closed (got \(granted))")

        await pair.owner.shutdown()
        await pair.node.shutdown()
    }

    /// CONSENT ON ⇒ the owner ALLOWS the interactive-terminal request.
    @Test func interactiveTerminal_allowedWithStandingConsent() async throws {
        let pair = try await establishPair(seedBase: 9_200, ownerAIs: [acpAI()])
        defer {
            pair.nodeAgent.cancel()
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.nodeHex, siloID: "")
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.ownerHex, siloID: "")
            AppSession.setAutonomousChangesConsent(false, nodeID: pair.nodeHex, siloID: "")
        }
        // Standing autonomous-changes consent ON (the explicit opt-in). No UI needed.
        AppSession.setAutonomousChangesConsent(true, nodeID: pair.nodeHex, siloID: "")

        _ = try? await pair.owner.draftReply(conversationID: pair.nodeHex)

        #expect(await pair.outcomes.waitForOne(), "the node must have received a permission outcome")
        let granted = await pair.outcomes.granted
        #expect(
            granted.contains(true),
            "with the standing consent ON the interactive terminal is allowed (got \(granted))")

        await pair.owner.shutdown()
        await pair.node.shutdown()
    }

    /// FAIL-CLOSED TEARDOWN: tearing the relay-ACP transport down drops the node's
    /// transport (so on a real device the node's runACPAgent inbound stream ends and it
    /// terminates every live PTY). Here we prove the phone-side trigger: after teardown,
    /// the transport is gone and a later ensure must rebuild a fresh one.
    @Test func teardown_dropsTransport_failClosed() async throws {
        let pair = try await establishPair(seedBase: 9_300, ownerAIs: [acpAI()])
        defer {
            pair.nodeAgent.cancel()
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.nodeHex, siloID: "")
            AppSession.setRemoteDevControlConsent(false, nodeID: pair.ownerHex, siloID: "")
        }
        // The owner has a live transport to the node.
        let before = await pair.owner.ensureRelayACPTransport(nodeHex: pair.nodeHex)
        #expect(before != nil)

        // Tear it down (the consent-revoke / unpair / lock path).
        await pair.owner.teardownRelayACPTransport(nodeHex: pair.nodeHex)

        // A fresh ensure builds a NEW transport instance — the old one was closed/dropped,
        // proving the teardown actually severed the path (not left it lingering).
        let after = await pair.owner.ensureRelayACPTransport(nodeHex: pair.nodeHex)
        #expect(after != nil)
        #expect(after !== before, "teardown must drop the transport so a later use rebuilds it")

        await pair.owner.shutdown()
        await pair.node.shutdown()
    }
}

/// A permission asker that would ALLOW any prompt (allow-once) and counts how many times
/// it was consulted — so a test can prove the interactive-PTY gate never reaches it.
@MainActor
private final class AllowingAsker: ACPPermissionAsking {
    private var count = 0
    func request(_ request: PermissionRequest) async -> ACPPermissionDecision {
        count += 1
        return .allowOnce
    }
    func cancelAll(nodeHex: String) {}
    func requestCount() -> Int { count }
}
