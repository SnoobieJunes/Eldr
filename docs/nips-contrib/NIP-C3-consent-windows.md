NIP-C3
======

Consent Windows — revocable, wall-clock-honest agent authorization
------------------------------------------------------------------

`draft` `optional`

This NIP defines a **bounded, human-signed, revocable authorization window**
that an owner grants to an agent, layered over [NIP-OA](NIP-OA.md)-style
provenance. Unlike a NIP-OA `auth` tag, a consent window can be **unilaterally
revoked by the owner** without any relay cooperation, and its expiry is enforced
by the verifier's own clock rather than by relay policy.

## Motivation

NIP-OA grants an agent a *reusable capability*: one `auth` tag authorizes many
events, bounded only by optional `created_at` conditions. Revoking it is not an
owner-side action — [NIP-AA](NIP-AA.md) §Revocation makes all three revocation
paths **relay-side** (drop membership, and the agent's next connect fails).

Under a **trusted** relay that is fine. Under an **untrusted** relay it is not:
there is no authority to drop membership, so a NIP-OA grant, once issued, cannot
be recalled. An owner who authorizes an agent for a task and then changes their
mind has no signed instrument that says "this authorization is over now."

Agents acting autonomously on a user's behalf need the opposite default of a
reusable capability: **least-privilege, time-boxed, and revocable by the human
at any moment.** This NIP provides that instrument in a relay-independent form.

## Definitions

- **Consent window**: a signed statement by the owner's *human identity key*
  that an agent MAY act autonomously within a bounded time interval and scope.
- **Revocation**: a signed statement by the same human key that a window is over,
  effective immediately regardless of its original expiry.
- **Verifier**: any party (recipient, harness, node) deciding whether an agent
  action is currently authorized.

## The window

A consent window is a signed object (carried as an event or inside a NIP-59
seal — see [NIP-C2](NIP-C2-sealed-attestation.md)) with:

```jsonc
{
  "type":       "consent_window",
  "agent":      "<agent_pubkey_hex>",
  "scope":      "<opaque scope id — a channel, a task, a thread>",
  "not_before": <unix_seconds>,
  "not_after":  <unix_seconds>,      // MUST be > not_before; bounded (see below)
  "nonce":      "<random id, for revocation targeting>"
}
```

signed by the **human identity key** (NOT the agent key) over the canonical
serialization. Rules:

1. **Human-signed only.** A window signed by the agent key MUST be rejected. An
   agent cannot self-authorize (this is the property NIP-OA provenance and this
   NIP jointly protect).
2. **Bounded duration.** `not_after − not_before` MUST NOT exceed an
   implementation ceiling (RECOMMENDED ≤ 30 days). An unbounded window is a
   reusable capability, which is what NIP-OA already is; this NIP is for the
   bounded case.
3. **Clock-enforced.** A verifier evaluates `not_before ≤ now < not_after`
   against **its own** clock at action time. Expiry needs no relay.

## Revocation

The owner ends a window early by publishing (or sealing) a signed revocation:

```jsonc
{ "type": "consent_revoke", "agent": "<agent_pubkey_hex>", "nonce": "<window nonce>" }
```

signed by the same human identity key. A verifier that has seen a matching
revocation MUST treat the window as closed from that moment, regardless of
`not_after`. Because the revocation is a self-contained signed object, it works
under an untrusted relay — no membership drop, no relay authority required.

## Verifier behavior

An agent action is authorized at time `now` iff **all** hold:

1. A valid consent window exists for `(agent, scope)` with
   `not_before ≤ now < not_after`, signed by the owner's human key.
2. No valid revocation for that window's `nonce` has been seen.
3. (If provenance is also required) a valid NIP-OA / [NIP-C2](NIP-C2-sealed-attestation.md)
   attestation binds the agent to that owner.

Absent a live window, an autonomous agent action MUST **fail closed**.

## Relationship to other NIPs

- [NIP-OA](NIP-OA.md): provenance (*who authorized this agent, forever*). This
  NIP adds *for how long, in what scope, and revocably* — orthogonal and
  composable.
- [NIP-AA](NIP-AA.md): relay-side revocation for trusted deployments. This NIP is
  the relay-independent counterpart for untrusted-relay deployments.
- [NIP-C2](NIP-C2-sealed-attestation.md): a window MAY be carried inside a seal
  for metadata privacy.

## Security considerations

**Clock skew.** Verifiers enforce expiry with local clocks; a window's bounds
should allow for reasonable skew. Timestamps here are authorization bounds, never
key-derivation inputs.

**Revocation propagation.** Under an untrusted relay a revocation must reach the
verifier to take effect. Owners requiring immediate global revocation should
narrow `not_after` accordingly; the bounded-duration rule caps the exposure
window even if a revocation is delayed.

## Reference implementation

Eldr's `AgentEngine` implements exactly this: `AIWindowAnnouncement` is
human-key-signed and time-bounded, `receiveWindow` gates on `clock.now()` against
`maxWindowDuration`, `endMyAIWindow` emits a signed revocation, and
`authorizeAutonomousSend` fails closed absent a live window. Its standing-grant
variant adds scope + budget, is human-signed, ≤ 30-day bounded, and revocable —
the shipping instance of this spec.
