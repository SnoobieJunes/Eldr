NIP-AS
======

Sealed Attestation — agent provenance without public linkage
------------------------------------------------------------

`draft` `optional`

**Depends on**: [NIP-OA](NIP-OA.md) (credential format and signing flow),
[NIP-59](59.md) (gift wrap)

## Abstract

This NIP defines a way to carry a [NIP-OA](NIP-OA.md)-equivalent owner
attestation **inside** a [NIP-59](59.md) gift-wrapped message, so a recipient
can verify that an agent was authorized by an owner **without** that
owner↔agent relationship being publicly observable. It adds no event kind and
no new cryptography: the credential math is NIP-OA's, unchanged. Only the tag's
position moves.

## Motivation

NIP-OA's `auth` tag is a public, reusable credential: it appears in cleartext on
events the agent publishes, and NIP-OA §Privacy Considerations states plainly
that "Including an `auth` tag intentionally links the owner key and the agent
key. Verifiers MAY correlate all events that reuse the same owner key and agent
key pair." For a public workspace that is the right trade — discoverability is a
feature, and NIP-AA depends on the relay seeing the linkage in order to admit a
virtual member.

For **private** or **metadata-sensitive** messaging it is not. A user running an
agent inside NIP-59 gift wraps has deliberately hidden sender, content, and
timestamp from the relay. Attaching a cleartext NIP-OA tag to prove the agent's
provenance would re-expose exactly the owner↔agent linkage the gift wrap exists
to hide. NIP-OA already names the alternative and its cost: "Agents that omit
the `auth` tag avoid this disclosure but also omit the provenance claim defined
by this NIP." Today those are the only two options — disclose the relationship
publicly, or make no provenance claim at all. There is no way to prove "an owner
authorized this agent" to the *recipient only*.

NIP-59 already treats the gift-wrap payload as opaque, and [NIP-PL](NIP-PL.md)
already relies on that opacity, so the ecosystem understands the primitive.
Nobody has specified provenance *within* it. This NIP does, and it is
deliberately a five-line change to an existing NIP-OA implementation.

## Non-Goals

This NIP does not replace NIP-OA. Public attestation remains correct where
discoverability is wanted, and [NIP-AA](NIP-AA.md) relay admission **requires**
the public form — a sealed attestation is invisible to a relay by construction
and therefore cannot serve as a relay-admission credential.

This NIP does not define a new event kind, a new signature scheme, or a new
condition grammar. All three are NIP-OA's.

This NIP does not define the transport's confidentiality properties; it inherits
whatever the enclosing wrap provides.

This NIP does not define authorization lifetime or revocation. See
[NIP-AC](NIP-AC-consent-windows.md).

## Definitions

- **Rumor**: the unsigned inner event of a NIP-59 gift wrap.
- **Seal**: the NIP-59 middle layer, signed by the sender's real key.
- **Sealed attestation**: an owner-authorization proof carried inside the seal,
  verifiable only after unwrap.

## The attestation

The rumor (or seal) carries an `oa_sealed` tag with the same semantics as a
NIP-OA `auth` tag, but positioned inside the encrypted layers:

```json
["oa_sealed", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
```

The signature is computed identically to NIP-OA:

```
preimage = "nostr:agent-auth:" || agent_pubkey_hex || ":" || conditions
message  = SHA256(preimage)
sig      = BIP-340 Schnorr(message, owner_secret_key)
```

where `agent_pubkey` is the rumor's `pubkey` (the agent is the real author of
the inner event). `conditions` uses the NIP-OA grammar unchanged (`kind=<n>`,
`created_at<<t>`, `created_at><t>`, `&`-joined, canonical decimals).

A verifier MUST reject an `oa_sealed` tag whose owner pubkey equals the rumor's
`pubkey` — the self-attestation rule of NIP-OA applies unchanged, for the same
reason (an agent must not bootstrap its own provenance).

## Verification

A recipient, **after** unwrapping the gift wrap:

1. Confirms the seal's signature is by the claimed agent key (NIP-59).
2. Reconstructs the NIP-OA preimage from the rumor `pubkey` and `conditions`.
3. Verifies the `oa_sealed` signature against the owner pubkey in the tag.
4. Confirms the rumor satisfies `conditions` (kind, time bounds).

Only then does the recipient treat the message as owner-attested. Because the
tag lives inside the encrypted layers, **the relay and any passive observer
learn nothing** about the owner↔agent relationship — the attestation is proven
to the recipient and no one else.

As in NIP-OA, verification MUST NOT depend on the verifier's local clock,
receipt time, or relay storage time; `conditions` constrain the rumor's own
`created_at`.

## Relationship to other NIPs

- [NIP-OA](NIP-OA.md): identical credential math and grammar; the only change is
  *where* the tag lives (inside the seal, not on a public event). An
  implementation can share its NIP-OA sign/verify code verbatim.
- [NIP-59](59.md): the transport. This NIP adds no new event kind — it is a tag
  convention inside an existing gift wrap.
- [NIP-AA](NIP-AA.md): explicitly out of scope. NIP-AA needs the relay to read
  the credential; this NIP hides it from the relay. An agent needing both
  presents a public `auth` tag at AUTH time and an `oa_sealed` tag inside its
  messages.
- [NIP-AC](NIP-AC-consent-windows.md): a sealed attestation says *who authorized
  the agent*; a consent window says *for how long and revocably*. They compose.

## Security considerations

**Provenance is only as private as the wrap.** A recipient who re-publishes the
unwrapped rumor discloses the attestation. Implementations MUST NOT surface the
`oa_sealed` tag outside the decrypted context.

**Reusable capability, unchanged.** A sealed attestation is a NIP-OA credential
and inherits its capability semantics: any holder of the agent's secret key can
attach the same tag to further rumors satisfying `conditions`. Sealing changes
who can *see* the credential, not how long it lasts. Bounded, revocable
authorization is [NIP-AC](NIP-AC-consent-windows.md)'s job.

**No forward secrecy is added or removed.** This NIP inherits the
confidentiality properties of whatever wrap carries it. When carried inside a
forward-secret ratcheted channel (as in Eldr), a compromised long-term key does
not retro-expose past attestations; inside a plain NIP-44 wrap it does — same as
NIP-OA.

**The recipient is now a disclosure surface.** Public attestation is verifiable
by anyone and therefore deniable by no one; a sealed attestation is verifiable
only by recipients, so a recipient's compromise discloses the relationship to
exactly the parties that already received the messages. This is the intended
trade, not an oversight.

## Test vectors

Because the credential math is NIP-OA's verbatim, NIP-OA's test vector applies
unchanged with `agent_pubkey` read from the rumor rather than from
`event.pubkey`. Restated for completeness, using NIP-OA's pinned keys:

```
owner_secret = 0000000000000000000000000000000000000000000000000000000000000001
owner_pubkey = 79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
agent_secret = 0000000000000000000000000000000000000000000000000000000000000002
agent_pubkey = c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5

conditions = kind=1&created_at<1713957000
preimage   = nostr:agent-auth:c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5:kind=1&created_at<1713957000
```

The resulting tag, placed on the **rumor** (whose `pubkey` is `agent_pubkey`)
rather than on a published event:

```json
["oa_sealed", "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
 "kind=1&created_at<1713957000", "<sig from NIP-OA vector>"]
```

A conforming implementation MUST produce the same `sig` as NIP-OA's vector for
these inputs; if it does not, the two implementations disagree on the preimage,
not on this NIP.

> **TEST KEYS — DO NOT USE IN PRODUCTION.**

## Reference implementation

Eldr proves agent provenance to the recipient inside its NIP-59 gift wrap using
its derived-agent-key signature (`participant_type:"agent"` requires an agent
signature over the ciphertext, verified post-unwrap). This NIP generalizes that
to the portable NIP-OA credential shape so any NIP-59 client can verify a Buzz-
ecosystem owner's attestation without the relay learning the relationship.
Eldr's NIP-OA codec is byte-exact against the NIP-OA vector above.
