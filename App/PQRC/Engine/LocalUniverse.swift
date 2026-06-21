import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr

/// The Local Universe (APP-SPEC §15, Debug/demo): seeded personas over an
/// in-process relay + Blossom, with a persona switcher and a scripted demo.
/// Reviewer-facing demo entry stays in Release (TESTFLIGHT-GUIDE §F); chaos
/// controls and the persona switcher are Debug-only surfaces.
///
/// The scripted demo (`runDemoScript`) is the live counterpart to the onboarding
/// tour: it exercises the CURRENT feature set so the tour has real things to point
/// at — multi-AI tethering with per-AI context profiles, the solo "My AI" chat,
/// curated marked-context + a bilateral context grant (what the in-chat context
/// chip reflects), the egress firewall on a tethered remote AI, agent-to-agent
/// thread skills, plus the original handshake / AI-draft / window / chunking /
/// message-request / group flows. Nothing here is aspirational — every step maps
/// to a shipped capability (DEVIATIONS A19–A36, APP-SPEC §19–24).
@MainActor
final class LocalUniverse {
    let relay: LocalRelaySimulator
    let blossom: LocalBlossomSimulator
    let mirror: LocalBlossomSimulator
    private(set) var models: [AppModel] = []
    var alice: AppModel { models[0] }
    var bob: AppModel { models[1] }

    private(set) var demoLog: [String] = []

    init() {
        relay = LocalRelaySimulator(url: "local://universe")
        blossom = LocalBlossomSimulator(baseURL: "local://blossom-primary")
        mirror = LocalBlossomSimulator(baseURL: "local://blossom-mirror")
    }

    /// Boots Alice, Bob (+ Carol and Dave for the group demo, + Eve who is
    /// nobody's contact — her handshake exercises the message-request gate).
    func boot() async throws {
        await blossom.addMirror(mirror)
        let names = ["Alice", "Bob", "Carol", "Dave", "Eve"]
        for (index, name) in names.enumerated() {
            let runtime = PersonaRuntime(
                displayName: name,
                transports: [await relay.connect()],
                blobStore: blossom,
                ais: demoAIs(for: name, index: index),
                randomSource: SeededRandomSource(seed: UInt64(9000 + index)),
                nonceSource: SeededRandomSource(seed: UInt64(9100 + index)),
                keychainService: "chat.pqrc.universe.\(name.lowercased())",
                siloID: "universe-\(name.lowercased())")
            // Fresh identities per boot: the demo universe never reuses keys.
            runtime.keychain.deleteAll()
            let model = AppModel(
                runtime: runtime, personaName: name, siloID: "universe-\(name.lowercased())")
            try await model.start(inMemoryStore: true)
            models.append(model)
        }
        // Everyone verifies everyone — except Eve, whom nobody knows (D12).
        let known = models.prefix(4)
        for model in known {
            for other in known where other !== model {
                try await model.runtime.addVerifiedPeer(other.runtime)
            }
        }
        // Eve knows Alice (one-directional): her handshake lands as a request.
        try await models[4].runtime.addVerifiedPeer(models[0].runtime)
    }

    /// Each persona's tethered AIs (multi-AI tethering, §20). Alice carries TWO:
    /// a primary on-device participant AND a draft-only "research" AI flagged
    /// `isRemote` so the egress firewall (§21) is on the path it takes — a visible
    /// per-AI context profile. The draft-only AI never auto-posts (it's excluded
    /// from every autonomous loop), so the deterministic core flow is unchanged.
    /// Bob and the others keep a single participating AI.
    private func demoAIs(for name: String, index: Int) -> [TetheredAI] {
        let scripted = MockAgentProvider(
            script: MockAgentProvider.Script(
                draft: "Sounds great — how about Tuesday at noon?",
                threadTurns: demoThreadTurns(for: name)),
            eager: true)
        let primary = TetheredAI(
            id: "demo", name: "\(name)'s AI", provider: scripted,
            instructions: "You are \(name)'s helpful, concise assistant.",
            contextPolicy: "active", outputMode: "participate")
        guard name == "Alice" else { return [primary] }
        // Alice's second tether: a research assistant routed off-device (so the
        // firewall redacts names + byte-bounds context before anything leaves),
        // set to draft-only so it suggests to Alice and never posts on its own.
        let research = TetheredAI(
            id: "demo-research",
            name: "Alice's research AI",
            provider: MockAgentProvider(
                script: MockAgentProvider.Script(draft: "(research) Tuesday is the popular slot.")),
            isRemote: true,
            appliesEgressFirewall: true,  // demo the firewall on the off-device path
            instructions: "Surface options and trade-offs; never decide.",
            contextPolicy: "strict",  // only marked context (privacy-forward default)
            outputMode: "draft")
        return [primary, research]
    }

    private func demoThreadTurns(for name: String) -> [AgentTurn?] {
        // Both agents contribute two context messages each before the loop
        // guard cuts the conversation (APP-SPEC §15).
        switch name {
        case "Alice":
            return [
                AgentTurn(messages: [
                    AgentMessage(
                        text: "Alice is free Tuesday 12–2 PM and Thursday morning.",
                        isContext: true)
                ]),
                AgentTurn(messages: [
                    AgentMessage(text: "Tuesday noon at the usual café works for Alice.")
                ]),
            ]
        case "Bob":
            return [
                AgentTurn(messages: [
                    AgentMessage(
                        text: "Bob's calendar shows a conflict Thursday; Tuesday is open.",
                        isContext: true)
                ]),
                AgentTurn(messages: [
                    AgentMessage(text: "Booked: Tuesday 12 PM. I'll remind Bob that morning.")
                ]),
            ]
        default:
            return []
        }
    }

    // MARK: - Scripted demo (docs/DEMO.md)

    func runDemoScript() async throws {
        func log(_ line: String) { demoLog.append(line) }

        // 1. Greeting exchange (handshake + replies).
        try await alice.runtime.establishWith(bob.runtime, firstMessage: "Hey Bob! Trying out EldrChat.")
        try await settle()
        await bob.send("Hey Alice! Post-quantum and everything?", conversationID: alice.myIdentityHex)
        try await settle()
        log("1. Greeting exchange complete")

        // 2. One AI-drafted message, sent as Alice's AI (agent bubble). The draft
        //    comes from Alice's PRIMARY tethered AI; her draft-only research AI
        //    stays out of the autonomous path.
        if let draft = await alice.draft(conversationID: bob.myIdentityHex) {
            await alice.sendAsAI(draft, conversationID: bob.myIdentityHex)
        }
        try await settle()
        log("2. AI-drafted message sent as Alice's AI (one of two tethered AIs)")

        // 3. 30-minute ai_window with the visible banner on every client.
        await alice.startWindow(conversationID: bob.myIdentityHex, minutes: 30)
        try await settle()
        log("3. ai_window active — banner visible to Bob")

        // 3.5 Curated context + bilateral grant (what the in-chat "AI here" chip
        //     reflects, §20 transparency). Alice marks one of her messages as
        //     AI-shareable, then both sides grant conversation-scoped sharing so
        //     each other's AI may consume the marked context (N23/N24).
        if let aliceMsg =
            (alice.messagesByConversation[bob.myIdentityHex] ?? [])
            .first(where: { $0.senderIdentity == alice.myIdentityHex })
        {
            await alice.markAIContext(
                messageIDs: [aliceMsg.id], value: true, conversationID: bob.myIdentityHex)
        }
        await alice.grantContextSharing(
            scope: .conversation(bob.myIdentityHex), minutes: 30, conversationID: bob.myIdentityHex)
        await bob.grantContextSharing(
            scope: .conversation(alice.myIdentityHex), minutes: 30, conversationID: alice.myIdentityHex)
        try await settle()
        log("3.5 Marked context + bilateral context grant — the AI-here chip has live data")

        // 4. Shared AI thread with PINNED SKILLS (agent-to-agent skills, §23): the
        //    humans pin "plan-sync" so each side's thread-turn AI gets the skill
        //    plus the base PQRC guardrails injected (pure prompt composition — no
        //    new wire format). Both invite their AIs; the agents exchange context
        //    inside the thread only, until the loop guard pauses them.
        if let threadID = await alice.createThread(
            conversationID: bob.myIdentityHex, title: "Plan lunch")
        {
            AppSession.setThreadSkills(
                ["plan-sync"], threadID: threadID, siloID: alice.siloID)
            AppSession.setThreadSkills(
                ["plan-sync"], threadID: threadID, siloID: bob.siloID)
            try await settle()
            await alice.inviteAI(threadID: threadID, minutes: 30)
            try await settle()
            await bob.inviteAI(threadID: threadID, minutes: 30)
            // Let the agents talk; the engine's loop guard stops them at 6.
            for _ in 0..<8 {
                try await settle(milliseconds: 120)
            }
            log("4. Shared AI thread (skill: plan-sync) ran to the loop guard")
        }

        // 4.5 Solo "My AI" chat (the brain icon / member-less group, §20): just
        //     Alice + her tethered AIs, who reply WITHOUT a window because there
        //     is no other human for the autonomous-send gate to protect. Alice's
        //     participating AI answers; her draft-only research AI stays silent.
        if let soloID = await alice.createSelfChat() {
            try await settle()
            await alice.send("What's a good time to grab lunch this week?", conversationID: soloID)
            for _ in 0..<3 {
                try await settle(milliseconds: 120)
            }
            log("4.5 Solo My-AI chat — tethered AI replied with no window needed")
        }

        // 5. >64 KB paste sent as ordered, ratcheted relay chunks (SPEC §11
        //    chunking — no blob server needed; reassembled full on Bob's side).
        let bigPaste = String(repeating: "PQRC large paste demo line.\n", count: 8000)  // ~218 KB
        try? await alice.runtime.sendMessage(bigPaste, conversationID: bob.myIdentityHex)
        try await settle()
        log("5. ~256 KB paste sent in encrypted, bucket-padded chunks")

        // 5.5 Unknown-sender handshake: Eve messages Alice; Alice's client
        //     gates it in Message Requests (D12), no conversation renders.
        try? await models[4].runtime.establishWith(
            alice.runtime, firstMessage: "Hi, you don't know me yet!")
        try await settle()
        log("5.5 Unknown-sender request gated for Alice")

        // 6. Group of 4 with pairwise fan-out.
        for member in [models[2], models[3]] {
            try await alice.runtime.establishWith(member.runtime, firstMessage: "hello!")
            try await settle()
        }
        if let groupID = await alice.createGroup(
            name: "Lunch crew", members: [bob.myIdentityHex, models[2].myIdentityHex, models[3].myIdentityHex])
        {
            try await settle()
            await alice.send("Welcome to the lunch crew 🎉", conversationID: groupID)
            try await settle()
            log("6. Group of 4 fan-out complete")
        }
    }

    private func settle(milliseconds: Int = 60) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
