// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrKeystore
@testable import PQRCCore
@testable import PQRCNostr

private actor Box {
    var all: [ClientEvent] = []
    func attach(_ s: AsyncStream<ClientEvent>) { Task { for await e in s { self.all.append(e) } } }
    func groupTexts(_ gid: String?) -> [String] {
        all.compactMap { if case .message(_, let m, let g) = $0, g == gid { return m.body.text } else { return nil } }
    }
    func hellos(from id: String) -> Bool {
        all.contains { if case .message(_, let m, nil) = $0 { return m.senderIdentityHex == id && m.body.text == "hello" } else { return false } }
    }
    var invites: [GroupRecord] { all.compactMap { if case .groupInvite(let g, _) = $0 { return g } else { return nil } } }
    var rosters: [GroupRecord] { all.compactMap { if case .groupChanged(let g) = $0 { return g } else { return nil } } }
    func wait(_ cond: @Sendable (Box) async -> Bool, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !(await cond(self)) && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return await cond(self)
    }
}

private func client(_ relay: LocalRelaySimulator) async throws -> (EldrClient, Box) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-grp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
    try EldrClient.initialize(store: store, relays: ["local://relay"])
    let c = try await EldrClient(store: store, transport: { await relay.connect() })
    try await c.announce(maxAttempts: 2)
    let b = Box()
    await b.attach(try await c.start())
    return (c, b)
}

/// `a` adds `b` as `name`, says hello, `b` accepts as `back`.
private func link(_ a: EldrClient, _ b: EldrClient, _ bBox: Box, name: String, back: String) async throws {
    try await a.addContact(b.pairingLink.uri, name: name)
    try await a.send("hello", to: name)
    for _ in 0..<300 where await b.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    try await b.accept(String(a.nostrPubkeyHex.prefix(10)), name: back)
    // Wait for THIS sender's hello (a hello from an earlier link must not satisfy it).
    let aID = a.identityHex
    #expect(await bBox.wait { await $0.hellos(from: aID) })
    // Root cause of the onlyAdmins flake: b just spent a one-time prekey. Until its
    // republish lands, the next initiator can draw the SAME OTP from the stale bundle
    // (1-in-16 per list) and its handshake is refused as a replay (AC165/AC167).
    await b.waitForBundleRepublish()
}

@Suite("Group chats (WS-N1)", .serialized)
struct GroupTests {
    @Test func create_send_reply_roster_andFiling() async throws {
        let relay = LocalRelaySimulator()
        let (a, ab) = try await client(relay)
        let (b, bb) = try await client(relay)
        let (c, cb) = try await client(relay)
        try await link(a, b, bb, name: "bob", back: "alice")
        try await link(a, c, cb, name: "carol", back: "alice")

        let (g, reached) = try await a.createGroup(name: "trio", members: ["bob", "carol"])
        #expect(reached == 2)
        #expect(g.members == [a.identityHex, b.identityHex, c.identityHex])
        // AC220: an invite is held until accepted.
        #expect(await bb.wait { await $0.invites.contains { $0.groupID == g.groupID } })
        #expect(await cb.wait { await $0.invites.contains { $0.groupID == g.groupID } })
        #expect(await b.groups.isEmpty)
        try await b.acceptGroupInvite(g.groupID)
        try await c.acceptGroupInvite(g.groupID)
        #expect(await b.groups.first?.assertedBy == a.identityHex)
        #expect(await b.groupHistory(g.groupID).contains { $0.text == "created the group \"trio\"" })

        let sent = try await a.sendToGroup("hi group", group: "trio")
        #expect(sent.reached == 2 && sent.skipped == 0)
        #expect(await bb.wait { await $0.groupTexts(g.groupID).contains("hi group") })
        #expect(await cb.wait { await $0.groupTexts(g.groupID).contains("hi group") })
        // Group rows never leak into the 1:1 history.
        #expect(await !b.history(with: a.identityHex).contains { $0.text == "hi group" })
        #expect(await b.groupHistory(g.groupID).contains { $0.text == "hi group" })

        // Bob doesn't have Carol as a contact: his reply reaches Alice and skips Carol.
        let r = try await b.sendToGroup("reply from bob", group: g.groupID)
        #expect(r.reached == 1 && r.skipped == 1)
        #expect(await ab.wait { await $0.groupTexts(g.groupID).contains("reply from bob") })

        // Removing Carol: she learns (union fan-out) and stops being sent to.
        let g2 = try await a.reviseGroup("trio", remove: ["carol"])
        #expect(g2.revision == 2 && !g2.members.contains(c.identityHex))
        #expect(await cb.wait { await $0.rosters.contains { $0.revision == 2 } })
        #expect(await c.groups.first?.members.contains(c.identityHex) == false)
        let after = try await a.sendToGroup("without carol", group: "trio")
        #expect(after.reached == 1)
    }

    @Test func nonMember_cannotPostIntoAGroup() async throws {
        let relay = LocalRelaySimulator()
        let (a, _) = try await client(relay)
        let (b, bb) = try await client(relay)
        let (m, _) = try await client(relay)
        try await link(a, b, bb, name: "bob", back: "alice")
        try await link(m, b, bb, name: "bob", back: "mallory")
        let (g, _) = try await a.createGroup(name: "pair", members: ["bob"])
        #expect(await bb.wait { await $0.invites.contains { $0.groupID == g.groupID } })
        try await b.acceptGroupInvite(g.groupID)

        // Mallory (Bob's contact, not a member) tags a message with the group id, and
        // also tries to assert a roster that adds herself.
        let bobForM = try await m.contact(matching: "bob")
        _ = try await m.deliver(
            MessageBody(text: "spoofed", sentAt: 1, messageID: "x1", group: RumorContent.GroupRef(id: g.groupID)),
            to: bobForM, participant: .human)
        let forged = GroupCreate(groupID: g.groupID, name: "pwned",
                                 members: [a.identityHex, b.identityHex, m.identityHex], revision: 9)
        _ = try await m.deliver(
            MessageBody(text: "roster", sentAt: 2, messageID: "x2", groupCreate: forged),
            to: bobForM, participant: .human)
        #expect(await bb.wait { await $0.groupTexts(nil).contains("roster") })
        #expect(await bb.groupTexts(g.groupID).isEmpty)
        #expect(await bb.groupTexts(nil).contains("spoofed"))
        let roster = await b.groups.first { $0.groupID == g.groupID }
        #expect(roster?.revision == 1 && roster?.name == "pair")
    }

    /// AC220: a non-admin member cannot change the roster; a declined group stays silent.
    @Test func onlyAdminsChangeRoster_andDeclineDropsPosts() async throws {
        let relay = LocalRelaySimulator()
        let (a, _) = try await client(relay)
        let (b, bb) = try await client(relay)
        let (c, cb) = try await client(relay)
        try await link(a, b, bb, name: "bob", back: "alice")
        try await link(a, c, cb, name: "carol", back: "alice")
        try await link(b, c, cb, name: "carol", back: "bob")
        let (g, _) = try await a.createGroup(name: "admins", members: ["bob", "carol"])
        #expect(await bb.wait { await $0.invites.contains { $0.groupID == g.groupID } })
        #expect(await cb.wait { await $0.invites.contains { $0.groupID == g.groupID } })
        try await b.acceptGroupInvite(g.groupID)
        try await c.acceptGroupInvite(g.groupID)
        // Bob (member, not admin): his own client refuses…
        await #expect(throws: EldrClientError.self) { _ = try await b.reviseGroup(g.groupID, remove: ["carol"]) }
        // …and a forged revision he sends anyway is ignored by Carol.
        let forged = GroupCreate(groupID: g.groupID, name: "bob's now", members: [b.identityHex, c.identityHex],
                                 revision: 5, admins: [b.identityHex])
        _ = try await b.deliver(MessageBody(text: "x", sentAt: 3, messageID: "f1", group: RumorContent.GroupRef(id: g.groupID), groupCreate: forged),
                                to: try await b.contact(matching: "carol"), participant: .human)
        #expect(await cb.wait { await $0.groupTexts(g.groupID).contains("x") })
        let cg = await c.groups.first { $0.groupID == g.groupID }
        #expect(cg?.revision == 1 && cg?.members.count == 3 && cg?.name == "admins")
        // Leaving is always allowed.
        try await b.leaveGroup(g.groupID)
        #expect(await cb.wait { _ in await c.groups.first?.members.contains(b.identityHex) == false })

        // Decline: a second group's posts never surface.
        let (g2, _) = try await a.createGroup(name: "spam", members: ["carol"])
        #expect(await cb.wait { await $0.invites.contains { $0.groupID == g2.groupID } })
        try await c.declineGroupInvite(g2.groupID)
        _ = try await a.sendToGroup("buy now", group: g2.groupID)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await c.groupHistory(g2.groupID).isEmpty)
        #expect(await !c.history.contains { $0.text == "buy now" })
    }

    @Test func oldStateWithoutGroups_decodes() throws {
        let old = #"{"contacts":[],"requests":[],"seenWrapIDs":[],"relays":[]}"#
        let s = try JSONDecoder().decode(ClientState.self, from: Data(old.utf8))
        #expect(s.groups == nil)
        let h = #"{"id":"1","peerIdentityHex":"aa","outgoing":false,"text":"t","sentAt":1,"agent":false,"sponsorship":{"human":{}}}"#
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: Data(h.utf8)).groupID == nil)
    }
}
