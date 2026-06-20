import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// The device-hosted relay over Multipeer ("local relay in your pocket"): one
/// device runs `NearbyRelayHost`, companions use `MultipeerRelayClient` as an
/// ordinary `RelayTransport`. Driven over `LocalLinkSimulator` — the whole
/// protocol is exercised headlessly; only the MC radio adapter needs hardware.
@Suite("Nearby relay hub")
struct NearbyRelayHubTests {
    private func keypair(_ byte: String) throws -> NostrKeypair {
        try NostrKeypair(privateKey: hexData(String(repeating: byte, count: 32)))
    }

    private func signed(
        _ kp: NostrKeypair, kind: Int = 1, content: String = "hello", tags: [[String]] = []
    ) throws -> NostrEvent {
        try kp.sign(
            NostrEvent(
                pubkey: kp.publicKeyHex, createdAt: 1_750_000_000, kind: kind, tags: tags,
                content: content), randomSource: SystemRandomSource())
    }

    /// First event from a subscription, or nil within `seconds` (so a test never
    /// hangs if delivery is broken).
    private func firstEvent(
        _ stream: AsyncThrowingStream<NostrEvent, Error>, seconds: Double = 2
    ) async -> NostrEvent? {
        await withTaskGroup(of: NostrEvent?.self) { group in
            group.addTask {
                do { for try await ev in stream { return ev } } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func makeHostAndClient(
        ai: HubAIAnswer? = nil, authorize: @escaping HubAuthorize = { _ in true }
    ) async throws -> (LocalRelaySimulator, NearbyRelayHost, MultipeerRelayClient) {
        let relay = LocalRelaySimulator()
        let hub = LocalLinkSimulator()
        let host = NearbyRelayHost(
            link: await hub.makeLink(name: "host"), relay: relay,
            randomSource: SeededRandomSource(seed: 1), aiAnswer: ai, authorize: authorize)
        let client = MultipeerRelayClient(
            link: await hub.makeLink(name: "client"), randomSource: SeededRandomSource(seed: 2))
        try await host.start()
        try await client.start()
        try await Task.sleep(for: .milliseconds(150))  // let connect + hello settle
        return (relay, host, client)
    }

    @Test func client_publishesAndReceives_throughNearbyHost() async throws {
        let (relay, host, client) = try await makeHostAndClient()
        // Publish is AUTH-gated (C-5): authenticate first. The default allowlist
        // is allow-all, so this is the ordinary relay path.
        try await client.authenticate(keypair: try keypair("44"), randomSource: SystemRandomSource())
        let stream = await client.subscribe([NostrFilter(kinds: [1])])
        let ack = try await client.publish(try signed(try keypair("44"), content: "over the radio"))
        #expect(ack.accepted, "the nearby host accepted the publish")
        #expect(await relay.storedEventCount == 1, "the host's relay engine stored it")
        let received = await firstEvent(stream)
        #expect(
            received?.content == "over the radio",
            "the client got its event back through the host — no router, no internet relay")
        await client.stop()
        await host.stop()
    }

    @Test func twoCompanions_relayThroughOneHost() async throws {
        let relay = LocalRelaySimulator()
        let hub = LocalLinkSimulator()
        let host = NearbyRelayHost(
            link: await hub.makeLink(name: "host"), relay: relay, randomSource: SeededRandomSource(seed: 1))
        let alice = MultipeerRelayClient(
            link: await hub.makeLink(name: "alice"), randomSource: SeededRandomSource(seed: 2))
        let bob = MultipeerRelayClient(
            link: await hub.makeLink(name: "bob"), randomSource: SeededRandomSource(seed: 3))
        try await host.start()
        try await alice.start()
        try await bob.start()
        try await Task.sleep(for: .milliseconds(150))

        // Publish is AUTH-gated (C-5); the publisher authenticates first (default
        // allow-all allowlist). Bob only reads, so he needs no AUTH for kind-1.
        try await alice.authenticate(keypair: try keypair("77"), randomSource: SystemRandomSource())
        let bobStream = await bob.subscribe([NostrFilter(kinds: [1])])
        _ = try await alice.publish(try signed(try keypair("77"), content: "hi bob"))
        let received = await firstEvent(bobStream)
        #expect(
            received?.content == "hi bob",
            "Bob received Alice's message relayed by the host device — the crowded-place use case")

        await alice.stop()
        await bob.stop()
        await host.stop()
    }

    @Test func authenticate_overHub_succeeds() async throws {
        let (_, host, client) = try await makeHostAndClient()
        // Must not throw: the host issues a NIP-42 challenge over the link and
        // verifies the signed kind-22242 answer.
        try await client.authenticate(keypair: try keypair("aa"), randomSource: SystemRandomSource())
        await client.stop()
        await host.stop()
    }

    @Test func authedRecipient_getsGiftWrap_overHub() async throws {
        let (_, host, client) = try await makeHostAndClient()
        let me = try keypair("bb")
        try await client.authenticate(keypair: me, randomSource: SystemRandomSource())
        let stream = await client.subscribe([NostrFilter(kinds: [PQRCConstants.giftWrapEventKind])])
        // A kind-1059 gift wrap p-tagged to me, signed by a fresh one-time key
        // (exactly the real wire shape). The anchor-relay rule must still serve it
        // only to the AUTHed, p-tagged recipient — over the hub, too.
        let oneTime = try keypair("cc")
        let wrap = try signed(
            oneTime, kind: PQRCConstants.giftWrapEventKind, content: "ciphertext",
            tags: [["p", me.publicKeyHex]])
        _ = try await client.publish(wrap)
        let received = await firstEvent(stream)
        #expect(
            received?.id == wrap.id,
            "the authed, p-tagged recipient receives the gift wrap through the hub")
        await client.stop()
        await host.stop()
    }

    @Test func host_sharesItsAI_overHub() async throws {
        // The host offers an AI; a companion uses it over the same link.
        let answer: HubAIAnswer = { system, prompt in "echo: \(prompt)" }
        let (_, host, client) = try await makeHostAndClient(ai: answer)
        try await client.authenticate(keypair: try keypair("ab"), randomSource: SystemRandomSource())
        let reply = await client.requestAI(system: "be brief", prompt: "what's the plan?")
        #expect(reply == "echo: what's the plan?", "the companion used the host's shared AI over Multipeer")
        await client.stop()
        await host.stop()
    }

    @Test func host_withNoAI_repliesNil() async throws {
        let (_, host, client) = try await makeHostAndClient(ai: nil)
        try await client.authenticate(keypair: try keypair("ac"), randomSource: SystemRandomSource())
        let reply = await client.requestAI(system: "x", prompt: "y")
        #expect(reply == nil, "a host not sharing an AI returns no reply")
        await client.stop()
        await host.stop()
    }

    /// After a radio drop + reconnect the companion must keep receiving its
    /// gift-wraps — it re-AUTHs against the host's fresh challenge and re-sends
    /// its subscriptions automatically (the crowded-place reliability fix). Drives
    /// the simulator's co-presence control to model the blip.
    @Test func client_recoversAfterReconnect() async throws {
        let relay = LocalRelaySimulator()
        let hub = LocalLinkSimulator()
        let host = NearbyRelayHost(
            link: await hub.makeLink(name: "host"), relay: relay,
            randomSource: SeededRandomSource(seed: 1))
        let client = MultipeerRelayClient(
            link: await hub.makeLink(name: "client"), randomSource: SeededRandomSource(seed: 2))
        try await host.start()
        try await client.start()
        try await Task.sleep(for: .milliseconds(150))

        let me = try keypair("dd")
        try await client.authenticate(keypair: me, randomSource: SystemRandomSource())
        let stream = await client.subscribe([NostrFilter(kinds: [PQRCConstants.giftWrapEventKind])])

        // Radio drops, then comes back.
        await hub.setCoPresent(NearbyPeerID("host"), NearbyPeerID("client"), false)
        try await Task.sleep(for: .milliseconds(100))
        await hub.setCoPresent(NearbyPeerID("host"), NearbyPeerID("client"), true)
        try await Task.sleep(for: .milliseconds(350))  // hello → re-AUTH → re-subscribe

        // A wrap published AFTER the reconnect still reaches the authed recipient.
        let oneTime = try keypair("ee")
        let wrap = try signed(
            oneTime, kind: PQRCConstants.giftWrapEventKind, content: "after reconnect",
            tags: [["p", me.publicKeyHex]])
        _ = try await client.publish(wrap)
        let received = await firstEvent(stream)
        #expect(
            received?.id == wrap.id,
            "after reconnect the companion re-auths + re-subscribes and still gets its wraps")

        await client.stop()
        await host.stop()
    }

    /// C-5 (audit G1, HIGH): a STRANGER in radio range — one whose pubkey is NOT
    /// in the host owner's paired-contact allowlist — must not be able to AUTH,
    /// even with a perfectly valid kind-22242 signature over the host's challenge.
    /// Without the allowlist a stranger self-AUTHs and then publishes into the
    /// host's store and spends its shared AI. With it, the AUTH is silently
    /// dropped (no `auth_ok`) and the existing un-authed guards reject the peer's
    /// publish and AI request. A paired contact (alice) is unaffected.
    @Test func strangerNotInAllowlist_isRefusedAuthPublishAndAI() async throws {
        let alice = try keypair("a1")
        let mallory = try keypair("33")  // a valid keypair — just not a paired contact

        let relay = LocalRelaySimulator()
        let hub = LocalLinkSimulator()
        let answer: HubAIAnswer = { _, prompt in "echo: \(prompt)" }
        // Allowlist admits ONLY alice; mallory's signature is valid but unapproved.
        let aliceKey = alice.publicKeyHex
        let host = NearbyRelayHost(
            link: await hub.makeLink(name: "host"), relay: relay,
            randomSource: SeededRandomSource(seed: 1), aiAnswer: answer,
            authorize: { $0 == aliceKey })
        // Short host timeout so the refused AUTH (no auth_ok ever arrives) resolves
        // fast instead of waiting out the default 12s.
        let malloryClient = MultipeerRelayClient(
            link: await hub.makeLink(name: "mallory"), randomSource: SeededRandomSource(seed: 2),
            hostTimeoutSeconds: 1)
        try await host.start()
        try await malloryClient.start()
        try await Task.sleep(for: .milliseconds(150))

        // 1) AUTH is refused: the host never sends auth_ok for an unapproved
        // pubkey, so authenticate() resolves un-authed and throws. (The host's
        // `authedPubkey[mallory]` is therefore never set — `private`, so we prove
        // "not authed" through its only observable consequence: the refusal here
        // plus the rejected publish/AI below.)
        await #expect(throws: NostrError.notAuthenticated) {
            try await malloryClient.authenticate(
                keypair: mallory, randomSource: SystemRandomSource())
        }

        // 2) Publish is rejected and the host store is unchanged.
        let storeBefore = await relay.storedEventCount
        let ack = try await malloryClient.publish(try signed(mallory, content: "spam into your store"))
        #expect(!ack.accepted, "the host refused a publish from an un-allowlisted, un-authed stranger")
        #expect(ack.message == "Authenticate first.", "publish gated behind AUTH")
        #expect(
            await relay.storedEventCount == storeBefore,
            "nothing from the stranger landed in the host's store")

        // 3) AI request is refused with the "authenticate first" path (no reply,
        // so the stranger can't spend the host's compute/battery).
        let reply = await malloryClient.requestAI(system: "be brief", prompt: "drain the battery")
        #expect(reply == nil, "the host refused inference for an un-authed stranger")

        await malloryClient.stop()

        // Control: alice IS in the allowlist, so she authenticates and publishes.
        let aliceClient = MultipeerRelayClient(
            link: await hub.makeLink(name: "alice"), randomSource: SeededRandomSource(seed: 3))
        try await aliceClient.start()
        try await Task.sleep(for: .milliseconds(150))
        try await aliceClient.authenticate(keypair: alice, randomSource: SystemRandomSource())
        let aliceAck = try await aliceClient.publish(try signed(alice, content: "i'm a paired contact"))
        #expect(aliceAck.accepted, "a paired, allowlisted contact authenticates and publishes normally")
        #expect(await relay.storedEventCount == 1, "only the paired contact's event is stored")

        await aliceClient.stop()
        await host.stop()
    }
}
