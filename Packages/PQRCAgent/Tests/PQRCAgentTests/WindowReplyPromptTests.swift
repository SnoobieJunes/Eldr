import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore

/// Regression coverage for BUG-5 and BUG-6, ported 2026-08-06 from the abandoned
/// `worktree-agent-addb164a1d5addcf5` branch — the only work on any stale branch
/// or stash that had not already re-landed on main. The *fixes* shipped; this
/// coverage did not.
///
/// BUG-6: "my AI would not respond to the other chatter during an active
/// ai_window." The plumbing (engine gate → sink) was always correct and is proven
/// by the `AgentIntegrity` suite — but those tests use the EAGER Demo/Mock
/// providers, which IGNORE the system prompt and always speak. A REAL provider
/// (FoundationModels / Anthropic) builds its turn from `turnSystemPrompt()` and
/// honors "reply exactly PASS to stay silent". Given the shared-thread framing —
/// "you are X's AI in a shared thread with ANOTHER person's AI … or reply exactly
/// PASS" — a real model PASSes when the latest speaker is a human guest, so the
/// AI silently never answered. The App-layer fix injects a window-specific
/// `systemPromptOverride` telling the AI to reply to the person.
///
/// BUG-5: a provider that THREW produced no message AND no reason, so the AI
/// looked dead for the duration of the window timer.
///
/// Two things changed since the original was written, and the port reflects them
/// rather than papering over them:
///
///  1. `runWindowReply` now takes a `conversationID`, pinned at gate-check time so
///     a mid-turn window switch cannot redirect chat A's content into chat B (the
///     F1 TOCTOU). Every call here passes one and asserts the destination.
///  2. `AgentContext.defaultThreadInstructions` is **no longer injected by
///     default** — EldrChat is a conduit, so `turnSystemPrompt()` is the user's
///     instructions or nothing. The BUG-6 scenario therefore has to set those
///     instructions explicitly; that is now a user-chosen configuration rather
///     than the built-in default, which is a real narrowing of the bug's blast
///     radius and is why the test states it outright.
@Suite("ai_window reply prompt (BUG-5 / BUG-6 regression)")
struct WindowReplyPromptTests {

    static let conversationID = "conv-lunch"

    /// Records conversation posts AND the failure diagnostics the engine surfaces.
    /// `AgentMessageSink.reportAgentFailure` has a no-op default, so a sink that
    /// does not override it silently observes nothing — which is exactly the hole
    /// BUG-5 lived in.
    actor WindowSpySink: AgentMessageSink {
        private(set) var conversationPosts: [MessageBody] = []
        private(set) var destinations: [String] = []
        private(set) var failures: [String] = []

        func postAgentMessage(
            _ body: MessageBody, threadID: String, agentName: String?, agentAIID: String?
        ) async throws {}

        func postAgentReply(
            _ body: MessageBody, conversationID: String, agentName: String?, agentAIID: String?
        ) async throws {
            conversationPosts.append(body)
            destinations.append(conversationID)
        }

        func reportAgentFailure(_ reason: String, threadID: String?, agentName: String?) async {
            failures.append(reason)
        }
    }

    /// A prompt-SENSITIVE provider, standing in for a real model: it stays silent
    /// (PASS → nil) under the "shared thread with another person's AI" framing,
    /// and replies under a prompt that tells it to answer the person. This is the
    /// behavior the eager Demo/Mock providers cannot exhibit.
    struct PromptKeyedProvider: AgentProvider {
        func draftReply(context: AgentContext) async throws -> Draft { Draft(text: "draft") }
        func threadTurn(context: AgentContext) async throws -> AgentTurn? {
            // Mimic a real model reading the system prompt: the misleading
            // "shared thread with another person's AI" framing (with no other AI
            // actually present and a human as the latest speaker) makes it decide
            // the turn isn't for it → PASS → nil.
            if context.turnSystemPrompt().contains("shared thread with another person's AI") {
                return nil
            }
            return AgentTurn(messages: [AgentMessage(text: "Sure — how about 1pm?")])
        }
    }

    /// Throws, as an unavailable on-device model or a bad API key would.
    struct FailingProvider: AgentProvider {
        func draftReply(context: AgentContext) async throws -> Draft {
            throw AgentProviderError.unavailable("on-device model unavailable")
        }
        func threadTurn(context: AgentContext) async throws -> AgentTurn? {
            throw AgentProviderError.unavailable("on-device model unavailable")
        }
    }

    /// Always returns nil — a deliberate PASS, never an error.
    struct PassingProvider: AgentProvider {
        func draftReply(context: AgentContext) async throws -> Draft { Draft(text: "x") }
        func threadTurn(context: AgentContext) async throws -> AgentTurn? { nil }
    }

    static func fixture() throws -> (engine: AgentEngine, sink: WindowSpySink) {
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let sink = WindowSpySink()
        return (AgentEngine(myIdentity: alice, clock: clock, sink: sink), sink)
    }

    /// A human guest's message as the latest transcript entry.
    static func guestContext(
        instructions: String? = nil, systemPromptOverride: String? = nil
    ) -> AgentContext {
        AgentContext(
            myIdentityHex: "self", myDisplayName: "Alice",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "peer", senderDisplayName: "Bob",
                    participantType: .human, text: "what time works for lunch?")
            ],
            instructions: instructions,
            systemPromptOverride: systemPromptOverride)
    }

    /// The BUG-6 symptom: shared-thread instructions, no window override → a real
    /// (prompt-sensitive) provider PASSes, so the AI posts NOTHING while the timer
    /// visibly runs.
    @Test func sharedThreadFraming_realProviderStaysSilentDuringWindow() async throws {
        let fx = try Self.fixture()
        _ = try await fx.engine.startMyWindow(durationSeconds: 30 * 60)

        let posted = await fx.engine.runWindowReply(
            provider: PromptKeyedProvider(),
            context: Self.guestContext(instructions: AgentContext.defaultThreadInstructions),
            conversationID: Self.conversationID)

        #expect(!posted, "with the shared-thread framing a real provider PASSes (the BUG-6 symptom)")
        #expect(await fx.sink.conversationPosts.isEmpty)
        #expect(await fx.sink.failures.isEmpty, "a PASS is not a failure")
    }

    /// The fix: the SAME provider and window, but the context carries the
    /// window-specific `systemPromptOverride` the App injects → the AI answers the
    /// guest, in the conversation the context was built from.
    @Test func withWindowOverride_realProviderRepliesToGuest() async throws {
        let fx = try Self.fixture()
        _ = try await fx.engine.startMyWindow(durationSeconds: 30 * 60)

        let posted = await fx.engine.runWindowReply(
            provider: PromptKeyedProvider(),
            context: Self.guestContext(
                instructions: AgentContext.defaultThreadInstructions,
                systemPromptOverride: """
                    You are Alice's AI assistant, and Alice has turned you ON for this \
                    conversation with Bob. Reply helpfully to the most recent message. \
                    Reply exactly PASS only if it clearly needs no response.
                    """),
            conversationID: Self.conversationID)

        #expect(posted, "the window-specific override makes the AI answer the guest")
        let posts = await fx.sink.conversationPosts
        #expect(posts.count == 1)
        #expect(posts.first?.text == "Sure — how about 1pm?")
        #expect(await fx.sink.destinations == [Self.conversationID])
    }

    /// Mechanism check: `turnSystemPrompt()` returns the override verbatim, so the
    /// App's injected window prompt actually reaches the model. This is the link
    /// the fix depends on — if it ever starts composing instead of replacing, the
    /// two tests above would still pass while the real behavior regressed.
    @Test func turnSystemPrompt_returnsOverrideVerbatim() {
        let override = "WINDOW REPLY: answer the person."
        let context = Self.guestContext(
            instructions: AgentContext.defaultThreadInstructions,
            systemPromptOverride: override)
        #expect(context.turnSystemPrompt() == override)
    }

    /// BUG-5: a provider throw during an active window is surfaced through the
    /// sink and posts nothing — so the host can show a reason instead of silence.
    @Test func providerError_isSurfaced_notSwallowed() async throws {
        let fx = try Self.fixture()
        _ = try await fx.engine.startMyWindow(durationSeconds: 30 * 60)

        let posted = await fx.engine.runWindowReply(
            provider: FailingProvider(), context: Self.guestContext(),
            conversationID: Self.conversationID)

        #expect(!posted)
        #expect(await fx.sink.failures == ["on-device model unavailable"])
        #expect(await fx.sink.conversationPosts.isEmpty, "a failure must never post")
    }

    /// A legitimate PASS (nil turn) is NOT an error — no diagnostic may fire, so a
    /// chosen silence never raises a spurious "your AI failed" alert.
    @Test func providerPass_doesNotReportAnError() async throws {
        let fx = try Self.fixture()
        _ = try await fx.engine.startMyWindow(durationSeconds: 30 * 60)

        let posted = await fx.engine.runWindowReply(
            provider: PassingProvider(), context: Self.guestContext(),
            conversationID: Self.conversationID)

        #expect(!posted)
        #expect(await fx.sink.failures.isEmpty, "a deliberate PASS is not an error")
        #expect(await fx.sink.conversationPosts.isEmpty)
    }

    /// Fail-closed: with NO active window, an eager provider still posts nothing
    /// and no failure is reported (the gate is silent by design). Guards against a
    /// future refactor that surfaces gate refusals as provider errors.
    @Test func withoutActiveWindow_repliesAreGatedSilently() async throws {
        let fx = try Self.fixture()

        let posted = await fx.engine.runWindowReply(
            provider: PromptKeyedProvider(), context: Self.guestContext(),
            conversationID: Self.conversationID)

        #expect(!posted)
        #expect(await fx.sink.conversationPosts.isEmpty)
        #expect(await fx.sink.failures.isEmpty, "a closed gate is not a provider failure")
    }
}
