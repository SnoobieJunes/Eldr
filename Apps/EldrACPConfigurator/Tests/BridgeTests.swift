import Foundation
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
