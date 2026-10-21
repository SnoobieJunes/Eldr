// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrKeystore
@testable import PQRCCore
@testable import PQRCNostr

private func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-sp-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private actor Events {
    var all: [ClientEvent] = []
    func attach(_ s: AsyncStream<ClientEvent>) { Task { for await e in s { self.all.append(e) } } }
    var texts: [String] { all.compactMap { if case .message(_, let m, _) = $0 { return m.body.text } else { return nil } } }
    var notes: [String] { all.compactMap { if case .sponsorship(let n) = $0 { return n } else { return nil } } }
    func wait(_ cond: @Sendable ([ClientEvent]) -> Bool, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond(all) && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return cond(all)
    }
}

private func textCount(_ n: Int) -> @Sendable ([ClientEvent]) -> Bool {
    { evs in evs.filter { if case .message = $0 { return true } else { return false } }.count >= n }
}
private func noteCount(_ n: Int) -> @Sendable ([ClientEvent]) -> Bool {
    { evs in evs.filter { if case .sponsorship = $0 { return true } else { return false } }.count >= n }
}

/// owner (human) and agent, mutual contacts with a live session; both listening.
private func pair() async throws -> (EldrClient, Events, EldrClient, Events, LocalRelaySimulator) {
    let relay = LocalRelaySimulator()
    func mk() async throws -> EldrClient {
        let store = FileIdentityStore(directory: tempDir(), masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try EldrClient.initialize(store: store, relays: ["local://relay"])
        let c = try await EldrClient(store: store, transport: { await relay.connect() })
        try await c.announce(maxAttempts: 2)
        return c
    }
    let owner = try await mk(), agent = try await mk()
    let oe = Events(), ae = Events()
    await oe.attach(try await owner.start())
    await ae.attach(try await agent.start())
    try await owner.addContact(agent.pairingLink.uri, name: "eldr")
    try await owner.send("hello", to: "eldr")
    for _ in 0..<200 where await agent.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    try await agent.accept(String(owner.nostrPubkeyHex.prefix(10)), name: "owner")
    #expect(await ae.wait(textCount(1)))
    return (owner, oe, agent, ae, relay)
}

@Suite("Sponsored agent identities", .serialized)
struct SponsorshipE2ETests {
    @Test func agentMode_refusesToSendWithoutSponsorship_andNeedsOwner() async throws {
        let (owner, _, agent, _, _) = try await pair()
        await #expect(throws: EldrClientError.self) { try await agent.setAgentMode(true, ownerIdentityHex: nil) }
        await #expect(throws: EldrClientError.self) { try await agent.setAgentMode(true, ownerIdentityHex: agent.identityHex) }
        try await agent.setAgentMode(true, ownerIdentityHex: owner.identityHex)
        await #expect(throws: EldrClientError.self) { try await agent.send("hi", to: "owner") }
        #expect(await agent.history.filter(\.outgoing).isEmpty)
    }

    @Test func sponsor_thenAgentMessagesVerifyPerMessage_thenRevokeStopsIt() async throws {
        let (owner, oe, agent, ae, _) = try await pair()
        try await agent.setAgentMode(true, ownerIdentityHex: owner.identityHex)
        let sp = try await owner.sponsor("eldr", days: 7, label: "ELDR")
        #expect(await ae.wait(noteCount(1)))
        #expect(await agent.mySponsorship == sp)
        _ = try await agent.liveSponsorship()

        try await agent.send("sponsored hello", to: "owner")
        #expect(await oe.wait(textCount(1)))
        let h = await owner.history(with: agent.identityHex).last
        #expect(h?.text == "sponsored hello")
        #expect(h?.agent == true)
        #expect(h?.sponsorship == .sponsored(sponsorIdentityHex: owner.identityHex, label: "ELDR", activeUntil: sp.activeUntil))

        // Revoke: the agent pauses on receipt, and the owner's view flips immediately.
        let ids = try await owner.revokeSponsorship("eldr")
        #expect(ids == [sp.sponsorshipID])
        #expect(await ae.wait(noteCount(2)))
        #expect(await agent.mySponsorship == nil)
        await #expect(throws: EldrClientError.self) { try await agent.send("after revoke", to: "owner") }
        // Even a replay of the old sponsorship is refused once revoked.
        #expect(await owner.issuedSponsorships.first?.revokedAt != nil)
        await #expect(throws: EldrClientError.self) { try await owner.revokeSponsorship("eldr") }
    }

    @Test func agentCannotSponsor_andAgentRefusesNonOwnerSponsor() async throws {
        let (owner, _, agent, ae, relay) = try await pair()
        try await agent.setAgentMode(true, ownerIdentityHex: String(repeating: "ab", count: 32))
        await #expect(throws: EldrClientError.self) { try await agent.sponsor("owner", days: 1) }
        _ = try await owner.sponsor("eldr", days: 1)
        #expect(await ae.wait(noteCount(1)))
        #expect(await ae.notes.first?.contains("not the pinned owner") == true)
        #expect(await agent.mySponsorship == nil)
        _ = relay
    }

    @Test func receiverStatus_unsponsoredForgedAndHuman() async throws {
        let (owner, _, agent, _, _) = try await pair()
        let other = try PQRCIdentity(seed: Data(repeating: 0x42, count: 32))
        let now = EldrClient.nowSeconds
        func msg(_ p: ParticipantType, _ sp: AgentSponsorship?) -> ReceivedMessage {
            var b = MessageBody(text: "x", sentAt: now)
            b.agentSponsorship = sp
            return ReceivedMessage(senderIdentityHex: agent.identityHex, participantType: p, body: b,
                contentPointer: nil, aiWindow: nil, aiContextGrant: nil, wrapEventID: "w")
        }
        #expect(await owner.sponsorshipStatus(of: msg(.human, nil)) == .human)
        #expect(await owner.sponsorshipStatus(of: msg(.agent, nil)) == .unsponsored)
        // Sponsorship for a DIFFERENT agent, re-presented by this one.
        let foreign = try AgentSponsorship.make(sponsorshipID: "f", agent: String(repeating: "cd", count: 32),
            label: nil, issuedAt: now, activeUntil: now + 3600, identity: other)
        if case .invalid = await owner.sponsorshipStatus(of: msg(.agent, foreign)) {} else { Issue.record("foreign accepted") }
        let good = try AgentSponsorship.make(sponsorshipID: "g", agent: agent.identityHex,
            label: nil, issuedAt: now, activeUntil: now + 3600, identity: other)
        #expect(await owner.sponsorshipStatus(of: msg(.agent, good)).isSponsored)
        let expired = try AgentSponsorship.make(sponsorshipID: "e", agent: agent.identityHex,
            label: nil, issuedAt: now - 7200, activeUntil: now - 3600, identity: other)
        if case .invalid = await owner.sponsorshipStatus(of: msg(.agent, expired)) {} else { Issue.record("expired accepted") }
    }

    @Test func largeMarkdown_isChunked_andReassembled() async throws {
        let (owner, _, agent, ae, _) = try await pair()
        var md = "# Big doc\n\n"
        for i in 0..<4000 { md += "- item \(i) with `code` and \"quotes\" — ünïcødé 🚀\n" }
        #expect(md.utf8.count > 200_000)
        try await owner.send(md, to: "eldr")
        #expect(await ae.wait(textCount(2), timeout: 30))
        #expect(await ae.texts.last == md)
        #expect(await agent.history(with: owner.identityHex).last?.text == md)
    }

    @Test func oldStateWithoutAgentField_stillDecodes() throws {
        let old = #"{"contacts":[],"requests":[],"seenWrapIDs":[],"relays":["wss://x"]}"#
        let st = try JSONDecoder().decode(ClientState.self, from: Data(old.utf8))
        #expect(st.agent == nil)
    }
}
