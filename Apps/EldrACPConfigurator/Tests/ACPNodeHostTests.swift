import Crypto
import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrACPConfigurator

/// The HIGH-VALUE proof for the NODE side of the ACP router: the FULL composition runs
/// OVER THE SEAL, end to end, headlessly.
///
/// ```
/// phone ACPAgentProvider → ACPClient → sealed NearbyACPTransport → LocalLinkSimulator
///       → sealed NearbyACPTransport → ACPNodeHost.runACPAgent → ACPAgent (scripted LLM)
/// ```
///
/// Both ends are REAL `NearbyACPTransport`s (the production sealed transport — the same
/// type that runs over `MultipeerNearbyLink` in the field), wired across one
/// `LocalLinkSimulator` (the LAN/loopback `NearbyLink`, no radios — TEST-PLAN §1). The
/// phone speaks ACP as the client via `ACPAgentProvider`; the Mac serves it via
/// `ACPNodeHost`, which calls `runACPAgent` with a scripted LLM. So this exercises the
/// node host logic plus the entire sealed path in one go.
///
/// Proven here:
///  - (a) a plain prompt → the agent's assistant text comes back THROUGH THE SEAL;
///  - (b) a `write_file` tool turn actually WRITES on the node (under the C-2 jail) and
///    the tool activity flows back to the phone;
///  - (P-8) the raw bytes crossing the link are CIPHERTEXT — the plaintext prompt + a
///    planted secret never appear on the wire (the canary would fire on the plaintext).
///
/// DEVICE-DEPENDENT, NOT exercised here (flagged, not faked): the live Multipeer radio
/// handshake between two physical devices (`MultipeerNearbyLink` discovery + the MC
/// session + the real `.connected` event). That is the ONLY remaining piece — the
/// transport + host logic + sealed composition are proven over the loopback above.
@Suite("ACP node host — full sealed composition (phone client ↔ node host over the seal)")
struct ACPNodeHostTests {

    /// A scripted LLM: returns queued responses in order, then a terminal "done". `stream`
    /// uses the protocol default (one-shot `complete`), so it works with the node host's
    /// `streamingEnabled: false` path.
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    /// Fail the test instead of hanging forever if `body` doesn't finish within `seconds`:
    /// a wiring bug (a frame that never crosses the seal, a continuation never resumed)
    /// surfaces as a thrown `TimedOut`, not a wedged suite.
    struct TimedOut: Error {}
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

    /// One end of the sealed loopback: the transport + its `NearbyPeerID` in the sim hub.
    private struct SealedEnd {
        let transport: NearbyACPTransport
        let peerID: NearbyPeerID
    }

    /// Build a phone↔node sealed `NearbyACPTransport` PAIR over one `LocalLinkSimulator`,
    /// each pointed at the other's identity. Both links are STARTED (so the sealed hello
    /// runs); returns once each side has a proven peer, so a prompt can flow immediately.
    ///
    /// Uses `SystemRandomSource`/`SystemNonceSource` (the public seams) for keys + nonces
    /// — this is a wiring/composition proof, not a frozen-vector test, so determinism
    /// isn't required (correctness is asserted by content + the canary, bounded by the
    /// timeout).
    private func makeSealedPair(hub: LocalLinkSimulator) async throws -> (
        phone: SealedEnd, node: SealedEnd
    ) {
        let phoneIdentity = try PQRCIdentity(randomSource: SystemRandomSource())
        let nodeIdentity = try PQRCIdentity(randomSource: SystemRandomSource())
        let phoneNostr = try NostrKeypair(randomSource: SystemRandomSource())
        let nodeNostr = try NostrKeypair(randomSource: SystemRandomSource())

        let phone = NearbyACPTransport(
            identity: phoneIdentity, nostrKeypair: phoneNostr,
            link: await hub.makeLink(name: "phone"),
            peerIdentityKey: nodeIdentity.publicKeyData,
            randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
        let node = NearbyACPTransport(
            identity: nodeIdentity, nostrKeypair: nodeNostr,
            link: await hub.makeLink(name: "node"),
            peerIdentityKey: phoneIdentity.publicKeyData,
            randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())

        try await phone.start()
        try await node.start()
        #expect(await waitPaired(phone))
        #expect(await waitPaired(node))
        return (
            SealedEnd(transport: phone, peerID: NearbyPeerID("phone")),
            SealedEnd(transport: node, peerID: NearbyPeerID("node"))
        )
    }

    /// Poll until `transport` has a proven peer (the sealed hello is async).
    private func waitPaired(
        _ transport: NearbyACPTransport, timeoutMillis: Int = 5_000
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await transport.isPeerProven() { return true }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }

    /// Render a phone-side `AgentContext` carrying one human message — what
    /// `ACPAgentProvider.draftReply` renders into a single `session/prompt`.
    private func contextWith(_ userText: String) -> AgentContext {
        AgentContext(
            myIdentityHex: "phone-identity-hex",
            myDisplayName: "Phone",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "peer-identity-hex", senderDisplayName: "User",
                    participantType: .human, text: userText)
            ])
    }

    // MARK: (a) plain prompt round-trips the assistant text back through the seal

    @Test func plainPrompt_assistantTextReturnsThroughTheSeal() async throws {
        try await withTimeout(30) {
            let hub = LocalLinkSimulator()
            let (phone, node) = try await self.makeSealedPair(hub: hub)

            // NODE: serve ACP over its sealed end with a scripted LLM (its link is already
            // started by makeSealedPair, so use start() not startNearby()).
            let host = ACPNodeHost(
                transport: node.transport,
                llm: ScriptedLLM([LLMResponse(content: "Hello from the node agent.")]),
                toolEnvironment: ToolEnvironment(workdir: NSTemporaryDirectory(), baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
            await host.start()
            #expect(await host.currentStatus() == .serving)

            // PHONE: drive the agent as the ACP client over its sealed end.
            let provider = ACPAgentProvider(transport: phone.transport)
            let draft = try await provider.draftReply(context: self.contextWith("hi node"))
            #expect(draft.text.contains("Hello from the node agent."))

            await provider.shutdown()
            await host.stop()
            #expect(await host.currentStatus() == .stopped)
        }
    }

    // MARK: (b) a write_file tool turn writes on the node (C-2 jail) + activity flows back

    @Test func writeFileToolTurn_writesUnderJailAndActivityReturns() async throws {
        try await withTimeout(30) {
            // The node's session workdir = the C-2 jail. The write target is INSIDE it.
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-node-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let target = (dir as NSString).appendingPathComponent("out.txt")

            let hub = LocalLinkSimulator()
            let (phone, node) = try await self.makeSealedPair(hub: hub)

            // Script: turn 1 → a write_file tool call; turn 2 → final text.
            let llm = ScriptedLLM([
                LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(
                            id: "w1", name: "write_file",
                            arguments: "{\"path\":\"\(target)\",\"content\":\"hello-from-seal\"}")
                    ]),
                LLMResponse(content: "wrote the file"),
            ])
            let host = ACPNodeHost(
                transport: node.transport, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
            await host.start()

            // PHONE: GRANT the mutating-tool permission (the C-1 gate is deny-by-default;
            // an explicit grant is required to let the write run).
            let provider = ACPAgentProvider(
                transport: phone.transport, permissionHandler: { _, _ in true })
            let draft = try await provider.draftReply(context: self.contextWith("write it"))

            // The node actually wrote the file, inside the C-2 jail (target is under cwd).
            #expect(FileManager.default.fileExists(atPath: target))
            #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "hello-from-seal")
            // The tool activity made it back across the seal (folded into the draft text).
            #expect(draft.text.contains("wrote the file"))
            #expect(draft.text.lowercased().contains("tool"))

            await provider.shutdown()
            await host.stop()
        }
    }

    // MARK: (b′) the C-1 gate stays fail-closed: a DENIED write never lands on the node

    @Test func deniedPermission_neverWritesOnTheNode() async throws {
        try await withTimeout(30) {
            let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-node-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let target = (dir as NSString).appendingPathComponent("out.txt")

            let hub = LocalLinkSimulator()
            let (phone, node) = try await self.makeSealedPair(hub: hub)

            let llm = ScriptedLLM([
                LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(
                            id: "w1", name: "write_file",
                            arguments: "{\"path\":\"\(target)\",\"content\":\"should-not-exist\"}")
                    ]),
                LLMResponse(content: "ok, skipped"),
            ])
            let host = ACPNodeHost(
                transport: node.transport, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
            await host.start()

            // The phone DENIES the permission. The host passes `config` straight through
            // and never sets allowUngatedTools, so deny-by-default holds: no write.
            let provider = ACPAgentProvider(
                transport: phone.transport, permissionHandler: { _, _ in false })
            _ = try await provider.draftReply(context: self.contextWith("write it"))

            #expect(!FileManager.default.fileExists(atPath: target))  // denied ⇒ never written

            await provider.shutdown()
            await host.stop()
        }
    }

    // MARK: (P-8) the bytes crossing the link are sealed — plaintext never on the wire

    @Test func p8Canary_rawLinkBytesAreCiphertext_notThePlaintextPromptOrSecret() async throws {
        try await withTimeout(30) {
            let hub = LocalLinkSimulator()
            let (phone, node) = try await self.makeSealedPair(hub: hub)

            // The assistant reply embeds a planted secret; the phone's prompt carries a
            // recognizable marker. Neither may appear in clear on the raw link.
            let secret = "sk-NODECANARY-789xyz"
            let promptMarker = "CANARY-PROMPT-MARKER"
            let host = ACPNodeHost(
                transport: node.transport,
                llm: ScriptedLLM([LLMResponse(content: "secret is \(secret)")]),
                toolEnvironment: ToolEnvironment(workdir: NSTemporaryDirectory(), baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
            await host.start()

            let provider = ACPAgentProvider(transport: phone.transport)
            let draft = try await provider.draftReply(
                context: self.contextWith("\(promptMarker) please answer"))
            #expect(draft.text.contains(secret))  // it DID come back (decrypted) on our end

            await provider.shutdown()
            await host.stop()

            // Every raw byte the underlying link carried, BOTH directions (hello, proof,
            // every sealed frame): the prompt marker, the secret, and a known ACP method
            // name must NOT appear. The frames are ciphertext.
            let raw =
                await hub.payloads(from: phone.peerID, to: node.peerID)
                + hub.payloads(from: node.peerID, to: phone.peerID)
            #expect(!raw.isEmpty)
            let needles = [
                Data(secret.utf8), Data(promptMarker.utf8), Data("session/prompt".utf8),
            ]
            for payload in raw {
                for needle in needles {
                    #expect(
                        !payload.containsSubsequence(needle),
                        "plaintext leaked in clear on the link")
                }
            }
            // Sanity: the canary is NOT vacuous — the marker + secret DO appear in the
            // plaintext the phone fed in / the node produced.
            #expect(Data("\(promptMarker) please answer".utf8).containsSubsequence(Data(promptMarker.utf8)))
            #expect(Data("secret is \(secret)".utf8).containsSubsequence(Data(secret.utf8)))
        }
    }

    // MARK: host lifecycle — stop() ends the agent loop (transport close → runACPAgent returns)

    @Test func stop_closesTransportAndEndsServing() async throws {
        try await withTimeout(20) {
            let hub = LocalLinkSimulator()
            let (_, node) = try await self.makeSealedPair(hub: hub)
            let host = ACPNodeHost(
                transport: node.transport, llm: ScriptedLLM([]),
                toolEnvironment: ToolEnvironment(workdir: NSTemporaryDirectory(), baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
            #expect(await host.currentStatus() == .idle)
            await host.start()
            #expect(await host.currentStatus() == .serving)
            await host.stop()
            #expect(await host.currentStatus() == .stopped)
            // Idempotent: a second stop is a no-op, still stopped.
            await host.stop()
            #expect(await host.currentStatus() == .stopped)
        }
    }
}

// MARK: - Test helpers

extension Data {
    /// Byte-subsequence containment — the P-8 canary's "does this plaintext appear in
    /// these raw bytes" check. (Named distinctly from any package-internal helper so it
    /// can't collide across the test target.)
    fileprivate func containsSubsequence(_ needle: Data) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return false }
        let hay = [UInt8](self)
        let pat = [UInt8](needle)
        let last = hay.count - pat.count
        var i = 0
        while i <= last {
            if Array(hay[i..<(i + pat.count)]) == pat { return true }
            i += 1
        }
        return false
    }
}
