## What this adds

One new draft:

- `docs/nips/NIP-AC.md` — **Agent Consent Windows**: a bounded, human-signed,
  owner-revocable authorization window.

It requires no change to existing Buzz code and adds no event kind.

## NIP-AC — the revocation instrument

NIP-AA §Revocation Semantics is explicit about the current state:

> Revocation requires one of: (a) removing the owner from the relay's member
> list, (b) the `auth` tag's `created_at` conditions expiring, or (c) the relay
> applying an independent denylist. NIP-OA credentials are reusable
> capabilities — the owner cannot unilaterally revoke a previously issued `auth`
> tag without one of these mechanisms.

Of those, (a) and (c) are relay actions, and (b) is passive expiry of a condition
evaluated against a field the agent itself populates — which the same section
flags:

> `created_at` is agent-controlled. A misbehaving agent can set `created_at` to
> any value.

**Under a trusted relay, this is sound.** The operator is a real authority and
dropping membership is a real remedy — in that deployment NIP-AA gives you
*stronger* revocation than anything in this draft, because it can terminate a
live connection. NIP-AC does not compete with that and says so.

The gap is the other deployment: no operator to call, no membership to drop, no
denylist anyone is obliged to honor. There, an owner who authorizes an agent and
then changes their mind has no signed instrument that says "this is over now."
NIP-AC supplies one.

The framing throughout is **counterpart, not correction**.

## What is actually new here, and what isn't

I want to be precise about this rather than overclaim, because two of the draft's
original selling points turned out to already be yours.

**Not new** — the human-signed rule. NIP-AC requires that a window signed by the
agent key be rejected. That is a restatement of NIP-OA's existing self-attestation
rule ("If `<owner-pubkey-hex>` equals `event.pubkey`, the `auth` tag is invalid
and MUST be rejected") applied to a different object. The draft now labels it as
such. Vector 3 exercises it because implementations get it wrong, not because the
property is novel.

**New, and not expressible within NIP-OA** — two things:

1. **Verifier-clock evaluation.** NIP-OA requires that "Verification MUST NOT
   depend on the verifier's local clock, receipt time, or relay storage time."
   NIP-AC requires the opposite. This is not a disagreement: NIP-OA proves a *past*
   authorization event, while NIP-AC decides a *present* permission. NIP-OA already
   delegates this case — "Relays or clients that require wall-clock freshness MUST
   enforce it independently of this NIP." NIP-AC is an attempt at that independent
   mechanism. If you read it as a conflict rather than a distinction, it's the
   first thing I'd want to talk about.
2. **A revocation object.** `consent_revoke` is a signed statement that ends a
   window before its expiry. I could not find an analogue anywhere in the tree.
   NIP-OA's revocation is forward-only ("Owners MAY revoke future authorization by
   refusing to issue new `auth` tags"), and NIP-AA's three paths are all relay-side.
   Because the object is self-authenticating, it takes effect without any relay's
   cooperation — which is the whole point under an untrusted relay.

Everything else in the draft composes with NIP-OA rather than replacing it.

## Test vectors

Generated with a real BIP-340 implementation using **NIP-OA's pinned test keys**,
so anything that already passes NIP-OA's vector reuses the same key material:

- Vector 1: a consent window, canonical serialization → SHA-256 → sig.
- Vector 2: its revocation.
- Vector 3: **negative** — the same window signed by the *agent* key. The
  signature is cryptographically valid against `agent_pubkey` and MUST still be
  rejected. An implementation that verifies the signature without checking whose
  key it is will accept a self-authorizing agent.
- Vector 4: inclusive/exclusive boundary table for `not_before` / `not_after`.

The draft also pins a **canonical serialization** the original left unspecified: a
compact positional JSON array following the NIP-01 event-id precedent, so there's
no object-key ordering to disagree about.

## Disclosure

I build [Eldr](https://github.com/SnoobieJunes/Eldr), a privacy-first personal
messenger on the same Nostr substrate — solo / untrusted-relay, post-quantum
ratcheted, E2EE. That's a different product from Buzz, and the relay-trust
difference is exactly why this draft exists: it's a primitive that axiom makes
necessary. It's offered because it composes with your specs rather than replacing
them, not as an argument that Buzz should adopt Eldr's axiom.

Eldr speaks Buzz's existing agent-plane crypto byte-exact against your own
vectors (NIP-44 v2, NIP-OA, NIP-AM, NIP-AO — green in Eldr's suite, including
"NIP-OA verifies the spec-provided signature"). This is a spec Eldr already runs;
the reference implementation is named in the file.

## Licensing

Eldr's protocol documents are CC0 1.0 (public domain) by deliberate choice, so
contributing this under Apache-2.0 is unencumbered. I'm the sole copyright
holder, there's no employer with a claim, and per CONTRIBUTING I'm submitting it
under the Apache-2.0 license with the right to do so.

## Notes for review

- **Naming.** `NIP-AC` rather than the obvious `NIP-CW` because **`NIP-CW` is
  taken** (Channel Window). `AC` (Agent Consent) is unclaimed and fits the `A*`
  agent-plane family. The file says maintainers should reassign freely.
- **A companion draft was withdrawn.** An earlier version of this PR also carried
  `NIP-AS.md` (Sealed Attestation), for carrying owner attestation inside a NIP-59
  gift wrap. On closer reading it was almost entirely redundant: NIP-OA already
  permits the `auth` tag on any event, a rumor carries everything the preimage
  needs, and NIP-17 already binds the seal's pubkey to the rumor's. The one real
  obstacle is NIP-OA's `sig` precondition, which a rumor structurally cannot meet.
  That's a verification rule, not a NIP, so it's filed separately as a small
  amendment to NIP-OA.
- **CI.** Documentation-only; `just ci` covers Rust and mobile, neither of which
  this touches. I haven't run it locally; I can run it if you'd like.
- **I'm happy to move this to a Discussion** if the argument is better had outside
  a PR. I'm genuinely more interested in the conversation than in the merge.
