# CLAUDE-CODE-RUNBOOK.md — One-shotting the PQRC client with Fable 5

## A. Prerequisites (your machine)

1. **macOS 26 (Tahoe) + Xcode 26.x** installed, with the iOS 26 simulator runtime downloaded (Xcode → Settings → Components). Run `sudo xcodebuild -license accept` once, and `xcodebuild -version` to confirm.
2. **Claude Code** installed and signed in (Pro/Max subscription or API key). Install per https://code.claude.com/docs (npm: `npm install -g @anthropic-ai/claude-code`). Then:
   ```bash
   claude update     # Fable 5 requires Claude Code v2.1.170 or later
   ```
3. Network access for SPM dependency resolution (swift-crypto, the secp256k1 package).

## B. Prepare the repository

```bash
mkdir pqrc && cd pqrc && git init
mkdir docs
# From this handoff package:
cp CLAUDE.md .
cp APP-SPEC.md TEST-PLAN.md docs/
# From your Claude project files:
cp pqrc-SPEC-v1_1.md NIP-XX-pqrc.md docs/
git add -A && git commit -m "PQRC v1 handoff: spec, NIP, app spec, test plan"
```

`CLAUDE.md` must sit at the repo root — Claude Code auto-loads it every session.

## C. Configure the model

```bash
cd pqrc
claude --model fable        # start this session on Fable 5
```

or, inside a session, `/model fable`. Verify with `/status`. Notes from the current model-config docs (https://code.claude.com/docs/en/model-config):

- Fable 5 is **not** the default model; you must select it. `best` also resolves to Fable 5 where your org has access.
- It's built for exactly this shape of work: long autonomous sessions on outcome-described tasks. The docs' guidance — *describe the outcome, not the steps; hand it ambiguous problems; skip the verification reminders; size up larger tasks* — is why the kickoff prompt below is outcome-shaped and why CLAUDE.md carries a definition-of-done instead of step-by-step orders. Consider using Claude Code's **goal** feature (see https://code.claude.com/docs/en/goal) to keep it working until the definition of done holds.
- An effort slider is available for supported models (`/model` picker, `--effort`, or `CLAUDE_CODE_EFFORT_LEVEL`); set it high for this run.
- Requests flagged by Fable 5's safety classifiers (most often cybersecurity/biology) trigger automatic fallback to another model. Building a defensive E2EE messenger from a published spec is legitimate work, but if you ever see a fallback notice mid-session, just re-issue the instruction with the spec context restated — and check `/status` to confirm you're back on Fable.

Grant file-write and `xcodebuild`/`swift` execution permissions when prompted (or pre-approve in `.claude/settings.json` permissions).

## D. The kickoff prompt (paste verbatim)

```
Build the complete v1 of this repository: the PQRC iOS client and its full test
suite, per the documents already present.

Read first, in order: CLAUDE.md, docs/pqrc-SPEC-v1_1.md, docs/NIP-XX-pqrc.md,
docs/APP-SPEC.md, docs/TEST-PLAN.md. CLAUDE.md's "Hard invariants" and
"Definition of done" are the acceptance criteria; APP-SPEC §18 seeds
docs/DEVIATIONS.md.

Outcome: every box in CLAUDE.md's Definition of done is checked. That means all
three SPM packages and the app target build; `swift test` is green on every
package; `xcodebuild test` is green including UI and accessibility tests; test
vectors are generated and frozen in TestVectors/; the Local Universe demo
scenario runs end-to-end; and docs/THREAT_MODEL.md, docs/DEMO.md, and
docs/DEVIATIONS.md exist and are accurate.

Constraints, non-negotiable: no new cryptographic primitives; swift-crypto
pinned >= 4.3.1; the SPEC's MUSTs override convenience everywhere; privacy wins
all ties. Where the documents leave a gap, choose the privacy-maximizing
option, implement it, record it in docs/DEVIATIONS.md, and keep moving — do
not block on questions.

Suggested build order (yours to change if you find a better path): PQRCCore
with vectors → PQRCNostr with the LocalRelaySimulator and its chaos matrix →
encrypted persistence → PQRCAgent with the Mock provider and the
silent-by-default / ai_window / ai_invite / loop-guard enforcement → SwiftUI
app (conversations, composer with the large-paste path, agent rendering,
shared AI threads, groups, settings, Local Universe) → UI + performance +
security tests → generated docs. Keep tests green as you go; finish with a
full test run and a summary table of suites, counts, and any deviations.
```

## E. While it runs

Let it work. Fable 5 verifies its own output; resist the urge to interrupt with "make sure you test that." If a session ends before the definition of done holds, `claude --continue` and restate only: "Continue until CLAUDE.md's Definition of done holds."

## F. Post-run verification (you, ~20 minutes)

1. `swift test --package-path Packages/PQRCCore` (then Nostr, Agent) — green.
2. Open `App` in Xcode → run tests (⌘U) → green, including UI tests.
3. Run the app in a simulator → Debug → Local Universe → replay `docs/DEMO.md`: AI-drafted message renders as agent bubble; ai_window banner counts down; shared AI thread records both agents' context messages and hits the loop guard; 200 KB paste becomes a chip and sends; group of 4 round-trips.
4. Skim `docs/DEVIATIONS.md` — every entry should trace to APP-SPEC §18 or be a defensible new call.
5. Skim `docs/THREAT_MODEL.md` for the honest-limitations list (IP visibility, recipient p-tag, no deniability, single device).
6. Commit. Tag `v0.1.0-local-universe`.

## G. Expectations for a "one-shot"

One *session*, not one *response*: Fable 5 will iterate internally (write → build → test → fix). Success for this run is a compiling app with a green suite and honest docs at session end. The two follow-on sessions you should expect later, by design: swapping `LocalRelaySimulator` for the real Nostr transport behind the same `RelayTransport` protocol (the conformance suite in TEST-PLAN §7 is the acceptance gate), and TestFlight packaging per TESTFLIGHT-GUIDE.md.
