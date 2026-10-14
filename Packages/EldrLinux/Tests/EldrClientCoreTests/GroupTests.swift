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
    #expect(await bBox.wait { await $0.groupTexts(nil).contains("hello") })
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
        #expect(await bb.wait { await $0.rosters.contains { $0.groupID == g.groupID } })
        #expect(await cb.wait { await $0.rosters.contains { $0.groupID == g.groupID } })
        #expect(await b.groups.first?.assertedBy == a.identityHex)

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
        #expect(await bb.wait { await $0.rosters.contains { $0.groupID == g.groupID } })

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
        #expect(await bb.groupTexts(g.groupID) == ["created the group \"pair\""])
        #expect(await bb.groupTexts(nil).contains("spoofed"))
        let roster = await b.groups.first { $0.groupID == g.groupID }
        #expect(roster?.revision == 1 && roster?.name == "pair")
    }

    @Test func oldStateWithoutGroups_decodes() throws {
        let old = #"{"contacts":[],"requests":[],"seenWrapIDs":[],"relays":[]}"#
        let s = try JSONDecoder().decode(ClientState.self, from: Data(old.utf8))
        #expect(s.groups == nil)
        let h = #"{"id":"1","peerIdentityHex":"aa","outgoing":false,"text":"t","sentAt":1,"agent":false,"sponsorship":{"human":{}}}"#
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: Data(h.utf8)).groupID == nil)
    }
}
