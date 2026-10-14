// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrKeystore
@testable import PQRCAgent
@testable import PQRCCore
@testable import PQRCNostr

/// Records every context it was given and (optionally) always speaks.
private actor Recorder: AgentProvider {
    let reply: String
    let eager: Bool
    private(set) var contexts: [AgentContext] = []
    init(_ reply: String, eager: Bool = true) { self.reply = reply; self.eager = eager }
    func draftReply(context: AgentContext) async throws -> Draft { contexts.append(context); return Draft(text: "draft: " + reply) }
    func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        contexts.append(context)
        return eager ? AgentTurn(messages: [AgentMessage(text: reply)]) : nil
    }
    var calls: Int { contexts.count }
}

private actor Log {
    var all: [ClientEvent] = []
    func attach(_ s: AsyncStream<ClientEvent>) { Task { for await e in s { self.all.append(e) } } }
    func texts(agent: Bool? = nil) -> [String] {
        all.compactMap {
            if case .message(_, let m, _) = $0, agent == nil || (m.participantType == .agent) == agent { return m.body.text }
            return nil
        }
    }
    func until(_ f: @Sendable (Log) async -> Bool, timeout: Double = 10) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !(await f(self)) && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return await f(self)
    }
}

private struct Node {
    let client: EldrClient
    let log: Log
    let store: FileIdentityStore
}

private func node(_ relay: LocalRelaySimulator, store existing: FileIdentityStore? = nil) async throws -> Node {
    let store: FileIdentityStore
    if let existing { store = existing } else {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try EldrClient.initialize(store: store, relays: ["local://relay"])
    }
    let c = try await EldrClient(store: store, transport: { await relay.connect() })
    if existing == nil { try await c.announce(maxAttempts: 2) }
    let l = Log()
    await l.attach(try await c.start())
    return Node(client: c, log: l, store: store)
}

private func pair(_ a: Node, _ b: Node, _ an: String, _ bn: String) async throws {
    try await a.client.addContact(b.client.pairingLink.uri, name: bn)
    try await a.client.send("hello", to: bn)
    for _ in 0..<300 where await b.client.requests.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    try await b.client.accept(String(a.client.nostrPubkeyHex.prefix(10)), name: an)
    #expect(await b.log.until { await $0.texts().contains("hello") })
}

@Suite("AI participation on Linux (WS-N2/N3)", .serialized)
struct AITests {
    @Test func window_gatesReplies_seesOnlyPostWindowContext_andCloses() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let ai = Recorder("auto-reply")
        await a.client.setProviderOverride(ai)

        // No window: Bob's message gets no AI reply.
        try await b.client.send("before window: secret plan", to: "alice")
        #expect(await a.log.until { await $0.texts().contains("before window: secret plan") })
        await a.client.settleAI()
        #expect(await ai.calls == 0)

        let until = try await a.client.startAIWindow(in: "bob", seconds: 3600)
        #expect(await b.log.until { await $0.all.contains { if case .aiWindow(_, _, let u) = $0 { return u == until } else { return false } } })
        #expect(await b.client.activeWindows(in: a.client.identityHex)[a.client.identityHex] == until)

        try await b.client.send("question for your AI", to: "alice")
        #expect(await b.log.until { await $0.texts(agent: true).contains("auto-reply") })
        let ctx = await ai.contexts.last
        #expect(ctx?.transcript.contains { $0.text == "question for your AI" } == true)
        #expect(ctx?.transcript.contains { $0.text.contains("secret plan") } == false, "pre-window history never reaches the provider")
        // Bob labels it as Alice's window-authorized AI, not an unsponsored account.
        let row = await b.client.history(with: a.client.identityHex).last { $0.agent }
        #expect(row?.aiAuthorizedUntil == until)

        try await a.client.endAIWindow()
        #expect(await b.log.until { await $0.all.contains { if case .aiWindow(_, _, nil) = $0 { return true } else { return false } } })
        #expect(await b.client.activeWindows(in: a.client.identityHex).isEmpty)
        let before = await ai.calls
        try await b.client.send("after close", to: "alice")
        #expect(await a.log.until { await $0.texts().contains("after close") })
        await a.client.settleAI()
        #expect(await ai.calls == before)
        await #expect(throws: EldrClientError.self) { try await a.client.startAIWindow(in: "bob", seconds: 120) }
    }

    @Test func threads_invites_andLoopGuardBoundsTwoEagerAIs() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        try await a.client.updateSettings(ClientSettings(loopGuardLimit: 3))
        try await b.client.updateSettings(ClientSettings(loopGuardLimit: 3))
        let aAI = Recorder("alice-ai says hi"), bAI = Recorder("bob-ai says hi")
        await a.client.setProviderOverride(aAI)
        await b.client.setProviderOverride(bAI)

        let t = try await a.client.createThread(in: "bob", title: "plan")
        #expect(await b.log.until { await $0.all.contains { if case .threadCreated(let r) = $0 { return r.threadID == t.threadID } else { return false } } })
        try await b.client.inviteMyAI(thread: t.threadID, seconds: 3600)
        #expect(await a.log.until { await $0.all.contains { if case .aiInvite(_, let id, let u) = $0 { return id == t.threadID && u != nil } else { return false } } })
        try await a.client.inviteMyAI(thread: t.threadID, seconds: 3600)

        // Two always-talking AIs: the loop guard (3) must stop the ping-pong.
        try await Task.sleep(for: .seconds(3))
        await a.client.settleAI(); await b.client.settleAI()
        let agentRows = await a.client.threadHistory(t.threadID).filter { $0.agent }.count
        // Each side pauses at 3 consecutive agent messages; two concurrent chains (the
        // invite itself triggers a turn on both sides) can interleave, so ≤ 2×limit.
        #expect(agentRows >= 2 && agentRows <= 6, "loop guard bounds agent turns (saw \(agentRows))")
        try await Task.sleep(for: .seconds(2))
        await a.client.settleAI(); await b.client.settleAI()
        #expect(await a.client.threadHistory(t.threadID).filter { $0.agent }.count == agentRows, "and it stays stopped")
        #expect(await a.client.loopGuardActive(thread: t.threadID))
        // Thread messages stay out of the 1:1 history.
        #expect(await !a.client.history(with: b.client.identityHex).contains { $0.threadID != nil })

        // A human post resumes them.
        try await a.client.say("human back", in: "", thread: t.threadID)
        #expect(await !a.client.loopGuardActive(thread: t.threadID))

        try await a.client.withdrawMyAI(thread: t.threadID)
        #expect(await b.log.until { _ in await b.client.activeInvites(thread: t.threadID)[a.client.identityHex] == nil })
    }

    @Test func forgedAIControls_areIgnored() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let bob = try await b.client.contact(matching: "alice")
        // Agent-labeled with no window: shown, but NOT marked as authorized.
        _ = try await b.client.deliver(MessageBody(text: "rogue agent", sentAt: 1, messageID: "r1"), to: bob, participant: .agent)
        // A thread claiming someone else created it, and an invite for an unknown thread.
        let fake = ThreadCreate(threadID: "T-FAKE", title: "x", anchorMessageID: nil, createdBy: a.client.identityHex)
        _ = try await b.client.deliver(MessageBody(text: "fake thread", sentAt: 2, messageID: "r2", threadCreate: fake), to: bob, participant: .human)
        let inv = try await b.client.signedInvite(threadID: "T-NONE", activeUntil: Int64(Date().timeIntervalSince1970) + 600)
        _ = try await b.client.deliver(MessageBody(text: "bad invite", sentAt: 3, messageID: "r3", aiInvite: inv), to: bob, participant: .human)
        #expect(await a.log.until { await $0.texts().contains("bad invite") })
        let rogue = await a.client.history(with: b.client.identityHex).first { $0.text == "rogue agent" }
        #expect(rogue?.agent == true && rogue?.aiAuthorizedUntil == nil)
        #expect(await a.client.threads.isEmpty)
        #expect(await a.client.activeInvites(thread: "T-NONE").isEmpty)
    }

    @Test func windowAndGrants_surviveRestart_andKeyStaysOutOfState() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let until = try await a.client.startAIWindow(in: "bob", seconds: 8 * 3600)
        let (g, export) = try await a.client.issueTownGrant(to: "bob", planes: [.wall], days: 7)
        #expect(export.contains(g.grantID))
        try await a.client.configureProvider(AIProviderConfig(baseURL: "http://127.0.0.1:1/v1", model: "m"), apiKey: "sk-CANARY-123")
        await #expect(throws: EldrClientError.self) {
            try await a.client.configureProvider(AIProviderConfig(baseURL: "file:///etc/passwd", model: "m"), apiKey: nil)
        }
        await a.client.stop()

        let again = try await node(relay, store: a.store)
        #expect(await again.client.myWindowConversation == b.client.identityHex)
        #expect(await again.client.engine.activeWindow(for: again.client.identityHex) == until)
        #expect(await again.client.townGrants().contains { $0.grantID == g.grantID })
        #expect(await again.client.hasStoredAPIKey)
        let stateBlob = String(decoding: try JSONEncoder().encode(await again.client.state), as: UTF8.self)
        #expect(!stateBlob.contains("sk-CANARY"), "API key never lives in the state blob")
        _ = try await again.client.revokeTownGrant(g.grantID)
        #expect(await !again.client.townGrants().contains { $0.grantID == g.grantID })
        try await again.client.configureProvider(nil, apiKey: nil)
        #expect(await !again.client.hasStoredAPIKey)
        await again.client.stop()
    }

    @Test func settings_validate() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay)
        await #expect(throws: EldrClientError.self) { try await a.client.updateSettings(ClientSettings(loopGuardLimit: -1)) }
        await #expect(throws: EldrClientError.self) { try await a.client.setRelays(["https://x"]) }
        try await a.client.setRelays(["wss://relay.example", "ws://127.0.0.1:7777"])
        try await a.client.updateSettings(ClientSettings(displayName: "Ann", loopGuardLimit: 0))
        #expect(await a.client.settings.displayName == "Ann")
        #expect(await a.client.state.relays.count == 2)
    }

    @Test func aiAccount_cannotSelfActivate() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "owner", "bot")
        try await b.client.setAgentMode(true, ownerIdentityHex: a.client.identityHex)
        await #expect(throws: EldrClientError.self) { try await b.client.startAIWindow(in: "owner", seconds: 3600) }
        await #expect(throws: EldrClientError.self) { try await b.client.issueTownGrant(to: "owner", planes: [.wall], days: 1) }
    }

    @Test func externalAgentBridge_gatesOnSponsorshipOwnerAndLoopGuard() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay), c = try await node(relay)
        try await pair(a, b, "owner", "eldr")
        try await pair(c, b, "carol", "eldr")
        // Human account: the bridge refuses outright.
        await #expect(throws: EldrClientError.self) { try await b.client.bridgeReply("x", to: "owner", thread: nil) }
        try await b.client.setAgentMode(true, ownerIdentityHex: a.client.identityHex)
        let ctx0 = await b.client.bridgeContext(conversationID: a.client.identityHex, threadID: nil)
        #expect(ctx0.refusal != nil && ctx0.ownerPresent)
        await #expect(throws: EldrClientError.self) { try await b.client.bridgeReply("unsponsored", to: "owner", thread: nil) }

        _ = try await a.client.sponsor("eldr", days: 1, label: "ELDR")
        #expect(await b.log.until { _ in (try? await b.client.liveSponsorship()) != nil })
        let t = try await a.client.createThread(in: "eldr", title: "plan")
        #expect(await b.log.until { _ in await b.client.threads.contains { $0.threadID == t.threadID } })
        let ctx = await b.client.bridgeContext(conversationID: a.client.identityHex, threadID: t.threadID)
        #expect(ctx.refusal == nil && ctx.threadTitle == "plan" && ctx.sponsoredUntil != nil)

        // Default limit is 50 (iOS parity): seven consecutive agent turns are fine.
        #expect(EldrClient.defaultLoopGuardLimit == 50)
        for i in 0..<7 { try await b.client.bridgeReply("turn \(i)", to: nil, thread: "plan") }
        #expect(await a.log.until { await $0.texts(agent: true).contains("turn 6") })
        #expect(await a.client.threadHistory(t.threadID).filter { $0.agent }.count == 7)

        // Tight limit: the bridge stops at the guard until a human posts.
        try await b.client.updateSettings(ClientSettings(loopGuardLimit: 8))
        try await b.client.bridgeReply("turn 7", to: nil, thread: "plan")
        await #expect(throws: EldrClientError.self) { try await b.client.bridgeReply("turn 8", to: nil, thread: "plan") }
        try await a.client.say("human again", in: "", thread: t.threadID)
        #expect(await b.log.until { await $0.texts().contains("human again") })
        try await b.client.bridgeReply("after human", to: nil, thread: "plan")

        // Owner absent: no replies into Carol's 1:1.
        let cc = await b.client.bridgeContext(conversationID: c.client.identityHex, threadID: nil)
        #expect(cc.ownerPresent == false && cc.refusal != nil)
        await #expect(throws: EldrClientError.self) { try await b.client.bridgeReply("hi carol", to: "carol", thread: nil) }

        // Revocation stops the bridge.
        _ = try await a.client.revokeSponsorship("eldr")
        #expect(await b.log.until { _ in (try? await b.client.liveSponsorship()) == nil })
        await #expect(throws: EldrClientError.self) { try await b.client.bridgeReply("after revoke", to: nil, thread: "plan") }
    }

    @Test func group_renameAndLeave() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay), c = try await node(relay)
        try await pair(a, b, "alice", "bob")
        try await pair(a, c, "alice", "carol")
        let (g, _) = try await a.client.createGroup(name: "old", members: ["bob", "carol"])
        #expect(await b.log.until { _ in await b.client.groups.contains { $0.groupID == g.groupID } })
        _ = try await a.client.reviseGroup(g.groupID, rename: "new name")
        #expect(await b.log.until { _ in await b.client.groups.first?.name == "new name" })
        try await b.client.leaveGroup(g.groupID)
        #expect(await b.client.groups.isEmpty)
        #expect(await a.log.until { _ in await a.client.groups.first?.members.contains(b.client.identityHex) == false })
        #expect(await a.client.groupHistory(g.groupID).contains { $0.text == "left the group" })
        await #expect(throws: EldrClientError.self) { try await a.client.reviseGroup(g.groupID, rename: "  ") }
    }
}

@Suite("QR encoder (WS-N4)")
struct QRTests {
    /// Every codeword+EC block is a valid RS codeword: zero syndromes at α^0…α^(ec-1).
    @Test func reedSolomon_syndromesAreZero() {
        let data: [UInt8] = Array("pqrc:add?npub=npub1test".utf8)
        for ec in [10, 16, 18, 22, 24, 26] {
            let cw = data + RS.remainder(data, RS.generator(ec))
            for i in 0..<ec {
                var s: UInt8 = 0
                for b in cw { s = RS.mul(s, RS.exp[i]) ^ b }
                #expect(s == 0)
            }
        }
    }

    @Test func versionsAndFinderPatterns() throws {
        #expect(try QRCode.encode("hi").size == 21)
        let link = "pqrc:add?npub=npub1qm2fhmeeem0e3gyzm58sk9gzd9tf82zutt6646mf9vx8ac9axqyq7n6394&relay=wss://relay.lerants.com"
        let q = try QRCode.encode(link)
        #expect(q.size == 45)  // version 7-M (107 bytes)
        for (ox, oy) in [(0, 0), (q.size - 7, 0), (0, q.size - 7)] {
            for i in 0..<7 {
                #expect(q.isDark(ox + i, oy) && q.isDark(ox + i, oy + 6) && q.isDark(ox, oy + i) && q.isDark(ox + 6, oy + i))
            }
            #expect(!q.isDark(ox + 1, oy + 1) && q.isDark(ox + 3, oy + 3))
        }
        #expect(q.isDark(8, q.size - 8))  // the always-dark module
        #expect(throws: QRCode.EncodeError.self) { try QRCode.encode(String(repeating: "x", count: 300)) }
    }

    /// Format info decodes back to level M + some mask (BCH-checked).
    @Test func formatInfoIsValid() throws {
        let q = try QRCode.encode("hello")
        var bits = 0
        let pos = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8), (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
        for (i, p) in pos.enumerated() where q.isDark(p.0, p.1) { bits |= 1 << i }
        let raw = bits ^ 0x5412
        #expect(raw >> 13 == 0b00)
        var rem = raw >> 10
        for _ in 0..<10 { rem = (rem << 1) ^ ((rem >> 9) * 0x537) }
        #expect((raw >> 10) << 10 | rem == raw)
    }
}
