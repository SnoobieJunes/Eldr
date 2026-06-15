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
        ai: HubAIAnswer? = nil
    ) async throws -> (LocalRelaySimulator, NearbyRelayHost, MultipeerRelayClient) {
        let relay = LocalRelaySimulator()
        let hub = LocalLinkSimulator()
        let host = NearbyRelayHost(
            link: await hub.makeLink(name: "host"), relay: relay,
            randomSource: SeededRandomSource(seed: 1), aiAnswer: ai)
        let client = MultipeerRelayClient(
            link: await hub.makeLink(name: "client"), randomSource: SeededRandomSource(seed: 2))
        try await host.start()
        try await client.start()
        try await Task.sleep(for: .milliseconds(150))  // let connect + hello settle
        return (relay, host, client)
    }

    @Test func client_publishesAndReceives_throughNearbyHost() async throws {
        let (relay, host, client) = try await makeHostAndClient()
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
        let reply = await client.requestAI(system: "be brief", prompt: "what's the plan?")
        #expect(reply == "echo: what's the plan?", "the companion used the host's shared AI over Multipeer")
        await client.stop()
        await host.stop()
    }

    @Test func host_withNoAI_repliesNil() async throws {
        let (_, host, client) = try await makeHostAndClient(ai: nil)
        let reply = await client.requestAI(system: "x", prompt: "y")
        #expect(reply == nil, "a host not sharing an AI returns no reply")
        await client.stop()
        await host.stop()
    }
}
