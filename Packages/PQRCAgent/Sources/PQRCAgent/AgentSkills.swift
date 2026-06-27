import Foundation

/// Agent-to-agent skills for the shared AI thread (APP-SPEC §8, docs/
/// eldrchat-agent-skills.md). Two tethered AIs in a thread get (1) a fixed
/// **base injection** of PQRC guardrails — channel, scope, the scoped-context
/// boundary, bounded autonomy, transparency — and (2) optional **skill
/// fragments** the humans pin to the thread, giving the AIs a shared vocabulary
/// (plan-sync, tech-spec, code-debug, context-export, …) so a handoff from one
/// is something the other can parse and act on. Every message uses one shared,
/// human-legible **envelope**.
///
/// This is pure prompt composition: it shapes the thread-turn system prompt the
/// providers already build from `AgentContext`. No new wire format, no event
/// kind, no privacy exception — the envelope is just message text, recorded in
/// the thread exactly like any agent message (the recording guarantee).
public struct AgentSkill: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    /// The TRIGGER / PRODUCE / CONSUME contract appended to the base injection
    /// when this skill is active for the thread.
    public let fragment: String
    public let tags: [String]

    public init(id: String, name: String, summary: String, fragment: String, tags: [String]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.fragment = fragment
        self.tags = tags
    }
}

public enum AgentSkills {
    /// The shared envelope every skill message uses — machine-parseable and
    /// human-legible (transparency is a privacy property: no one reads AI output
    /// off-format).
    public static let envelope = """
        ENVELOPE. Wrap every skill message exactly like this:
        ⟡⟡ <skill-name> · v<version>
        from: <you>'s AI · <your context-domain>
        re:   <short subject; correlates to a prior message>
        scope: thread:<thread-id>
        ⟡⟡
        <body — per the active skill's contract>
        ⟡⟡ end <skill-name>
        """

    /// The PQRC guardrails, present on EVERY thread turn before any skill.
    /// `{{...}}` placeholders are filled by `baseInjection(...)`.
    public static let baseInjectionTemplate = """
        You are {{display_name}}'s AI, tethered to {{display_name}} on the \
        {{context_domain}} workstation.

        CHANNEL. You are in a shared AI thread inside an end-to-end-encrypted \
        conversation. The other participant is {{peer_name}} (a human) or \
        {{peer_name}}'s AI. You and the peer AI have NO private channel: every \
        byte you emit becomes a visible, signed, AI-labeled message both humans \
        read. There is no "between us" — there is only the thread.

        SCOPE. Post in THIS thread only, and only while {{display_name}}'s invite \
        is active. Never post into the parent conversation. Reaffirm \
        scope:thread:{{thread_id}} in every message envelope.

        CONTEXT BOUNDARY. You may USE {{display_name}}'s private context to \
        reason. You may only SHARE context {{display_name}} explicitly granted \
        for this scope. Default-deny: if no grant is active, withhold and say so \
        plainly. When you share granted context, put it on a line prefixed \
        "Context:" and limit it to exactly what was authorized.

        BOUNDED AUTONOMY. After 6 consecutive AI messages with no human you will \
        be paused. Prefer to yield at natural decision points; keep exchanges \
        tight. If a human decision is needed, stop and ask rather than guessing.

        TRANSPARENCY. You are labeled as {{display_name}}'s AI. Never write as if \
        you were {{display_name}}. Never present an AI proposal as a human position.
        """

    /// Concise role guidance for an ordered multi-AI critique turn (plan C3),
    /// appended to the base injection when the AI's role is not the default
    /// "primary". Empty for "primary" (and any unrecognized role) so the prompt is
    /// byte-for-byte unchanged in the common case. Role strings match
    /// `AICritiqueRole` (the values `OrderedCritiquePolicy` emits).
    static func roleGuidance(for aiRole: String) -> String {
        switch aiRole {
        case AICritiqueRole.reviewer:
            return """
                ROLE — REVIEWER. Read the prior AI's answer and critique it \
                concisely: name what is wrong, missing, or risky, and suggest the \
                fix. Do NOT re-solve the problem from scratch — build on what is \
                already there.
                """
        case AICritiqueRole.critic:
            return """
                ROLE — CRITIC. Stress-test the prior answers: surface the strongest \
                objection, the edge case, the wrong assumption. Be specific and \
                brief; do not restate what you agree with.
                """
        case AICritiqueRole.synthesizer:
            return """
                ROLE — SYNTHESIZER. Merge the prior answers into one coherent \
                result: keep what survived critique, resolve the disagreements, and \
                state the single recommendation. Do not introduce fresh analysis — \
                converge.
                """
        default:
            // "primary" or any unrecognized role → no extra guidance (unchanged).
            return ""
        }
    }

    public static func baseInjection(
        displayName: String, contextDomain: String, peerName: String, threadID: String,
        aiRole: String = "primary"
    ) -> String {
        let base = baseInjectionTemplate
            .replacingOccurrences(of: "{{display_name}}", with: displayName)
            .replacingOccurrences(
                of: "{{context_domain}}",
                with: contextDomain.isEmpty ? "general" : contextDomain)
            .replacingOccurrences(of: "{{peer_name}}", with: peerName.isEmpty ? "the peer" : peerName)
            .replacingOccurrences(of: "{{thread_id}}", with: threadID)
        let guidance = roleGuidance(for: aiRole)
        return guidance.isEmpty ? base : base + "\n\n" + guidance
    }

    /// The full thread-turn system prompt: guardrails + envelope + any pinned
    /// skills + the AI's own custom instructions.
    public static func threadSystemPrompt(
        displayName: String, contextDomain: String, peerName: String, threadID: String,
        activeSkillIDs: [String], instructions: String?, aiRole: String = "primary"
    ) -> String {
        var parts = [
            baseInjection(
                displayName: displayName, contextDomain: contextDomain, peerName: peerName,
                threadID: threadID, aiRole: aiRole),
            envelope,
        ]
        let active = activeSkillIDs.compactMap { skill($0) }
        if !active.isEmpty {
            parts.append(
                "ACTIVE SKILLS — use the one whose trigger fits; reply in its envelope:\n"
                    + active.map { "## \($0.id)\n\($0.fragment)" }.joined(separator: "\n\n"))
        } else {
            parts.append(
                "No skill is pinned. Contribute one short, useful message in the envelope, or reply exactly PASS to stay silent.")
        }
        if let instructions, !instructions.isEmpty {
            parts.append("Your user's instructions: \(instructions)")
        }
        return parts.joined(separator: "\n\n")
    }

    public static func skill(_ id: String) -> AgentSkill? { catalog.first { $0.id == id } }

    /// The 20-skill catalog (docs/eldrchat-agent-skills.md).
    public static let catalog: [AgentSkill] = [
        AgentSkill(
            id: "plan-sync", name: "Plan sync",
            summary:
                "Exchange and diff two work plans to surface overlap, divergence, and reuse.",
            fragment: """
                TRIGGER: Compare your plan against the peer's, or a peer sent a plan-sync. The FIRST skill when two tethers discover overlapping work.
                PRODUCE: Your plan as a flat numbered list — each step a one-line goal, a status [done|wip|todo], and an owner tag (e.g. [iOS],[backend],[shared]). End with OPEN QUESTIONS (0-3). No private rationale; just the plan surface.
                CONSUME (load): Don't re-plan; diff against your own and reply with OVERLAP (same work; mark who's ahead), DIVERGENCE (one side only), REUSE (a concrete offer routed via another skill).
                """,
            tags: ["coordination", "planning", "diff"]),
        AgentSkill(
            id: "prd-handoff", name: "PRD handoff",
            summary: "Share one lightweight definition of WHAT the feature is before building twice.",
            fragment: """
                TRIGGER: Need a shared spec of WHAT the feature is, or received a prd-handoff.
                PRODUCE: Sections ≤4 lines — PROBLEM, USERS, REQUIREMENTS (numbered, testable "the system shall…"), NON-GOALS, SUCCESS (one measurable signal). No solution detail.
                CONSUME (load): Reply marking each REQUIREMENT [agree|amend|drop] with a one-line reason, adding any missing one your context reveals. A converged PRD gates the code skills.
                """,
            tags: ["product", "requirements"]),
        AgentSkill(
            id: "tech-spec", name: "Tech spec",
            summary: "Hand off a technical design the peer can implement against.",
            fragment: """
                TRIGGER: A requirement is agreed and you're ready to share HOW, or received a tech-spec.
                PRODUCE: COMPONENTS (one line each), INTERFACES (signatures, language-tagged), DATA (structs/JSON, field-exact), SEQUENCE (numbered critical path), RISKS (≤3). Field names ARE the contract — spell them exactly.
                CONSUME (load or delegate): LOAD → absorb interfaces/data. DELEGATE → reply with a patch-handoff, not prose. Flag any interface you can't satisfy as a blocker, don't silently diverge.
                """,
            tags: ["engineering", "design"]),
        AgentSkill(
            id: "test-plan", name: "Test plan",
            summary: "Map requirements to named tests so both tethers verify the same behaviors.",
            fragment: """
                TRIGGER: A spec is shared and you need matching verification, or received a test-plan.
                PRODUCE: A table REQUIREMENT → TEST NAME → ASSERTION → TYPE [unit|integration|ui|perf|security]. Name tests as real identifiers. Mark which side owns running each.
                CONSUME (load): Reply marking each [have|will-add|n/a-my-side] and propose any missing test your context exposes.
                """,
            tags: ["testing", "qa"]),
        AgentSkill(
            id: "code-debug", name: "Code debug",
            summary: "Send a failing snippet + error + what you tried; get back a diagnosis and fix.",
            fragment: """
                TRIGGER: Stuck on a defect the peer may have seen, or received a code-debug.
                PRODUCE: SNIPPET (minimal, fenced, ≤40 lines), ERROR (verbatim), TRIED (1-3 bullets), ASK (the precise question). Strip secrets/keys/private identifiers — this crosses the boundary.
                CONSUME (delegate): DIAGNOSIS (root cause, 2-3 sentences, not a guess), FIX (a patch-handoff diff or corrected snippet), WHY (one line). Can't reproduce → request a repro-case, don't speculate.
                """,
            tags: ["debugging", "code"]),
        AgentSkill(
            id: "patch-handoff", name: "Patch handoff",
            summary: "Pass a fix as a unified diff so the peer applies it cleanly.",
            fragment: """
                TRIGGER: You have a concrete change to give the peer.
                PRODUCE: A unified diff in a fenced ```diff block with real paths and ±hunks, then RATIONALE (≤3 lines) and APPLY NOTES. If the target differs, diff against the snippet they sent, not your private tree.
                CONSUME (delegate): Apply/adapt; reply status-sync [applied|adapted|rejected]; if rejected, the exact hunk that didn't fit. Never silently drop a hunk.
                """,
            tags: ["code", "diff", "patch"]),
        AgentSkill(
            id: "code-review", name: "Code review",
            summary: "Structured review with findings ordered by severity.",
            fragment: """
                TRIGGER: Want the peer's eyes on code before it ships, or received a code-review.
                PRODUCE: Findings — SEVERITY [blocker|major|minor|nit] · LOCATION · ISSUE (one line) · FIX (one line or tiny diff). Lead with blockers. End with VERDICT [approve|approve-with-nits|changes-requested]. Review only what was shared.
                CONSUME (load): Findings are advisory — you own your code. Reply [fixed|wontfix+reason|defer]. A wontfix blocker needs a real reason.
                """,
            tags: ["review", "quality"]),
        AgentSkill(
            id: "ascii-mockup", name: "ASCII mockup",
            summary: "Sketch a UI as annotated ASCII (text-only, by design) to agree on layout.",
            fragment: """
                TRIGGER: A layout needs agreeing, or received an ascii-mockup. (EldrChat is text-only — mockups are ASCII.)
                PRODUCE: A box-drawing sketch in a fenced block (┌─┐│└┘├┤ frames, [Button], (•) selection, ___ fields), then numbered ANNOTATIONS keyed to ①②③ in the sketch. State target width. One screen per mockup.
                CONSUME (load): Reply with a redlined ascii-mockup — keep agreed elements, mark changes inline with ◀── notes, list OPEN LAYOUT QUESTIONS.
                """,
            tags: ["design", "ui", "ascii"]),
        AgentSkill(
            id: "schema-propose", name: "Schema propose",
            summary: "Agree a shared data model/API schema so two components interoperate.",
            fragment: """
                TRIGGER: Two tethers must agree a shared data shape, or received a schema-propose.
                PRODUCE: Fenced JSON-with-types (field: type // note), every field named exactly as on the wire. Mark [required]/[optional], give one example instance, note forward-compat (unknown fields ignored, never fatal).
                CONSUME (load): Reply [accept|counter]. A counter is a FULL revised schema. Field-name/type mismatches are blockers; resolve here before serializing.
                """,
            tags: ["schema", "api", "contract"]),
        AgentSkill(
            id: "context-export", name: "Context export",
            summary: "Share a scoped, human-granted slice of private context, prefixed and bounded.",
            fragment: """
                TRIGGER: The peer needs a piece of your private context AND your human granted sharing for this scope. No grant → DO NOT run; say a grant is needed.
                PRODUCE: Open with "Context:" on its own line. Share only the authorized slice — a pattern, a decision, a gotcha — never surrounding private material. Strip identifiers/keys. State what you're NOT sharing if relevant.
                CONSUME (load): Absorb as reference; attribute it. Never re-share another tether's exported context without that tether's own grant.
                """,
            tags: ["context", "privacy"]),
        AgentSkill(
            id: "decision-record", name: "Decision record",
            summary: "Record an ADR both tethers follow, so they don't drift into contradictions.",
            fragment: """
                TRIGGER: A choice both will live with was settled (or must be), or received a decision-record.
                PRODUCE: ADR — DECISION (one line), CONTEXT, OPTIONS (2-3, one line each), CHOSEN + WHY, CONSEQUENCES. Give it an id DR-NN so later messages cite it.
                CONSUME (load): Reply [ratify|object]. Ratify = you won't contradict it later. Object reopens OPTIONS with a reason. Once ratified, cite DR-NN instead of re-litigating.
                """,
            tags: ["adr", "decisions"]),
        AgentSkill(
            id: "math-solve", name: "Math solve",
            summary: "Pose/return a worked math or physics problem with assumptions stated.",
            fragment: """
                TRIGGER: A quantitative result the peer can derive, or received a math-solve.
                PRODUCE (problem): GIVEN (knowns+units), FIND, CONSTRAINTS. State every assumption — unstated units are the usual failure.
                PRODUCE (solution): ASSUMPTIONS, a numbered derivation (one op/step, units carried), RESULT fenced with units and sig-figs.
                CONSUME (load or verify): LOAD → use it. VERIFY → re-derive independently, reply [confirmed|discrepancy]; a discrepancy names the exact step you part.
                """,
            tags: ["math", "reasoning"]),
        AgentSkill(
            id: "fermi-estimate", name: "Fermi estimate",
            summary: "Order-of-magnitude sizing with every multiplier shown to be challengeable.",
            fragment: """
                TRIGGER: A rough sizing (throughput, cost, storage, latency), or received a fermi-estimate.
                PRODUCE: A factor chain — each line "quantity × rate = subtotal // source" — ending in RESULT with a confidence band (e.g. ±1 order). Label each input [measured|assumed|guessed].
                CONSUME (load): Challenge the weakest input by name with a better number, then a revised RESULT. Converge on the band, not false precision.
                """,
            tags: ["estimation", "sizing"]),
        AgentSkill(
            id: "api-contract", name: "API contract",
            summary: "Negotiate the request/response contract two components must honor.",
            fragment: """
                TRIGGER: A's component must call B's (or they share a boundary), or received an api-contract.
                PRODUCE: ENDPOINT/METHOD, REQUEST (field-exact), RESPONSE (success + each error case with codes), INVARIANTS, VERSIONING (how it evolves without breaking the peer).
                CONSUME (load): Reply [accept|counter] in the same structure. Error cases are part of the contract — an unhandled error shape is a blocker. Pin with a decision-record once agreed.
                """,
            tags: ["api", "interface", "integration"]),
        AgentSkill(
            id: "repro-case", name: "Repro case",
            summary: "Package a minimal reproducible example the peer can run.",
            fragment: """
                TRIGGER: A code-debug couldn't be reproduced and the peer needs a runnable case, or received a repro-case request.
                PRODUCE: SETUP (exact versions/config), STEPS (numbered, copy-pasteable), EXPECTED vs ACTUAL, minimal CODE fenced. Change exactly one thing from a known-good baseline.
                CONSUME (delegate): Run it (or reason precisely), reply OBSERVED; if reproduced, hand back a code-debug diagnosis/patch-handoff. If it does NOT reproduce, that difference IS the clue — report it.
                """,
            tags: ["debugging", "repro"]),
        AgentSkill(
            id: "refactor-propose", name: "Refactor propose",
            summary: "Propose a refactor with before/after and an explicit risk read.",
            fragment: """
                TRIGGER: You see a structural improvement worth sharing, or received a refactor-propose.
                PRODUCE: MOTIVATION (the smell, one line), BEFORE (tiny snippet), AFTER (tiny snippet/diff), RISK [low|med|high] + the specific thing that could break, BLAST RADIUS. No refactor without a stated risk.
                CONSUME (load): Reply [adopt|adapt|decline] with a reason. Adapt = take the idea with a variation (show it). Decline names the risk that outweighs the benefit for your side.
                """,
            tags: ["refactor", "design"]),
        AgentSkill(
            id: "ask-clarify", name: "Ask clarify",
            summary: "A single bounded clarifying question that advances the work.",
            fragment: """
                TRIGGER: You genuinely cannot proceed without one fact from the peer. (Use sparingly — the loop guard pauses runaway exchanges.)
                PRODUCE: ONE question, as a choice where possible — "A or B?" with the consequence of each — so the answer is one token. State what you'll do with each answer. Never stack questions.
                CONSUME (load): Answer the single question directly and briefly. If the real answer is "a human should decide," say so and stop.
                """,
            tags: ["coordination", "question"]),
        AgentSkill(
            id: "status-sync", name: "Status sync",
            summary: "A compact done/blocked/next progress beat.",
            fragment: """
                TRIGGER: A natural checkpoint, or received a status-sync.
                PRODUCE: DONE (since last sync), BLOCKED (each with the blocker and who can clear it), NEXT. One line each. Also your natural yield point to a human.
                CONSUME (load): Reply with your own status-sync and, for each BLOCKED item you can clear, an offer routed through the right skill. Don't leave a named blocker unanswered.
                """,
            tags: ["coordination", "status"]),
        AgentSkill(
            id: "conflict-resolve", name: "Conflict resolve",
            summary: "Lay out diverging options + tradeoffs and tee up a human decision.",
            fragment: """
                TRIGGER: The two tethers are heading different directions on the same thing, or received a conflict-resolve.
                PRODUCE: THE FORK (the one decision in dispute, neutrally stated), OPTION A / OPTION B (each: what it is + what it costs + who it favors), RECOMMENDATION (your pick + the single reason) — clearly a recommendation, not a decision. Then STOP and yield.
                CONSUME (load): Add any missed cost, then second the recommendation or counter ONCE. Then yield — tee up a human, don't negotiate to a stalemate.
                """,
            tags: ["coordination", "tradeoff"]),
        AgentSkill(
            id: "handoff-summary", name: "Handoff summary",
            summary: "A distilled close-out so the humans get the TL;DR and decisions.",
            fragment: """
                TRIGGER: An exchange concluded, or a human asked "what did you decide?", or the loop guard is about to fire.
                PRODUCE: Open with "Context:" (it's for the humans). OUTCOME (1-2 lines), DECISIONS (cite DR-NN), ARTIFACTS SHARED (which skills produced what), OPEN (what still needs a human). Keep it skimmable.
                CONSUME (load): If anything's wrong/missing, reply ONE correction. Otherwise acknowledge briefly. The clean exit — after it, both AIs go silent until re-invited.
                """,
            tags: ["summary", "handoff"]),
    ]
}
