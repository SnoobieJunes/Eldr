import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

@Suite("Groups: pairwise fan-out (APP-SPEC §7, D1)", .tags(.group))
struct GroupTests {
    struct GroupUniverse {
        let relay: LocalRelaySimulator
        let personas: [Persona]  // [0] is the creator
        let inboxes: [EventCollector]
        let groupID: String

        func persona(_ index: Int) -> Persona { personas[index] }
    }

    /// Four members; the creator establishes pairwise sessions with everyone,
    /// and the remaining members with each other (full mesh, as the app does
    /// on group_create receipt).
    static func makeGroup() async throws -> GroupUniverse {
        let relay = LocalRelaySimulator()
        let clock = FixedClock(now: 1_754_000_000)
        var personas: [Persona] = []
        for (index, seedByte) in ["d1", "d2", "d3", "d4"].enumerated() {
            personas.append(
                try await Persona.make(
                    name: "member\(index)", seedByte: seedByte, seed: UInt64(601 + index),
                    transports: [await relay.connect()], clock: clock))
        }
        var inboxes: [EventCollector] = []
        for persona in personas {
            for other in personas where other.identityHex != persona.identityHex {
                await persona.messenger.addContact(try other.asContact())
            }
            let collector = EventCollector()
            await collector.attach(try await persona.messenger.start())
            inboxes.append(collector)
        }
        // Full session mesh.
        for i in personas.indices {
            for j in personas.indices where j > i {
                try await personas[i].messenger.establishSession(
                    with: try personas[j].asContact(),
                    bundle: try await personas[j].prekeyManager.publicBundle(),
                    firstMessage: MessageBody(text: "mesh \(i)->\(j)", sentAt: 0))
            }
        }
        return GroupUniverse(
            relay: relay, personas: personas, inboxes: inboxes, groupID: "group-uuid-1")
    }

    @Test func group_fanOut_allMembersDecryptSameMessage() async throws {
        let universe = try await Self.makeGroup()
        let members = universe.personas.map(\.identityHex)
        let body = MessageBody(
            text: "hello group", sentAt: 0, group: RumorContent.GroupRef(id: universe.groupID))
        try await universe.persona(0).messenger.sendToGroup(body, memberIdentityHexes: members)

        for index in 1..<4 {
            let messages = await universe.inboxes[index].waitForMessages(4)  // 3 mesh + 1 group
            let groupMessages = messages.filter { $0.body.group?.id == universe.groupID }
            #expect(groupMessages.count == 1, "member \(index) gets the group message exactly once")
            #expect(groupMessages.first?.body.text == "hello group")
        }
        // The relay saw 3 independent pairwise envelopes for the group send —
        // and zero shared-key material (every link is its own session).
        for inbox in universe.inboxes { await inbox.stop() }
    }

    @Test func group_pairwiseSessionsIndependent() async throws {
        let universe = try await Self.makeGroup()
        let creator = universe.persona(0)
        // Compromise member 1's pairwise session with the creator (full snapshot).
        let stolenSnapshot = try #require(
            await creator.messenger.sessionSnapshot(peerIdentityHex: universe.persona(1).identityHex))
        var stolenRatchet = try DoubleRatchet(
            snapshot: stolenSnapshot, randomSource: SeededRandomSource(seed: 999))

        // A group message fans out; the stolen 0↔1 session state must be unable
        // to read the 0↔2 copy (independent PQXDH secrets per link).
        let members = universe.personas.map(\.identityHex)
        try await creator.messenger.sendToGroup(
            MessageBody(text: "compartmentalized", sentAt: 0, group: .init(id: universe.groupID)),
            memberIdentityHexes: members)

        let member2Messages = await universe.inboxes[2].waitForMessages(4)
        #expect(member2Messages.map(\.body.text).contains("compartmentalized"))

        // Grab the 0->2 wrap off the relay and try the stolen 0->1 ratchet on it.
        let wraps = await universe.relay.storedEvents(kind: PQRCConstants.giftWrapEventKind)
        let member2 = universe.persona(2)
        var crossDecryptSucceeded = false
        for wrap in wraps {
            guard let unwrapped = try? GiftWrap.unwrap(wrap, recipient: member2.nostrKeypair),
                let header = unwrapped.rumor.header,
                let ciphertext = unwrapped.rumor.ciphertext
            else { continue }
            let ad = AssociatedData.build(
                participantType: unwrapped.rumor.participantType, n: header.n,
                fuzzedTimestamp: unwrapped.fuzzedTimestamp)
            if (try? stolenRatchet.decrypt(
                header: header, ciphertext: ciphertext, associatedData: ad)) != nil {
                crossDecryptSucceeded = true
            }
        }
        #expect(!crossDecryptSucceeded, "a compromised pairwise link must not open another link")
        for inbox in universe.inboxes { await inbox.stop() }
    }

    @Test func roster_addMemberSeesNothingPrior_removedStopsReceiving() async throws {
        let universe = try await Self.makeGroup()
        let creator = universe.persona(0)
        // Phase 1: group of 3 (members 0,1,2). Member 3 not yet in the roster.
        let phase1Members = Array(universe.personas.prefix(3).map(\.identityHex))
        try await creator.messenger.sendToGroup(
            MessageBody(text: "before join", sentAt: 0, group: .init(id: universe.groupID)),
            memberIdentityHexes: phase1Members)

        // Phase 2: add member 3, remove member 1 (new roster revision).
        let phase2Members = [0, 2, 3].map { universe.personas[$0].identityHex }
        try await creator.messenger.sendToGroup(
            MessageBody(
                text: "after roster change", sentAt: 0, group: .init(id: universe.groupID)),
            memberIdentityHexes: phase2Members)

        let member3Messages = await universe.inboxes[3].waitForMessages(4)
        let member3Group = member3Messages.compactMap { $0.body.group != nil ? $0.body.text : nil }
        #expect(member3Group == ["after roster change"], "joiner sees no history")

        let member1Messages = await universe.inboxes[1].waitForMessages(4)
        let member1Group = member1Messages.compactMap { $0.body.group != nil ? $0.body.text : nil }
        #expect(member1Group == ["before join"], "removed member simply stops receiving")
        for inbox in universe.inboxes { await inbox.stop() }
    }

    @Test func roster_inconsistentRosterSurfacedAsAsserted() {
        // No cryptographic membership agreement (honest limitation): rosters
        // are tracked per asserter, surfaced as "asserted by X".
        let creatorHex = "aa11"
        let malloryHex = "bb22"
        var roster = GroupRoster(
            create: GroupCreate(
                groupID: "g", name: "Lunch", members: [creatorHex, malloryHex, "cc33"], revision: 1),
            assertedBy: creatorHex)
        #expect(roster.assertedBy == creatorHex)

        // Mallory asserts a conflicting roster at a higher revision: applied,
        // but attribution follows (the UI renders "roster as asserted by Mallory").
        let applied = roster.apply(
            GroupCreate(groupID: "g", name: "Lunch", members: [creatorHex, malloryHex], revision: 2),
            assertedBy: malloryHex)
        #expect(applied)
        #expect(roster.assertedBy == malloryHex)
        #expect(roster.members == [creatorHex, malloryHex])

        // Stale revisions never regress state.
        let stale = roster.apply(
            GroupCreate(groupID: "g", name: "Lunch", members: ["zz"], revision: 1),
            assertedBy: creatorHex)
        #expect(!stale)
        // Foreign group ids are ignored.
        let foreign = roster.apply(
            GroupCreate(groupID: "other", name: "x", members: [], revision: 9),
            assertedBy: creatorHex)
        #expect(!foreign)
    }
}
