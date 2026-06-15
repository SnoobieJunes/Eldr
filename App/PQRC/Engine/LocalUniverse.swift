import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr

/// The Local Universe (APP-SPEC §15, Debug/demo): seeded personas over an
/// in-process relay + Blossom, with a persona switcher and a scripted demo.
/// Reviewer-facing demo entry stays in Release (TESTFLIGHT-GUIDE §F); chaos
/// controls and the persona switcher are Debug-only surfaces.
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
            let scripted = MockAgentProvider(
                script: MockAgentProvider.Script(
                    draft: "Sounds great — how about Tuesday at noon?",
                    threadTurns: demoThreadTurns(for: name)),
                eager: true)
            let runtime = PersonaRuntime(
                displayName: name,
                transports: [await relay.connect()],
                blobStore: blossom,
                ais: [TetheredAI(id: "demo", name: "\(name)'s AI", provider: scripted)],
                randomSource: SeededRandomSource(seed: UInt64(9000 + index)),
                nonceSource: SeededRandomSource(seed: UInt64(9100 + index)),
                keychainService: "chat.pqrc.universe.\(name.lowercased())")
            // Fresh identities per boot: the demo universe never reuses keys.
            runtime.keychain.deleteAll()
            let model = AppModel(runtime: runtime, personaName: name)
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
        try await alice.runtime.establishWith(bob.runtime, firstMessage: "Hey Bob! Trying out PQRC.")
        try await settle()
        await bob.send("Hey Alice! Post-quantum and everything?", conversationID: alice.myIdentityHex)
        try await settle()
        log("1. Greeting exchange complete")

        // 2. One AI-drafted message, sent as Alice's AI (agent bubble).
        if let draft = await alice.draft(conversationID: bob.myIdentityHex) {
            await alice.sendAsAI(draft, conversationID: bob.myIdentityHex)
        }
        try await settle()
        log("2. AI-drafted message sent as Alice's AI")

        // 3. 30-minute ai_window with the visible banner on every client.
        await alice.startWindow(conversationID: bob.myIdentityHex, minutes: 30)
        try await settle()
        log("3. ai_window active — banner visible to Bob")

        // 4. Shared AI thread: both humans invite their AIs; the agents
        //    exchange context until the loop guard pauses them.
        if let threadID = await alice.createThread(
            conversationID: bob.myIdentityHex, title: "Plan lunch")
        {
            try await settle()
            await alice.inviteAI(threadID: threadID, minutes: 30)
            try await settle()
            await bob.inviteAI(threadID: threadID, minutes: 30)
            // Let the agents talk; the engine's loop guard stops them at 6.
            for _ in 0..<8 {
                try await settle(milliseconds: 120)
            }
            log("4. Shared AI thread ran to the loop guard")
        }

        // 5. >64 KB paste sent as ordered, ratcheted relay chunks (SPEC §11
        //    chunking — no blob server needed; reassembled full on Bob's side).
        let bigPaste = String(repeating: "PQRC large paste demo line.\n", count: 8000)  // ~218 KB
        try? await alice.runtime.sendMessage(bigPaste, conversationID: bob.myIdentityHex)
        try await settle()
        log("5. 200 KB paste sent in encrypted chunks")

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
