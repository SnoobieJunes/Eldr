# RELAY-EPHEMERAL-KEYS-SETUP.md — enabling ephemeral receiving keys on relay.lerants.com

**Audience:** the server-side AI / operator that administers `relay.lerants.com`.
**Goal:** make the relay support EldrChat's **ephemeral receiving keys** (NIP-XX §13,
SPEC §9.3, kind `10422`) so the app feature can be switched on in a later session.
**Status when you start:** the relay is the strict **anchor** relay described in
`docs/guide/RELAY-DEPLOY-CROSTINI.md` (khatru/Go preferred; NIP-42 AUTH read-gate on
kind-1059 by `p`-tag match). Nothing here changes message confidentiality — it only
changes which **routing tag** the relay will deliver on.

> ⚠️ Do **not** flip the EldrChat app toggle until this relay passes the §6 gate below.
> Today, turning ephemeral keys on against the unmodified anchor relay **breaks inbound
> delivery** (a recipient cannot NIP-42 AUTH as an X25519 sub-key), which is exactly why
> the app keeps the feature off until the relay is ready.

---

## 1. Why a relay change is needed (the one-paragraph version)

Messages are gift-wrapped + double-ratcheted regardless of relay — the relay only ever
holds ciphertext. The ephemeral-keys feature replaces the recipient's long-term Nostr
pubkey in the gift-wrap (`kind 1059`) **`p`-tag** with a rotating **X25519 sub-key**
(advertised in a `kind 10422` event), so a passive observer can't link the envelope to
the identity. **But** the anchor relay only serves a `kind 1059` to a reader who has
**NIP-42-AUTHed as the pubkey in that `p`-tag** — and an X25519 sub-key is not a Nostr
(secp256k1) keypair, so the recipient can't AUTH as it. The relay must therefore learn to
deliver sub-key-tagged gift wraps to their rightful owner by another means.

---

## 2. kind 10422 — what the relay will see (from NIP-XX §13)

A **replaceable** event (kind 10000–19999 ⇒ NIP-01 replaceable: keep only the latest per
`pubkey`), authored (outer BIP-340 sig) by the recipient's **Nostr** key:

```json
{
  "kind": 10422,
  "pubkey": "<recipient_nostr_pubkey_hex>",
  "tags": [
    ["pqrc_version", "1"],
    ["identity_key", "<ed25519_identity_pub_hex>"],
    ["public_key",   "<x25519_sub_key_hex>"],     // the rotating routing tag
    ["conversation_binding", "<utf8 domain>"],    // default = recipient identity hex
    ["epoch", "<u64 decimal>"],
    ["sig", "<base64 ed25519 sig, context pqrc-ephemeral-receiving-v1>"]
  ],
  "content": ""
}
```

Facts the relay relies on:
- The event is **signed by the recipient's Nostr key** (`pubkey`) → the relay can trust
  that `pubkey` owns the advertised `public_key` sub-key. (The inner `sig`/`identity_key`
  check is the *client's* job; the relay only needs the outer BIP-340 sig + that the event
  is well-formed.)
- It is **replaceable**: the latest `10422` per `pubkey` is the current sub-key. The app
  also listens on the immediately-previous sub-key during a changeover, so brief overlap
  is normal.
- `epoch` rotates **message-driven** (~every 20–30 messages), so a given identity's
  `10422` is rewritten periodically.

---

## 3. Pick the relay model (decision the operator must ratify)

Three ways to serve sub-key-tagged `kind 1059`. They differ in *who can still link a
sub-key to an identity*. Recommendation: **Model B** for `relay.lerants.com` — it keeps
the existing anti-enumeration guarantee for legacy npub addressing and adds sub-key
support with the least disruption.

| Model | What it does | Keeps anti-enumeration? | Operator can link sub-key→identity? |
|---|---|---|---|
| **A — public `1059` reads** | Drop the AUTH read-gate; serve `kind 1059` by filter to anyone (a normal public Nostr relay for that kind). | ❌ no (npub-tagged `1059` become crawlable) | yes (via the `10422` it stores) |
| **B — AUTH-aware sub-key allowlist (recommended)** | Keep the AUTH read-gate, but when a connection AUTHs as identity X, also let it read `kind 1059` `p`-tagged with the sub-keys from **X's own valid `10422` events** (current + previous). | ✅ yes | yes (via the `10422` it stores) |
| **C — split relays (max unlinkability)** | Publish `10422` to a *different* discovery relay than the one carrying `1059`. The message relay then runs Model A but never sees the `10422` linkage. | n/a | no, on the message relay |

**Important caveat for A and B:** because `relay.lerants.com` would store the `10422`
(which contains `identity_key` + `public_key`, signed by the npub), **the relay operator
can still link a sub-key to the identity**. Ephemeral keys on a single relay hide you from
*passive subscribers/crawlers who don't cross-reference `10422`*, not from the operator.
Operator-blind unlinkability requires **Model C** (host `10422` on a separate relay). This
is a real, documented limit (DEVIATIONS T4 / THREAT_MODEL) — make sure the owner accepts it.

---

## 4. Config changes (khatru / Go — the recommended relay per RELAY-DEPLOY-CROSTINI §4)

### 4.1 Write policy — accept and bound `kind 10422`
- Add `10422` to the accepted-write kind set (currently `1059, 10420, 10421, 10050`).
- Enforce **owner-only writes**: accept a `10422` only if its outer BIP-340 signature is
  valid for `event.pubkey` (khatru validates signatures by default; do not disable it).
  No extra rule is needed — a stranger can't forge an npub's signature.
- Treat `10422` as **replaceable** (NIP-01 10000–19999): keep only the newest per
  `pubkey`. khatru's standard replaceable handling covers this; confirm it's enabled.
- Keep max event size ≥ 1 MB and the existing `1059`/`1042x`/`10050` accepts.

### 4.2 Read gate — extend the `RejectFilter` for `kind 1059` (Model B)
Today the `RejectFilter` rejects any `kind 1059` subscription whose `p` filter ≠ the
AUTHed pubkey. Extend the allowed set from `{authedPubkey}` to
`{authedPubkey} ∪ {sub-keys advertised in the authed pubkey's valid 10422 events}`:

```go
// Pseudocode — adapt to your khatru version's RejectFilter signature.
func rejectKind1059(ctx, authedPubkey string, filter nostr.Filter) (reject bool, msg string) {
    if !hasKind(filter, 1059) { return false, "" }            // not our concern
    if authedPubkey == "" { return true, "auth-required: kind 1059" }

    allowed := map[string]bool{ authedPubkey: true }          // legacy npub addressing
    for _, sk := range currentSubKeysFor(authedPubkey) {      // from this pubkey's 10422(s)
        allowed[sk] = true                                    // current + previous epoch
    }
    for _, p := range filter.Tags["p"] {                      // every requested p-tag
        if !allowed[p] { return true, "auth-mismatch: p-tag not owned by authed key" }
    }
    return false, ""
}

// currentSubKeysFor: query the relay's own store for the latest (and, if you retain it,
// the immediately-previous) kind-10422 authored by `authedPubkey`, and return each
// event's `public_key` tag. Cache briefly; 10422 changes only every ~20–30 messages.
```

Net effect: the AUTHed owner (and only they) can read both their npub-tagged and their
sub-key-tagged `kind 1059`. A reader AUTHed as the wrong key still gets nothing (the §6
gate must still pass for the wrong-key case).

> If the owner instead chooses **Model A**, the change is simpler — stop rejecting
> unauthenticated `kind 1059` reads and serve by filter — but you lose the anti-enumeration
> property for npub-tagged traffic. Only do this if you understand that tradeoff.

### 4.3 Serving `kind 10422` reads
A **sender** must fetch the recipient's current `10422` to learn the sub-key to tag.
Senders are not the owner, so they can't AUTH as the recipient — `10422` reads must be
**servable to non-owners** (open read for kind `10422`). This is what exposes
identity→sub-key to a crawler on this relay (the §3 caveat). If that is unacceptable, use
**Model C** and host `10422` on a separate discovery relay.

### 4.4 If the relay is strfry instead of khatru
strfry's write-policy plugin governs writes only (it can add the `10422` accept), but the
**read-side** sub-key allowlist (§4.2) is not expressible in a stock strfry write plugin —
same limitation as the anchor read-gate (RELAY-DEPLOY-CROSTINI §4). Use khatru for the
read logic, or a strfry build with native NIP-42 read-auth that you extend. Verify with §6.

---

## 5. What the app does (so you can reason about traffic)
- Publishes its own `kind 10422` (current sub-key) and rotates it message-driven.
- **Sends:** fetches the recipient's `10422`, verifies it (outer BIP-340 + inner identity
  sig), and uses the sub-key as the `1059` `p`-tag; **falls back to the identity npub**
  (with a short timeout) if no valid `10422` is found — so an un-upgraded recipient still
  receives.
- **Receives:** subscribes to `1059` p-tagged with its npub **and** its current+previous
  sub-keys (dual-subscribe), AUTHed as its identity. This is why Model B's allowlist must
  include both.
- The feature is **OFF by default** and per-silo; nothing changes until the owner enables
  it in a session *after* this relay passes §6.

---

## 6. Prove it before enabling the app (extend the RELAY-DEPLOY-CROSTINI §5 gate)
Run these against the modified relay; all must hold:

1. **Legacy unchanged:** an unauthenticated reader still gets **zero** `kind 1059`
   (npub-tagged delivery still requires AUTH). [Model B]
2. **Write accept:** publishing a well-formed, npub-signed `kind 10422` succeeds; a
   `10422` with a bad signature is rejected; re-publishing replaces the prior one (only
   the latest is stored).
3. **Sender discovery:** a *different* connection can `REQ` and receive that recipient's
   `kind 10422` (open read).
4. **Sub-key delivery:** publish a `kind 1059` whose `p`-tag is the recipient's advertised
   sub-key; the recipient, **AUTHed as its identity**, subscribing on that sub-key `p`-tag,
   **receives** it.
5. **Cross-key denial:** a reader AUTHed as a *different* identity, subscribing on that
   sub-key, receives **nothing**.
6. **Fallback path:** an npub-tagged `kind 1059` still reaches the AUTHed owner.

Capture the transcript of 1, 4, and 5 — those three are the security-load-bearing cases.

---

## 7. Turn-on checklist (for the later session)
- [ ] Relay passes all of §6 (paste the transcript).
- [ ] Owner has accepted the §3 caveat (operator can link via `10422`, unless Model C).
- [ ] Decide `conversation_binding` policy: keep the **privacy-safe default (recipient's
      own identity hex** = one rotating key). A per-peer binding leaks the social link and
      MUST NOT be used in a cleartext tag without that being understood (NIP-XX §13).
- [ ] Then, in EldrChat, enable ephemeral receiving keys (per-silo). Verify a real
      message round-trips both directions (upgraded↔upgraded and upgraded↔legacy).

## 8. Residual leaks to keep documented (THREAT_MODEL / DEVIATIONS T4)
- The **count** of distinct sub-keys in flight roughly reveals a user's conversation
  count (not who-with).
- The **existence/timing/size** of (still-encrypted) events is publicly visible on a
  by-filter relay; fuzzed timestamps + fixed padding buckets blunt correlation but don't
  remove it.
- Operator can link sub-key→identity on a single relay (§3) — Model C is the only way to
  remove that.
