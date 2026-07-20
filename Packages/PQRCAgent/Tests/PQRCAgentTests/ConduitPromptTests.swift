// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCAgent

/// EldrChat is a conduit: by default it injects NO system-prompt text on the
/// user's behalf. The per-AI `instructions` field IS the entire system prompt,
/// and is empty by default — so an empty context yields an empty system prompt
/// (DEVIATIONS AC49). These are pure value checks; no network, no engine.
@Suite("Conduit prompts")
struct ConduitPromptTests {
    private func context(instructions: String? = nil, summarize: Bool = false) -> AgentContext {
        AgentContext(
            myIdentityHex: "00", myDisplayName: "Alice", transcript: [],
            instructions: instructions, summarize: summarize)
    }

    @Test func emptyInstructions_yieldEmptySystemPrompts() {
        let ctx = context()
        #expect(ctx.draftSystemPrompt().isEmpty)
        #expect(ctx.turnSystemPrompt().isEmpty)
    }

    @Test func noHardcodedBasePromptLeaks() {
        // The old always-on chaff must NOT appear when the user wrote nothing.
        let ctx = context()
        #expect(!ctx.draftSystemPrompt().contains("You draft brief"))
        #expect(!ctx.turnSystemPrompt().contains("shared thread"))
        #expect(!ctx.turnSystemPrompt().contains("PASS"))
    }

    @Test func userInstructionsAreTheEntireSystemPrompt() {
        let ctx = context(instructions: "Be terse.")
        #expect(ctx.draftSystemPrompt() == "Be terse.")
        #expect(ctx.turnSystemPrompt() == "Be terse.")
    }

    @Test func summarizeModeAppendsItsOwnNote_only() {
        // Summarize is a user-selected behavior, not chaff: it's the ONLY non-user
        // text, and only when the mode is on.
        let off = context(instructions: "Be terse.")
        #expect(!off.draftSystemPrompt().lowercased().contains("summary"))

        let on = context(instructions: "Be terse.", summarize: true)
        #expect(on.draftSystemPrompt().hasPrefix("Be terse."))
        #expect(on.draftSystemPrompt().lowercased().contains("summary"))
    }

    @Test func summarizeWithNoInstructions_isJustTheNote() {
        let ctx = context(summarize: true)
        // No leading user text, no blank-line join chaff.
        #expect(!ctx.draftSystemPrompt().hasPrefix("\n"))
        #expect(ctx.draftSystemPrompt().lowercased().contains("summary"))
    }

    @Test func systemPromptOverrideStillWinsForThreads() {
        let ctx = AgentContext(
            myIdentityHex: "00", myDisplayName: "Alice", transcript: [],
            instructions: "ignored when overridden",
            systemPromptOverride: "GUARDRAILS")
        #expect(ctx.turnSystemPrompt() == "GUARDRAILS")
    }

    @Test func openAIChatMessages_omitsSystemWhenEmpty() {
        let none = openAIChatMessages(system: "", user: "hi")
        #expect(none.count == 1)
        #expect(none.first?["role"] == "user")

        let blank = openAIChatMessages(system: "   \n ", user: "hi")
        #expect(blank.count == 1)  // whitespace-only is still "no system"

        let withSystem = openAIChatMessages(system: "Be terse.", user: "hi")
        #expect(withSystem.count == 2)
        #expect(withSystem.first?["role"] == "system")
        #expect(withSystem.first?["content"] == "Be terse.")
    }

    @Test func acpComposePrompt_omitsSystemHeaderWhenEmpty() {
        let ctx = context()
        let prompt = ACPAgentProvider.composePrompt(system: "", context: ctx)
        #expect(!prompt.contains("[System]"))
        #expect(prompt.contains("[Conversation]"))

        let withSystem = ACPAgentProvider.composePrompt(system: "Be terse.", context: ctx)
        #expect(withSystem.contains("[System]"))
        #expect(withSystem.contains("Be terse."))
    }
}
