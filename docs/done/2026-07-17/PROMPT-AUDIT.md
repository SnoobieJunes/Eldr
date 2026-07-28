# PROMPT-AUDIT.md — everything EldrChat injects into an LLM

**Audience:** product/eng, deciding what to strip so EldrChat is a **conduit**, not an
author. **Scope:** every place the app assembles text that reaches a model — system
prompts, persona/instructions, guardrails, transcript formatting, context markers, and
the redaction transform that rewrites all of it for cloud models.

**Verdict vocabulary**
- **Functional** — protocol/coordination/labeling the product needs to behave correctly
  (multi-AI threads, AI-vs-human labeling, tool contracts). Keep, or keep behind a clear
  condition.
- **Chaff** — text we put in the model's mouth on the user's behalf. Conduit candidates:
  strip by default, restore per-persona.

**State note (post-2026-06-25):** the items marked **CHANGED** were updated in this push
(DEVIATIONS AC49–AC51). The defaults below are the *new* ones; the old behavior is noted
where it helps.

---

## 0. The big picture — what reaches the model, in order

For a normal (non-thread) turn a provider receives exactly two things:

1. a **system prompt** — see §1; **empty by default now**, and
2. a **rendered transcript** — see §8 (`role: text`, last N entries).

A **shared AI-to-AI thread** turn additionally replaces the system prompt with the
**guardrails + envelope + pinned skills** block (§3–§5). A **paired Mac coding agent**
(ACP) turn is composed differently (§10–§11).

Everything in (1)+(2) crosses the **egress-firewall redaction** (§14) before reaching a
*remote* model when the firewall is on.

---

## 1. Base system prompts (draft / thread-turn / window) — **CHANGED → conduit**

| Where | Old text (no longer auto-sent) | Now |
|---|---|---|
| `AgentContext.draftSystemPrompt()` — `Packages/PQRCAgent/.../AgentProvider.swift` | `"You draft brief, natural message replies for {name}. Reply with the draft text only."` | **Empty** unless the user set `instructions`. |
| `AgentContext.turnSystemPrompt()` — same file | `"You are {name}'s AI in a shared thread with another person's AI. Contribute one short useful message, or reply exactly PASS to stay silent."` | **Empty** unless the user set `instructions` (or a thread override applies, §3). |
| `PersonaRuntime.windowReplySystemPrompt()` — `App/.../PersonaRuntime.swift` | `"You are {name}'s AI assistant, and {name} has turned you ON … reply exactly PASS ONLY if …"` | **Empty** unless the user set `instructions`. |

- **Trigger:** every draft / window / thread-turn (the override path in §3 wins for threads).
- **Controlling setting:** per-AI **Instructions** field (`ConfiguredAI.instructions`,
  Settings ▸ AI ▸ Instructions). Empty by default. The old text is one tap away via **"Use
  EldrChat's default"** (`ConfiguredAI.defaultInstructions` /
  `AgentContext.defaultDraft/ThreadInstructions`).
- **Verdict:** was **chaff** → now stripped by default. ✅ This is the core of the conduit change.
- **Note:** the `summarize` output mode still appends one sentence (§13) — a user-selected
  behavior, not chaff.

---

## 2. The "summarize" suffix — §13 (kept, opt-in by output mode)

## 3. Shared-thread guardrails — `AgentSkills.baseInjectionTemplate` — **FUNCTIONAL (kept)**

`Packages/PQRCAgent/.../AgentSkills.swift`. Injected (via
`AgentSkills.threadSystemPrompt`, called from `PersonaRuntime.contextFor`) for **shared
AI-to-AI thread turns only**. Five blocks, substituting `{{display_name}}`,
`{{context_domain}}`, `{{peer_name}}`, `{{thread_id}}`:

- **CHANNEL** — "you're in a shared, signed, AI-labeled thread; no private channel."
- **SCOPE** — "post in THIS thread only, while the invite is active; reaffirm
  `scope:thread:{{thread_id}}`."
- **CONTEXT BOUNDARY** — "use private context to reason; only SHARE what was granted;
  default-deny."
- **BOUNDED AUTONOMY** — "paused after 6 consecutive AI messages; yield at decision points."
- **TRANSPARENCY** — "you're labeled as {{name}}'s AI; never write as the human."

- **Trigger:** a thread turn that is **not** a trusted-node turn.
- **Controlling setting:** none — always-on for ordinary shared threads.
- **Verdict:** **functional** (the multi-AI coordination + labeling contract; backs
  invariant 8/9 at the prompt layer). **Kept by default.** Bypassed for trusted nodes (§12).
- **Strip candidate?** Only if you decide solo/1:1 personas shouldn't ever get it — they
  already don't (it's thread-only). Flagged for a later "strip for everything but multi-AI
  threads" decision; today it's already scoped to exactly that.

## 4. Skill envelope — `AgentSkills.envelope` — **FUNCTIONAL (kept, thread-only)**

The `⟡⟡ <skill> · v<version> … ⟡⟡ end` wrapper. Injected with §3 for thread turns.
Functional (it's the parseable skill-message format). Same scope/bypass as §3.

## 5. Pinned skill fragments — `AgentSkills` 20-skill catalog + custom — **OPT-IN**

Each pinned skill appends its TRIGGER/PRODUCE/CONSUME contract.
- **Controlling setting:** `AppSession.threadSkills(threadID)` (user pins per thread) +
  `AppSession.loadCustomSkills`. **None pinned by default.**
- **Verdict:** **functional + opt-in** — already conduit-friendly (off unless chosen).

---

## 6. Focus directive — "Have my AI answer this" — **OPT-IN**

`PersonaRuntime.swift` (~`contextFor` focus path):
`"Answer THIS specific message from the conversation, directly and helpfully: \"{msg}\""`,
merged into `instructions`. Credential-scrubbed if the firewall is on.
- **Trigger:** user long-presses a message → "Have my AI answer this." Opt-in.
- **Verdict:** **functional + opt-in** (it's a user action). Keep.

## 7. (reserved)

## 8. Transcript rendering — `FoundationModelsAgentProvider.renderTranscript` — **FUNCTIONAL**

`"{senderDisplayName}: {text}"`, or `"{senderDisplayName}'s AI: {text}"` for agent
entries; last **20** entries.
- **Trigger:** every turn (this *is* the conversation).
- **Verdict:** **functional** — this is the payload we're a conduit *for*. The `…'s AI:`
  labeling is invariant-8 support; keep. (Names are codenamed by §14 for remote models.)

## 9. "Context:" prefix — `AgentEngine.swift` — **FUNCTIONAL (display)**

`isContext` messages render as `"Context: {text}"`. A UI/marking convention for
context-sharing contributions; strippable for readability via the silo "Show agent
protocol envelope" toggle. Keep.

---

## 10. ACP coding-agent system prompt — `Packages/PQRCACP/.../ACPAgent.swift` — **FUNCTIONAL (node-side)**

A large hard-coded prompt ("You are EldrChat's coding agent … tools: read_file,
write_file, edit_file, list_dir, search, run_shell … guidelines …"). This runs
**node-side** (on the Mac), not in EldrChat's send path.
- **Controlling settings:** `ELDR_ACP_SYSTEM_PROMPT` (replaces it), `ELDR_ACP_PROMPT_PREAMBLE`
  (appends), skills.
- **Verdict:** **functional** — it's the coding harness's own operating prompt. Out of scope
  for the EldrChat conduit change, but the owner controls it via env/config on their Mac.

## 11. ACP client-side compose — `ACPAgentProvider.composePrompt` — **CHANGED → conduit**

Was always `"[System]\n{system}\n\n[Conversation]\n{transcript}"`. Now, when `system` is
empty (the conduit default), it sends **only** `"[Conversation]\n{transcript}"` — no empty
`[System]` header. Verdict: chaff (empty header) removed.

---

## 12. Trusted-node bypass — **CHANGED (new)**

For a consented `coding_agent` node (`isConsentedCodingAgentNode`),
`PersonaRuntime.contextFor` sets the system-prompt override to **nil** (skips §3/§4 and the
window prompt) → the node gets the raw transcript + the user's own `instructions` only, and
the firewall (§14) defaults **off**. See DEVIATIONS AC50/AC51. This is the maximal-conduit
path, scoped to the user's own device.

## 13. "summarize" output mode suffix — **OPT-IN (kept)**

`draft`: `"Prefer a concise summary over verbatim quoting."`
`thread/window`: `"Share a brief summary of the relevant context rather than quoting it verbatim."`
- **Controlling setting:** per-AI **Does** = "Summarize" (`outputMode == "summarize"`).
  Default "participate" → not sent.
- **Verdict:** **functional + opt-in** (a behavior the user selected). Keep.

## 14. Egress-firewall redaction — `PersonaRuntime.redactedForRemote` — **FUNCTIONAL (modifier)**

Not added text — it *rewrites* everything above before it reaches a **remote** model:
real names → local codenames ("you" / a contact's `autoName`), credentials scrubbed
(`CredentialRedactor`), 64 KB byte-bound (applied earlier in `visibleContextMessages`).
- **Controlling setting:** account `egressFirewallEnabled` (default on) + per-conversation
  override; **defaults OFF for a trusted node** (§12, AC50). On-device models are never
  redacted.
- **Verdict:** **functional privacy guard.** Keep for cloud models; off for the user's own node.

## 15. Demo personas — `LocalUniverse.swift` — **DEMO-ONLY**

Scripted fixtures set `instructions` (e.g. "You are Alice's helpful, concise assistant",
"Surface options and trade-offs; never decide"). Demo universe only; not user data. Ignore.

---

## Summary table

| # | Site | Default after this push | Verdict |
|---|---|---|---|
| 1 | draft/turn/window base prompt | **empty** (was hard-coded) | chaff → stripped |
| 3 | thread guardrails | on (thread-only) | functional |
| 4 | skill envelope | on (thread-only) | functional |
| 5 | pinned skills | off unless pinned | functional/opt-in |
| 6 | "Have my AI answer this" | off unless invoked | functional/opt-in |
| 8 | transcript `role: text` | always (the payload) | functional |
| 9 | "Context:" prefix | per marked message | functional/display |
| 10 | ACP node system prompt | node-side; env-overridable | functional (node) |
| 11 | ACP compose `[System]` header | omitted when empty | chaff → stripped |
| 12 | trusted-node bypass | conduit for own node | new |
| 13 | summarize suffix | off unless "Summarize" | functional/opt-in |
| 14 | firewall redaction | on for cloud, off for trusted node | functional |

---

## Recommended strip list (the conduit direction)

1. **Done this push:** base persona prompts (§1) and the empty `[System]` header (§11) no
   longer auto-injected; trusted-node turns (§12) are pure conduit; firewall defaults off
   for the user's own node (§14).
2. **Decide next — thread guardrails (§3/§4) for *non*-multi-AI use.** They're already
   thread-only and functional for AI-to-AI coordination. If you want even threads to be raw
   for specific personas, gate §3 behind a per-AI "raw thread" flag. Recommendation: **keep
   as-is** — this is coordination, not chaff.
3. **Keep:** transcript (§8), AI-vs-human labeling (§8), firewall for cloud models (§14),
   opt-in skills/summarize/focus (§5/§13/§6). Stripping these breaks correctness, privacy,
   or invariant 8/9.
4. **Per-persona override is the right knob, not global deletion.** The Instructions field
   (§1) now *is* the system prompt — that's the per-persona seam. Anything we keep
   "functional" should, over time, be expressible/disable-able per persona rather than
   hard-coded.
