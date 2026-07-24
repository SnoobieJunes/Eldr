# Eldr ↔ Buzz Pairing — key architecture and both attestation modes

> **Design doc. Nothing here is implemented.** Companion to
> `INTEROP-LANDSCAPE.md` (same directory), which establishes why a gateway is
> the right integration shape and why Buzz needs no changes. This doc answers
> the narrower question: *what keys, and how do the two sides recognize each
> other?*
>
> Written 2026-07-23. **Deliberately kept outside the Eldr repo** — active work
> is underway on branch `gooseworld-on-main` touching `EldrNodeMain.swift`,
> `NodeKeychain.swift`, `GooseworldMCPServer.swift`, `eldr-gooseworld/main.swift`,
> and adding `FileIdentityStore.swift`. **Line-number citations below will
> drift**; symbol names are the stable reference. Re-verify against HEAD before
> implementing.
>
> **Decision taken: support both Option A and Option B.** They serve different
> threat models and the selection is per-pairing, not global.

---

## 1. Why there cannot be one key

Buzz and Eldr sign on **different elliptic curves**. This is arithmetic, not
policy — no conversion, no shared representation, no clever encoding.

| | Curve | Signature | Used for |
|---|---|---|---|
| **Buzz / Nostr** | secp256k1 | BIP-340 Schnorr | every event |
| **Eldr PQRC identity** | Curve25519 | Ed25519 | application identity, gates, agent provenance |

Eldr's own source states the constraint (`PQRCCore/…/PQRCIdentity.swift`,
doc comment on `PQRCIdentity`):

> Distinct from the secp256k1 Nostr signing key: Nostr events require BIP-340
> signatures, which Ed25519 cannot produce, so a PQRC user holds both and binds
> them.

So "use the same key" is off the table. The useful question is *which key Buzz
sees*, and the answer is already sitting in the keychain.

## 2. What Eldr already holds

`NodeKeychain` loads-or-creates four pieces of key material per node: **a Nostr
identity, a PQRC identity seed, an identity-DH seed, and a prekey**. The Nostr
identity is `P256K.Schnorr` — secp256k1, BIP-340 (`PQRCNostr/…/NostrKeypair.swift`).

**That key already satisfies Buzz's entire join requirement**: secp256k1
keypair, BIP-340 signing, NIP-01 canonical JSON, WebSocket, NIP-42 AUTH.
No new cryptography is needed for a node to be a Buzz principal.

### 2.1 The binding pattern already exists

Eldr has already solved "prove a secp256k1 key and an Ed25519 key are one
principal, verifiable in both directions" — that is kind-10420
(`PQRCNostr/…/PQRCEvents.swift`, `bindingEvent` / `verifyBindingEvent`):

```
outer signature: the Nostr key (secp256k1 / BIP-340)
tags:
  ["pqrc_version",      <version>]
  ["identity_key",      <Ed25519 identity pubkey, hex>]
  ["agent_key",         <Ed25519 agent pubkey, hex>]
  ["binding_sig",       <cross-signature, base64>]
  ["pqrc_capabilities", ...]
```

The Nostr key signs an event asserting the identity key; the identity key
cross-signs back. Neither can unilaterally claim the other — CLAUDE.md
invariant 7, re-verified on every restore.

**Pairing with Buzz is the same shape at a different boundary.** Reuse this
rather than inventing a second binding mechanism.

---

## 3. Option A — Bound Town Identity

*The node's existing Nostr key is the Buzz member key.*

### Mechanics

1. The Eldr node already has its Nostr keypair and a published kind-10420
   binding.
2. A Buzz operator adds that pubkey as a relay member (allowlist row).
3. The gateway authenticates to Buzz over NIP-42 using **that same key**.
4. Buzz sees an ordinary member. Eldr sees its own node identity.

### Properties

- **Zero new key material.** Nothing generated, nothing to back up, nothing to
  rotate independently.
- **Publicly verifiable linkage.** Anyone can fetch the 10420 event and confirm
  that Buzz member `npub1…` is the same principal as PQRC town `Y`. For a
  *town* gateway this is a feature — you want a town to be identifiable and
  accountable as that town.
- **Single revocation point.** Removing the membership row cuts Buzz access
  without touching Eldr identity.

### Cost

**Public correlation.** Buzz activity and Eldr identity become linkable by
anyone, permanently — 10420 is a public replaceable event and Buzz events are
relay-visible to members. This is not recoverable after the fact.

### Use when

The gateway represents a **town or organization** whose identity is meant to be
public, and where accountability across the boundary is desirable.

---

## 4. Option B — Attested Gateway Identity

*A fresh secp256k1 key, authorized by a Buzz member via NIP-OA.*

### Mechanics

1. Generate a fresh secp256k1 keypair for the gateway. It is **not** derived
   from and **not** bound to the Eldr identity.
2. A human who is already a Buzz member signs a NIP-OA `auth` tag over it
   (`buzz/docs/nips/NIP-OA.md`, `buzz-sdk/src/nip_oa.rs`):

   ```json
   ["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
   ```

   signed over `SHA256("nostr:agent-auth:" || <gateway-pubkey-hex> || ":" || <conditions>)`.

3. Conditions use Buzz's validated grammar — `kind=<n>`, `created_at<n>`,
   `created_at>n`, `&`-joined, canonical base-10, no whitespace. For a chat
   bridge: `kind=9&created_at<<expiry>`.
4. The gateway presents the attestation inside its kind-22242 AUTH event. If
   the owner is a relay member, it connects with no membership row of its own
   (NIP-AA virtual membership).

### Properties

- **No public linkage** between Buzz presence and Eldr identity.
- **Conditioned capability.** The attestation constrains kinds and time
  window — a genuine capability, not a blanket credential.
- **Reusable.** One tag, many events.
- **Cascading revocation.** Drop the owner's membership and the gateway's next
  connect fails (NIP-AA).
- **Reference implementation exists.** `buzz/examples/countdown-bot` implements
  exactly this path (`src/main.rs`, "owner-attested" mode) in ~600 lines.

### Cost

- Requires `BUZZ_ALLOW_NIP_OA_AUTH` on the target relay. **Defaults to `false`**
  (`buzz-relay/src/config.rs`) — the operator must opt in, so this is not
  unilaterally available.
- Separate key to store, back up, and rotate.
- Provenance is weaker by design: observers see an authorized agent, not which
  town it fronts. That is the point, but it means cross-boundary accountability
  must be handled some other way.

### Use when

The gateway represents an **individual agent**, or when correlation between
Buzz activity and Eldr identity is unwanted, or when the Eldr side wants to
bridge without publishing a town↔community relationship.

---

## 5. Supporting both

The two options differ only in **how the gateway's Buzz-facing key is
authorized**. Everything downstream — subscription, translation, framing,
grants — is identical. So the split belongs at the bottom of the gateway, as a
per-pairing setting:

```
GatewayIdentityMode
  ├── .boundTown          // Option A: reuse node Nostr key; 10420 provides linkage
  └── .attestedGateway(   // Option B: dedicated key + NIP-OA
        keyRef:  KeychainRef,     // e.g. "buzzgw.<pairingId>"
        auth:    NIPOAAttestation // owner pubkey, conditions, sig
      )
```

Per-pairing, not global: one deployment may bridge a public town to one
community and a private agent to another. Storing the mode alongside the
existing `WorldTown` grant record keeps the trust decisions in one place.

**Keychain convention.** Option B keys follow the established per-item pattern
(`apikey.<id>` today) — use `buzzgw.<pairingId>`. Never store a gateway key in
UserDefaults; note that `ConfiguredAI` currently persists to UserDefaults in
plaintext, which is fine for display config and would not be fine here.

---

## 6. The pairing ceremony

The asymmetry matters and is the most likely source of confusion:

- **Buzz membership is server-granted.** An operator inserts an allowlist row,
  or a member issues a NIP-OA attestation. Closed by default.
- **Eldr pairing is a mutual peer act.** Invite-based, human-performed, no
  public directory, with each plane granted separately (`WorldTown.wallPlaneGranted`,
  `.delegatePlaneGranted`).

Neither side's model subsumes the other, so pairing is genuinely two-sided.

### Option A flow

1. **Eldr side** — node exists; kind-10420 binding published.
2. **Human, out of band** — conveys the node's npub to the Buzz operator.
3. **Buzz side** — operator adds the npub as a relay member; notes the channel
   UUID to bridge.
4. **Eldr side** — records the community as a paired town: relay URL, channel
   UUID, label, `identityMode = .boundTown`.
5. **Eldr side** — human signs a `standing_grant` scoping planes, budgets, and
   expiry.

### Option B flow

1. **Eldr side** — gateway generates a fresh secp256k1 key; stores at
   `buzzgw.<pairingId>`.
2. **Human, out of band** — conveys the gateway pubkey to a Buzz *member*
   (not necessarily an operator).
3. **Buzz side** — that member signs the NIP-OA attestation with conditions and
   expiry, returns the `auth` tag.
4. **Eldr side** — stores the attestation with the pairing;
   `identityMode = .attestedGateway(...)`.
5. **Eldr side** — human signs the `standing_grant` as above.

**Both flows end at the same place**: a `standing_grant` is what actually
authorizes traffic. The attestation gets you *onto* Buzz; the grant governs what
may *cross*. Keeping those separate preserves invariant 9 — the Buzz side can
never widen what Eldr permits.

### Revocation

| | Option A | Option B |
|---|---|---|
| Cut Buzz access | remove membership row | revoke owner membership (cascades) or let conditions expire |
| Cut crossing traffic | revoke `standing_grant` | revoke `standing_grant` |
| Cut everything | both | both |

Note NIP-OA has **no explicit revocation event** — revocation is via the owner's
membership or condition expiry. So set `created_at<` bounds deliberately rather
than far in the future.

---

## 7. Addressing

**A Buzz destination is the pair `(relay host URL, channel UUID)` — never the
UUID alone.** Buzz resolves the community from the HTTP Host header before AUTH,
and channel UUIDs are explicitly scoped per community, so *the same UUID
legitimately exists in two different communities*
(`buzz-auth/src/access.rs`). Storing a bare UUID is a latent
cross-community misroute.

Eldr's side is already correctly shaped: `WorldTown.id` is a local pairing
label, deliberately not an identity key, with the real identity held by the
node.

Every Buzz message the gateway emits needs an `h` tag equal to the channel
UUID on kind-9. Omitting it is rejected.

---

## 8. Message mapping, and the one real gap

### Maps cleanly

| Eldr | Buzz |
|---|---|
| Wall post (`WallPost`) | kind-9 with `h` tag |
| Inbound Buzz kind-9 | wall post, wrapped in `UntrustedDataEnvelope` |
| Town roster | channel membership |

Inbound content **must** go through `UntrustedDataEnvelope` — quoted,
nonce-fenced, control-char-escaped. Cross-boundary text reaching an
orchestrator that spawns shells is the dominant risk in the whole design
(GOOSEWORLD.md §4.1), and Buzz content is exactly that.

### Does not map: task delegation

**Buzz has no request/response primitive.** Its job kinds 43001–43006
(JOB_REQUEST / ACCEPTED / PROGRESS / RESULT / CANCEL / ERROR) are declared in
`buzz-core/src/kind.rs` but have **no dispatcher** — they appear only in
`buzz-db/src/feed.rs` as activity-feed filters. Reserved integers, nothing more.

Two options, and the second is better:

1. **Convention over kind-9** — encode A2A task frames in message content.
   Cheap, but invents a private protocol on someone else's wire and inherits no
   correlation guarantees.
2. **Gateway holds A2A task state** — Buzz only ever sees chat; the gateway
   maintains the task lifecycle (submitted → working → completed/failed) and
   correlates. Keeps correlation logic in one place, consistent with
   `INTEROP-LANDSCAPE.md` §7.

Option 2 makes the gateway **stateful**, which changes its failure model: a
gateway restart must not orphan in-flight tasks. Task state needs to persist
(the node already has an encrypted store) and reconcile on reconnect.

---

## 9. E2EE termination — the disclosure requirement

**The gateway necessarily terminates end-to-end encryption.** Eldr's premise is
that the relay is hostile and sees only ciphertext; Buzz's relay is the source
of truth and sees plaintext for the kinds it routes. Bridging two crypto
regimes means decrypting at the boundary. This is inherent, not a defect.

Non-negotiables that follow:

- The gateway **MUST** be operated by the town owner. Never a third party,
  never a hosted convenience.
- The boundary **MUST** be visible in-product, with the same transparency
  property the `ai_window` banner already has: *"messages crossing into
  &lt;community&gt; are readable by that relay's operator."*
- The existing per-chat egress firewall is the natural enforcement point —
  reuse it rather than adding a parallel mechanism.
- THREAT_MODEL needs an entry before any of this ships. The metadata story
  changes materially: Buzz learns timing, volume, membership, and (Option A)
  the town↔community linkage.

---

## 10. Security notes

- **Do not let Buzz-side state widen Eldr grants.** The attestation authorizes
  connection; only a human-signed `standing_grant` authorizes crossing. Keep
  the two checks independent and fail closed on either.
- **Option A's linkage is irreversible.** Once a 10420-bound npub has posted to
  a Buzz community, the correlation is public and permanent. Choose the mode at
  pairing time, deliberately.
- **NIP-OA conditions are the only bound on an attested gateway.** With
  `created_at<` far in the future and no owner-membership change, the
  capability is effectively permanent. Set short windows and re-attest.
- **Buzz's read gate will surprise you.** REQs matching p-gated kinds are
  rejected unless every `#p` equals the authed pubkey, and omitting `kinds`
  entirely triggers it. The gateway must enumerate kinds explicitly.
- **Size limits.** Buzz: 512 KiB WS frame, 256 KiB event content, 65,535 B
  NIP-44 plaintext ceiling. Eldr chunks above these via `RelayFraming`; the
  gateway must re-chunk or reject rather than silently truncate.
- **Inbound is untrusted, always.** See §8.

---

## 11. Open questions

1. **Does the gateway run in-process with `eldr-node`, or as a separate
   binary?** Separate is better for blast radius (it holds plaintext) and
   matches the `eldr-gooseworld` loopback+token pattern already established.
   Decide before building.
2. **Whose relay carries Eldr-side traffic when both sides are bridged?**
   Kind spaces do not collide and both use kind-1059 gift wrap, so a single
   relay *could* carry both — but that couples availability. Probably keep
   them separate.
3. **Multi-community fan-out.** One town bridged to several Buzz communities:
   does a wall post go to all of them? Almost certainly not by default —
   per-community plane grants, like `WorldTown` already does per-town.
4. **Identity rotation.** Option B key rotation requires re-attestation by the
   owner. Is there a ceremony for that, or does rotation mean re-pairing?
