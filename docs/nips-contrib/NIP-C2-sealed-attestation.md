NIP-C2
======

Sealed Attestation — agent provenance without public linkage
------------------------------------------------------------

`draft` `optional`

This NIP defines a way to carry an [NIP-OA](NIP-OA.md)-equivalent owner
attestation **inside** a [NIP-59](59.md) gift-wrapped message, so a recipient
can verify that an agent was authorized by an owner **without** that
owner↔agent relationship being publicly observable.

## Motivation

NIP-OA's `auth` tag is a public, reusable credential: it appears in cleartext on
events the agent publishes, and NIP-OA §Privacy states plainly that "the `auth`
tag intentionally links the owner key and the agent key; verifiers MAY
correlate." For a public workspace that is the right trade — discoverability is a
feature.

For **private** or **metadata-sensitive** messaging it is not. A user running an
agent inside NIP-59 gift wraps has deliberately hidden sender, content, and
timestamp from the relay. Attaching a cleartext NIP-OA tag to prove the agent's
provenance would re-expose exactly the owner↔agent linkage the gift wrap exists
to hide. Today there is no way to prove "an owner authorized this agent" to the
*recipient only*.

NIP-59 already treats the gift-wrap payload as opaque, and [NIP-PL](NIP-PL.md)
already relies on that opacity, so the ecosystem understands the primitive.
Nobody has specified provenance *within* it. This NIP does.

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

## Relationship to other NIPs

- [NIP-OA](NIP-OA.md): identical credential math and grammar; the only change is
  *where* the tag lives (inside the seal, not on a public event). An
  implementation can share its NIP-OA sign/verify code verbatim.
- [NIP-59](59.md): the transport. This NIP adds no new event kind — it is a tag
  convention inside an existing gift wrap.
- [NIP-C3](NIP-C3-consent-windows.md): a sealed attestation says *who authorized
  the agent*; a consent window says *for how long and revocably*. They compose.

## Security considerations

**Provenance is only as private as the wrap.** A recipient who re-publishes the
unwrapped rumor discloses the attestation. Implementations MUST NOT surface the
`oa_sealed` tag outside the decrypted context.

**No forward secrecy is added or removed.** This NIP inherits the confidentiality
properties of whatever wrap carries it. When carried inside a forward-secret
ratcheted channel (as in Eldr), a compromised long-term key does not retro-expose
past attestations; inside a plain NIP-44 wrap it does — same as NIP-OA.

## Reference implementation

Eldr proves agent provenance to the recipient inside its NIP-59 gift wrap using
its derived-agent-key signature (`participant_type:"agent"` requires an agent
signature over the ciphertext, verified post-unwrap). This NIP generalizes that
to the portable NIP-OA credential shape so any NIP-59 client can verify a Buzz-
ecosystem owner's attestation without the relay learning the relationship.
