# Eldr documentation

Two files answer most questions:

| | |
|---|---|
| **[`BACKLOG.md`](BACKLOG.md)** | **What's planned and not built.** The only list. Everything unbuilt, unshipped, or waiting on you. |
| **[`DEVIATIONS.md`](DEVIATIONS.md)** | **Why it's like this.** Every judgment call, tagged and dated, AC1–AC154. Check here before re-litigating anything. |

Everything else is reference material, in four folders.

---

## The law — read in this order

Conflict resolution: **SPEC > NIP > APP-SPEC > CLAUDE.md**.

1. [`pqrc-SPEC-v1_1.md`](pqrc-SPEC-v1_1.md) — the protocol. **This is law.**
2. [`NIP-XX-pqrc.md`](NIP-XX-pqrc.md) — the wire format. Law for anything on the wire.
3. [`APP-SPEC.md`](APP-SPEC.md) — what to build.
4. [`TEST-PLAN.md`](TEST-PLAN.md) — how to prove it works.

Plus [`THREAT_MODEL.md`](THREAT_MODEL.md) — what leaks and what doesn't. Read §2 before
making any privacy claim out loud.

**Normative, narrower scope:** [`A2A-PQRC-EXTENSION.md`](A2A-PQRC-EXTENSION.md) (CC0,
E2EE transport binding for A2A) · [`pqrc-ext-standing-grants.md`](pqrc-ext-standing-grants.md)
(CC0, scoped revocable agent authorization) · [`eldrchat-agent-skills.md`](eldrchat-agent-skills.md)
(the 20 agent-to-agent skills) ·
[`PQXDH-CONFORMANCE-2026-07.md`](PQXDH-CONFORMANCE-2026-07.md) — why the handshake
suite is now `hybrid-v2` and why **all peers must update together**.

---

## [`guide/`](guide/) — how to do things

| I want to… | |
|---|---|
| build and test it | [`SETUP-GUIDE.md`](guide/SETUP-GUIDE.md) — the eight-package loop, the relay, Multipeer, Xcode 27 + `eldr-acp` |
| understand every feature fast | [`FEATURES-AND-TESTING-GUIDE.md`](guide/FEATURES-AND-TESTING-GUIDE.md) — what it does + how to smoke-test it |
| hand it to a tester | [`USER-GUIDE.md`](guide/USER-GUIDE.md) — plain language, no jargon |
| see it work with no network | [`DEMO.md`](guide/DEMO.md) — Local Universe, five personas, one process |
| drive a Mac agent from the phone | [`CONDUIT-SETUP.md`](guide/CONDUIT-SETUP.md) · [`OPENCLAW-SETUP.md`](guide/OPENCLAW-SETUP.md) · [`DEMO-SYBILCLAW.md`](guide/DEMO-SYBILCLAW.md) |
| run agent-to-agent | [`A2A-INTEGRATION.md`](guide/A2A-INTEGRATION.md) · [`ELDR-BUZZ-INTEROP.md`](guide/ELDR-BUZZ-INTEROP.md) · [`DEMO-GOOSEWORLD.md`](guide/DEMO-GOOSEWORLD.md) |
| run a relay | [`RELAY-DEPLOY-CROSTINI.md`](guide/RELAY-DEPLOY-CROSTINI.md) · [`RELAY-EPHEMERAL-KEYS-SETUP.md`](guide/RELAY-EPHEMERAL-KEYS-SETUP.md) |
| ship the apps | [`DISTRIBUTION.md`](guide/DISTRIBUTION.md) · [`TESTFLIGHT-GUIDE.md`](guide/TESTFLIGHT-GUIDE.md) · [`SIGNING-AND-DISTRIBUTION.md`](guide/SIGNING-AND-DISTRIBUTION.md) · [`EXPORT-COMPLIANCE.md`](guide/EXPORT-COMPLIANCE.md) |
| open-source it | [`OSS-EXTRACTION-AUDIT.md`](guide/OSS-EXTRACTION-AUDIT.md) (what the 8 repos are) · [`OSS-RELEASE-RUNBOOK.md`](guide/OSS-RELEASE-RUNBOOK.md) (how to publish) · [`UPSTREAM-GOOSE-EXTENSION.md`](guide/UPSTREAM-GOOSE-EXTENSION.md) |

## [`pitch/`](pitch/) — positioning

[`WHY-ELDR.md`](pitch/WHY-ELDR.md) (vs Block's Buzz, honest about limits) ·
[`ENTERPRISE-PITCH.md`](pitch/ENTERPRISE-PITCH.md) (the funder narrative) ·
[`GOOSEWORLD.md`](pitch/GOOSEWORLD.md) (why cross-town transport exists)

## [`plan/`](plan/) — designs for unbuilt work

**1 file.** If this folder is empty, nothing is designed-but-unstarted. See
[`BACKLOG.md`](BACKLOG.md) for the full picture — a plan is *how*, the backlog is
*what and whether*.

## [`nips-contrib/`](nips-contrib/) — outbound

Three PR-ready contributions to `block/buzz`. **Not yet submitted** — see
[`BACKLOG.md`](BACKLOG.md) §B1.

## [`done/`](done/) — finished, read-only

19 documents, filed by the date they were retired. **Nothing here describes the
current system.** Each carries a header saying what superseded it — and, where a
claim turned out to be *wrong* rather than merely superseded, which one.

---

## The rule that keeps this small

Every document is **law**, **guide**, **ledger**, or **plan**. The first three live
forever and are edited in place. **A plan expires**: the moment its work lands in
`DEVIATIONS.md`, it moves to `done/<date>/` — it is never edited into a status report
and left here.

That is the rule that stopped being followed on 2026-07-17, and it is why this folder
had 39 files in it. Full version: `CLAUDE.md` § Documentation lifecycle.
