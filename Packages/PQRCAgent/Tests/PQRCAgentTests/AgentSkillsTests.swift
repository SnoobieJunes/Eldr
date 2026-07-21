// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCAgent

/// The agent-to-agent skills for shared AI threads (docs/eldrchat-agent-skills.md):
/// a fixed guardrail base injection + a pinnable skill catalog, composed into the
/// thread-turn system prompt. Pure prompt composition — no wire/format change.
@Suite("Agent skills")
struct AgentSkillsTests {
    @Test func catalog_hasTheTwentySkills() {
        #expect(AgentSkills.catalog.count == 20)
        #expect(AgentSkills.skill("plan-sync") != nil)
        #expect(AgentSkills.skill("tech-spec") != nil)
        #expect(AgentSkills.skill("context-export") != nil)
        #expect(AgentSkills.skill("handoff-summary") != nil)
        #expect(AgentSkills.skill("nope") == nil)
        // Every skill carries a non-empty contract fragment.
        #expect(AgentSkills.catalog.allSatisfy { !$0.fragment.isEmpty && !$0.summary.isEmpty })
    }

    @Test func baseInjection_carriesGuardrailsAndScope() {
        let p = AgentSkills.baseInjection(
            displayName: "Alice", contextDomain: "iOS / Xcode", peerName: "Bob", threadID: "t-1")
        #expect(p.contains("Alice"))
        #expect(p.contains("iOS / Xcode"))
        #expect(p.contains("scope:thread:t-1"))
        for guardrail in ["CHANNEL", "SCOPE", "CONTEXT BOUNDARY", "BOUNDED AUTONOMY", "TRANSPARENCY"] {
            #expect(p.contains(guardrail), "base injection includes the \(guardrail) guardrail")
        }
        // No unfilled template placeholders leak into the prompt.
        #expect(!p.contains("{{"))
    }

    @Test func threadSystemPrompt_injectsPinnedSkillAndInstructions() {
        let p = AgentSkills.threadSystemPrompt(
            displayName: "Alice", contextDomain: "iOS", peerName: "Bob", threadID: "t-1",
            activeSkillIDs: ["tech-spec"], instructions: "Be terse.")
        #expect(p.contains("scope:thread:t-1"))
        #expect(p.contains("⟡⟡"), "the shared envelope format is present")
        #expect(p.contains("tech-spec"))
        #expect(p.contains("COMPONENTS"), "the pinned skill's contract fragment is present")
        #expect(p.contains("Be terse."), "the AI's own instructions ride along")
    }

    @Test func threadSystemPrompt_noSkills_keepsGuardrailsAndPASS() {
        let p = AgentSkills.threadSystemPrompt(
            displayName: "A", contextDomain: "", peerName: "", threadID: "t",
            activeSkillIDs: [], instructions: nil)
        #expect(p.contains("CONTEXT BOUNDARY"))
        #expect(p.contains("PASS"), "with no skill pinned the AI may still PASS to stay silent")
    }

    /// The default role ("primary") injects NO role guidance, and an explicit
    /// "primary" produces byte-for-byte the same prompt as the default — backward
    /// compatible for every existing caller.
    @Test func threadSystemPrompt_primary_isDefaultAndUnchanged() {
        let omitted = AgentSkills.threadSystemPrompt(
            displayName: "Alice", contextDomain: "iOS", peerName: "Bob", threadID: "t-1",
            activeSkillIDs: ["tech-spec"], instructions: "Be terse.")
        let explicit = AgentSkills.threadSystemPrompt(
            displayName: "Alice", contextDomain: "iOS", peerName: "Bob", threadID: "t-1",
            activeSkillIDs: ["tech-spec"], instructions: "Be terse.", aiRole: "primary")
        #expect(omitted == explicit)
        #expect(!omitted.contains("ROLE —"), "no role guidance for the default primary role")
    }

    /// A non-primary role appends concise role guidance while preserving the
    /// guardrails, the envelope, and the AI's own instructions.
    @Test func threadSystemPrompt_reviewer_injectsCritiqueGuidance() {
        let p = AgentSkills.threadSystemPrompt(
            displayName: "Alice", contextDomain: "iOS", peerName: "Bob", threadID: "t-1",
            activeSkillIDs: [], instructions: nil, aiRole: "reviewer")
        #expect(p.contains("ROLE — REVIEWER"))
        #expect(p.contains("critique"), "the reviewer is told to critique, not re-solve")
        // Guardrails still present alongside the role text.
        #expect(p.contains("CONTEXT BOUNDARY"))
        #expect(p.contains("⟡⟡"), "the shared envelope is still present")
    }

    @Test func threadSystemPrompt_synthesizer_injectsMergeGuidance() {
        let p = AgentSkills.threadSystemPrompt(
            displayName: "Alice", contextDomain: "iOS", peerName: "Bob", threadID: "t-1",
            activeSkillIDs: [], instructions: nil, aiRole: "synthesizer")
        #expect(p.contains("ROLE — SYNTHESIZER"))
        #expect(p.contains("Merge"), "the synthesizer is told to merge the prior answers")
    }

    /// An unrecognized role is treated like "primary": no guidance, prompt
    /// unchanged (fail-open to the default, never a broken prompt).
    @Test func baseInjection_unknownRole_isUnchanged() {
        let base = AgentSkills.baseInjection(
            displayName: "A", contextDomain: "", peerName: "", threadID: "t")
        let unknown = AgentSkills.baseInjection(
            displayName: "A", contextDomain: "", peerName: "", threadID: "t", aiRole: "bogus")
        #expect(base == unknown)
    }
}
