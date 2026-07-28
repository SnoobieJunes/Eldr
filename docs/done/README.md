# docs/done — finished work

Everything in here is **historical**: finished plans, spent analyses, one-time
audits whose findings were acted on, and dated research notes. Kept for the record
— several are cited by DEVIATIONS entries and commit messages — but **nothing in
here describes the current system. Do not build from these.**

The live documentation set is `docs/` one level up. If a document in here
contradicts one out there, the one out there wins. Where a specific claim in an
archived doc is now known to be *wrong* rather than merely superseded, the header
says so, because "superseded" and "was never true" are different warnings.

## The rule

A document moves here when it is superseded by shipped code, by a newer document,
or by a `DEVIATIONS.md` entry. **It is never edited to catch it up**, and it is
never deleted — the reasoning behind a decision stays readable even after the
decision changes.

Moving a document has three steps, and skipping the third is what breaks things:

1. Move it into `done/<YYYY-MM-DD>/`, dated by **retirement**, not by authorship.
2. Add a header saying what superseded it and what is still worth reading in it.
3. **Re-point every inbound reference — including Swift source comments.**
   When `ACPRouterplan.md` was archived on 2026-07-17, seven files under
   `Packages/PQRCACP/` were left pointing at its old path and stayed broken for ten
   days. They were repointed on 2026-07-27 alongside this reorganisation.
   `grep -rn "<filename>" .` before you consider the move finished — `Packages/`
   comments count.

**Documents in here are never caught up.** That includes their links: an archived
doc may reference a path that has since moved, and that is correct — it is a record
of what was true when it was written, not a live map.

## Contents

### [`2026-07-24/`](2026-07-24/) — the Buzz-interop and OSS-extraction wave

Seven documents, retired the day their workstreams closed.

| Document | Why it was retired |
|---|---|
| `INTEROP-LANDSCAPE.md` | WS-I1–I7 shipped (AC144, AC146) |
| `BUZZ-NIP-INTEROP-PLAN.md` | Self-declared IMPLEMENTED; landed as AC144 |
| `ELDR-BUZZ-PAIRING.md` | Gateway modes shipped (AC146); its ceremony is the wrong door for humans (AC147) |
| `ELDR-BUZZ-GUI-PLAN.md` | Built the same day it was written (AC146) |
| `GOOSEWORLD-LINUX-PORT.md` | Port shipped as WS-L0–L5 (AC133, AC139, AC141); two of its technical calls were proven wrong by doing the work |
| `OPEN-SOURCE-EXTRACTION-CATALOG.md` | Superseded by `OSS-EXTRACTION-AUDIT.md`; four claims wrong, one recommendation reversed |
| `A2A-SDK-IMPROVEMENTS.md` | **Never implemented.** No owner, no inbound references, and its premise (AC112) has since flipped |

### [`2026-07-17/`](2026-07-17/) — the pre-July set

Twelve documents; this was the previous `docs/deprecated/` folder, renamed for
consistency and dated by when its contents were retired. Superseded planning
artifacts (`ACPRouterplan.md`, `WATCH-ALONG-ENDPOINT-PLAN.md`,
`AI-WINDOW-PER-CONVERSATION.md`), one-time reviews whose findings were acted on
(`SPEC_COMPLIANCE_REVIEW.md`, `EXTERNAL_CROSSCHECK_REVIEW.md`, `PROMPT-AUDIT.md`,
`UX-RECOMMENDATIONS.md`), and dated notes.
