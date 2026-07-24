# Eldr → Buzz NIP contributions

Three draft NIPs specifying primitives Eldr has shipped and Block/Buzz's own
drafts name as open problems. Written PR-ready for **`block/buzz/docs/nips`**
(their staging ground — every draft there is unnumbered and several say "don't
advertise in `supported_nips` until numbered").

| Draft | Fills | Eldr reference impl |
|---|---|---|
| [NIP-C1 Untrusted Data Admission](NIP-C1-untrusted-data-admission.md) | the memory-poisoning / admission-control hole `NIP-AE.md §Security` names and punts on | `PQRCMCP/UntrustedDataEnvelope.swift`, `TownWall.swift` |
| [NIP-C2 Sealed Attestation](NIP-C2-sealed-attestation.md) | NIP-OA §Privacy's permanent public owner↔agent linkage | agent-signed provenance inside Eldr's NIP-59 gift wrap |
| [NIP-C3 Consent Windows](NIP-C3-consent-windows.md) | NIP-AA §Revocation being relay-side only (no owner revocation under an untrusted relay) | `PQRCAgent/AgentEngine.swift` (`AIWindowAnnouncement`, standing grants, `endMyAIWindow`) |

## Direction & licensing

- Eldr's protocol docs are **CC0**; Buzz's repo is **Apache-2.0** — a clean
  contribution direction (CC0 → Apache). Check for a CLA before opening the PR.
- Disclose in the PR that Eldr ships a privacy-first personal client on the same
  Nostr substrate; these are specs Eldr already runs, offered for the shared
  agent-plane, not a competitive fork.
- `nostr-protocol/nips` is the later, joint step; land next to the specs they
  cite first (low friction).

## Why this is the adoption path

Eldr also now speaks Buzz's existing agent-plane crypto **byte-exact** against
Block's own vectors (NIP-OA, NIP-44 v2, NIP-AM, NIP-AO — see
`../ELDR-BUZZ-INTEROP.md` and `PQRCNostr/{NIP44,NIPOA,BuzzEvents}.swift`). A
client that gets Buzz's vectors right is immediately useful *inside* Block's
ecosystem — that mutual conformance, not a bilateral protocol ask, is the
distribution strategy (INTEROP-LANDSCAPE §8.2).
