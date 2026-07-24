// SPDX-License-Identifier: Apache-2.0
#if canImport(Network)
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

/// The Eldr↔Buzz gateway: joins a Buzz workspace channel as a first-class bot
/// member, listens for @mentions, runs each turn against the owner's LOCAL model
/// (Huginn / MLX / any OpenAI-compatible endpoint), and posts the reply as a
/// signed kind:9 message — plus optional NIP-AM turn metrics and NIP-AO observer
/// frames encrypted to the owner.
///
/// This is the "our local model is one of the agents in Buzz" path from
/// INTEROP-LANDSCAPE §8. Zero changes are required on the Buzz side: to the Buzz
/// relay this process is an ordinary NIP-42-authenticated (optionally
/// NIP-OA-attested) bot member.
///
/// Transport is the concrete `NostrWebSocketTransport` so the same code runs the
/// loopback E2E test (against `NostrRelayServer`) and a live Buzz relay — only
/// the URL changes. The reply/mention DECISION logic is factored into pure
/// static helpers (`GatewayLogic`) that are unit-tested without any socket.
public actor BuzzGateway {
    private let transport: NostrWebSocketTransport
    private let keypair: NostrKeypair
    private let llm: any LLMClient
    private let config: BuzzGatewayConfig
    private let random: any RandomSource
    private let log: @Sendable (String) -> Void
    private let usageBox: UsageBox

    private var startedAt: Int64 = 0
    private var repliesSent = 0
    private var seenEventIDs = Set<String>()
    private var historyByChannel: [String: [(role: LLMMessage.Role, name: String, text: String)]] = [:]
    // NIP-AM/AO session state is PER CHANNEL: each channel is its own session,
    // so `turnSeq` and observer `seq` are monotonic within one `sessionId` and
    // `cumulative` forms a valid within-session series (NIP-AM §Ordering).
    private var sessionIdByChannel: [String: String] = [:]
    private var turnSeqByChannel: [String: Int] = [:]
    private var observerSeqByChannel: [String: Int] = [:]
    private var cumulativeByChannel: [String: (input: Int, output: Int, total: Int)] = [:]

    public init(
        transport: NostrWebSocketTransport, keypair: NostrKeypair, llm: any LLMClient,
        config: BuzzGatewayConfig, random: any RandomSource = SystemRandomSource(),
        usageBox: UsageBox = UsageBox(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transport = transport
        self.keypair = keypair
        self.llm = llm
        self.config = config
        self.random = random
        self.usageBox = usageBox
        self.log = log
    }

    public var agentPubkey: String { keypair.publicKeyHex }
    public var replyCount: Int { repliesSent }

    /// Connect, authenticate, publish the profile, announce membership, then
    /// serve inbound mentions until cancelled.
    public func run() async throws {
        startedAt = Int64(Date().timeIntervalSince1970)
        log(config.disclosureBanner)
        try await connectAndAuthenticate()
        try await publishProfile()
        try await announceMemberships()
        await serve()
    }

    // MARK: - Join

    private func connectAndAuthenticate() async throws {
        _ = await transport.connect()
        var extraTags: [[String]] = []
        if let authTag = config.authTagJSON {
            // Parse the NIP-OA tag JSON into the ["auth", owner, conditions, sig]
            // array the relay expects in the AUTH event (owner-attested path).
            if let parts = try? NIPOA.parseAuthTag(authTag) {
                extraTags = [parts]
                log("using NIP-OA owner-attested auth (owner=\(parts[1].prefix(12))…)")
            } else {
                log("WARNING: BUZZ_AUTH_TAG did not parse as a NIP-OA tag; using standalone auth")
            }
        }
        try await transport.authenticate(
            keypair: keypair, randomSource: random, extraTags: extraTags)
        log("authenticated to \(config.relayURL.absoluteString) as \(keypair.publicKeyHex.prefix(12))…")
    }

    private func publishProfile() async throws {
        let profile = BuzzEvents.profile(
            pubkey: keypair.publicKeyHex, displayName: config.displayName, name: config.displayName,
            about: config.about)
        _ = try? await publishSigned(profile, label: "kind:0 profile")
        if let owner = config.ownerPubkeyHex {
            let agentProfile = BuzzEvents.agentProfile(
                pubkey: keypair.publicKeyHex, ownerPubkeyHex: owner, displayName: config.displayName,
                about: config.about)
            _ = try? await publishSigned(agentProfile, label: "kind:10100 agent profile")
        }
    }

    private func announceMemberships() async throws {
        guard config.announceMembership else { return }
        for channel in config.channelIds {
            let announce = BuzzEvents.membershipAnnounce(
                pubkey: keypair.publicKeyHex, channelId: channel)
            // A rejection here is non-fatal (private channels need an admin to
            // add the pubkey) — mirror countdown-bot's behavior.
            do {
                let ack = try await publishSigned(announce, label: "kind:9000 membership")
                if !ack.accepted {
                    log("membership announce for \(channel.prefix(8))… not accepted: \(ack.message ?? "")")
                }
            } catch {
                log("membership announce for \(channel.prefix(8))… failed (non-fatal): \(error)")
            }
        }
    }

    // MARK: - Serve loop

    private func serve() async {
        guard !config.channelIds.isEmpty else {
            log("no channels configured (ELDR_BUZZ_CHANNELS); nothing to listen to")
            return
        }
        // One subscription across all channels: kind:9, #h in channels, only new.
        let filter = NostrFilter(
            kinds: [BuzzEvents.Kind.streamMessage], hTags: config.channelIds, since: startedAt)
        let stream = await transport.subscribe([filter])
        log("listening on \(config.channelIds.count) channel(s) for @mentions of \(config.displayName)")
        do {
            for try await event in stream {
                await handleInbound(event)
            }
        } catch {
            log("subscription ended: \(error)")
        }
    }

    private func handleInbound(_ event: NostrEvent) async {
        // Dedup + skip our own output + skip anything from before we joined.
        guard !seenEventIDs.contains(event.id) else { return }
        seenEventIDs.insert(event.id)
        guard event.pubkey != keypair.publicKeyHex else { return }
        guard event.createdAt >= startedAt else { return }
        guard let channel = GatewayLogic.channelId(of: event) else { return }
        guard config.channelIds.contains(channel) else { return }

        // Record every observed message as context for the channel.
        appendHistory(channel: channel, role: .user, name: shortName(event.pubkey), text: event.content)

        let addressed = GatewayLogic.isAddressedToAgent(
            event: event, agentPubkey: keypair.publicKeyHex, displayName: config.displayName,
            mentionsOnly: config.respondToMentionsOnly)
        guard addressed else { return }

        log("mention in \(channel.prefix(8))… from \(event.pubkey.prefix(12))…: \(event.content.prefix(80))")
        await runTurnAndReply(triggering: event, channel: channel)
    }

    // MARK: - The turn

    private func runTurnAndReply(triggering event: NostrEvent, channel: String) async {
        let turnId = UUID().uuidString
        await emitObserver(kind: "turn_started", channel: channel, turnId: turnId, payload: [:])

        let messages = buildMessages(channel: channel, triggering: event)
        usageBox.reset()
        let reply: String
        do {
            let response = try await llm.complete(messages: messages, tools: [])
            reply = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            log("LLM turn failed: \(error)")
            await emitObserver(
                kind: "session_resolved", channel: channel, turnId: turnId,
                payload: ["status": "error"])
            return
        }
        guard !reply.isEmpty else {
            log("model produced no text; not replying")
            await emitObserver(
                kind: "session_resolved", channel: channel, turnId: turnId,
                payload: ["status": "empty"])
            return
        }

        // Post the reply as a flat reply to the triggering message, mentioning
        // its author so they get the Buzz callback notification.
        let replyEvent = BuzzEvents.streamMessage(
            pubkey: keypair.publicKeyHex, channelId: channel, content: reply,
            mentions: [event.pubkey], replyToEventId: event.id, rootEventId: event.id)
        do {
            let ack = try await publishSigned(replyEvent, label: "kind:9 reply")
            if ack.accepted {
                repliesSent += 1
                appendHistory(channel: channel, role: .assistant, name: config.displayName, text: reply)
                log("replied in \(channel.prefix(8))… (\(reply.count) chars)")
            } else {
                log("reply rejected: \(ack.message ?? "")")
            }
        } catch {
            log("reply publish failed: \(error)")
        }

        await emitTurnMetric(channel: channel, turnId: turnId)
        await emitObserver(
            kind: "session_resolved", channel: channel, turnId: turnId,
            payload: ["status": "completed"])
    }

    private func buildMessages(channel: String, triggering event: NostrEvent) -> [LLMMessage] {
        var messages: [LLMMessage] = [
            LLMMessage(role: .system, content: config.systemPrompt)
        ]
        // Rolling context (excluding the just-appended triggering message, which
        // we frame explicitly last).
        let history = historyByChannel[channel] ?? []
        let context = history.dropLast().suffix(config.historyWindow)
        for entry in context {
            switch entry.role {
            case .assistant:
                messages.append(LLMMessage(role: .assistant, content: entry.text))
            default:
                messages.append(LLMMessage(role: .user, content: "\(entry.name): \(entry.text)"))
            }
        }
        messages.append(
            LLMMessage(role: .user, content: "\(shortName(event.pubkey)): \(event.content)"))
        return messages
    }

    // MARK: - NIP-AM emission

    private func emitTurnMetric(channel: String, turnId: String) async {
        guard config.emitTurnMetrics, let owner = config.ownerPubkeyHex else { return }
        guard let usage = usageBox.take(), usage.hasAnyCount else {
            // NIP-AM §Publisher Behavior: no observed usage ⇒ no event.
            return
        }
        let seq = (turnSeqByChannel[channel] ?? 0) + 1
        turnSeqByChannel[channel] = seq
        var cumulative = cumulativeByChannel[channel] ?? (0, 0, 0)
        if let i = usage.promptTokens { cumulative.input += i }
        if let o = usage.completionTokens { cumulative.output += o }
        if let t = usage.totalTokens { cumulative.total += t }
        cumulativeByChannel[channel] = cumulative

        let payload = AgentTurnMetricPayload(
            harness: config.harnessName, timestamp: GatewayLogic.rfc3339Now(), model: config.model,
            channelId: channel, sessionId: sessionId(for: channel), turnId: turnId, turnSeq: seq,
            turn: TokenCounts(
                inputTokens: usage.promptTokens, outputTokens: usage.completionTokens,
                totalTokens: usage.totalTokens),
            cumulative: TokenCounts(
                inputTokens: cumulative.input, outputTokens: cumulative.output,
                totalTokens: cumulative.total),
            deltaReliable: true, stopReason: "end_turn")
        do {
            let event = try BuzzEvents.turnMetric(
                agentPrivateKey: keypair.privateKeyData, agentPubkeyHex: keypair.publicKeyHex,
                ownerPubkeyHex: owner, payload: payload, randomSource: random)
            _ = try await publishSigned(event, label: "NIP-AM kind:44200 metric")
            log("emitted NIP-AM metric turnSeq=\(seq) tokens=\(usage.totalTokens ?? -1)")
        } catch {
            log("NIP-AM emit failed: \(error)")
        }
    }

    // MARK: - NIP-AO emission

    private func emitObserver(
        kind: String, channel: String, turnId: String, payload: [String: String]
    ) async {
        guard config.emitObserverFrames, let owner = config.ownerPubkeyHex else { return }
        let seq = (observerSeqByChannel[channel] ?? 0) + 1
        observerSeqByChannel[channel] = seq
        let frame = ObserverEvent(
            seq: seq, timestamp: GatewayLogic.rfc3339Now(), kind: kind, channelId: channel,
            sessionId: sessionId(for: channel), turnId: turnId, payload: payload)
        do {
            let event = try BuzzEvents.observerTelemetryFrame(
                agentPrivateKey: keypair.privateKeyData, agentPubkeyHex: keypair.publicKeyHex,
                ownerPubkeyHex: owner, event: frame, channelId: channel, randomSource: random)
            _ = try await publishSigned(event, label: "NIP-AO kind:24200 \(kind)")
        } catch {
            log("NIP-AO emit failed: \(error)")
        }
    }

    // MARK: - Helpers

    private func publishSigned(_ event: NostrEvent, label: String) async throws -> PublishAck {
        let signed = try keypair.sign(event, randomSource: random)
        return try await transport.publish(signed)
    }

    private func appendHistory(
        channel: String, role: LLMMessage.Role, name: String, text: String
    ) {
        var list = historyByChannel[channel] ?? []
        list.append((role: role, name: name, text: text))
        if list.count > config.historyWindow * 2 { list.removeFirst(list.count - config.historyWindow * 2) }
        historyByChannel[channel] = list
    }

    private func shortName(_ pubkey: String) -> String { String(pubkey.prefix(8)) }

    /// Stable per-channel session id (one NIP-AM/AO session per channel), minted
    /// lazily on first use so `turnSeq`/`seq` are monotonic within it.
    private func sessionId(for channel: String) -> String {
        if let existing = sessionIdByChannel[channel] { return existing }
        let id = UUID().uuidString
        sessionIdByChannel[channel] = id
        return id
    }
}

/// Thread-safe latch for the most recent `LLMUsage` reported by the endpoint.
/// Create ONE, wire it to the LLM's `usageObserver`, and pass the SAME box into
/// `BuzzGateway.init(usageBox:)`. The observer fires on a URLSession thread
/// inside `complete`; the gateway reads it on its actor right after `complete`
/// returns. Lock-guarded, so `@unchecked Sendable` is justified.
public final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LLMUsage?
    public init() {}
    public func set(_ u: LLMUsage) { lock.lock(); value = u; lock.unlock() }
    func reset() { lock.lock(); value = nil; lock.unlock() }
    func take() -> LLMUsage? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
}

/// Pure decision logic, unit-tested without any socket.
public enum GatewayLogic {
    /// The channel (`h` tag) an event belongs to, if any.
    public static func channelId(of event: NostrEvent) -> String? {
        event.tags.first { $0.count >= 2 && $0[0] == "h" }?[1]
    }

    /// Is this event addressed to the agent? True when a `p` tag equals the
    /// agent pubkey, or (fallback) the content contains the display name. When
    /// `mentionsOnly` is false, every non-self message is addressed.
    public static func isAddressedToAgent(
        event: NostrEvent, agentPubkey: String, displayName: String, mentionsOnly: Bool
    ) -> Bool {
        if !mentionsOnly { return true }
        let pTagged = event.tags.contains { $0.count >= 2 && $0[0] == "p" && $0[1] == agentPubkey }
        if pTagged { return true }
        // Name fallback: "@Name" or a bare name mention (case-insensitive).
        let haystack = event.content.lowercased()
        let name = displayName.lowercased()
        return !name.isEmpty && (haystack.contains("@" + name) || haystack.contains(name))
    }

    /// RFC 3339 timestamp with fractional seconds (NIP-AM/AO `timestamp`).
    public static func rfc3339Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
#endif
