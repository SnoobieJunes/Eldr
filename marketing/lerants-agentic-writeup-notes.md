# Eldr × Claude — source notes for the lerants.com writeup

Generated 2026-07-10 from the repo's full commit history on `origin/main` (204
commits, spanning every merged branch) plus a code/doc audit. Every number below
is verifiable from `git log` / `git ls-tree` / `git show` — cite them; they're
the credibility.

---

## What Eldr actually is

**PQRC ("PQ-Ratchet & Clank")** is a post-quantum, decentralized, AI-native
end-to-end-encrypted messenger over Nostr — "iMessage for the AI age." **EldrChat**
is the iOS/iPadOS/Mac client: hybrid X25519 + ML-KEM-768 handshake, Double Ratchet,
gift-wrapped envelopes, and — its distinguishing idea — every human has a
cryptographically-derived AI agent as a first-class, transparently-labeled
conversation participant (never silently impersonating the human). **Huginn**
(formerly "Eldr ACP Configurator") is a macOS companion app that lets the phone
remote-drive a real coding agent running on your Mac over the same encrypted
transport — "conduit mode," provisioned over SSH by the `eldrctl` CLI
(`docs/CONDUIT-SETUP.md`).

## Headline numbers

| Stat | Value |
|---|---|
| Calendar time | **23 days** — first commit 2026-06-11 (`c3b5208`) → PR #11 merged to `main` 2026-07-04 (`e38f559`) |
| Commits / PRs | **204 commits** (186 direct + 18 merges) across **11 merged pull requests** |
| Authorship | **168 commits authored or co-authored by Claude** (165 via `Co-Authored-By` trailer on human-authored commits + 3 authored directly as `Claude <noreply@anthropic.com>`); **36 by the human alone** (16 of those are GitHub web-UI merge commits) |
| Shipping code | **273 Swift files, 67,012 lines** across 7 SPM packages (PQRCCore, PQRCNostr, PQRCAgent, PQRCACP, PQRCMCP, EldrNode, Eldrctl) + the App target + the Huginn Mac app |
| Tests | **90 test files, 689 test methods** (Swift Testing `@Test` + XCTest), incl. a security-regression suite and a networked chaos-matrix suite |
| Frozen test vectors | **7 JSON files** in `TestVectors/` (agent derivation, kind-10420 binding, PQXDH handshake, 40-message ratchet chain, PQ rekey boundary, padding buckets, gift-wrap) — byte-for-byte regression-locked crypto proofs |
| Lifetime churn | **94,387 lines added / 7,561 deleted** (non-merge diffs) — roughly 12 lines added for every 1 deleted; this was mostly *new* surface, not rewrite-heavy |
| Process artifacts | **39 committed markdown docs**; `docs/DEVIATIONS.md` is a **1,308-line, 173-entry** decision ledger, touched in **54 separate commits across 16 of the 23 days** — updated continuously, not batched |
| Day-one drop | The very first substantive commit (`c3b5208`, 2026-06-11) landed **98 files / 13,242 lines** — a complete v1 client, protocol packages, and test suite in one shot |
| Marathon days | **40 commits on 2026-06-15**, **25 on 2026-06-20** (the ACP-router build-out, closing with commit message "NOW THIS IS PODRACING") |
| Security hardening waves | At least 3: Phase-0 `C-1…C-8` (2026-06-19), a follow-up "2 critical + 3 high" audit (2026-06-25/26), and a closing self-audit commit `a5d23f3` ("Bugs found (ranked) — and what I did") on 2026-06-28 |

---

## The arc in five acts

**Act 1 — A complete v1 lands whole (Jun 11–13).** Unlike a from-zero build, day
one ships nearly the whole protocol: `c3b5208` "PQRC v1: complete iOS client,
protocol packages, and test suite" (98 files, 13,242 lines), followed same-day
by `65e6ad1` "Ride the lightning." By Jun 12: "Final state: all suites pass"
(×3, each after a hardening pass) plus external compliance cross-checks
(`5f9ec75`, `88cd2cb`). Jun 13 adds the relay-free Nearby transport and a
device-store fix relaxing file protection to `completeUntilFirstUserAuthentication`
(`946444e`) — an early example of privacy-vs-usability tradeoffs being resolved
and written down rather than silently patched.

**Act 2 — AI-native messaging, at speed (Jun 13–15).** Chunked large-message
delivery, a full-screen markdown/HTML reader, AI draft-into-composer, the egress
firewall (redact + 64KB-bound everything sent to an off-device AI), deniable
multi-account "silos" with duress/decoy semantics, biometric unlock, and
per-AI tethering with per-AI Keychain keys — capped by a **40-commit day** on
Jun 15 that also ships the first MCP server and the first ACP agent
(`448af00`, `528790d`). *Article beat: this is not incremental feature work —
it's an entire privacy-preserving AI-consent model (windows, invites, loop
guards) stood up and tested inside 48 hours.*

**Act 3 — The ACP-router pivot and "PODRACING" (Jun 16–21).** `62ca63d`
(Jun 16) ships a macOS GUI, "Eldr ACP Configurator," to wrap the coding-agent
CLI. Jun 18 adds a Private Cloud Compute tier gated behind `@available(iOS 27)`
guards, with a comment recording that the Xcode 27.0 *seed* SDK lacks the PCC
symbols it needs (`c18dcf2`) — a discovered platform constraint documented
inline rather than worked around. Jun 20 is the architecture day: four
phases (P1 sealed transport → P2 pluggable routing → P3 relay-carried ACP →
P4 standalone headless node) land in **25 commits**, closing with `2e6a232`
"NOW THIS IS PODRACING." The next day the app is renamed top to bottom:
`d837353` "Rename the Mac node app: EldrACPConfigurator → Huginn."

**Act 4 — Two security-audit waves (Jun 19, Jun 25–26).** Jun 19: a Phase-0
hardening pass fixes eight numbered findings in sequence — `C-1` fail-closed
tool permissions, `C-2` path-jailed file tools, `C-3` a confused-deputy RCE gate
on agent prompt intake, `C-8` moving the LLM token out of a cleartext env file
into the Keychain — each its own commit, each recorded in `DEVIATIONS.md`
(`f286efa`, AC26–AC30). A second wave on Jun 25–26 closes "2 critical agent-trust
gaps + 3 high privacy leaks" (`3425c57`) and does an honesty pass across the
whole doc set for overclaiming (`d0d6be5`, `01eacc8`). *Article beat: the repo
treats its own audit findings as first-class commits, not silent fixes —
you can `git log --grep "Fix C-"` and read the whole remediation history.*

**Act 5 — Demo hardening, conduit mode, and the self-audit (Jun 22–28).**
Four ACP capabilities ship in sequence (plan/TODO visibility, node-side image
input, MCP passthrough, an interactive PTY terminal, each hard-gated and
killable) ahead of a funding demo, alongside honest "stop overclaiming Stage
1/2" doc fixes for the Sybilclaw gateway integration. `eldrctl` (SSH
provisioner for "conduit mode") and encrypted at-rest AI memory land Jun
27. The branch closes Jun 28 with `635e0eb` — flagging that
`SybilclawGatewayClient.swift` now exists as **two diverged copies** — followed
immediately by `a5d23f3`, a self-authored ranked bug ledger with a status
column (Fixed / Reported-not-fixed / product-intent) that reads like a mini
postmortem before the PR merges to `main` on Jul 4.

---

## The practices (thought-leadership core)

1. **A read-order, not just a memory file.** CLAUDE.md opens with a numbered
   reading list — SPEC → NIP → APP-SPEC → TEST-PLAN — and a stated conflict
   resolution order ("SPEC > NIP > APP-SPEC > this file"), plus a cardinal rule
   ("user privacy is the number one priority, without exception. Every tie
   resolves in favor of privacy"). It also bans sycophancy explicitly: "Never
   report a build, test, or feature as working without having run it and seen
   it pass... Label every unverified claim as unverified."
2. **A living decisions ledger, not a changelog.** `DEVIATIONS.md` (173 entries,
   1,308 lines) tags every judgment call `[upstream-NIP]` / `[app-only]` /
   `[tech-debt]` and was touched in 54 separate commits across 16 of the
   project's 23 days — evidence of updating docs after every change rather
   than batching them at the end.
3. **The test suite is a deliverable, not a chore.** TEST-PLAN.md states it
   outright ("equal to the app") and maps every SPEC "MUST" to a named test —
   `pqRekey_firesAtExactly50_rotatesRoot_andHealsQuantumCompromise`,
   `forwardSecrecy_oldCiphertextsUndecryptableAfterAdvance` — with 12 numbered
   "hard invariants" in CLAUDE.md that "the tests enforce... a failed build,
   not a style issue."
4. **Frozen vectors as a contract.** Seven `TestVectors/*.json` files are
   generated once, then committed and asserted byte-for-byte forever
   (`368b711`, "Test integrity: guard that frozen crypto vectors are present —
   no silent regen").
5. **Numbered fix commits from a numbered audit.** Two full security-audit
   waves (`C-1`…`C-8`, then a second "critical + high" pass) each fix landed as
   its own dated commit, cross-referenced into `DEVIATIONS.md` by ID — an
   auditable remediation trail, not a squash.
6. **The human/AI task split is itself a document.** `meatsuittasks.md` ("things
   only a human can do") explicitly separates code work (tracked in git
   history) from device-testing, account decisions, and physical config —
   with checkboxes, demo caveats ("Don't tap the Apple Private Cloud Compute
   tier... it's forward-investment scaffolding"), and a dated "last updated"
   line.
7. **Permissions as a committed artifact.** `.claude/settings.json` ships an
   explicit allow/deny Bash and Edit list (`Bash(rm -rf *)` and `Bash(sudo *)`
   denied; `git`/`swift`/`xcodebuild` allowed) — the agent's operating envelope
   is versioned alongside the code it operates on.

## Humanizing details (use sparingly)

- Commit subjects: "Ride the lightning," "NOW THIS IS PODRACING" (×2, one a
  merge of the earlier checkpoint), "Bugs found (ranked) — and what I did."
- The Huginn tour copy leans into a raven-of-thought / lobster (OpenClaw)
  theme: "each org's boat, end-to-end encrypted, 'shared thoughts', 'leaking
  overboard.'"
- The Mac gateway integration is named **Sybilclaw**, and one commit is
  refreshingly honest about its own state: `635e0eb` "Sybilclaw gateway
  (SybilclawGatewayClient.swift — two copies, now DIVERGED)."
- `meatsuittasks.md` is exactly what it sounds like: the human-only punch list.

## What to show WITHOUT opening the repo

- Screenshots: the reading-order block atop CLAUDE.md, a `DEVIATIONS.md`
  excerpt showing the `[upstream-NIP]`/`[app-only]`/`[tech-debt]` tags, the
  ranked bug-ledger table from commit `a5d23f3`, the `docs/` folder listing
  (31 files), the `.claude/settings.json` permission list.
- The stats table above.
- A commit-log montage mixing the funny subjects with the audit-fix
  (`C-1`…`C-8`) sequence, to show tone alongside rigor.

## Accuracy guardrails for drafting

- Don't overclaim autonomy: the human directed scope, ran/verified on-device
  tests (per `meatsuittasks.md`), made every decision recorded in
  `DEVIATIONS.md`, and merged all 11 PRs; Claude authored or co-authored most
  commits but every merge and several direct commits are human-only.
- The "23 days" and "204 commits" figures are for the `origin/main` mainline
  specifically — the repo has 12+ additional local/remote branches (including
  a currently-checked-out `feat/encrypted-mac-ai-memory` with its own
  200-commit history) that fork from and re-merge into this line; don't imply
  a single linear thread without that caveat if quoting branch-specific
  numbers.
- Several features are explicitly marked **not yet proven on real hardware**
  in the repo's own docs (`docs/CONDUIT-SETUP.md`: "wired and tested headlessly
  but not yet proven on real hardware") — do not describe conduit mode or the
  Sybilclaw gateway as shipped/working without that caveat.
- PQRC's cryptographic claims (post-quantum, forward secrecy, etc.) are
  design/test claims from the repo's own SPEC and test suite, not independent
  third-party security review — phrase accordingly ("the test suite proves X
  against the spec," not "X is cryptographically proven").
- Naming note: Eldr's "conduit mode" (`eldrctl` + `docs/CONDUIT-SETUP.md`) is
  UNRELATED to the standalone `MOSIS/conduit` device-connectivity project —
  they share only the word. Don't conflate them in the article.
- All hashes/dates above are from `git log`; keep them exact if quoted.
