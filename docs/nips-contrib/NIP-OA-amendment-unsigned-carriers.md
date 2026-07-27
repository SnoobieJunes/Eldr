NIP-OA amendment — verification inside unsigned carriers
=========================================================

This is a proposed amendment to [NIP-OA](NIP-OA.md), not a new NIP. It replaces
an earlier draft ("NIP-AS Sealed Attestation") that proposed a separate `oa_sealed`
tag. That draft was withdrawn: the tag, the preimage, the grammar and the
signature were all NIP-OA's unchanged, so it amounted to a second name for `auth`.

## The gap

NIP-OA already permits the tag anywhere: "Events MAY include zero or one `auth`
tag." Nothing requires the carrying event to be published, signed, or visible to a
relay. A [NIP-59](59.md) rumor is "the same thing as an unsigned event" and carries
`pubkey`, `kind`, `created_at`, and `id` — everything the preimage and the clause
evaluation need. [NIP-17](17.md) already requires that the seal's pubkey equal the
rumor's pubkey, "otherwise any sender can impersonate any other by simply changing
the pubkey on the rumor", so the seal's signature already authenticates the agent
key the preimage uses.

So an owner attestation inside a gift wrap is constructible today, with no new
cryptography and no new tag — except for one rule that forbids it. NIP-OA §Client
Behavior requires:

> Clients MUST validate the event according to the core Nostr event rules,
> including that `id` and `sig` are valid for `event.pubkey`, before treating an
> `auth` tag as verified provenance.

A rumor has an `id` but structurally has no `sig`. A conforming verifier therefore
can never accept an `auth` tag inside a gift wrap, and NIP-OA's Privacy
Considerations leaves only two options: disclose the owner-agent linkage publicly,
or make no provenance claim at all.

## The change

Add a section to NIP-OA, after `## Client Behavior`. Written in NIP-OA's
one-sentence-per-line style.

```markdown
## Unsigned Carriers

An `auth` tag MAY appear on an unsigned event, including a [NIP-59](59.md) rumor.
An unsigned carrier has no `sig`, so the authenticity precondition in Client Behavior cannot be satisfied by the carrier itself.
Verifiers MUST NOT treat an `auth` tag on an unsigned carrier as verified provenance unless an enclosing signed layer authenticates the carrier's `pubkey`.
For a NIP-59 rumor that layer is the seal: the verifier MUST confirm the seal's signature is valid and that the seal's `pubkey` equals the rumor's `pubkey`, as [NIP-17](17.md) already requires.
The signing preimage is unchanged and uses the rumor's `pubkey`.
Conditions are evaluated against the rumor's `kind` and `created_at`, which NIP-59 designates as canonical.
Verifiers MUST NOT substitute the seal's or gift wrap's `created_at`, which NIP-59 permits to be tweaked.
An `auth` tag carried inside a gift wrap is not observable by the relay, so the correlation described in Privacy Considerations is disclosed to recipients only.
Implementations MUST NOT surface the tag outside the decrypted context.
```

## Test vectors

None required. The credential is NIP-OA's, so NIP-OA's existing vector applies
unchanged with `agent_pubkey` read from the rumor rather than from a published
`event.pubkey`. An implementation that passes NIP-OA's vector passes this.

## Reference implementation

Eldr proves agent provenance to the recipient inside its NIP-59 gift wrap, verified
after unwrap. Its NIP-OA codec is byte-exact against the vector above.

## Why this is smaller than it looks

The amendment adds no event kind, no tag, no cryptography, and no condition
grammar. It resolves an interaction between two existing NIPs that currently makes
a legal construction unverifiable.
