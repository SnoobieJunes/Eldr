## What this adds

Two new drafts, submitted together because they cross-reference and argue one
story:

- `docs/nips/NIP-AS.md` — **Sealed Attestation**: carry a NIP-OA-equivalent
  owner attestation *inside* a NIP-59 gift wrap.
- `docs/nips/NIP-AC.md` — **Agent Consent Windows**: a bounded, human-signed,
  owner-revocable authorization window.

Neither requires a change to existing Buzz code, and neither adds an event kind.
NIP-AS reuses NIP-OA's credential math verbatim — only the tag's position moves.

## NIP-AS — provenance without public linkage

NIP-OA §Privacy Considerations states the trade plainly:

> Including an `auth` tag intentionally links the owner key and the agent key.
> Verifiers MAY correlate all events that reuse the same owner key and agent key
> pair.

and names the only alternative:

> Agents that omit the `auth` tag avoid this disclosure but also omit the
> provenance claim defined by this NIP.

For a public workspace, disclosure is a feature — and NIP-AA *depends* on the
relay seeing the linkage to admit a virtual member. But that leaves exactly two
options for anyone running an agent inside a NIP-59 wrap: publish the owner↔agent
relationship in cleartext, or make no provenance claim at all. There's no way to
prove "an owner authorized this agent" to the **recipient only**.

NIP-AS is that third option: the same `preimage`/SHA-256/BIP-340 construction as
NIP-OA, in an `oa_sealed` tag placed on the rumor instead of on a public event.
An implementation shares its NIP-OA sign/verify code unchanged; the delta is
roughly five lines.

It is explicitly **not** a NIP-AA replacement — a sealed attestation is
invisible to a relay by construction and therefore cannot serve as a relay
admission credential. The spec says so in Non-Goals and again in §Relationship.
An agent needing both presents a public `auth` tag at AUTH time and an
`oa_sealed` tag inside its messages.

## NIP-AC — the revocation instrument

This is the one I expect discussion on, so let me put the argument up front.

NIP-AA §Revocation Semantics is unusually clear about the current state:

> Revocation requires one of: (a) removing the owner from the relay's member
> list, (b) the `auth` tag's `created_at` conditions expiring, or (c) the relay
> applying an independent denylist. NIP-OA credentials are reusable
> capabilities — the owner cannot unilaterally revoke a previously issued `auth`
> tag without one of these mechanisms.

Of those, (a) and (c) are relay actions, and (b) is passive expiry of a
condition the agent itself populates — which the same section flags:

> `created_at` is agent-controlled. A misbehaving agent can set `created_at` to
> any value.

**Under a trusted relay this is fine.** The operator is a real authority and
dropping membership is a real remedy — in that deployment NIP-AA gives you
*stronger* revocation than anything in this draft, because it can kill a live
connection. NIP-AC does not compete with that and says so.

The gap is the other deployment: no operator to call, no membership to drop, no
denylist anyone is obliged to honor. There, an owner who authorizes an agent and
then changes their mind has no signed instrument that says "this is over now."
NIP-AC supplies one — a human-key-signed window with a bounded duration, a
verifier-clock-enforced expiry, and a self-authenticating revocation object that
needs no relay's cooperation to take effect.

The framing throughout is **counterpart, not correction**.

### One deliberate departure worth flagging

NIP-OA requires that verification not depend on the verifier's local clock.
NIP-AC requires the opposite: `not_before ≤ now < not_after` against the
verifier's own clock. That's intentional and called out in the spec — NIP-OA
proves a *past* authorization event, while NIP-AC decides a *present*
permission, and a present permission that ignores the present isn't one. If you
read that as a conflict rather than a distinction, it's the first thing I'd want
to talk about.

## Test vectors

Both specs carry them, generated with a real BIP-340 implementation using
**NIP-OA's pinned test keys**, so anything that already passes NIP-OA's vector
reuses the same key material:

- NIP-AC vector 1: a consent window, canonical serialization → SHA-256 → sig.
- NIP-AC vector 2: its revocation.
- NIP-AC vector 3: **negative** — the same window signed by the *agent* key. The
  signature is cryptographically valid against `agent_pubkey` and MUST still be
  rejected. An implementation that verifies the signature without checking whose
  key it is will accept a self-authorizing agent.
- NIP-AC vector 4: inclusive/exclusive boundary table for `not_before` /
  `not_after`.
- NIP-AS: restates NIP-OA's vector with `agent_pubkey` read from the rumor,
  since the math is unchanged — a conforming implementation MUST produce
  NIP-OA's exact `sig`.

NIP-AC also pins a **canonical serialization** the original draft left
unspecified: a compact positional JSON array following the NIP-01 event-id
precedent, so there's no object-key ordering to disagree about.

## Disclosure

I build [Eldr](https://github.com/SnoobieJunes/Eldr), a privacy-first personal
messenger on the same Nostr substrate — solo / untrusted-relay, post-quantum
ratcheted, E2EE. That's a different product from Buzz, and the relay-trust
difference is exactly why these two drafts exist: they're the primitives that
axiom forces you to build. They're offered because they compose with your specs
rather than replacing them, not as an argument that Buzz should adopt Eldr's
axiom.

Eldr speaks Buzz's existing agent-plane crypto byte-exact against your own
vectors (NIP-44 v2, NIP-OA, NIP-AM, NIP-AO — green in Eldr's suite, including
"NIP-OA verifies the spec-provided signature"). Both drafts are specs Eldr
already runs; the reference implementations are named in each file.

## Licensing

Eldr's protocol documents are CC0 1.0 (public domain) by deliberate choice, so
contributing these under Apache-2.0 is unencumbered. I'm the sole copyright
holder, there's no employer with a claim, and per CONTRIBUTING I'm submitting
them under the Apache 2.0 license with the right to do so.

## Notes for review

- **Naming.** `NIP-AC` rather than the obvious `NIP-CW` because **`NIP-CW` is
  taken** (Channel Window). `AC` (Agent Consent) and `AS` (Agent Sealed
  attestation) are unclaimed and fit the `A*` agent-plane family. Both files say
  maintainers should reassign freely.
- **Split.** Happy to separate these into two PRs if you'd prefer to take one
  without the other — I grouped them because each references the other and NIP-AS
  reads as half a story alone. NIP-AD is already in a separate PR for exactly
  this reason.
- **CI.** Documentation-only; `just ci` covers Rust and mobile, neither of which
  this touches. Not run locally — happy to if you want it.
- **Happy to move this to a Discussion** if the NIP-AC argument is better had
  outside a PR. Genuinely more interested in the conversation than the merge on
  that one.
