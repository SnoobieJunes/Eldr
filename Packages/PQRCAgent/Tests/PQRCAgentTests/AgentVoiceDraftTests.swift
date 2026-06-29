import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore
@testable import PQRCNostr

// §13.5 endpoint voicing: the owner's phone takes a draft from its Mac agent and voices
// it to the group. The engine must (a) fail closed without the owner's active window,
// and (b) when open, hand the sink a REDACTED wire body while preserving the raw text
// for the owner's local view.
@Suite("Agent voiceAgentDraft (§13.5)", .tags(.agent))
struct AgentVoiceDraftTests {

    actor DraftSpy: AgentMessageSink {
        struct Voiced: Sendable { let wireText: String; let rawText: String; let threadID: String? }
        private(set) var voiced: [Voiced] = []
        func postAgentMessage(
            _ body: MessageBody, threadID: String, agentName: String?, agentAIID: String?
        ) async throws {}
        func postAgentReply(
            _ body: MessageBody, agentName: String?, agentAIID: String?
        ) async throws {}
        func postAgentDraft(
            _ body: MessageBody, rawText: String, threadID: String?, agentName: String?,
            agentAIID: String?
        ) async throws {
            voiced.append(Voiced(wireText: body.text, rawText: rawText, threadID: threadID))
        }
        func all() -> [Voiced] { voiced }
    }

    private static let secret = "sk-abc123DEF456ghi789JKL012"

    @Test func failsClosedWithoutOwnerWindow() async throws {
        let me = try PQRCIdentity(seed: Data(repeating: 0x11, count: 32))
        let spy = DraftSpy()
        let engine = AgentEngine(myIdentity: me, clock: FixedClock(now: 1_756_000_000), sink: spy)
        #expect(await engine.voiceAgentDraft(rawText: "the key is \(Self.secret)") == false)
        #expect(await spy.all().isEmpty)
    }

    @Test func voicesRedactedOnWireRawForOwnerWhenWindowOpen() async throws {
        let me = try PQRCIdentity(seed: Data(repeating: 0x11, count: 32))
        let spy = DraftSpy()
        let engine = AgentEngine(myIdentity: me, clock: FixedClock(now: 1_756_000_000), sink: spy)
        _ = try await engine.startMyWindow(durationSeconds: 1800)

        #expect(await engine.voiceAgentDraft(rawText: "the key is \(Self.secret)"))
        let voiced = try #require(await spy.all().first)
        // Wire copy is scrubbed; raw is preserved for the owner's local view.
        #expect(!voiced.wireText.contains(Self.secret))
        #expect(voiced.wireText.contains("‹redacted:"))
        #expect(voiced.rawText.contains(Self.secret))
        #expect(voiced.threadID == nil)  // conversation scope
    }

    @Test func threadScopeRequiresOwnerInvite() async throws {
        let me = try PQRCIdentity(seed: Data(repeating: 0x11, count: 32))
        let spy = DraftSpy()
        let engine = AgentEngine(myIdentity: me, clock: FixedClock(now: 1_756_000_000), sink: spy)

        // No invite for the thread → fail closed.
        #expect(await engine.voiceAgentDraft(rawText: "x \(Self.secret)", threadID: "t1") == false)
        // With my invite → voices into the thread, redacted.
        _ = try await engine.startMyInvite(threadID: "t1", durationSeconds: 1800)
        #expect(await engine.voiceAgentDraft(rawText: "x \(Self.secret)", threadID: "t1"))
        let voiced = try #require(await spy.all().first)
        #expect(voiced.threadID == "t1")
        #expect(!voiced.wireText.contains(Self.secret))
    }
}
