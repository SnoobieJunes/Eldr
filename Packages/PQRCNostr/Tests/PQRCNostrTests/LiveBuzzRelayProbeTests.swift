// SPDX-License-Identifier: Apache-2.0
#if canImport(Network)
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// A LIVE probe against a real Buzz relay, run with Eldr's OWN transport client
/// (`NostrWebSocketTransport`) — not a synthetic script. It answers, concretely:
/// "does Eldr's client reach a Buzz relay, and what does the relay accept?"
///
/// Opt-in (never runs in the normal suite — it touches the real network):
///   BUZZ_LIVE_RELAY=wss://auston.communities.buzz.xyz \
///   BUZZ_LIVE_OWNER=<owner-hex-pubkey> \
///   [BUZZ_LIVE_NSEC=nsec1… or 64-hex agent/owner private key] \
///   swift test --package-path Packages/PQRCNostr --filter LiveBuzzRelayProbe
///
/// Without BUZZ_LIVE_NSEC it uses a FRESH throwaway key (proves the membership
/// gate). With a member nsec it proves the kind-level acceptance (kind:1059
/// gift wraps accepted, Eldr's kind:10420 identity events rejected).
@Suite("Live Buzz relay probe", .serialized)
struct LiveBuzzRelayProbeTests {

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_LIVE_RELAY"] != nil))
    func live_buzzRelayProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        let relayURL = try #require(URL(string: env["BUZZ_LIVE_RELAY"] ?? ""))
        let ownerHex = env["BUZZ_LIVE_OWNER"] ?? ""
        func log(_ s: String) { print("PROBE: \(s)") }

        log("relay = \(relayURL.absoluteString)")

        // Key: a supplied member key, or a fresh throwaway (non-member).
        let random = SystemRandomSource()
        let (keypair, isMember): (NostrKeypair, Bool)
        if let nsec = env["BUZZ_LIVE_NSEC"], !nsec.isEmpty {
            keypair = try Self.parseKey(nsec)
            isMember = true
            log("auth key = SUPPLIED (\(keypair.publicKeyHex.prefix(16))…) — expecting membership")
        } else {
            keypair = try NostrKeypair(randomSource: random)
            isMember = false
            log("auth key = FRESH THROWAWAY (\(keypair.publicKeyHex.prefix(16))…) — non-member")
        }

        // STEP 1 — reach the relay and observe the NIP-42 AUTH challenge.
        let transport = NostrWebSocketTransport(url: relayURL, responseTimeout: .seconds(12))
        let events = TransportEventCollector()
        await events.attach(await transport.transportEvents())
        _ = await transport.connect()
        let lifecycle = await events.waitUntil(minimumCount: 3, timeoutMillis: 12000)
        let sawConnect = lifecycle.contains(.connected)
        let sawChallenge = lifecycle.contains(.authChallenge)
        log("STEP 1 reachability: connected=\(sawConnect) gotNIP42Challenge=\(sawChallenge)")
        #expect(sawConnect, "could not open a WebSocket to the relay")

        // STEP 2 — NIP-42 AUTH. A non-member should be rejected (membership gate).
        var authed = false
        do {
            try await transport.authenticate(keypair: keypair, randomSource: random)
            authed = true
            log("STEP 2 AUTH: ACCEPTED\(isMember ? " (member)" : " — relay allowed a NON-member!")")
        } catch {
            log("STEP 2 AUTH: REJECTED — \(error). This is the membership gate (NIP-42/43).")
        }

        // STEP 3 — read the owner's public kind:0 profile (does it allow reads?).
        if !ownerHex.isEmpty {
            let stream = await transport.subscribe([NostrFilter(kinds: [0], authors: [ownerHex])])
            let got = await Self.firstEvent(stream, timeoutMs: 8000) { $0.pubkey == ownerHex && $0.kind == 0 }
            log("STEP 3 read owner kind:0 profile: \(got != nil ? "RECEIVED (\(got!.content.prefix(60)))" : "none (read gated or not present)")")
        }

        // STEP 4 — try to publish EACH event class and report the relay's verdict.
        // Only meaningful once AUTHed; otherwise everything bounces on AUTH.
        if authed {
            // 4a: Eldr identity binding (kind 10420) — expected REJECTED "unknown kind".
            let binding = try keypair.sign(
                NostrEvent(
                    pubkey: keypair.publicKeyHex, createdAt: Int64(Date().timeIntervalSince1970),
                    kind: PQRCConstants.bindingEventKind, tags: [], content: "eldr-identity-probe"),
                randomSource: random)
            let bindingAck = try? await transport.publish(binding)
            log("STEP 4a Eldr identity kind:\(PQRCConstants.bindingEventKind) → accepted=\(bindingAck?.accepted ?? false) reason=\(bindingAck?.message ?? "(no OK)")")

            // 4b: NIP-59 gift wrap (kind 1059) — expected ACCEPTED (Buzz carries these).
            let wrap = try keypair.sign(
                NostrEvent(
                    pubkey: keypair.publicKeyHex, createdAt: Int64(Date().timeIntervalSince1970),
                    kind: PQRCConstants.giftWrapEventKind, tags: [["p", ownerHex.isEmpty ? keypair.publicKeyHex : ownerHex]],
                    content: "eldr-giftwrap-probe-opaque-ciphertext"),
                randomSource: random)
            let wrapAck = try? await transport.publish(wrap)
            log("STEP 4b Eldr gift wrap kind:\(PQRCConstants.giftWrapEventKind) → accepted=\(wrapAck?.accepted ?? false) reason=\(wrapAck?.message ?? "(no OK)")")
        } else {
            log("STEP 4 SKIPPED: not authenticated (need a member nsec via BUZZ_LIVE_NSEC to test kind acceptance).")
        }

        await transport.disconnect()
        log("done.")
    }

    /// LIVE: mint a fresh agent key, owner-attest it (NIP-OA) with the supplied
    /// owner key, join the Buzz relay owner-attested, publish a kind:0 profile,
    /// and post a real kind:9 hello to a channel — so a brand-new Eldr-hosted
    /// agent appears and speaks in the Buzz GUI.
    ///
    ///   BUZZ_LIVE_RELAY=wss://…  BUZZ_LIVE_NSEC=<OWNER nsec/hex>
    ///   BUZZ_LIVE_POST_CHANNEL=<channel-uuid>  [BUZZ_LIVE_AGENT_NAME=Eldr]
    ///   swift test --package-path Packages/PQRCNostr --filter live_postAgentHelloToBuzz
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_LIVE_POST_CHANNEL"] != nil))
    func live_postAgentHelloToBuzz() async throws {
        let env = ProcessInfo.processInfo.environment
        let relayURL = try #require(URL(string: env["BUZZ_LIVE_RELAY"] ?? ""))
        let channel = try #require(env["BUZZ_LIVE_POST_CHANNEL"])
        let ownerNsec = try #require(env["BUZZ_LIVE_NSEC"], "set BUZZ_LIVE_NSEC to the OWNER key")
        let agentName = env["BUZZ_LIVE_AGENT_NAME"] ?? "Eldr (local model)"
        let random = SystemRandomSource()
        func log(_ s: String) { print("POST: \(s)") }

        let owner = try Self.parseKey(ownerNsec)
        let agent = try NostrKeypair(randomSource: random)  // brand-new agent identity
        log("owner=\(owner.publicKeyHex.prefix(16))…  new agent=\(agent.publicKeyHex.prefix(16))…")
        log("agent npub=\(agent.npub)")

        // Owner attests the agent (NIP-OA) — no conditions (valid for any kind).
        let authTag = try NIPOA.computeAuthTag(
            ownerPrivateKey: owner.privateKeyData, agentPublicKeyHex: agent.publicKeyHex,
            conditions: "", randomSource: random)
        let authTagParts = try NIPOA.parseAuthTag(authTag)

        let transport = NostrWebSocketTransport(url: relayURL, responseTimeout: .seconds(12))
        _ = await transport.connect()
        try await transport.authenticate(
            keypair: agent, randomSource: random, extraTags: [authTagParts])
        log("STEP 1 authenticated as owner-attested agent ✓")

        // kind:0 profile so the agent has a name/face in Buzz.
        let profile = try agent.sign(
            BuzzEvents.profile(
                pubkey: agent.publicKeyHex, displayName: agentName, name: agentName,
                about: "A local, on-device AI hosted on this machine via Eldr/Huginn."),
            randomSource: random)
        let profileAck = try await transport.publish(profile)
        log("STEP 2 kind:0 profile → accepted=\(profileAck.accepted) \(profileAck.message ?? "")")

        let hello =
            "👋 Hello from Eldr — I'm a local model running on your own machine (Huginn), now "
            + "connected to this Buzz workspace as an agent. Mention me and I'll answer from your "
            + "hardware; nothing leaves your Mac to a cloud model. — posted by the Eldr↔Buzz gateway"

        // STEP 3 (diagnostic) — try the EXISTING channel. Buzz gates posting on
        // per-channel membership, and its relay has no member-management API
        // (buzz-acp README), so this is expected to bounce with "not a channel
        // member" unless the agent was already added. Non-fatal.
        let existing = try agent.sign(
            BuzzEvents.streamMessage(pubkey: agent.publicKeyHex, channelId: channel, content: hello),
            randomSource: random)
        let existingAck = try await transport.publish(existing)
        log("STEP 3 post to EXISTING channel \(channel.prefix(8))… → accepted=\(existingAck.accepted) \(existingAck.message ?? "")")

        // STEP 4 — the reliable path: the agent CREATES its own channel (creator
        // becomes owner/member per the relay), ADDS you so it lands in your Buzz
        // sidebar, then posts there.
        let newChannel = UUID().uuidString.lowercased()
        let createEv = try agent.sign(
            NostrEvent(
                pubkey: agent.publicKeyHex, createdAt: Int64(Date().timeIntervalSince1970),
                kind: 9007,
                tags: [["h", newChannel], ["name", "eldr-agent-demo"], ["visibility", "open"]],
                content: ""), randomSource: random)
        let createAck = try await transport.publish(createEv)
        log("STEP 4a create channel \(newChannel.prefix(8))… (kind:9007) → accepted=\(createAck.accepted) \(createAck.message ?? "")")

        if createAck.accepted {
            // Add the owner so the channel appears in their sidebar.
            let addOwner = try agent.sign(
                NostrEvent(
                    pubkey: agent.publicKeyHex, createdAt: Int64(Date().timeIntervalSince1970),
                    kind: 9000, tags: [["h", newChannel], ["p", owner.publicKeyHex]], content: ""),
                randomSource: random)
            let addAck = try await transport.publish(addOwner)
            log("STEP 4b add owner as member (kind:9000) → accepted=\(addAck.accepted) \(addAck.message ?? "")")

            // Post the greeting into the agent's own channel.
            let msg = try agent.sign(
                BuzzEvents.streamMessage(
                    pubkey: agent.publicKeyHex, channelId: newChannel, content: hello),
                randomSource: random)
            let msgAck = try await transport.publish(msg)
            log("STEP 4c post hello to new channel (kind:9) → accepted=\(msgAck.accepted) eventId=\(msg.id) \(msgAck.message ?? "")")
            #expect(msgAck.accepted, "relay rejected the hello in the agent's own channel: \(msgAck.message ?? "")")
            if msgAck.accepted {
                log("SUCCESS ✓ — open Buzz and look for a channel named 'eldr-agent-demo' (\(newChannel.prefix(8))…) with the message.")
            }
        } else {
            log("channel create was refused — the agent lacks channel-create scope; the owner must create a channel and the agent posts there. Paste this line to me.")
        }

        await transport.disconnect()
        log("done.")
    }

    static func parseKey(_ s: String) throws -> NostrKeypair {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("nsec1"), let (hrp, data) = Bech32.decode(t), hrp == "nsec", data.count == 32 {
            return try NostrKeypair(privateKey: data)
        }
        guard let data = Data(hexString: t), data.count == 32 else {
            throw NostrError.invalidKey
        }
        return try NostrKeypair(privateKey: data)
    }

    static func firstEvent(
        _ stream: AsyncThrowingStream<NostrEvent, Error>, timeoutMs: Int,
        where predicate: @escaping @Sendable (NostrEvent) -> Bool
    ) async -> NostrEvent? {
        await withTaskGroup(of: NostrEvent?.self) { group in
            group.addTask {
                do { for try await e in stream where predicate(e) { return e } } catch {}
                return nil
            }
            group.addTask { try? await Task.sleep(for: .milliseconds(timeoutMs)); return nil }
            let r = await group.next() ?? nil
            group.cancelAll()
            return r
        }
    }
}
#endif
