// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrUIModel
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

@Suite("Linux parity Phase A (WS-N7)", .serialized)
struct ParityATests {
    @Test func aiContextMarks_coauthoredSend_andPerThreadLoopGuard() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let ai = Recorder("ok")
        await a.client.setProviderOverride(ai)
        try await a.client.say("plan: ship friday", in: "bob")
        try await a.client.say("unmarked chatter", in: "bob")
        // AI off: a private draft sees only what I marked.
        _ = try await a.client.markAIContext(in: "bob", message: try #require(await a.client.history(with: b.client.identityHex).first { $0.text == "plan: ship friday" }?.id), true)
        _ = try await a.client.draftWithMyAI(in: "bob")
        let ctx = await ai.contexts.last
        #expect(ctx?.transcript.map(\.text) == ["plan: ship friday"])
        // The peer mirrors the mark on its copy (content-free control, no new row).
        #expect(await b.log.until { _ in await b.client.history(with: a.client.identityHex).first { $0.text == "plan: ship friday" }?.aiContext == true })
        #expect(await b.client.history(with: a.client.identityHex).filter { $0.text.isEmpty }.isEmpty)

        try await a.client.sendAsMyAI("drafted with my AI", in: "bob")
        #expect(await b.log.until { await $0.texts(agent: true).contains("drafted with my AI") })
        let row = await b.client.history(with: a.client.identityHex).last
        #expect(row?.coauthored == true && row?.agent == true)
        #expect(UIFormat.rowBadge(try #require(row), names: { _ in "Alice" }).text.contains("made with Alice"))

        let t = try await a.client.createThread(in: "bob", title: "t")
        try await a.client.setThreadLoopGuard(t.threadID, limit: 2)
        #expect(await a.client.threads.first?.loopGuardLimit == 2)
        await #expect(throws: EldrClientError.self) { try await a.client.setThreadLoopGuard(t.threadID, limit: 5000) }
    }

    @Test func newerSchemaState_isRefused_andLeftUntouched() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay)
        await a.client.stop()
        let file = a.store.directory.appendingPathComponent("state.enc")
        // Re-save the state with a future schema, as a newer build would.
        var st = try JSONDecoder().decode(ClientState.self, from: try #require(a.store.load(account: "state")))
        #expect(st.schema == ClientState.currentSchema)
        st.schema = ClientState.currentSchema + 1
        try a.store.save(JSONEncoder().encode(st), account: "state")
        let before = try Data(contentsOf: file)
        await #expect(throws: EldrClientError.self) { _ = try await EldrClient(store: a.store, transport: { await relay.connect() }) }
        #expect(try Data(contentsOf: file) == before, "an older build must not rewrite newer state")
        // A stopped client never writes again (late background persist after lock release).
        try await a.client.persist()
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func contactManagement_renameVerifyPinBlockDelete_andSymmetricSafetyCode() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let ca = try await a.client.safetyCode(with: "bob"), cb = try await b.client.safetyCode(with: "alice")
        #expect(ca == cb && ca.split(separator: " ").count == 12 && ca.filter(\.isNumber).count == 60)
        try await a.client.renameContact("bob", to: "Robert")
        #expect(await a.client.contacts.first?.name == "Robert")
        try await a.client.setVerified("Robert", true)
        try await a.client.setPinned("Robert", true)
        let first = await a.client.contacts.first
        #expect(first?.verified == true && first?.pinned == true)
        try await a.client.setBlocked("Robert", true)
        try await b.client.send("while blocked", to: "alice")
        try await Task.sleep(for: .milliseconds(600))
        #expect(await !a.log.texts().contains("while blocked"))
        try await a.client.setBlocked("Robert", false)
        try await b.client.send("after unblock", to: "alice")
        #expect(await a.log.until { await $0.texts().contains("after unblock") })
        let n = try await a.client.deleteHistory(with: "Robert")
        #expect(n >= 1)
        #expect(await a.client.history(with: b.client.identityHex).isEmpty)
        #expect(await a.client.contacts.count == 1, "deleting history is not unfriending")
    }

    @Test func providerKinds_mapToTheVendorProviders() {
        func k(_ kind: String?) -> String {
            String(describing: type(of: EldrClient.makeProvider(AIProviderConfig(baseURL: "http://x/v1", model: "", kind: kind), key: "k")))
        }
        #expect(k(nil) == "CustomOpenAIProvider")
        #expect(k("claude") == "AnthropicAPIProvider")
        #expect(k("openai") == "OpenAIAPIProvider")
        #expect(k("gemini") == "GeminiAPIProvider")
        #expect(k("openrouter") == "OpenRouterAPIProvider")
        #expect(k("groq") == "GroqAPIProvider")
    }

    @Test func contextGrants_areBilateral_andGatePeerAIContentInAWindow() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay), bot = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let ai = Recorder("ok")
        await a.client.setProviderOverride(ai)
        await #expect(throws: EldrClientError.self) { try await a.client.setContextSharing(in: "bob", axis: "ai", seconds: 120) }
        _ = try await a.client.startAIWindow(in: "bob", seconds: 3600)
        // Bob's AI posts (window from Bob), then Bob asks a question.
        let bobAI = Recorder("bob-ai-says-hi")
        await b.client.setProviderOverride(bobAI)
        _ = try await b.client.startAIWindow(in: "alice", seconds: 3600)
        try await a.client.say("hello bob", in: "bob")
        #expect(await a.log.until { await $0.texts(agent: true).contains("bob-ai-says-hi") })
        try await b.client.endAIWindow()
        try await b.client.send("question", to: "alice")
        #expect(await a.log.until { _ in await ai.contexts.contains { $0.transcript.last?.text == "question" } })
        await a.client.settleAI()
        let ctx1 = await ai.contexts.last { $0.transcript.last?.text == "question" }
        #expect(ctx1?.transcript.contains { $0.text == "question" } == true)
        #expect(ctx1?.transcript.contains { $0.text == "bob-ai-says-hi" } == false, "peer AI content needs the ai-axis grant")

        // One-sided grant is not enough; both sides make it flow.
        _ = try await a.client.setContextSharing(in: "bob", axis: "ai", seconds: 3600)
        #expect(await a.client.contextSharedNow(conversationID: b.client.identityHex, threadID: nil, axis: "ai") == false)
        _ = try await b.client.setContextSharing(in: "alice", axis: "ai", seconds: 3600)
        #expect(await a.log.until { _ in await a.client.contextSharedNow(conversationID: b.client.identityHex, threadID: nil, axis: "ai") })
        let live = await a.client.contextGrants(conversationID: b.client.identityHex, threadID: nil, axis: "ai")
        #expect(live.count == 2)
        try await b.client.send("question 2", to: "alice")
        #expect(await a.log.until { _ in await ai.contexts.contains { $0.transcript.last?.text == "question 2" } })
        await a.client.settleAI()
        #expect(await ai.contexts.last { $0.transcript.last?.text == "question 2" }?.transcript.contains { $0.text == "bob-ai-says-hi" } == true)
        // Withdraw mine: it stops again.
        _ = try await a.client.setContextSharing(in: "bob", axis: "ai", seconds: nil)
        #expect(await a.client.contextSharedNow(conversationID: b.client.identityHex, threadID: nil, axis: "ai") == false)
        _ = bot
    }
}

private actor StubBuzzHTTP: BuzzHTTPTransport {
    var responses: [BuzzHTTPResponse]
    init(_ r: [BuzzHTTPResponse]) { responses = r }
    func send(_ request: BuzzHTTPRequest) async throws -> BuzzHTTPResponse {
        responses.isEmpty ? BuzzHTTPResponse(status: 500, body: Data()) : responses.removeFirst()
    }
}

@Suite("Buzz workspaces on Linux (WS-N7)", .serialized)
struct BuzzLinuxTests {
    @Test func join_persistsRecordAndKey_failureLeavesNoKey_forgetDestroysKey() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay)
        let ok = try JSONSerialization.data(withJSONObject: ["status": "joined", "community_id": "c1", "host": "buzz.example", "role": "member"])
        let policyNone = try JSONSerialization.data(withJSONObject: [String: Any]())
        let w = try await a.client.buzzJoin(
            link: "https://buzz.example/invite/CODE123", name: "Team",
            http: StubBuzzHTTP([BuzzHTTPResponse(status: 200, body: policyNone), BuzzHTTPResponse(status: 200, body: ok)]))
        #expect(w.communityID == "c1" && w.role == "member" && w.name == "Team")
        #expect(a.store.load(account: "buzzws.\(w.id)") != nil)
        #expect(await a.client.buzzWorkspaces.count == 1)
        // The key is never in the state blob.
        let blob = try #require(a.store.load(account: "state"))
        let key = try #require(a.store.load(account: "buzzws.\(w.id)"))
        #expect(blob.range(of: Data(key.base64EncodedString().utf8)) == nil && blob.range(of: Data(key.hexString.utf8)) == nil)

        await #expect(throws: (any Error).self) {
            _ = try await a.client.buzzJoin(link: "https://buzz.example/invite/BAD", http: StubBuzzHTTP([]))
        }
        #expect(await a.client.buzzWorkspaces.count == 1)
        let orphans = try FileManager.default.contentsOfDirectory(atPath: a.store.directory.path).filter { $0.hasPrefix("buzzws.") }
        #expect(orphans.count == 1, "a failed claim leaves no orphan key")

        try await a.client.buzzForget("Team")
        #expect(a.store.load(account: "buzzws.\(w.id)") == nil)
        #expect(await a.client.buzzWorkspaces.isEmpty)
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

@Suite("WS-N7a EldrChat parity", .serialized)
struct WSN7aTests {
    @Test func unread_markRead_retry_mentions_relayStatus() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        try await a.client.send("ping @bob and @nobody", to: "bob")
        #expect(await b.log.until { await $0.texts().contains("ping @bob and @nobody") })
        let aHex = a.client.identityHex
        #expect(await b.client.unreadCount(aHex) >= 2)
        let row = await b.client.history(with: aHex).last
        #expect(row?.mentionsMe == true)
        #expect(UIFormat.rowBadge(try #require(row), names: { _ in nil }).text.contains("mentions you"))
        try await b.client.markRead(aHex)
        #expect(await b.client.unreadCount(aHex) == 0)
        // My own messages never count as unread.
        try await b.client.send("pong", to: "alice")
        #expect(await b.client.unreadCount(aHex) == 0)

        // Retry: a "Not sent" row is replaced by a fresh delivery (synthesized failure).
        var failed = HistoryEntry(id: "failed-1", peerIdentityHex: b.client.identityHex, outgoing: true,
                                  text: "second try", sentAt: 1, agent: false, sponsorship: .human)
        failed.failed = true
        await a.client.appendHistory(failed)
        #expect(await a.client.failedMessages().count == 1)
        let r = try await a.client.retry("failed-1")
        #expect(r.reached == 1)
        #expect(await a.client.failedMessages().isEmpty)
        #expect(await b.log.until { await $0.texts().contains("second try") })
        await #expect(throws: EldrClientError.self) { try await a.client.retry("nope") }

        let st = await a.client.relayStatus(check: true)
        #expect(st.status == .connected)
    }

    @Test func multiAI_rosterOrder_orderedCritique_roles_inThread() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let p1 = Recorder("primary says"), p2 = Recorder("second says")
        await a.client.setProviderOverride(p1)
        try await a.client.configureProvider(AIProviderConfig(baseURL: "", model: "", kind: "openai"), apiKey: nil)
        let second = try await a.client.addAI(name: "Critic", config: AIProviderConfig(baseURL: "", model: "", kind: "groq"), apiKey: nil)
        await a.client.setAIOverride(second.id, p2)
        await #expect(throws: EldrClientError.self) { try await a.client.addAI(name: "critic", config: AIProviderConfig(baseURL: "", model: ""), apiKey: nil) }
        await #expect(throws: EldrClientError.self) { try await a.client.addAI(name: "has space", config: AIProviderConfig(baseURL: "", model: "", kind: "openai"), apiKey: nil) }

        let t = try await a.client.createThread(in: "bob", title: "review")
        #expect(await b.log.until { _ in await b.client.threads.contains { $0.threadID == t.threadID } })
        try await a.client.setOrderedCritique(true, in: "bob")
        try await a.client.setAIRoster(["Critic", await a.client.primaryAIName], in: "bob")
        _ = try await a.client.inviteMyAI(thread: t.threadID, seconds: 3600)
        await a.client.settleAI()
        // Roster order: Critic first (role primary, no override), then the primary AI as synthesizer.
        let rows = await a.client.threadHistory(t.threadID).filter { $0.mine == true }
        #expect(rows.map(\.agentName) == ["Critic", await a.client.primaryAIName])
        let c2 = await p2.contexts.last, c1 = await p1.contexts.last
        #expect(c2?.systemPromptOverride == nil)
        #expect(c1?.systemPromptOverride?.isEmpty == false)
        // The synthesizer saw the critic's message first.
        #expect(c1?.transcript.contains { $0.text == "second says" && $0.senderDisplayName == "Critic" } == true)

        // Silence roster → no AI posts.
        try await a.client.setAIRoster([], in: "bob")
        let before = await p1.calls + p2.calls
        try await b.client.say("anyone?", in: "alice", thread: t.threadID)
        #expect(await a.log.until { await $0.texts().contains("anyone?") })
        await a.client.settleAI()
        #expect(await p1.calls + p2.calls == before)
        try await a.client.removeAI("Critic")
        #expect(await a.client.myAIs().count == 1)
    }

    @Test func contextMode_off_and_marked() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let ai = Recorder("auto")
        await a.client.setProviderOverride(ai)
        _ = try await a.client.startAIWindow(in: "bob", seconds: 3600)
        try await a.client.setContextMode("off", in: "bob")
        try await b.client.send("are you there", to: "alice")
        #expect(await a.log.until { await $0.texts().contains("are you there") })
        await a.client.settleAI()
        #expect(await ai.calls == 0)  // off = silent
        let d = try await a.client.draftWithMyAI(in: "bob")
        #expect(d.hasPrefix("draft:"))
        #expect(await ai.contexts.last?.transcript.isEmpty == true)

        try await a.client.setContextMode("marked", in: "bob")
        try await a.client.say("secret plan", in: "bob")
        try await a.client.say("public plan", in: "bob")
        _ = try await a.client.markAIContext(in: "bob", message: try #require(await a.client.history(with: b.client.identityHex).last?.id), true)
        _ = try await a.client.draftWithMyAI(in: "bob")
        #expect(await ai.contexts.last?.transcript.map(\.text) == ["public plan"])
        await #expect(throws: EldrClientError.self) { try await a.client.setContextMode("loud", in: "bob") }
    }

    @Test func soloAIChat_repliesWithoutWindow_andMentionChoice() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let p1 = Recorder("solo primary"), p2 = Recorder("solo helper")
        await a.client.setProviderOverride(p1)
        let h = try await a.client.addAI(name: "Helper", config: AIProviderConfig(baseURL: "", model: "", kind: "openai"), apiKey: nil)
        await a.client.setAIOverride(h.id, p2)
        let g = try await a.client.createSoloAIChat(name: "Me")
        #expect(await a.client.isSolo(UIConversation.group(g.groupID)))
        _ = try await a.client.sendToGroup("help me think", group: g.groupID)
        await a.client.settleAI()
        let rows = await a.client.history.filter { $0.groupID == g.groupID && $0.mine == true }
        #expect(Set(rows.compactMap(\.agentName)) == [await a.client.primaryAIName, "Helper"])
        // @Helper in solo → only Helper answers.
        _ = try await a.client.sendToGroup("@Helper just you", group: g.groupID)
        await a.client.settleAI()
        let last = await a.client.history.filter { $0.groupID == g.groupID && $0.mine == true }.suffix(1)
        #expect(last.first?.agentName == "Helper")
        #expect(await p2.contexts.last?.transcript.last?.text == "@Helper just you")
        // Nothing reached bob.
        #expect(await b.log.texts().allSatisfy { !$0.contains("solo") && !$0.contains("help me think") })

        // @Helper in a regular chat with no window → a choice event, nothing posted.
        let calls = await p2.calls
        try await a.client.send("@Helper what do you think", to: "bob")
        #expect(await a.log.until { await $0.all.contains { if case .aiMentionChoice(_, "Helper") = $0 { return true }; return false } })
        await a.client.settleAI()
        #expect(await p2.calls == calls)
    }
}

@Suite("AC198 one-shot client (no start) runs AI turns", .serialized)
struct OneShotAITests {
    @Test func aiInvite_withoutStart_postsTurn_andSeesReplayedInvite() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay), b = try await node(relay)
        try await pair(a, b, "alice", "bob")
        let t = try await a.client.createThread(in: "bob", title: "oneshot")
        #expect(await b.log.until { _ in await b.client.threads.contains { $0.threadID == t.threadID } })
        await a.client.stop()
        // A CLI-style client: opened, never started.
        let c = try await EldrClient(store: a.store, transport: { await relay.connect() })
        await c.setProviderOverride(Recorder("one-shot reply"))
        _ = try await c.inviteMyAI(thread: t.threadID, seconds: 3600)
        await c.settleAI()
        #expect(await c.threadHistory(t.threadID).contains { $0.mine == true && $0.text == "one-shot reply" })
        #expect(await b.log.until { await $0.texts(agent: true).contains("one-shot reply") })
        await c.stop()
        // A second one-shot open sees the invite replayed (ai-status).
        let d = try await EldrClient(store: a.store, transport: { await relay.connect() })
        #expect(await d.activeInvites(thread: t.threadID)[d.identityHex] != nil)
        await d.stop()
    }
}

@Suite("AC199 early context mark")
struct EarlyMarkTests {
    @Test func markBeforeMessage_isAppliedWhenMessageArrives() async throws {
        let relay = LocalRelaySimulator()
        let a = try await node(relay)
        let peer = "ab" + String(repeating: "c", count: 62)
        await a.client.applyContextMark(AIContextMark(messageID: "m-1", value: true), from: peer)
        var e = HistoryEntry(id: "m-1", peerIdentityHex: peer, outgoing: false, text: "x", sentAt: 0, agent: false, sponsorship: .human)
        await a.client.applyPendingMark(to: &e)
        #expect(e.aiContext == true)
        // Another author can't use someone else's held mark.
        await a.client.applyContextMark(AIContextMark(messageID: "m-2", value: true), from: peer)
        var f = HistoryEntry(id: "m-2", peerIdentityHex: "other", outgoing: false, text: "x", sentAt: 0, agent: false, sponsorship: .human)
        await a.client.applyPendingMark(to: &f)
        #expect(f.aiContext == nil)
    }
}
