NIP-AC
======

Agent Consent Windows — revocable, wall-clock-honest authorization
-------------------------------------------------------------------

`draft` `optional`

**Depends on**: [NIP-OA](NIP-OA.md) (provenance, composed with — not replaced),
BIP-340 Schnorr signatures

> Named `AC` (Agent Consent) rather than `CW`, which is taken by
> [NIP-CW](NIP-CW.md) Channel Window. Maintainers should feel free to reassign.

## Abstract

This NIP defines a **bounded, human-signed, revocable authorization window**
that an owner grants to an agent, layered over [NIP-OA](NIP-OA.md)-style
provenance. Unlike a NIP-OA `auth` tag, a consent window can be **unilaterally
revoked by the owner** without any relay cooperation, and its expiry is enforced
by the verifier's own clock rather than by relay policy.

## Motivation

NIP-OA grants an agent a *reusable capability*: one `auth` tag authorizes many
events, bounded only by optional `created_at` conditions. NIP-OA says so
directly — "A valid `auth` tag is a reusable capability" — and
[NIP-AA](NIP-AA.md) §Revocation Semantics spells out the consequence:
"Revocation requires one of: (a) removing the owner from the relay's member
list, (b) the `auth` tag's `created_at` conditions expiring, or (c) the relay
applying an independent denylist. NIP-OA credentials are reusable capabilities —
the owner cannot unilaterally revoke a previously issued `auth` tag without one
of these mechanisms."

Of those three, (a) and (c) are relay actions and (b) is the passive expiry of a
condition the *agent itself* populates — NIP-AA notes this too: "`created_at` is
agent-controlled. A misbehaving agent can set `created_at` to any value."
**None of the three is an owner-initiated revocation.**

Under a **trusted** relay that is fine: the operator is the authority, and
dropping membership is a real remedy. Under an **untrusted** relay it is not.
There is no authority to drop membership, no denylist anyone is obliged to
honor, and no operator to call. An owner who authorizes an agent for a task and
then changes their mind has no signed instrument that says "this authorization
is over now."

Agents acting autonomously on a user's behalf need the opposite default of a
reusable capability: **least-privilege, time-boxed, and revocable by the human
at any moment.** This NIP provides that instrument in a relay-independent form,
so the same agent-plane works whether the relay is a trusted workspace server or
a stranger's box.

## Non-Goals

This NIP does not replace NIP-OA or NIP-AA. Provenance ("who authorized this
agent") and relay admission remain theirs. This NIP answers a different
question: "is that authorization live *right now*?"

This NIP does not define transport. A window may be published as an event or
sealed inside a NIP-59 wrap (see [NIP-AS](NIP-AS-sealed-attestation.md));
nothing here depends on which.

This NIP does not guarantee revocation propagation. It guarantees that a
revocation, once seen, is self-authenticating and needs no relay's cooperation
to take effect. Propagation is a delivery problem, bounded by the duration rule.

This NIP does not define scope semantics. `scope` is an opaque identifier the
issuer and verifier agree on out of band.

## Definitions

- **Consent window**: a signed statement by the owner's *human identity key*
  that an agent MAY act autonomously within a bounded time interval and scope.
- **Revocation**: a signed statement by the same human key that a window is over,
  effective immediately regardless of its original expiry.
- **Verifier**: any party (recipient, harness, node) deciding whether an agent
  action is currently authorized.

## The window

A consent window is a signed object with these fields:

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

### Canonical serialization

Signing is over a **compact JSON array in fixed field order**, following the
NIP-01 event-id precedent (positional, no object-key ordering to disagree
about, no whitespace):

```
serialization = ["consent_window",<agent>,<scope>,<not_before>,<not_after>,<nonce>]
message       = SHA256(UTF8(serialization))
sig           = BIP-340 Schnorr(message, human_identity_secret_key)
```

Strings are JSON-escaped; integers are canonical decimals with no leading zeros,
no `+`, and no fractional part. There is **no whitespace anywhere** in the
serialization. `agent` is lowercase hex.

Rules:

1. **Human-signed only.** A window signed by the agent key MUST be rejected. An
   agent cannot self-authorize (this is the property NIP-OA provenance and this
   NIP jointly protect, and it mirrors NIP-OA's self-attestation rule).
2. **Bounded duration.** `not_after − not_before` MUST NOT exceed an
   implementation ceiling (RECOMMENDED ≤ 30 days). An unbounded window is a
   reusable capability, which is what NIP-OA already is; this NIP is for the
   bounded case. Verifiers MUST enforce the ceiling on receipt, so a hostile
   issuer cannot mint itself a decade.
3. **Clock-enforced.** A verifier evaluates `not_before ≤ now < not_after`
   against **its own** clock at action time. Expiry needs no relay. This is a
   deliberate departure from NIP-OA, whose verification MUST NOT depend on the
   verifier's clock: NIP-OA is proving a *past* authorization event, while this
   NIP is deciding a *present* permission, and a present permission that ignores
   the present is not one.

## Revocation

The owner ends a window early by publishing (or sealing) a signed revocation:

```jsonc
{ "type": "consent_revoke", "agent": "<agent_pubkey_hex>", "nonce": "<window nonce>" }
```

serialized and signed the same way:

```
serialization = ["consent_revoke",<agent>,<nonce>]
message       = SHA256(UTF8(serialization))
sig           = BIP-340 Schnorr(message, human_identity_secret_key)
```

signed by the same human identity key that signed the window. A verifier that
has seen a matching revocation MUST treat the window as closed from that moment,
regardless of `not_after`. Because the revocation is a self-contained signed
object, it works under an untrusted relay — no membership drop, no relay
authority required. A revocation is idempotent and MUST be retained at least
until the revoked window's `not_after` has passed.

## Verifier behavior

An agent action is authorized at time `now` iff **all** hold:

1. A valid consent window exists for `(agent, scope)` with
   `not_before ≤ now < not_after`, signed by the owner's human key.
2. No valid revocation for that window's `nonce` has been seen.
3. (If provenance is also required) a valid NIP-OA /
   [NIP-AS](NIP-AS-sealed-attestation.md) attestation binds the agent to that
   owner.

Absent a live window, an autonomous agent action MUST **fail closed**. A
verifier that cannot evaluate the conditions — malformed object, unknown signer,
clock unavailable — MUST also fail closed.

## Relationship to other NIPs

- [NIP-OA](NIP-OA.md): provenance (*who authorized this agent, forever*). This
  NIP adds *for how long, in what scope, and revocably* — orthogonal and
  composable. A deployment may use either, or both.
- [NIP-AA](NIP-AA.md): relay-side revocation for trusted deployments. This NIP is
  the relay-independent counterpart for untrusted-relay deployments. They are not
  in competition: a trusted-relay workspace gets stronger immediate revocation
  from NIP-AA, and this NIP covers the case where no such authority exists.
- [NIP-AS](NIP-AS-sealed-attestation.md): a window MAY be carried inside a seal
  for metadata privacy.
- [NIP-AD](NIP-AD-untrusted-data-admission.md): a live window authorizes an agent
  to *act*; it says nothing about whether the content it read is safe. Both
  apply.

## Security considerations

**Clock skew.** Verifiers enforce expiry with local clocks; a window's bounds
should allow for reasonable skew. Timestamps here are authorization bounds, never
key-derivation inputs.

**Revocation propagation.** Under an untrusted relay a revocation must reach the
verifier to take effect. Owners requiring immediate global revocation should
narrow `not_after` accordingly; the bounded-duration rule caps the exposure
window even if a revocation is delayed. This is strictly better than the status
quo (no owner-initiated revocation at all) and strictly weaker than a trusted
relay's ability to drop a connection — implementers should choose accordingly.

**Replay.** A window is a bearer statement about `(agent, scope)`, not a
one-time token; re-presenting it within its bounds is expected. The `nonce` is a
revocation target, not an anti-replay device.

**Human key exposure.** The window is signed by the human identity key, not the
agent key. Implementations MUST NOT hold the human key in the agent's process —
that would let a compromised agent sign its own windows and defeat rule 1
entirely.

**Grant sprawl.** A verifier accepting windows from many issuers SHOULD bound how
many live windows it retains per issuer; unbounded acceptance of signed objects
from a peer is a memory-exhaustion primitive fed by another party's machine.

## Test vectors

> **TEST KEYS — DO NOT USE IN PRODUCTION.** Keys are NIP-OA's, so an
> implementation that already passes NIP-OA's vector reuses the same key
> material here. `schnorr_aux` is all zeros for every signature below;
> production code MUST source aux from a CSPRNG.

### Inputs

```
human_secret = 0000000000000000000000000000000000000000000000000000000000000001
human_pubkey = 79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
agent_secret = 0000000000000000000000000000000000000000000000000000000000000002
agent_pubkey = c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5
schnorr_aux  = 0000000000000000000000000000000000000000000000000000000000000000

scope      = channel:7f3a
nonce      = 9f2c1a7b4e6d80f3
not_before = 1750000000
not_after  = 1750604800          (not_before + 7 days)
```

### Vector 1 — consent window

```
serialization = ["consent_window","c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5","channel:7f3a",1750000000,1750604800,"9f2c1a7b4e6d80f3"]
sha256        = f2c136defe0cba238555a212e71067c83392e3985eee83d69e2870df1b613838
sig           = e06cb3567d3637d1df4b30fb5acd53e1f8de90086124bbd250497cd50ba321ff7b56a05e945f0b4a9ad3c6d0fe4f1edbb61f3063567aa46fc554fb194163a036
```

Verifies against `human_pubkey`. Duration is 604800 s = 7 days, within the
RECOMMENDED 30-day ceiling.

### Vector 2 — revocation of Vector 1

```
serialization = ["consent_revoke","c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5","9f2c1a7b4e6d80f3"]
sha256        = 8c42c7fccc6a9e8d7d99de382dcd982e26f99677984f475e6230f784bdb5ad09
sig           = dd7ea749ef60f1df7519b765d3ac99553562e5e3d277496a48fb9a3d1565a38ae48043dd26fdd5ce18b558f8a635d0e283093e2f6c9b39ec61135e35f1bfd662
```

After a verifier has seen this, Vector 1 is closed at every `now`, including
`now < 1750604800`.

### Vector 3 — NEGATIVE: agent-signed window MUST be rejected

The same serialization as Vector 1, signed with `agent_secret` instead of
`human_secret`:

```
sig = 564f7bf690edc07048578b8d5ec34a391efc420a6308ecba2baf0919e7fd4d3c65c8014776d4e287a36d43d70f1433eccaaccbe27b1ae8a028e039ff9c414259
```

This signature is cryptographically valid **against `agent_pubkey`** and MUST
still be rejected: rule 1 requires the signer to be the owner's human identity
key. An implementation that verifies the signature without checking *whose* key
it is will accept a self-authorizing agent.

### Vector 4 — boundary behavior

With Vector 1's window and no revocation seen:

| `now`        | Authorized |
|--------------|------------|
| `1749999999` | no — before `not_before` |
| `1750000000` | yes — `not_before` is inclusive |
| `1750604799` | yes |
| `1750604800` | no — `not_after` is exclusive |

## Reference implementation

Eldr's `AgentEngine` implements exactly this: `AIWindowAnnouncement` is
human-key-signed and time-bounded, `receiveWindow` gates on `clock.now()` against
`maxWindowDuration`, `endMyAIWindow` emits a signed revocation, and
`authorizeAutonomousSend` fails closed absent a live window. Its standing-grant
variant adds scope + budget, is human-signed, ≤ 30-day bounded, revocable, and
bounded to 64 live grants per granter — the shipping instance of this spec. The
vectors above were generated with the same BIP-340 implementation Eldr uses to
pass NIP-OA's vector.
