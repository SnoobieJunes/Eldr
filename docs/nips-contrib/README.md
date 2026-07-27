# Eldr → Buzz NIP contributions

Two draft NIPs and one amendment, specifying primitives Eldr has shipped and
Block/Buzz's own drafts name as open problems. Written PR-ready for
**`block/buzz/docs/nips`** (their staging ground — every draft there is unnumbered
and several say "don't advertise in `supported_nips` until numbered").

**To submit: follow [`PR-SUBMISSION-RUNBOOK.md`](PR-SUBMISSION-RUNBOOK.md).**
It assumes you have never opened a pull request and gives every command.

> **These files are written for a foreign directory root.** Links such as
> `[NIP-OA](NIP-OA.md)`, `[NIP-AE](NIP-AE.md)` and `[NIP-59](59.md)` resolve
> inside **`block/buzz/docs/nips/`** and `nostr-protocol/nips`, which is where
> these drafts are meant to land — so they are **expected to be broken here** and
> must NOT be "fixed" to point at local paths. Rewriting them would break the PRs.
> There are 28 such links across the four drafts; a link checker run over this repo
> should skip `docs/nips-contrib/`.

| Draft | Fills | Eldr reference impl |
|---|---|---|
| [NIP-AD Untrusted Data Admission](NIP-AD-untrusted-data-admission.md) | the memory-poisoning / admission-control hole `NIP-AE.md §Security` names and punts on | `PQRCMCP/UntrustedDataEnvelope.swift`, `TownWall.swift` |
| [NIP-AC Agent Consent Windows](NIP-AC-consent-windows.md) | NIP-AA §Revocation being relay-side only (no owner revocation under an untrusted relay) | `PQRCAgent/AgentEngine.swift` (`AIWindowAnnouncement`, standing grants, `endMyAIWindow`) |
| [NIP-OA amendment: unsigned carriers](NIP-OA-amendment-unsigned-carriers.md) | NIP-OA's `sig` precondition making an `auth` tag unverifiable inside a NIP-59 gift wrap | agent provenance verified post-unwrap in Eldr's gift wrap |

## NIP-AS was withdrawn — read this before citing it

An earlier draft, **NIP-AS Sealed Attestation**, proposed an `oa_sealed` tag for
carrying owner attestation inside a gift wrap. It was withdrawn on 2026-07-24
after cross-referencing it against NIP-OA, NIP-17 and NIP-59. It was almost
entirely a second name for something NIP-OA already permits:

- NIP-OA says "Events MAY include zero or one `auth` tag" and never requires the
  carrier to be published, signed, or relay-visible.
- A NIP-59 rumor is "the same thing as an unsigned event" and carries `pubkey`,
  `kind`, `created_at` and `id` — everything the preimage and clause evaluation
  need.
- NIP-17 already binds the seal's pubkey to the rumor's pubkey, so the seal's
  signature already authenticates the agent key the preimage uses.

The tag, the preimage, the condition grammar and the signature were all NIP-OA's
unchanged. The **only** real obstacle was NIP-OA §Client Behavior demanding that
`id` and `sig` be valid before an `auth` tag counts as provenance — and a rumor
structurally has no `sig`. That is one verification rule, not a NIP, so it is now
filed as an amendment to NIP-OA. The old draft is in git history.

## Submission plan

Three PRs, bodies pre-written:

| PR | Files | Body |
|---|---|---|
| 1 | `NIP-AD.md` | [`pr-body-1-nip-ad.md`](pr-body-1-nip-ad.md) |
| 2 | `NIP-AC.md` | [`pr-body-2-nip-ac.md`](pr-body-2-nip-ac.md) |
| 3 | amendment to `NIP-OA.md` | [`NIP-OA-amendment-unsigned-carriers.md`](NIP-OA-amendment-unsigned-carriers.md) |

NIP-AD ships alone because it is the strongest of the three (uncontested, fills a
hole they wrote down themselves) and shouldn't share a fate with NIP-AC, which
pushes on Buzz's trusted-relay axiom. The NIP-OA amendment ships separately
because it is a small, self-contained fix to a NIP they already own and has the
best odds of any of the three.

## Renamed from C1/C2/C3 — read this before citing the old codes

The earlier drafts were `NIP-C1/C2/C3`. Two problems, both now fixed:

- Buzz uses **two-letter** codes, not `C<n>`.
- **`NIP-CW` is already taken** by Channel Window — a direct collision with
  "Consent Windows".

| Was | Now | Title |
|---|---|---|
| NIP-C1 | **NIP-AD** | Untrusted Data Admission |
| NIP-C2 | *withdrawn* | Sealed Attestation → NIP-OA amendment |
| NIP-C3 | **NIP-AC** | Agent Consent Windows |

Both codes are unclaimed in Buzz's tree and fit the `A*` agent-plane family
(`NIP-AA`, `AE`, `AM`, `AO`, `AP`). Each file tells maintainers to reassign freely.

**Upstream is a different namespace.** `nostr-protocol/nips` uses hex letter codes
(A0, A4, B0, B7, C0, C7, CC, EE, F4), and its merged corpus contains **zero**
occurrences of "agent" — which makes the lane look emptier than it is. There are
~16 open agent-plane PRs, including **#2253 claiming `AC.md`** and #2220 claiming
`AE.md` (a collision with Buzz's own NIP-AE). Expect reassignment on any upstream
step. This does not affect the Buzz PRs.

## What changed beyond the rename

The originals argued their case but were thin by the standards of Buzz's house
style. Added to each:

- **`## Non-Goals`** — house style in NIP-OA and others, and the load-bearing
  section for NIP-AC (it says plainly what it does *not* replace, which is what
  defuses the "you're saying our design is wrong" reading).
- **`## Test Vectors`** — every mature NIP in their tree carries pinned vectors;
  ours had none. All vectors are **generated from running code**, not written by
  hand:
  - NIP-AD's seven are the literal output of `UntrustedDataEnvelope`.
  - NIP-AC's first three are real BIP-340 signatures over the canonical
    serialization, computed with the same secp256k1 implementation Eldr uses to
    pass NIP-OA's vector, and they reuse **NIP-OA's own test keys**. The fourth
    is a boundary table for `not_before`/`not_after` inclusivity.
  - NIP-AC vector 3 is a **negative** vector: a window signed by the agent key,
    cryptographically valid and required to be rejected.
- **A canonical serialization for NIP-AC**, which the original left undefined —
  a compact positional JSON array following the NIP-01 event-id precedent.
- **Accurate quotation.** Every claim about NIP-AE/NIP-OA/NIP-AA is a direct quote
  checked against `block/buzz@e67303f6`, not a paraphrase. NIP-AC's original "all
  three revocation paths are relay-side" was an overstatement; it now quotes
  NIP-AA verbatim and makes the weaker, correct argument.
- **Trimmed overclaims.** NIP-AC's human-signed rule is now labelled as a restatement
  of NIP-OA's existing self-attestation rule rather than presented as novel. What
  survives as genuinely new is narrower and defensible: verifier-clock evaluation
  (which NIP-OA forbids, and explicitly delegates elsewhere) and the
  `consent_revoke` object (which has no analogue anywhere in Buzz's tree).

## Direction & licensing

- Eldr's protocol docs are **CC0**; Buzz's repo is **Apache-2.0** — a clean
  contribution direction (public domain → Apache). Verified: Buzz requires
  **no CLA and no DCO sign-off**; `CONTRIBUTING.md` says submitting a PR is
  itself the Apache-2.0 grant.
- Disclose in the PR that Eldr ships a privacy-first personal client on the same
  Nostr substrate; these are specs Eldr already runs, offered for the shared
  agent-plane, not a competitive fork. The pre-written bodies do this up front.
- `nostr-protocol/nips` is the later, joint step; land next to the specs they
  cite first (low friction).

## Why this is the adoption path

Eldr also now speaks Buzz's existing agent-plane crypto **byte-exact** against
Block's own vectors (NIP-OA, NIP-44 v2, NIP-AM, NIP-AO — see
`../ELDR-BUZZ-INTEROP.md` and `PQRCNostr/{NIP44,NIPOA,BuzzEvents}.swift`).
Verified 2026-07-24: `swift test --package-path Packages/PQRCNostr --filter
BuzzInteropCryptoTests` → **12/12 pass**, including "NIP-OA verifies the
spec-provided signature" and "NIP-01 id + BIP-340 sig reproduce Buzz NIP-AE
events byte-exactly". A client that gets Buzz's vectors right is immediately
useful *inside* Block's ecosystem — that mutual conformance, not a bilateral
protocol ask, is the distribution strategy (`../done/2026-07-24/INTEROP-LANDSCAPE.md` §8.2).
