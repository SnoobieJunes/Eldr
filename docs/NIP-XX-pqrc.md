<!-- SPDX-License-Identifier: CC0-1.0 -->

# NIP-XX — PQRC: Post-Quantum Ratcheted Conversations over Nostr

`draft` `optional`

> **This document is public domain (CC0-1.0)** — deliberately, so it can be
> submitted to [nostr-protocol/nips](https://github.com/nostr-protocol/nips)
> ("all NIPs are public domain") and implemented by anyone under any license.
> It is **not** covered by the repository's AGPL. See [`LICENSING.md`](../LICENSING.md).

**Status note.** The original handoff package referenced this document but did
not contain it. This file was authored alongside the v1 reference
implementation to be the normative wire format, derived from
`pqrc-SPEC-v1_1.md` (protocol law) and the field-name contract in `CLAUDE.md`
(`spk`, `pqpk`, `otp`, `otp_pq`, `lrp`, `dh`, `pn`, `n`, `pq`, `ptr`).
Where this NIP fills a gap the SPEC leaves open, the decision is also recorded
in `docs/DEVIATIONS.md` tagged `[upstream-NIP]`. The frozen vectors in
`TestVectors/` are the byte-level contract for a second client.

**Upstream intent.** This document is written for submission to
[`nostr-protocol/nips`](https://github.com/nostr-protocol/nips) once the
protocol and the frozen vectors stabilize; the `[upstream-NIP]` tags in
`docs/DEVIATIONS.md` enumerate exactly what must be reconciled before that
submission. Until it is merged upstream, the event kinds and `pqrc` tag names
used here are provisional and may be renumbered on upstream review.

## 1. Overview

PQRC carries post-quantum, double-ratcheted 1:1 messages as NIP-59 gift-wrapped
events. Event kinds:

| kind  | meaning                              | signed by                |
|-------|--------------------------------------|--------------------------|
| 10420 | identity binding (replaceable)       | Nostr key (secp256k1)    |
| 10421 | prekey bundle (replaceable)          | Nostr key                |
| 10422 | ephemeral receiving key (replaceable, OPTIONAL) | Nostr key (outer) + identity key (inner) |
| 10050 | DM relay list (replaceable)          | Nostr key                |
| 1420  | rumor (NEVER published, unsigned)    | — (unsigned)             |
| 13    | seal                                 | sender's Nostr key       |
| 1059  | gift wrap                            | fresh one-time key       |
| 22242 | NIP-42 AUTH                          | client's Nostr key       |

A PQRC user holds **two long-term keypairs**: a secp256k1 Nostr key (BIP-340,
for events) and an Ed25519 PQRC identity key (for protocol signatures). Nostr
events cannot be signed by Ed25519 keys, so SPEC §3.3's "signed by identity
key" is realized as the two-directional binding below.

All binary values are base64 in JSON bodies and lowercase hex in tags, as shown.

## 2. Domain-separated signature contexts (Ed25519, identity or agent key)

| context string        | message                                                        |
|-----------------------|----------------------------------------------------------------|
| `pqrc-binding-v1`     | ‖ nostr_pubkey(32) ‖ identity_pub(32) ‖ agent_pub(32)          |
| `pqrc-prekey-v1`      | ‖ label(utf8: `ik_dh`/`spk`/`pqpk`/`lrp`) ‖ key bytes          |
| `pqrc-ai-window-v1`   | ‖ active_until(i64be) ‖ enabled_by(32) [‖ thread_id(utf8)]     |
| `pqrc-agent-msg-v1`   | ‖ ratchet ciphertext                                           |
| `pqrc-ephemeral-receiving-v1` | ‖ identity_pub(32) ‖ public_key(32) ‖ conversation_binding(utf8) ‖ epoch(u64be) |

## 3. kind 10420 — identity binding

```json
{
  "kind": 10420,
  "pubkey": "<nostr_pubkey_hex>",
  "tags": [
    ["pqrc_version", "1"],
    ["identity_key", "<ed25519_identity_pub_hex>"],
    ["agent_key", "<ed25519_agent_pub_hex>"],
    ["binding_sig", "<base64 ed25519 sig, context pqrc-binding-v1>"],
    ["pqrc_capabilities", "pqxdh", "double-ratchet", "ml-kem-768"]
  ],
  "content": ""
}
```

Verification is bidirectional and all-or-nothing (no key from an unverified
binding may be used):
1. outer BIP-340 signature verifies under `pubkey` (Nostr key asserts the PQRC keys);
2. `binding_sig` verifies under `identity_key` over the `pqrc-binding-v1`
   context (identity key asserts the Nostr + agent keys).

The agent key is derived per SPEC §3.2; third parties cannot recompute the
derivation (it requires the identity private key) and rely on the binding.

## 4. kind 10421 — prekey bundle

`content` is a JSON object (structured keys with per-key signatures fit JSON
better than flat tags; `[upstream-NIP]`):

```jsonc
{
  "pqrc_version": "1",
  "ik":    "<base64 ed25519 identity pub>",        // binds bundle to identity
  "ik_dh": { "key": "<base64 X25519>", "sig": "<base64>" },  // identity-DH key
  "spk":   { "key": "<base64 X25519>", "sig": "<base64>" },  // signed prekey
  "pqpk":  { "key": "<base64 ML-KEM-768 ek>", "sig": "<base64>" },
  "otp":    ["<base64 X25519>", ...],              // one-time, unsigned
  "otp_pq": ["<base64 ML-KEM-768 ek>", ...],       // one-time PQ, unsigned
  "lrp":   { "key": "<base64 X25519>", "sig": "<base64>" }   // last-resort, OPTIONAL
}
```

`ik_dh` exists because Ed25519→X25519 conversion is not exposed by CryptoKit
and reimplementing it would violate SPEC §2 (no custom primitives); the
dedicated X25519 identity-DH key is signed by the identity key instead.
Signatures use the `pqrc-prekey-v1` context. One-time prekeys are covered by
the outer event signature only (Signal pattern).

## 5. Handshake (PQXDH, suite `hybrid-v2`)

Initiation computes all four PQXDH legs, in the specification's order
(SPEC §4.2):

```
dh1 = X25519(ik_dh_A, spk_B)
dh2 = X25519(ek_A,   ik_dh_B)
dh3 = X25519(ek_A,   spk_B)
dh4 = X25519(ek_A,   otp_B)        # or lrp_B (flagged) or omitted
ss  = ML-KEM-768.Encaps(otp_pq_B or pqpk_B)
SK  = HKDF-SHA256(dh1‖dh2‖dh3‖[dh4]‖ss, salt="pqrc-v1-handshake",
                  info="pqrc-root-key"‖ik_A‖ik_B, 32)
```

`dh1` and `dh2` authenticate — each requires one side's **long-term** key —
while `dh3` and `dh4` supply forward secrecy. `dh2` is the reason compromising
the medium-lived `spk` private half alone is not enough to impersonate the
responder to an initiator working from their published bundle.

The initiator MUST pick `otp_B` and `otp_pq_B` **at random** from the pool the
bundle publishes. A bundle carries the whole pool, so a deterministic choice
(e.g. the first entry) makes any two initiators collide, and the second one's
handshake is then rejected at prekey resolution.

The handshake rumor (`type: "handshake"`) carries message #0 piggybacked (D10):

```jsonc
{
  "suite": "hybrid-v2",
  "ik":         "<base64>",   // initiator identity pub
  "ik_dh":      "<base64>",   // initiator identity-DH pub
  "ik_dh_sig":  "<base64>",   // ik's signature over ik_dh, `pqrc-prekey-v1` context
  "ek":         "<base64>",   // initiator ephemeral pub
  "kem_ct":     "<base64>",   // ML-KEM-768 ciphertext
  "kem_pk":     "<base64>",   // initiator's fresh ML-KEM pub (for responder rekeys)
  "spk_used":    "<base64 sha256 of spk>",   // D4
  "otp_used":    "<base64 sha256>" | null,
  "otp_pq_used": "<base64 sha256>" | null,
  "lrp_used":    false
}
```

**Identity-binding invariant.** `ik_dh_sig` is REQUIRED, and a responder MUST
verify it against `ik` before deriving `SK`. Without it `ik` is a free-text
field: `ik_dh` performs the arithmetic while `ik` names the peer, so anything
that fails to tie them together lets a sender put another party's name on a
handshake built with their own keys — the responder then derives a secret the
sender knows in full and files the session under the wrong identity. The
gift-wrap seal signature (§8) independently pins the sender, but a responder
MUST NOT rely on that alone; the binding is checked at the handshake itself.

`lrp_used` and `otp_used` are mutually exclusive — `dh4` has exactly one source.
A message asserting both MUST be rejected, not silently resolved to one.

**Prekey-resolution invariant.** A responder MUST resolve every prekey a
handshake references before deleting any of them. Deleting the `otp_used`
private half and only then resolving `otp_pq_used` lets a message pairing a real
one-time prekey with a bogus PQ reference burn a published prekey at no cost to
the sender.

**Rekey-target invariant:** the initiator's first PQ rekey MUST target the KEM
key actually consumed by the handshake (`otp_pq` when present, else `pqpk`).

The responder's signed prekey doubles as their initial ratchet public key; the
initiator derives the first sending chain from `DH(dhs_A, spk_B)` per the
Signal Double Ratchet initialization.

## 6. Ratchet header and PQ rekey

Ratchet header (inside the rumor, field `ratchet_header`):

```jsonc
{
  "dh": "<base64 sender ratchet pub>",
  "pn": 0,            // previous chain length
  "n":  7,            // message number in chain
  "pq": {             // present ONLY on a rekey message
    "ct":  "<base64 ML-KEM-768 ciphertext>",
    "pk":  "<base64 sender's fresh ML-KEM pub>",   // inline rotation (PQ3)
    "ctr": 1,                                      // sender's rekey counter
    "tgt": "<base64 sha256 of the receiver KEM pub targeted>"
  }
}
```

KDFs (all vetted constructions; SPEC §2):
- `KDF_RK(rk, dh) = HKDF-SHA256(ikm=dh, salt=rk, info="pqrc-v1-ratchet-root", 64) → (rk', ck)`
- `KDF_CK(ck): mk = HMAC-SHA256(ck, 0x01); ck' = HMAC-SHA256(ck, 0x02)`
- message key → AES-256-GCM key+nonce: `HKDF-SHA256(mk, salt="pqrc-v1-msg", info="pqrc-msgkeys", 44) → key(32)‖nonce(12)`.
  The nonce is derived, never transmitted; each mk is used exactly once.

**Rekey cadence**: each party counts every message sent *or* received since its
last rekey; the send that reaches `PQ_REKEY_INTERVAL = 50` carries `pq`.

**Rekey application** (normative; refines SPEC §6.2 for bidirectional safety):
1. *Immediately*, the fresh shared secret refreshes the ACTIVE chain:
   `ck' = HKDF-SHA256(ck‖ss, salt="pqrc-v1-rekey", info="pqrc-pq-rekey-chain"‖ctr_u32be, 32)` —
   sender refreshes its sending chain before encrypting the rekey message;
   receiver refreshes the matching receiving chain at exactly that `(dh, n)`
   position (after deriving any skipped keys below `n`, which belong to the
   pre-rekey chain).
2. *Deferred*, the same `ss` folds into the root key at the next DH ratchet
   boundary, at the SAME root-chain position on both sides:
   `rk' = HKDF-SHA256(rk‖ss, salt="pqrc-v1-rekey", info="pqrc-pq-rekey-root", 32)`.
   The rekey *sender* applies its pending fold(s) between the recv-half and
   send-half of its next DH ratchet step (i.e. immediately before creating its
   next chain); the *receiver* applies the peer's pending fold(s) immediately
   before the recv-half of that new chain. Folding eagerly instead would
   desynchronize the root chain whenever a rekey crosses concurrent traffic.
3. Receivers retain a bounded history (8) of their own recent KEM private keys
   and select by `tgt`; rekeys may cross several of the receiver's own
   rotations in flight. `pk` replaces the peer's current KEM key unless a
   higher `ctr` was already applied.

Out-of-order messages that depend on an unprocessed rekey fail AEAD cleanly
and MUST be retried after the rekey message arrives (bounded retry queue).

`MAX_SKIP = 1000`; skipped message keys are cached bounded and deleted on use.

## 7. Rumor content (`kind` 1420, unsigned)

```jsonc
{
  "pqrc_version": "1",
  "type": "message" | "handshake" | "group_create" | "thread_create" | "ai_invite",
  "participant_type": "human" | "agent",
  "sender_role": "identity" | "agent",
  "ratchet_header": { ... },        // §6
  "ciphertext": "<base64>",         // AES-256-GCM(padded plaintext), ct‖tag
  "ptr": {                          // OPTIONAL, >64 KB content (SPEC §11)
    "blossom_url": "...", "decryption_key": "<base64>", "sha256": "<hex>",
    "size_bytes": 0, "mirror_urls": []
  },
  "ai_window": { "type": "ai_active", "active_until": 0,
                 "enabled_by": "<base64 identity pub>", "sig": "<base64>" },
  "handshake": { ... },             // §5, type == "handshake" only
  "agent_sig": "<base64>"           // §8, REQUIRED iff participant_type=="agent"
}
```

Unknown fields MUST be ignored, never fatal (SPEC §12). The rumor event's
`pubkey` MUST equal the seal's `pubkey`; mismatch is rejected.

**Padding**: plaintext is `u32be(len) ‖ plaintext ‖ 0x00…` to the smallest
bucket of {256, 1024, 4096, 16384, 65536} ≥ len. The 4-byte prefix sits outside
the bucket size, so ciphertext length = bucket + 20 and plaintext of exactly
65536 bytes remains inlineable. Larger content MUST use `ptr` or chunking.

**AEAD AD** = `"1"(utf8) ‖ participant_type(utf8) ‖ n(u32be) ‖ created_at_fuzzed(i64be)`.
The fuzzed timestamp is drawn once per message — uniform in
[now − 172800, now], never the future — and reused as `created_at` on BOTH the
seal and the wrap.

**Decrypted body** (inside `ciphertext`): `{"text", "sent_at", "message_id",
"group": {"id"}, "thread": {"id"}, "group_create", "thread_create", "ai_invite",
"is_context"}` — true send time and all routing live inside the encryption.
`message_id` is the sender's stable id for this message; the recipient stores it
verbatim so both parties key the same message identically (older clients omit it
and mint their own). It is what lets a later `ai_context_mark` resolve the peer's
copy of a message. Optional and ignored by clients that don't recognize it (§12).

## 8. Agent authenticity (`agent_sig`)

Agent keys are Ed25519 and cannot sign Nostr events; agent authorship is
proven inside the encryption instead: a rumor with
`participant_type: "agent"` MUST carry `agent_sig`, an Ed25519 signature by the
sender's bound agent key (kind 10420) over `"pqrc-agent-msg-v1" ‖ ciphertext`.
Recipients MUST reject as a protocol violation:
- `participant_type: "agent"` without a valid `agent_sig`;
- `participant_type: "human"` WITH an `agent_sig` (the SPEC §13.4 forgery case);
- `sender_role` inconsistent with `participant_type`.
The AD additionally binds `participant_type` into the AEAD, so a relay cannot
flip the label without breaking decryption.

## 9. Seal and gift wrap encryption (`pqrc-seal-v1`)

NIP-44 v2 requires raw (unauthenticated) ChaCha20, which CryptoKit does not
expose; reimplementing it would violate SPEC §2. pqrc-seal-v1 keeps the NIP-44
shape with vetted parts `[upstream-NIP]`:

```
shared   = x-coordinate (32 bytes) of secp256k1 ECDH(priv, lift_even(pub_xonly))
convkey  = HKDF-SHA256(shared, salt="pqrc-seal-v1", info="conversation-key", 32)
payload  = base64( 0x01 ‖ nonce(12) ‖ ChaCha20-Poly1305(plaintext) ‖ tag(16) )
```

Only the x-coordinate enters HKDF (lifting x-only keys can negate the shared
point between directions; x is invariant). Seal: conversation key between the
sender's real key and the recipient. Wrap: between a FRESH one-time key and the
recipient. `created_at` on seal and wrap = the fuzzed timestamp from §7. The
wrap's tags are `["p", recipient]` and a NIP-40 `["expiration", created_at + 7
days]` so an expiration-aware relay auto-deletes the event (≈5–7 days effective
retention; the value is anchored to the fuzzed `created_at`, so `expiration −
7 days == created_at` and it reveals no timing the public `created_at` doesn't).
The seal carries no tags. Interop with NIP-44 clients is deferred.

## 10. Relays

Receive relays are advertised via kind 10050 (`["relay", url]` tags). Anchor
relays MUST serve kind-1059 events only to the NIP-42-authenticated, p-tagged
recipient and SHOULD set `max_content_length ≥ 1 MB`. Replaceable kinds keep
only the newest event per (kind, pubkey).

## 11. Group and thread extensions (inside the encrypted body only)

- `group_create`: `{"group_id", "name", "members": [identity_hex...],
  "conversation_type": "group", "revision"}` — pairwise fan-out (D1), roster
  tracked per asserter, revisions monotonic.
- `thread_create`: `{"thread_id", "title", "anchor_message_id", "created_by"}`.
- `ai_invite`: thread-scoped ai_window analogue, signed with the
  `pqrc-ai-window-v1` context INCLUDING the thread id (signatures do not
  transfer between threads).

Nothing in these structures is visible to relays.

## 12. Second-client checklist

Reproduce `TestVectors/*.json` byte-for-byte: agent_derivation, binding_10420,
pqxdh_handshake (responder path), ratchet_chain (full 40-message replay),
pq_rekey (receiver replay across the boundary), padding, giftwrap
(deterministic re-wrap given seeds).

## 13. kind 10422 — ephemeral receiving key (SPEC §9.3, OPTIONAL)

A replaceable event advertising a rotating X25519 **public** sub-key. When a
sender has fetched the recipient's current sub-key, it uses it as the gift-wrap
`p` tag (§9) instead of the recipient's long-term identity Nostr pubkey, so a
passive relay observer cannot link the envelope to the identity. The sub-key is
**only a routing tag** — `SK`, the ratchet, and the seal/wrap *encryption* are
unchanged (still to the recipient's Nostr key), so confidentiality is unaffected.

```json
{
  "kind": 10422,
  "pubkey": "<recipient_nostr_pubkey_hex>",
  "tags": [
    ["pqrc_version", "1"],
    ["identity_key", "<ed25519_identity_pub_hex>"],
    ["public_key", "<x25519_sub_key_hex>"],
    ["conversation_binding", "<utf8 domain>"],
    ["epoch", "<u64 decimal>"],
    ["sig", "<base64 ed25519 sig, context pqrc-ephemeral-receiving-v1>"]
  ],
  "content": ""
}
```

Verification is bidirectional, like kind 10420 (a sender MUST do both before
using the sub-key):
1. outer BIP-340 signature verifies under `pubkey` (the Nostr key vouches for
   the event);
2. `sig` verifies under `identity_key` over the `pqrc-ephemeral-receiving-v1`
   context, AND `identity_key` equals the recipient's binding-verified identity
   (the identity key owns the sub-key).

Derivation (so a peer reconstructs nothing — it simply reads the published key —
and so the recipient re-derives the same sub-key after a restart from the epoch
alone):
```
seed   = HKDF(ikm = identity_priv, salt = "pqrc-ephemeral-receiving-v1",
              info = "pqrc-ephemeral-receiving-root" ‖ identity_pub, 32)
subkey = HKDF(ikm = seed, salt = "pqrc-ephemeral-receiving-v1",
              info = "pqrc-ephemeral-receiving-sub" ‖ conversation_binding ‖ epoch(u64be), 32)
public_key = X25519(subkey).publicKey
```

`epoch` rotates **message-driven** (no wall-clock; SPEC §5.2 / invariant 1),
roughly every 20–30 messages with random jitter. The recipient subscribes to
gift wraps p-tagged with BOTH its identity pubkey AND its current (and
immediately-previous) sub-keys, so the changeover never drops in-flight traffic
and an old, identity-p-tag sender still reaches it.

`conversation_binding` is signed material; the **privacy-safe default is the
recipient's own identity hex** (one rotating key, leaking nothing the kind-10420
binding doesn't already). A per-peer binding would expose the social link to any
observer and MUST NOT be used in a cleartext tag without that tradeoff being
understood (DEVIATIONS T4, THREAT_MODEL).

Because a recipient cannot NIP-42-AUTH as an X25519 sub-key (it is not a Nostr
keypair), this mitigation is **incompatible with an anchor relay that gates
kind-1059 delivery to the AUTHed p-tagged recipient (§10)**; it targets public
relays that serve kind-1059 by filter match. The two §9.3 mitigations are
therefore alternatives, not layers. Relays SHOULD AUTH-gate *writes* of kind
10422 so only the owner publishes theirs.
