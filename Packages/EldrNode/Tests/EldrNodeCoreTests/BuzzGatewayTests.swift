// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr
import Testing

#if canImport(Network)
@testable import EldrBuzzGateway

/// Tests for the Eldr↔Buzz gateway (WS-I5).
///
/// The pure decision logic and the NIP-AM/NIP-AO codec round-trips run always
/// (no sockets). The full loopback E2E — gateway joins a real in-process Nostr
/// relay, a "human" posts a mention, the local model (a deterministic mock)
/// replies, and an encrypted NIP-AM metric is decrypted by the owner — is gated
/// behind `ELDR_BUZZ_E2E=1` (same policy as PQRC's loopback socket tests: the
/// standard suite touches no network/clock).
@Suite("Eldr↔Buzz gateway")
struct BuzzGatewayTests {
    private static let ownerKeyHex = String(repeating: "11", count: 32)
    private static let agentKeyHex = String(repeating: "22", count: 32)

    // MARK: - Pure decision logic (always on)

    @Test("isAddressedToAgent: p-tag mention")
    func addressedByPTag() throws {
        let agent = try NostrKeypair(privateKey: Data(hexString: Self.agentKeyHex)!)
        let event = NostrEvent(
            pubkey: "ff", createdAt: 1, kind: 9,
            tags: [["h", "chan"], ["p", agent.publicKeyHex]], content: "hello there")
        #expect(
            GatewayLogic.isAddressedToAgent(
                event: event, agentPubkey: agent.publicKeyHex, displayName: "Eldr",
                mentionsOnly: true))
    }

    @Test("isAddressedToAgent: display-name mention and negative case")
    func addressedByName() {
        let event = NostrEvent(
            pubkey: "ff", createdAt: 1, kind: 9, tags: [["h", "chan"]],
            content: "hey @Eldr can you help?")
        #expect(
            GatewayLogic.isAddressedToAgent(
                event: event, agentPubkey: "aa", displayName: "Eldr", mentionsOnly: true))
        let unrelated = NostrEvent(
            pubkey: "ff", createdAt: 1, kind: 9, tags: [["h", "chan"]], content: "just chatting")
        #expect(
            !GatewayLogic.isAddressedToAgent(
                event: unrelated, agentPubkey: "aa", displayName: "Eldr", mentionsOnly: true))
        // mentionsOnly=false ⇒ every message is addressed.
        #expect(
            GatewayLogic.isAddressedToAgent(
                event: unrelated, agentPubkey: "aa", displayName: "Eldr", mentionsOnly: false))
    }

    @Test("channelId extracts the h tag")
    func channelIdExtraction() {
        let event = NostrEvent(
            pubkey: "ff", createdAt: 1, kind: 9, tags: [["e", "x"], ["h", "the-channel"]],
            content: "")
        #expect(GatewayLogic.channelId(of: event) == "the-channel")
        let none = NostrEvent(pubkey: "ff", createdAt: 1, kind: 9, tags: [], content: "")
        #expect(GatewayLogic.channelId(of: none) == nil)
    }

    // MARK: - NIP-AM / NIP-AO codec round-trips (always on)

    @Test("NIP-AM turn metric encrypts to owner and decrypts to the same payload")
    func nipAMRoundTrip() throws {
        let owner = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        let agent = try NostrKeypair(privateKey: Data(hexString: Self.agentKeyHex)!)
        let payload = AgentTurnMetricPayload(
            harness: "eldr-buzz-agent", timestamp: "2026-07-24T00:00:00.000Z", model: "qwen",
            channelId: "chan", sessionId: "sess", turnId: "t1", turnSeq: 1,
            turn: TokenCounts(inputTokens: 42, outputTokens: 12, totalTokens: 54),
            cumulative: TokenCounts(inputTokens: 42, outputTokens: 12, totalTokens: 54),
            deltaReliable: true, stopReason: "end_turn")
        let event = try BuzzEvents.turnMetric(
            agentPrivateKey: agent.privateKeyData, agentPubkeyHex: agent.publicKeyHex,
            ownerPubkeyHex: owner.publicKeyHex, payload: payload, randomSource: SystemRandomSource())
        #expect(event.kind == 44200)
        #expect(event.tags.contains(["p", owner.publicKeyHex]))
        #expect(event.tags.contains(["agent", agent.publicKeyHex]))
        // Owner decrypts.
        let json = try NIP44.decrypt(
            payload: event.content, recipientPrivateKey: owner.privateKeyData,
            senderPublicKeyHex: agent.publicKeyHex)
        let recovered = try AgentTurnMetricPayload.parse(json)
        #expect(recovered == payload)
    }

    @Test("NIP-AO observer frame encrypts to owner and decrypts to the same event")
    func nipAORoundTrip() throws {
        let owner = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        let agent = try NostrKeypair(privateKey: Data(hexString: Self.agentKeyHex)!)
        let frame = ObserverEvent(
            seq: 3, timestamp: "2026-07-24T00:00:01.500Z", kind: "turn_started", channelId: "chan",
            sessionId: "sess", turnId: "t1", payload: ["status": "ok"])
        let event = try BuzzEvents.observerTelemetryFrame(
            agentPrivateKey: agent.privateKeyData, agentPubkeyHex: agent.publicKeyHex,
            ownerPubkeyHex: owner.publicKeyHex, event: frame, channelId: "chan",
            randomSource: SystemRandomSource())
        #expect(event.kind == 24200)
        #expect(event.tags.contains(["frame", "telemetry"]))
        let json = try NIP44.decrypt(
            payload: event.content, recipientPrivateKey: owner.privateKeyData,
            senderPublicKeyHex: agent.publicKeyHex)
        let recovered = try JSONDecoder().decode(ObserverEvent.self, from: Data(json.utf8))
        #expect(recovered == frame)
    }

    // MARK: - Full loopback E2E (gated: ELDR_BUZZ_E2E=1)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ELDR_BUZZ_E2E"] == "1"))
    func endToEnd_localModelRepliesAndEmitsMetric() async throws {
        let owner = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        let agent = try NostrKeypair(privateKey: Data(hexString: Self.agentKeyHex)!)
        let channel = UUID().uuidString

        // A real in-process Nostr relay over a loopback socket.
        let relay = LocalRelaySimulator(url: "ws://127.0.0.1:0")
        let server = NostrRelayServer(relay: relay, port: 0)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let url = URL(string: "ws://127.0.0.1:\(port)")!

        // Deterministic local "model" that also reports token usage.
        let box = UsageBox()
        let llm = MetricMockLLM(
            reply: "Post-quantum cryptography resists attacks from quantum computers.",
            usage: LLMUsage(promptTokens: 42, completionTokens: 12, totalTokens: 54), box: box)
        let config = BuzzGatewayConfig(
            relayURL: url, channelIds: [channel], displayName: "Eldr", about: "test",
            systemPrompt: "Be concise.", ownerPubkeyHex: owner.publicKeyHex,
            respondToMentionsOnly: true, emitTurnMetrics: true, emitObserverFrames: true)
        let gatewayTransport = NostrWebSocketTransport(url: url)
        let gateway = BuzzGateway(
            transport: gatewayTransport, keypair: agent, llm: llm, config: config, usageBox: box,
            log: { print("GATEWAY: \($0)") })

        let runTask = Task { try? await gateway.run() }
        defer { runTask.cancel() }
        // Let the gateway authenticate + subscribe before the human posts.
        try await Task.sleep(for: .milliseconds(1200))

        // The "human" (owner) connects, subscribes to replies + metrics, posts a mention.
        let human = NostrWebSocketTransport(url: url)
        _ = await human.connect()
        try await human.authenticate(keypair: owner, randomSource: SystemRandomSource())
        let replyStream = await human.subscribe([
            NostrFilter(kinds: [9], hTags: [channel])
        ])
        let metricStream = await human.subscribe([
            NostrFilter(kinds: [44200], pTags: [owner.publicKeyHex])
        ])

        let mention = try owner.sign(
            BuzzEvents.streamMessage(
                pubkey: owner.publicKeyHex, channelId: channel,
                content: "@Eldr what is post-quantum cryptography?",
                mentions: [agent.publicKeyHex]),
            randomSource: SystemRandomSource())
        let mentionAck = try await human.publish(mention)
        #expect(mentionAck.accepted)

        // The agent's reply should arrive on the channel.
        let reply = await Self.firstEvent(replyStream, timeoutMs: 8000) {
            $0.pubkey == agent.publicKeyHex && $0.kind == 9
        }
        #expect(reply != nil, "gateway did not reply within timeout")
        #expect(reply?.content.contains("Post-quantum") == true)
        #expect(NostrKeypair.verify(reply!), "reply must be a valid BIP-340 signature")
        // Reply threads to the mention.
        #expect(reply?.tags.contains(["e", mention.id, "", "reply"]) == true)

        // The NIP-AM metric should arrive, encrypted to the owner, decryptable
        // with the owner key + agent pubkey, carrying the REAL token counts.
        let metric = await Self.firstEvent(metricStream, timeoutMs: 8000) {
            $0.pubkey == agent.publicKeyHex && $0.kind == 44200
        }
        #expect(metric != nil, "no NIP-AM metric received")
        if let metric {
            let json = try NIP44.decrypt(
                payload: metric.content, recipientPrivateKey: owner.privateKeyData,
                senderPublicKeyHex: agent.publicKeyHex)
            let payload = try AgentTurnMetricPayload.parse(json)
            #expect(payload.harness == "eldr-buzz-agent")
            #expect(payload.turn?.totalTokens == 54)
            #expect(payload.turnSeq == 1)
        }
    }

    /// Same loopback E2E but driving the REAL local model (MLX / Huginn /
    /// OpenAI-compatible endpoint) end-to-end: the proof that "our local model
    /// is one of the agents in Buzz." Gated separately (`ELDR_BUZZ_E2E_LIVE_MODEL=1`)
    /// because it needs the model server up (default http://127.0.0.1:1337/v1).
    /// Set `ELDR_LLM_MODEL` to the loaded model id.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ELDR_BUZZ_E2E_LIVE_MODEL"] == "1"))
    func endToEnd_realLocalModelReplies() async throws {
        let env = ProcessInfo.processInfo.environment
        let owner = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        let agent = try NostrKeypair(privateKey: Data(hexString: Self.agentKeyHex)!)
        let channel = UUID().uuidString

        let relay = LocalRelaySimulator(url: "ws://127.0.0.1:0")
        let server = NostrRelayServer(relay: relay, port: 0)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let url = URL(string: "ws://127.0.0.1:\(port)")!

        // Real local model, with real token usage feeding NIP-AM.
        let box = UsageBox()
        let llmConfig = LLMConfig(
            url: env["ELDR_LLM_URL"] ?? "http://127.0.0.1:1337/v1", token: env["ELDR_LLM_TOKEN"] ?? "",
            model: env["ELDR_LLM_MODEL"]
                ?? "dawncr0w/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-OptiQ-5bpw-MLX",
            requestTimeoutSeconds: 180)
        let llm = OpenAICompatibleLLMClient(config: llmConfig, usageObserver: { box.set($0) })
        let config = BuzzGatewayConfig(
            relayURL: url, channelIds: [channel], displayName: "Eldr",
            about: "A local, on-device AI hosted by Eldr/Huginn.",
            systemPrompt: "You are a concise, helpful AI in a Buzz workspace. Answer directly.",
            ownerPubkeyHex: owner.publicKeyHex, respondToMentionsOnly: true, emitTurnMetrics: true,
            emitObserverFrames: true, model: llmConfig.model)
        let gateway = BuzzGateway(
            transport: NostrWebSocketTransport(url: url), keypair: agent, llm: llm, config: config,
            usageBox: box, log: { print("GATEWAY: \($0)") })

        let runTask = Task { try? await gateway.run() }
        defer { runTask.cancel() }
        try await Task.sleep(for: .milliseconds(1200))

        let human = NostrWebSocketTransport(url: url)
        _ = await human.connect()
        try await human.authenticate(keypair: owner, randomSource: SystemRandomSource())
        let replyStream = await human.subscribe([NostrFilter(kinds: [9], hTags: [channel])])

        let mention = try owner.sign(
            BuzzEvents.streamMessage(
                pubkey: owner.publicKeyHex, channelId: channel,
                content: "@Eldr in one sentence, what is post-quantum cryptography?",
                mentions: [agent.publicKeyHex]), randomSource: SystemRandomSource())
        _ = try await human.publish(mention)

        let reply = await Self.firstEvent(replyStream, timeoutMs: 180_000) {
            $0.pubkey == agent.publicKeyHex && $0.kind == 9
        }
        #expect(reply != nil, "real local model did not reply within timeout")
        if let reply {
            print("LIVE MODEL REPLY: \(reply.content)")
            #expect(!reply.content.isEmpty)
            #expect(NostrKeypair.verify(reply))
        }
    }

    /// First stream event matching `predicate`, or nil after `timeoutMs`.
    private static func firstEvent(
        _ stream: AsyncThrowingStream<NostrEvent, Error>, timeoutMs: Int,
        where predicate: @escaping @Sendable (NostrEvent) -> Bool
    ) async -> NostrEvent? {
        await withTaskGroup(of: NostrEvent?.self) { group in
            group.addTask {
                do {
                    for try await event in stream where predicate(event) { return event }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(timeoutMs))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// Deterministic local "model": returns fixed text and reports token usage into
/// the shared `UsageBox` exactly as `OpenAICompatibleLLMClient` would.
private struct MetricMockLLM: LLMClient {
    let reply: String
    let usage: LLMUsage?
    let box: UsageBox
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        if let usage { box.set(usage) }
        return LLMResponse(content: reply)
    }
}
#endif
