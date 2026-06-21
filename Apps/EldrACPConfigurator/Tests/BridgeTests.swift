import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrACPConfigurator

@Suite("Bridge — pairing payload + activity formatting")
struct BridgePureTests {

    @Test func pairingPayloadRoundTrips() {
        let payload = PairingPayload(pubkey: "abc123def", relay: "wss://relay.example")
        let json = payload.jsonString()
        #expect(json.contains("abc123def"))
        #expect(PairingPayload.decode(json) == payload)
    }

    @Test func pairingPayloadOptionalRelayRoundTrips() {
        let payload = PairingPayload(pubkey: "deadbeef", relay: nil)
        #expect(PairingPayload.decode(payload.jsonString()) == payload)
    }

    @Test func pairingPayloadRejectsGarbage() {
        #expect(PairingPayload.decode("not json") == nil)
    }

    /// The QR must encode EldrChat's registered `pqrc:add?npub=…` deep link, NOT a
    /// bare JSON blob — a blob is read as plain text by the Camera and web-searched
    /// instead of deep-linking into the app.
    @Test func deepLinkEncodesPqrcScheme() throws {
        let kp = try NostrKeypair(randomSource: SystemRandomSource())
        let link = ACPBridgeService.deepLink(pubkeyHex: kp.publicKeyHex, relay: nil)
        #expect(link == "pqrc:add?npub=\(Bech32.npub(kp.publicKeyHex))&type=coding_agent")
        let comps = URLComponents(string: link)
        #expect(comps?.scheme == "pqrc")
        let npub = comps?.queryItems?.first(where: { $0.name == "npub" })?.value
        #expect(npub?.hasPrefix("npub1") == true)
        // Marks the contact as a coding agent so the phone enables the watch-along path.
        #expect(comps?.queryItems?.first(where: { $0.name == "type" })?.value == "coding_agent")
    }

    @Test func deepLinkCarriesPreferredRelay() {
        let link = ACPBridgeService.deepLink(pubkeyHex: "deadbeef", relay: "wss://relay.example")
        let comps = URLComponents(string: link)
        #expect(comps?.queryItems?.first(where: { $0.name == "relay" })?.value == "wss://relay.example")
    }

    @Test func nostrKeypairGeneratesAndReloads() throws {
        let kp = try NostrKeypair(randomSource: SystemRandomSource())
        #expect(kp.publicKeyHex.count == 64)  // 32-byte x-only pubkey, hex
        #expect(kp.privateKeyData.count == 32)
        let reloaded = try NostrKeypair(privateKey: kp.privateKeyData)
        #expect(reloaded.publicKeyHex == kp.publicKeyHex)  // stable identity
    }

    @Test func agentActivityFormatting() {
        let tool = AgentActivity.toolCall(
            name: "write_file", argsJSON: "{\"path\":\"A.swift\"}", result: "wrote 10 bytes",
            isError: false)
        #expect(tool.contains("write_file"))
        #expect(tool.contains("A.swift"))

        let build = AgentActivity.buildResult(command: "swift build", exitCode: 1, output: "boom")
        #expect(build.contains("build failed"))
        #expect(build.contains("exit 1"))

        let summary = AgentActivity.sessionSummary(summary: "did the thing", filesChanged: 3)
        #expect(summary.contains("3 file"))
        #expect(summary.contains("did the thing"))
    }
}

@Suite("Bridge — agent participant + toggle gating")
struct BridgeSendTests {

    /// Records what the bridge would send, in place of the real PQRC session.
    actor RecordingMessaging: BridgeMessaging {
        struct Sent: Sendable { let text: String; let peer: String; let type: ParticipantType }
        private(set) var sent: [Sent] = []
        func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
            async throws
        { sent.append(Sent(text: body.text, peer: peerIdentityHex, type: participantType)) }
        func all() -> [Sent] { sent }
    }

    @MainActor
    @Test func reportSendsAsAgentParticipantToEnabledConversations() async {
        let recorder = RecordingMessaging()
        let bridge = ACPBridgeService(messaging: recorder)
        bridge.shareToolCalls = true
        bridge.activeConversations = [
            .init(id: "peer-hex-1", name: "Phone", enabled: true),
            .init(id: "peer-hex-2", name: "Muted group", enabled: false),
        ]

        await bridge.reportToolCall(
            name: "write_file", argsJSON: "{}", result: "ok", isError: false)

        let sent = await recorder.all()
        #expect(sent.count == 1)  // only the ENABLED conversation
        // Invariant 8: agent activity is sent with participant_type == .agent.
        #expect(sent.first?.type == .agent)
        #expect(sent.first?.peer == "peer-hex-1")
        #expect(sent.first?.text.contains("write_file") == true)
    }

    @MainActor
    @Test func togglesOffSendNothing() async {
        let recorder = RecordingMessaging()
        let bridge = ACPBridgeService(messaging: recorder)
        // Toggles default OFF — the user hasn't opted in.
        bridge.activeConversations = [.init(id: "p", name: "P", enabled: true)]
        await bridge.reportToolCall(name: "x", argsJSON: "{}", result: "ok", isError: false)
        await bridge.reportBuildResult(command: "swift build", exitCode: 0, output: "")
        await bridge.reportSessionSummary(summary: "s", filesChanged: 1)
        #expect(await recorder.all().isEmpty)
    }
}

// MARK: - Path 2 watch-along bridge: owner gate + per-recipient redaction

@Suite("Bridge — watch-along (owner gate + per-recipient redaction)")
struct BridgeWatchAlongTests {

    actor RecordingMessaging: BridgeMessaging {
        struct Sent: Sendable {
            let text: String
            let peer: String
            let type: ParticipantType
            let isDraft: Bool
            let voiceInto: String?
        }
        private(set) var sent: [Sent] = []
        func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
            async throws
        {
            sent.append(
                Sent(
                    text: body.text, peer: peerIdentityHex, type: participantType,
                    isDraft: body.agentDraft != nil, voiceInto: body.agentDraft?.voiceInto))
        }
        func all() -> [Sent] { sent }
        func text(to peer: String) -> String? { sent.first { $0.peer == peer }?.text }
    }

    /// No-op sink — the bridge does its OWN per-recipient fan-out (§9); the engine here
    /// is only the authorization oracle, never a posting path.
    struct NoopSink: AgentMessageSink {
        func postAgentMessage(_ body: MessageBody, threadID: String, agentName: String?) async throws {}
        func postAgentReply(_ body: MessageBody, agentName: String?) async throws {}
    }

    struct StubRunner: BridgeAgentRunner {
        let answer: String
        func run(prompt: String, workdir: String?) async throws -> String { answer }
    }

    private static let secret = "sk-abc123DEF456ghi789JKL012"

    /// Build a bridge with a live owner window already open, plus the owner/other hexes.
    @MainActor
    private static func openGateBridge(recorder: RecordingMessaging) async throws -> (
        bridge: ACPBridgeService, ownerHex: String, otherHex: String
    ) {
        let clock = FixedClock(now: 1_756_000_000)
        let mac = try PQRCIdentity(seed: Data(repeating: 0x1a, count: 32))
        let owner = try PQRCIdentity(seed: Data(repeating: 0x2b, count: 32))
        let other = try PQRCIdentity(seed: Data(repeating: 0x3c, count: 32))
        let ownerHex = owner.publicKeyData.hexString
        let otherHex = other.publicKeyData.hexString

        let engine = AgentEngine(myIdentity: mac, clock: clock, sink: NoopSink())
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-owner-\(UUID().uuidString)")
        let bridge = ACPBridgeService(messaging: recorder, configDir: tempDir)
        bridge.setOwnerAuthority(engine)
        bridge.setOwnerIdentity(ownerHex)

        // Owner enables their AI → signs a window → bridge routes it into the engine.
        let window = try AIWindowAnnouncement.make(
            activeUntil: clock.now() + 1800, identity: owner)
        await bridge.receiveOwnerWindow(window, fromSenderIdentityHex: ownerHex)
        return (bridge, ownerHex, otherHex)
    }

    @MainActor
    @Test func ownerSeesRawEveryoneElseSeesRedacted() async throws {
        let recorder = RecordingMessaging()
        let (bridge, ownerHex, otherHex) = try await Self.openGateBridge(recorder: recorder)

        let convo = ACPBridgeService.BridgeConversation(
            id: "group-1", name: "Project group", enabled: true,
            members: [ownerHex, otherHex])
        await bridge.broadcastAgentMessage(
            "The API key is \(Self.secret) — use it.", conversation: convo)

        // The owner's session carries the raw secret…
        let ownerText = await recorder.text(to: ownerHex)
        #expect(ownerText?.contains(Self.secret) == true)
        // …every other member's copy is scrubbed.
        let otherText = await recorder.text(to: otherHex)
        #expect(otherText?.contains(Self.secret) == false)
        #expect(otherText?.contains("‹redacted:") == true)
        // Both are agent-labeled (invariant 8).
        #expect(await recorder.all().allSatisfy { $0.type == .agent })
    }

    @MainActor
    @Test func failsClosedWithNoOwnerWindow() async throws {
        let recorder = RecordingMessaging()
        // Owner pinned + engine set, but NO window received → gate shut.
        let clock = FixedClock(now: 1_756_000_000)
        let mac = try PQRCIdentity(seed: Data(repeating: 0x1a, count: 32))
        let owner = try PQRCIdentity(seed: Data(repeating: 0x2b, count: 32))
        let engine = AgentEngine(myIdentity: mac, clock: clock, sink: NoopSink())
        let bridge = ACPBridgeService(
            messaging: recorder,
            configDir: (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-owner-\(UUID().uuidString)"))
        bridge.setOwnerAuthority(engine)
        bridge.setOwnerIdentity(owner.publicKeyData.hexString)

        let convo = ACPBridgeService.BridgeConversation(
            id: "g", name: "g", enabled: true, members: [owner.publicKeyData.hexString])
        await bridge.broadcastAgentMessage("anything", conversation: convo)
        #expect(await recorder.all().isEmpty)  // no live window ⇒ nothing sent
    }

    @MainActor
    @Test func noOwnerPinnedFailsClosed() async throws {
        let recorder = RecordingMessaging()
        let bridge = ACPBridgeService(messaging: recorder)  // no owner, no engine
        let convo = ACPBridgeService.BridgeConversation(
            id: "peer", name: "peer", enabled: true)
        await bridge.broadcastAgentMessage("anything", conversation: convo)
        #expect(await recorder.all().isEmpty)
    }

    @MainActor
    @Test func windowFromNonOwnerIsRejected() async throws {
        let recorder = RecordingMessaging()
        let clock = FixedClock(now: 1_756_000_000)
        let mac = try PQRCIdentity(seed: Data(repeating: 0x1a, count: 32))
        let owner = try PQRCIdentity(seed: Data(repeating: 0x2b, count: 32))
        let stranger = try PQRCIdentity(seed: Data(repeating: 0x9f, count: 32))
        let engine = AgentEngine(myIdentity: mac, clock: clock, sink: NoopSink())
        let bridge = ACPBridgeService(
            messaging: recorder,
            configDir: (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-owner-\(UUID().uuidString)"))
        bridge.setOwnerAuthority(engine)
        bridge.setOwnerIdentity(owner.publicKeyData.hexString)

        // A window the STRANGER signed and tries to deliver — must not open the gate.
        let strangerHex = stranger.publicKeyData.hexString
        let forged = try AIWindowAnnouncement.make(
            activeUntil: clock.now() + 1800, identity: stranger)
        await bridge.receiveOwnerWindow(forged, fromSenderIdentityHex: strangerHex)

        let convo = ACPBridgeService.BridgeConversation(
            id: "g", name: "g", enabled: true, members: [owner.publicKeyData.hexString])
        await bridge.broadcastAgentMessage("secret stuff", conversation: convo)
        #expect(await recorder.all().isEmpty)  // stranger can't authorize the agent
    }

    @MainActor
    @Test func handleInboundPromptDrivesAgentAndFansOut() async throws {
        let recorder = RecordingMessaging()
        let (bridge, ownerHex, otherHex) = try await Self.openGateBridge(recorder: recorder)
        bridge.watchAlongMode = .direct  // Mac-fans-out path (AC20)
        bridge.setAgentRunner(StubRunner(answer: "Found it: \(Self.secret)"))

        let convo = ACPBridgeService.BridgeConversation(
            id: "group-1", name: "Group", enabled: true, members: [ownerHex, otherHex])
        await bridge.handleInboundPrompt(
            "read config.env", conversation: convo, senderIdentityHex: ownerHex)

        // handleInboundPrompt now also sends an "On it…" ack, so assert over ALL
        // messages to each peer (not just the first): the raw answer reached the owner,
        // the redacted answer reached the other, and the secret NEVER reached the other.
        let toOwner = await recorder.all().filter { $0.peer == ownerHex }.map(\.text)
        let toOther = await recorder.all().filter { $0.peer == otherHex }.map(\.text)
        #expect(toOwner.contains { $0.contains(Self.secret) })
        #expect(toOther.contains { $0.contains("‹redacted:") })
        #expect(!toOther.contains { $0.contains(Self.secret) })
    }

    @MainActor
    @Test func endpointModeSendsRawDraftToOwnerOnly() async throws {
        // §13.5: the Mac sends the COMPLETE (raw) answer to the OWNER ONLY, marked as a
        // draft for the phone to voice. No fan-out, no Mac-side redaction. The phone (not
        // tested here) does the redaction + group voicing.
        let recorder = RecordingMessaging()
        let (bridge, ownerHex, otherHex) = try await Self.openGateBridge(recorder: recorder)
        bridge.watchAlongMode = .endpoint
        bridge.setAgentRunner(StubRunner(answer: "Found it: \(Self.secret)"))

        let convo = ACPBridgeService.BridgeConversation(
            id: "group-1", name: "Group", enabled: true, members: [ownerHex, otherHex])
        await bridge.handleInboundPrompt(
            "read config.env", conversation: convo, senderIdentityHex: ownerHex)

        let sent = await recorder.all()
        #expect(sent.count == 1)  // ONLY the owner — the Mac isn't a group participant
        let draft = try #require(sent.first)
        #expect(draft.peer == ownerHex)
        #expect(draft.type == .agent)
        #expect(draft.isDraft)  // carries the AgentDraft marker
        #expect(draft.voiceInto == "group-1")
        #expect(draft.text.contains(Self.secret))  // raw — redaction happens on the phone
        // Nothing went to the other member directly.
        #expect(await recorder.text(to: otherHex) == nil)
    }

    @MainActor
    @Test func nonOwnerPromptIsRejected() async throws {
        // C-3: with the owner's window open, a message from a NON-owner must not task
        // the agent. The owner window governs autonomous *output*; intake must ALSO be
        // owner-only, or any group member could run shell/xcodebuild on the node.
        let recorder = RecordingMessaging()
        let (bridge, _, otherHex) = try await Self.openGateBridge(recorder: recorder)
        bridge.watchAlongMode = .direct
        bridge.setAgentRunner(StubRunner(answer: "Found it: \(Self.secret)"))

        let convo = ACPBridgeService.BridgeConversation(
            id: "group-1", name: "Group", enabled: true, members: [otherHex])
        // A non-owner (otherHex) sends the prompt — must be dropped, no agent run.
        await bridge.handleInboundPrompt(
            "read config.env", conversation: convo, senderIdentityHex: otherHex)
        #expect(await recorder.all().isEmpty)
    }

    @Test func resolveAgentExecutablePrefersLauncherThenBinaryThenBundled() throws {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let bundled = URL(fileURLWithPath: "/bundled/eldr-acp")

        func makeExecutable(_ path: String) throws {
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/zsh\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        // Nothing installed → the app-bundled binary.
        #expect(ACPBridgeService.resolveAgentExecutable(paths: paths, bundled: bundled) == bundled)
        // Installed binary present → preferred over bundled.
        try makeExecutable(paths.installedBinary)
        #expect(
            ACPBridgeService.resolveAgentExecutable(paths: paths, bundled: bundled)?.path
                == paths.installedBinary)
        // Launcher present → preferred over the bare binary (it sources the LLM env).
        try makeExecutable(paths.launcher)
        #expect(
            ACPBridgeService.resolveAgentExecutable(paths: paths, bundled: bundled)?.path
                == paths.launcher)
    }

    @MainActor
    @Test func configureProductionWiresWorkingOwnerEngine() async throws {
        // configureProduction() stands up a real owner-authority engine (random-identity
        // oracle) — prove the gate then opens for a genuine owner-signed window and the
        // fan-out diverges owner-vs-others, with NO engine injected by the test.
        let recorder = RecordingMessaging()
        let bridge = ACPBridgeService(
            messaging: recorder,
            configDir: (NSTemporaryDirectory() as NSString).appendingPathComponent(
                "eldr-owner-\(UUID().uuidString)"))
        bridge.configureProduction()

        let owner = try PQRCIdentity(seed: Data(repeating: 0x2b, count: 32))
        let otherHex = try PQRCIdentity(seed: Data(repeating: 0x3c, count: 32))
            .publicKeyData.hexString
        let ownerHex = owner.publicKeyData.hexString
        bridge.setOwnerIdentity(ownerHex)

        // The engine uses the real clock, so sign a window that's live now.
        let activeUntil = Int64(Date().timeIntervalSince1970) + 1800
        let window = try AIWindowAnnouncement.make(activeUntil: activeUntil, identity: owner)
        await bridge.receiveOwnerWindow(window, fromSenderIdentityHex: ownerHex)
        #expect(await bridge.ownerAuthorized() == true)

        let convo = ACPBridgeService.BridgeConversation(
            id: "g", name: "g", enabled: true, members: [ownerHex, otherHex])
        await bridge.broadcastAgentMessage(
            "key sk-abc123DEF456ghi789JKL012", conversation: convo)
        #expect(await recorder.text(to: ownerHex)?.contains("sk-abc123DEF456ghi789JKL012") == true)
        #expect(await recorder.text(to: otherHex)?.contains("‹redacted:") == true)
    }

    @MainActor
    @Test func ownerIdentityPersistsAcrossInstances() async throws {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-owner-\(UUID().uuidString)")
        let first = ACPBridgeService(configDir: tempDir)
        first.setOwnerIdentity("deadbeefowner")
        #expect(first.ownerIdentityHex == "deadbeefowner")

        // A fresh instance pointed at the same config dir reloads the pinned owner.
        let second = ACPBridgeService(configDir: tempDir)
        #expect(second.ownerIdentityHex == "deadbeefowner")

        // Clearing removes it for the next load too.
        second.setOwnerIdentity(nil)
        let third = ACPBridgeService(configDir: tempDir)
        #expect(third.ownerIdentityHex == nil)
    }
}
