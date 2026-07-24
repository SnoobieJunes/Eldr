# Eldr → Buzz NIP contributions

Three draft NIPs specifying primitives Eldr has shipped and Block/Buzz's own
drafts name as open problems. Written PR-ready for **`block/buzz/docs/nips`**
(their staging ground — every draft there is unnumbered and several say "don't
advertise in `supported_nips` until numbered").

**To submit: follow [`PR-SUBMISSION-RUNBOOK.md`](PR-SUBMISSION-RUNBOOK.md).**
It assumes you have never opened a pull request and gives every command.

| Draft | Fills | Eldr reference impl |
|---|---|---|
| [NIP-AD Untrusted Data Admission](NIP-AD-untrusted-data-admission.md) | the memory-poisoning / admission-control hole `NIP-AE.md §Security` names and punts on | `PQRCMCP/UntrustedDataEnvelope.swift`, `TownWall.swift` |
| [NIP-AS Sealed Attestation](NIP-AS-sealed-attestation.md) | NIP-OA §Privacy's permanent public owner↔agent linkage | agent-signed provenance inside Eldr's NIP-59 gift wrap |
| [NIP-AC Agent Consent Windows](NIP-AC-consent-windows.md) | NIP-AA §Revocation being relay-side only (no owner revocation under an untrusted relay) | `PQRCAgent/AgentEngine.swift` (`AIWindowAnnouncement`, standing grants, `endMyAIWindow`) |

## Submission plan

Two PRs, bodies pre-written:

| PR | Files | Body |
|---|---|---|
| 1 | `NIP-AD.md` | [`pr-body-1-nip-ad.md`](pr-body-1-nip-ad.md) |
| 2 | `NIP-AS.md`, `NIP-AC.md` | [`pr-body-2-nip-as-ac.md`](pr-body-2-nip-as-ac.md) |

NIP-AD ships alone because it is the strongest of the three (uncontested, fills
a hole they wrote down themselves) and shouldn't share a fate with the two that
push on Buzz's trusted-relay axiom. NIP-AS and NIP-AC ship together because they
cross-reference and argue one story.

## Renamed from C1/C2/C3 — read this before citing the old codes

The earlier drafts were `NIP-C1/C2/C3`. Two problems, both now fixed:

- Buzz uses **two-letter** codes, not `C<n>`.
- **`NIP-CW` is already taken** by Channel Window — a direct collision with
  "Consent Windows".

Current codes, all unclaimed in their tree and all fitting the `A*` agent-plane
family (`NIP-AA`, `AE`, `AM`, `AO`, `AP`):

| Was | Now | Title |
|---|---|---|
| NIP-C1 | **NIP-AD** | Untrusted Data Admission |
| NIP-C2 | **NIP-AS** | Sealed Attestation |
| NIP-C3 | **NIP-AC** | Agent Consent Windows |

Each file tells maintainers to reassign freely.

## What changed beyond the rename

The originals were argued but thin against Buzz's house style. Added to each:

- **`## Non-Goals`** — house style in NIP-OA and others, and the load-bearing
  section for NIP-AS/NIP-AC (both say plainly what they do *not* replace, which
  is what defuses the "you're saying our design is wrong" reading).
- **`## Test vectors`** — every mature NIP in their tree carries pinned vectors;
  ours had none. All vectors are **generated from running code**, not written by
  hand:
  - NIP-AD's seven are the literal output of `UntrustedDataEnvelope`.
  - NIP-AC's four are real BIP-340 signatures over the canonical serialization,
    computed with the same secp256k1 implementation Eldr uses to pass NIP-OA's
    vector, and they reuse **NIP-OA's own test keys**.
  - NIP-AC vector 3 is a **negative** vector: a window signed by the agent key,
    cryptographically valid and required to be rejected.
- **A canonical serialization for NIP-AC**, which the original left undefined —
  a compact positional JSON array following the NIP-01 event-id precedent.
- **Accurate quotation.** Every claim about NIP-AE/NIP-OA/NIP-AA is now a direct
  quote checked against `block/buzz@e67303f6`, not a paraphrase. NIP-AC's
  original "all three revocation paths are relay-side" was an overstatement;
  it now quotes NIP-AA verbatim and makes the weaker, correct argument.

## Direction & licensing

- Eldr's protocol docs are **CC0**; Buzz's repo is **Apache-2.0** — a clean
  contribution direction (public domain → Apache). Verified: Buzz requires
  **no CLA and no DCO sign-off**; `CONTRIBUTING.md` says submitting a PR is
  itself the Apache-2.0 grant.
- Disclose in the PR that Eldr ships a privacy-first personal client on the same
  Nostr substrate; these are specs Eldr already runs, offered for the shared
  agent-plane, not a competitive fork. Both pre-written bodies do this up front.
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
protocol ask, is the distribution strategy (INTEROP-LANDSCAPE §8.2).
