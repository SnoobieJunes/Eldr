# PQRC Protocol Specification v1

**PQRC (Post-Quantum Ratcheted Conversations)** — a post-quantum, decentralized, AI-native end-to-end encrypted messaging protocol for iOS.

Protocol identifier: `pqrc-v1`
Status: Draft
Target platform: iOS 26+ / iPadOS 26+ / macOS 26+
Reference implementation language: Swift (CryptoKit + swift-crypto)
License: AGPL-3.0 (recommended; see §15)

---

## 0. Design Goals and Non-Goals

PQRC exists to fill a gap no existing system occupies as of 2026: **post-quantum + decentralized transport + no phone number + Apple-native + open source + AI-native**. Signal is centralized and phone-bound. Nostr's native DMs (NIP-17) have no forward secrecy, no post-compromise security, and no post-quantum protection. XMTP requires a crypto wallet. PQRC borrows proven cryptography (the Apple PQ3 / Signal PQXDH pattern) and runs it over the Nostr relay network, with first-class AI agent participation.

**The cardinal rule of this protocol: user privacy is the number one priority, without exception.** Every design decision in this document resolves ties in favor of privacy, even at the cost of convenience, features, or performance. Implementers MUST preserve this ordering.

### Requirements this spec satisfies

| # | Requirement | How PQRC satisfies it | Section |
|---|---|---|---|
| 1 | Forward Secrecy | Double Ratchet symmetric + DH ratchet; per-message keys derived then destroyed | §5, §6 |
| 2 | Post-Compromise Security | DH ratchet on each round-trip + periodic ML-KEM rekey re-injects entropy | §5, §6 |
| 3 | Post-Quantum | PQXDH hybrid handshake (X25519 + ML-KEM-768) + periodic ML-KEM rekey (PQ3 pattern) | §4, §6 |
| 4 | Sender metadata hidden from relay | NIP-59 gift wrap: outer event signed by random one-time key | §8 |
| 5 | Recipient metadata hidden from relay | AUTH-gated receive relays + optional ephemeral receiving keys | §8, §9 |
| 6 | Timing/size metadata obfuscated | Timestamp fuzzing (±up to 2 days) + fixed-size bucket padding | §7, §8 |
| 7 | Async delivery | Relays store-and-forward; prekey bundles enable offline session setup | §4, §9 |
| 8 | Group support | MLS (RFC 9420) over Nostr in v2; schema forward-compatible from v1 | §12 |
| 9 | Decentralization | Nostr relay network + self-hosted anchor relay + BLE/Multipeer local path | §9, §10 |
| 10 | Unlimited message size | Inline ≤64KB; Blossom pointer >64KB; chunking fallback | §11 |

### Architecture at a glance

```
                              PQRC v1 — 1:1 SESSION
                              =====================

  ALICE (iOS 26+)                  NOSTR RELAYS                   BOB (iOS 26+)
  ┌───────────────────┐         ┌──────────────────┐         ┌───────────────────┐
  │ Identity key (Ed25519)      │ Public relays    │         │ Identity key       │
  │   Keychain, device-only     │ (free, redundant)│         │   Keychain         │
  │ Agent key (derived)         │ + ANCHOR RELAY   │         │ Agent key (derived)│
  │   HKDF "pqrc-agent-v1"      │   (yours, AUTH,  │         │ SecureEnclave wrap │
  │ SecureEnclave P-256 wrap    │    1059-gated)   │         │                    │
  └─────────┬─────────┘         └────────┬─────────┘         └─────────┬─────────┘
            │                            │                             │
   ① PUBLISH PREKEY BUNDLE (kind 10421, replaceable)                   │
            │  X25519 prekey + ML-KEM-768 prekey + one-time prekeys    │
            ├───────────────────────────►│◄────────────────────────────┤
            │                            │                             │
   ② FETCH Bob's bundle, run PQXDH handshake                           │
            │  SK = HKDF( X25519 dh's || ML-KEM-768 ss )               │
            │  (X-Wing preferred — break BOTH to break SK)             │
            │                            │                             │
   ③ DOUBLE RATCHET (per message)        │                             │
            │  symmetric ratchet → FS    │                             │
            │  DH ratchet/round-trip → PCS                             │
            │  ML-KEM rekey every 50 msgs (PQ3) → PQ-PCS               │
            │                            │                             │
   ④ PAD plaintext → bucket {256,1K,4K,16K,64K}                        │
   ⑤ AES-256-GCM encrypt (AD = ver|role|msg#|fuzzed_time)              │
   ⑥ WRAP: rumor(unsigned) → seal(k13) → GIFT WRAP(k1059, random key)  │
            │  relay sees recipient only, NOT sender, NOT content      │
            │  created_at fuzzed up to 2 days                          │
            ├───── publish 1059 to Bob's kind-10050 relays ──────────►│
            │                            │      (AUTH: served to Bob)  │
            │                            │                             │
            │   APNs push proxy (notepush, self-hostable, content-free)│
            │   ◄── wake signal: "Bob has an envelope" ──────────────► │
            │                            │                             │
            │                            │   ⑦ Bob: unwrap→unseal→     │
            │                            │      ratchet-decrypt→unpad  │
            │                            │                             │
   ░░░ LOCAL-FIRST PATH (no relay, no internet) ░░░                    │
            └─────── BLE / MultipeerConnectivity direct ──────────────►│
                     (same ratchet ciphertext, no gift wrap needed)

   ░░░ LARGE MESSAGES (>64KB) ░░░
   encrypt blob → upload to Blossom (SHA-256 addressed, mirrored)
   → rumor.content_pointer = { blossom_url, decryption_key, sha256 }
   → on-relay envelope stays small & constant-size

   ░░░ AI PARTICIPANTS (4 logical: Alice, Alice-AI, Bob, Bob-AI) ░░░
   agents read decrypted plaintext on-device; SILENT by default
   human can broadcast signed "ai_active until T" → all parties see indicator
   every agent msg: participant_type="agent", signed by derived agent key
```

### Non-Goals (v1)

- **Network-level anonymity (IP hiding).** PQRC does not run over Tor/mixnet in v1. Relays and the push proxy see IP addresses. This is documented honestly in THREAT_MODEL.md, not hidden.
- **Deniability.** v1 signs messages (PQ3 pattern). Cryptographic deniability is deferred.
- **Multi-device sync.** v1 is single-device per identity. Linked devices are a v2 concern.
- **Group chat.** Architected for, but not shipped in, v1. See §12.

---

## 1. Terminology

- **Identity key** — long-term Ed25519 keypair representing a human user. Device-bound, never leaves the Secure Enclave's protection.
- **Agent key** — Ed25519 keypair for a user's AI assistant, derived from the identity key (§3). Tightly coupled to its human.
- **Prekey bundle** — a signed, published set of public keys (X25519 + ML-KEM-768) allowing others to start a session asynchronously.
- **Session** — the cryptographic state shared by two parties after a successful handshake: root key, chain keys, ratchet state.
- **Participant** — any keyholder in a conversation. In a 1:1 PQRC conversation there are exactly **four** participants: two humans and their two agents.
- **Envelope** — a gift-wrapped Nostr event carrying one PQRC ciphertext message.
- **Anchor relay** — a relay operated by the app maintainer, AUTH-gated, serving the app's users as a reliability backstop.

---

## 2. Cryptographic Primitives

All primitives are provided by Apple CryptoKit (iOS 26+) and/or Apple swift-crypto ≥ 4.3.1. **No custom cryptographic primitives are defined or permitted.** PQRC composes vetted building blocks; it does not invent them.

| Role | Primitive | Source |
|---|---|---|
| Signatures (identity, agent) | Ed25519 | CryptoKit `Curve25519.Signing` |
| Classical key agreement | X25519 | CryptoKit `Curve25519.KeyAgreement` |
| Post-quantum KEM | ML-KEM-768 | CryptoKit `MLKEM768` |
| Hybrid KEM (preferred) | X-Wing (ML-KEM-768 + X25519) | CryptoKit `HPKE` ciphersuite `XWingMLKEM768X25519` |
| AEAD | AES-256-GCM | CryptoKit `AES.GCM` |
| KDF | HKDF-SHA256 | CryptoKit `HKDF<SHA256>` |
| Hash | SHA-256 | CryptoKit `SHA256` |
| Key wrapping (at rest) | Secure Enclave P-256 | CryptoKit `SecureEnclave.P256` |

**Version pin:** swift-crypto ≥ 4.3.1 is REQUIRED (it fixes the X-Wing decapsulation CVE-2026-28815). Implementations MUST NOT ship with earlier versions.

---

## 3. Identity and Key Management

### 3.1 Identity key

On first launch, the client generates an Ed25519 identity keypair. The private key is stored in the iOS Keychain with accessibility `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. **It is never synced to iCloud, never exported, never transmitted.**

The identity public key, encoded as a Nostr-style bech32 `npub`, is the user's stable PQRC address. There is no phone number, email, or wallet.

### 3.2 Agent key derivation (tightly-coupled AI)

A user's AI agent gets its own signing key, deterministically derived from the identity key so the agent provably belongs to that human but **cannot impersonate** them (different key, different declared role):

```
agent_seed = HKDF-SHA256(
    inputKeyMaterial = identity_private_key_bytes,
    salt             = "pqrc-v1",
    info             = "pqrc-agent-v1" || identity_pubkey,
    outputByteCount  = 32
)
agent_key = Ed25519(seed = agent_seed)
```

The agent public key is published in the user's profile metadata, cryptographically bound to the identity key via a signed assertion (§3.3). Bob's client verifies that `Alice-AI`'s key derives-and-binds to `Alice`'s published identity before accepting any agent message. An agent key can read and send within conversations its human participates in, but a signature from the agent key is always displayed as agent-authored, never as the human.

**Privacy invariant:** because the agent key is derived from (not equal to) the identity key, and the derivation is one-way, exposure of the agent key does NOT expose the identity key. The reverse exposure (identity → agent) is acceptable because they share a trust domain (the same human's device).

### 3.3 Identity binding assertion

The user publishes a signed assertion linking their identity and agent keys:

```json
{
  "kind": 10420,
  "pubkey": "<identity_pubkey_hex>",
  "tags": [
    ["pqrc_version", "1"],
    ["agent_key", "<agent_pubkey_hex>"],
    ["pqrc_capabilities", "pqxdh", "double-ratchet", "ml-kem-768"]
  ],
  "content": "",
  "sig": "<signature_by_identity_key>"
}
```

This is a **replaceable event** (kind 10000–19999 range) so only the latest is retained per user.

### 3.4 Key storage at rest

All long-term secret material (identity private key, derived agent seed, ratchet session state) is encrypted at rest using a P-256 wrapping key generated in and bound to the **Secure Enclave**. The Secure Enclave key is non-exportable hardware-bound; it wraps a symmetric key that encrypts the session database. The Secure Enclave cannot hold X25519 or ML-KEM keys directly (it is P-256 only), so it is used strictly as a hardware root-of-trust for wrapping.

---

## 4. Prekey Bundles and Asynchronous Handshake (PQXDH)

PQRC uses the **PQXDH** pattern (Signal's post-quantum X3DH), which is also the foundation of Apple's PQ3. The elegant property for a decentralized system: **prekey bundles are published as Nostr events**, so a sender can establish a session with an offline recipient using only data fetched from relays — no dedicated key-distribution server required.

### 4.1 Prekey bundle event

Each user publishes and periodically refreshes a prekey bundle:

```json
{
  "kind": 10421,
  "pubkey": "<identity_pubkey_hex>",
  "tags": [
    ["pqrc_version", "1"],
    ["signed_prekey_x25519", "<base64>"],
    ["signed_prekey_sig", "<signature_by_identity_key>"],
    ["mlkem_prekey", "<base64 ML-KEM-768 encapsulation key>"],
    ["mlkem_prekey_sig", "<signature_by_identity_key>"],
    ["onetime_prekeys", "<base64>", "<base64>", "..."],
    ["last_resort_prekey", "<base64>"]
  ],
  "content": "",
  "sig": "<signature_by_identity_key>"
}
```

- The **signed prekey** (X25519) and **ML-KEM prekey** are medium-lived and signed by the identity key.
- **One-time prekeys** are consumed per session; the client republishes the bundle when they run low.
- A **last-resort prekey** handles the race where all one-time prekeys are exhausted (reused, accepted as a documented downgrade in unlinkability for that session — never a downgrade in confidentiality).

This is a **replaceable event**; the latest bundle supersedes prior ones.

### 4.2 Handshake computation

When Alice initiates a session with Bob, she fetches Bob's prekey bundle (kind 10421) from relays and computes a hybrid shared secret. The X-Wing path is preferred:

```
# Preferred: X-Wing single-call hybrid
(ss_pq, kem_ciphertext) = XWing.Encapsulate(bob_xwing_public_key)

# Equivalent explicit hybrid if X-Wing unavailable:
dh1 = X25519(alice_identity, bob_signed_prekey)
dh2 = X25519(alice_ephemeral, bob_signed_prekey)
dh3 = X25519(alice_ephemeral, bob_onetime_prekey)
(ss_kem, kem_ct) = MLKEM768.Encapsulate(bob_mlkem_prekey)

SK = HKDF-SHA256(
    ikm  = dh1 || dh2 || dh3 || ss_kem,   # or ss_pq for X-Wing
    salt = "pqrc-v1-handshake",
    info = "pqrc-root-key" || alice_pubkey || bob_pubkey,
    L    = 32
)
```

`SK` becomes the initial **root key** of the Double Ratchet (§5). Alice sends Bob an initial message containing her ephemeral public key, the ML-KEM ciphertext, and which prekeys she used, so Bob can derive the same `SK`. To break `SK`, an adversary must break **both** X25519 **and** ML-KEM-768 — satisfying the post-quantum requirement against harvest-now-decrypt-later.

---

## 5. The Double Ratchet

After the handshake, PQRC runs the classical Double Ratchet for ongoing per-message forward secrecy and post-compromise security. This is the Signal Double Ratchet, unmodified in its core algorithm.

### 5.1 Two ratchets

- **Symmetric-key ratchet** — every message advances a one-way KDF chain, producing a unique message key that is used once and immediately deleted. This delivers forward secrecy: a compromise today cannot decrypt yesterday's messages because those keys no longer exist.
- **Diffie-Hellman ratchet** — each conversational round-trip mixes a fresh X25519 exchange into the root key, providing post-compromise security ("self-healing"): after a compromise, the next round-trip injects new entropy the attacker doesn't have.

### 5.2 Why message-driven, not time-driven

Key rotation is driven by **messages and round-trips, never by a wall clock**. This is deliberate and required: wall-clock rotation introduces clock-skew bugs, leaks a predictable key schedule, breaks for offline/async delivery, and provides zero cryptographic entropy. Message-driven ratcheting dominates on every axis. Implementers MUST NOT add timer-based key rotation.

### 5.3 Out-of-order and skipped messages

Because relays may deliver out of order, the ratchet MUST cache skipped message keys (bounded — recommended `MAX_SKIP = 1000`) to decrypt late-arriving messages, then delete them after use or after a bounded retention window.

---

## 6. Periodic ML-KEM Rekey (the PQ3 Pattern)

The Double Ratchet's DH ratchet is classical (X25519), which is quantum-vulnerable. To extend post-quantum protection into the *ongoing* session (not just the handshake), PQRC adopts Apple PQ3's approach: **periodically re-inject a fresh ML-KEM-768 shared secret into the root key.**

### 6.1 Rekey cadence

A PQ rekey is triggered every **`PQ_REKEY_INTERVAL = 50` messages** OR on a new session, whichever comes first. Rationale: ML-KEM-768 adds ~2KB on the wire (public key 1,184 B, ciphertext 1,088 B), so per-message PQ rekeying is wasteful, while per-session-only leaves too long a window. Fifty messages bounds exposure while keeping the ~2KB overhead occasional. The interval is a named constant and MAY be tuned downward (more frequent) but SHOULD NOT exceed 50 without documented justification.

### 6.2 Rekey mechanism

At a rekey point, the initiating party generates a fresh ML-KEM-768 encapsulation against the peer's current ML-KEM public key (rotated inline, PQ3-style), and folds the resulting shared secret into the root key:

```
(ss_pq_new, kem_ct_new) = MLKEM768.Encapsulate(peer_current_mlkem_pubkey)
root_key = HKDF-SHA256(
    ikm  = root_key || ss_pq_new,
    salt = "pqrc-v1-rekey",
    info = "pqrc-pq-rekey" || rekey_counter,
    L    = 32
)
```

The KEM ciphertext travels in the message header. After this, even an adversary who recorded everything and later breaks X25519 cannot derive the post-rekey keys without also breaking ML-KEM-768. This satisfies post-compromise security against a future quantum adversary.

---

## 7. Message Padding (Size Metadata)

Ciphertext under AES-256-GCM is already indistinguishable from random, so key rotation does nothing for size correlation. PQRC defeats size-based traffic analysis with **fixed-size bucket padding** applied to plaintext before encryption.

Plaintext is padded up to the next bucket boundary before AEAD encryption:

```
Buckets (bytes): 256, 1024, 4096, 16384, 65536
```

Messages larger than 64KB use the Blossom path (§11) and the *event* carries only a fixed-size pointer, so the on-relay envelope size is constant regardless of media size. Padding bytes are zero-filled and stripped after decryption using a length prefix inside the plaintext. This ensures an observer cannot distinguish a one-word reply from a paragraph within the same bucket.

---

## 8. Message Envelope (Gift Wrap)

PQRC messages travel as **NIP-59 gift-wrapped Nostr events**, which hide sender metadata from relays. The structure has three layers (following NIP-17/NIP-59):

### 8.1 Three-layer structure

1. **Rumor** — the actual PQRC message, *unsigned* (an unsigned inner event). Contains the ratchet ciphertext and PQRC headers.
2. **Seal (kind 13)** — the rumor, NIP-44-encrypted to the recipient and signed by the sender's real key. Tags empty.
3. **Gift wrap (kind 1059)** — the seal, encrypted again and signed by a **random one-time key**, with only the recipient in a `p` tag.

Because the outer gift wrap is signed by a throwaway key, **the relay never sees who sent the message.** The recipient's pubkey is present (necessary for delivery) but is mitigated per §9.

### 8.2 Rumor content schema

The rumor's content carries the PQRC message payload:

```json
{
  "pqrc_version": "1",
  "type": "message",
  "participant_type": "human",          // "human" | "agent"
  "sender_role": "<identity|agent>",
  "ratchet_header": {
    "dh_pubkey": "<base64>",
    "prev_chain_len": 42,
    "message_number": 7,
    "pq_rekey": null                     // or { "kem_ct": "<base64>", "counter": 3 }
  },
  "ciphertext": "<base64 AES-256-GCM output>",
  "content_pointer": null,               // or Blossom ref, see §11
  "ai_window": null                      // or signed AI-active announcement, see §13
}
```

The `participant_type` field is cryptographically meaningful: a message signed by an agent key MUST carry `"agent"`, and recipients MUST display it as AI-authored. Forging a human label on an agent message is a protocol violation detectable by signature verification.

### 8.3 AEAD associated data

The AES-256-GCM associated data (AD) binds context and provides replay/freshness protection:

```
AD = pqrc_version || participant_type || message_number || created_at_fuzzed
```

`participant_type` (the `"human"` | `"agent"` field of §8.2) is the AEAD-bound field here: binding it into the associated data means the human/agent authorship claim is authenticated by AES-256-GCM and cannot be flipped in transit without breaking the tag. (This matches the wire format in NIP-XX and the implementation in `AssociatedData.build`.)

This is the one legitimate place a timestamp appears: as authenticated associated data for freshness, **not** as a source of key material.

### 8.4 Timestamp fuzzing

Per NIP-59, `created_at` on both the seal and gift wrap is randomized up to **two days in the past** to frustrate timing correlation. The true send time is conveyed (if needed) inside the encrypted rumor, never in the public event.

---

## 9. Transport: Nostr Relays

### 9.1 Relay roles

- **Public relays** — the existing Nostr network provides free, redundant store-and-forward and censorship resistance. Any relay can carry PQRC envelopes (they are opaque kind-1059 events).
- **Anchor relay** — the app maintainer SHOULD run one AUTH-gated relay (strfry/khatru) that serves kind-1059 events only to the p-tagged recipient (NIP-42 AUTH), restricting writes to app users. This is both a reliability backstop and a "pay it forward" community contribution. It reduces public observability of recipient metadata for app users without reintroducing a single point of failure (public relays remain a fallback).

### 9.2 Relay-list publishing

Recipients advertise which relays they receive on, using a kind-10050-style DM relay list (NIP-65 inbox/outbox model). Senders publish prekey bundles widely but keep receive-relay lists small and redundant (1–3 relays).

### 9.3 Recipient metadata mitigation

The gift-wrap `p` tag reveals the recipient pubkey to anyone reading a public relay. Two mitigations, in order of strength:

1. **AUTH-gated relays** (baseline): the anchor relay serves kind-1059 to the recipient only, so non-recipients cannot enumerate envelopes.
2. **Ephemeral receiving keys** (strong, OPTIONAL in v1): the recipient publishes a rotating X25519 receiving sub-key (**kind 10422**, NIP-XX §13), so the long-term identity pubkey never appears as a `p` tag — the gift-wrap `p` tag carries the sub-key instead, while the seal/wrap encryption (and therefore confidentiality) is unchanged. The sub-key is HKDF-derived from the identity key (no extra shared secret — a peer simply reads the published key), bound to the identity in both directions (outer Nostr-event signature + inner identity-key signature over `pqrc-ephemeral-receiving-v1`), and rotated **message-driven** with jitter (no wall-clock; §5.2). The recipient dual-subscribes (identity p-tag + sub-keys) so an old sender still reaches it and a new sender falls back to the identity p-tag when the recipient publishes no key — making rollout backward-compatible. This complicates discovery and is offered as a privacy-maximizing opt-in (OFF by default in v1). Because privacy is the cardinal rule (§0), implementations SHOULD work toward enabling this by default in a future version. **Note:** because an X25519 sub-key is not a Nostr keypair, a recipient cannot AUTH as it — so this mitigation is an *alternative* to the AUTH-gated anchor relay above (it targets public relays serving kind-1059 by filter match), not a layer on top of it.

**Honest limitation:** against a *global passive observer* who reads all public relays, recipient + fuzzed timing leak unless ephemeral receiving keys are used. Even with them, the count of distinct sub-keys in flight still leaks an approximate conversation/contact count (just not the identity). This is documented in THREAT_MODEL.md. The tradeoff buys censorship resistance and availability that a single self-run relay cannot match.

---

## 10. Local-First Transport (BLE / MultipeerConnectivity)

When two parties are co-present, PQRC can deliver the **same ratchet ciphertext** directly over Bluetooth (CoreBluetooth) or MultipeerConnectivity, with no relay and no internet. The cryptographic payload is identical; only the outer gift-wrap envelope is unnecessary (there is no relay to hide the sender from — the link is already point-to-point). This is a genuine differentiator for offline/censored environments and leverages existing platform capabilities. Local delivery falls back to relay delivery automatically when peers are not co-present.

### 10.1 iOS background constraint (honest)

iOS terminates background WebSocket connections, so live relay delivery while backgrounded is impossible. Push notifications require APNs. PQRC's push strategy:

- A minimal, **self-hostable** APNs push proxy (Damus `notepush` pattern) forwards a content-free wake signal. The proxy learns that a p-tagged recipient received *an* envelope and roughly when — never content, never sender. This is the one acceptable, minimized, optional server, and it is documented honestly. Privacy-maximizing users can run their own proxy or use foreground-only polling.

---

## 11. Unlimited Message Size

PQRC supports arbitrarily large messages via a pointer pattern, keeping on-relay envelopes small and constant-size.

### 11.1 Size tiers

- **≤ 64 KB** — the ratchet ciphertext is carried inline in the rumor `ciphertext` field.
- **> 64 KB** — the plaintext is encrypted with a fresh symmetric key, the ciphertext blob is uploaded to a **Blossom** server (content-addressed by SHA-256), and the rumor's `content_pointer` carries the Blossom URL + the decryption key (itself inside the ratchet-encrypted payload):

```json
"content_pointer": {
  "blossom_url": "https://blossom.example/<sha256>",
  "decryption_key": "<base64>",       // encrypted within the ratchet payload
  "sha256": "<hex>",
  "size_bytes": 5242880,
  "mirror_urls": ["https://cdn2.example/<sha256>"]
}
```

The blob is encrypted **before** upload; Blossom servers store only opaque ciphertext. Mirroring across multiple Blossom servers (BUD-04) provides durability.

### 11.2 Chunking fallback

For payloads too large even for the anchor relay's `max_content_length`, or when Blossom is unavailable, the message is split into sequentially numbered chunk events sharing a common thread-ID tag, encrypted independently, and reassembled client-side. The anchor relay SHOULD set `max_content_length` to at least **1 MB**.

---

## 12. Group Chat (v2 — Forward-Compatible Design)

v1 ships 1:1 only. Groups arrive in v2 via **MLS (RFC 9420)** over Nostr — the Marmot pattern — which provides forward secrecy, post-compromise security, and O(log n) membership operations that scale to large groups. The v1 event schema is designed to accommodate this without breaking changes:

- `pqrc_version` gates protocol evolution.
- A `conversation_type` field (`"1to1"` | `"group"`) will distinguish session types; v1 clients treat absence as `"1to1"`.
- Group messages will use MLS group events (KeyPackages as kind 443, Welcomes as gift-wrapped kind 444, group messages as kind 445), with the **X-Wing ciphersuite** (`MLS_256_XWING_...`) for post-quantum group security via OpenMLS.
- **AI agents in groups** are MLS members with their own KeyPackages — adding Alice-AI is the same operation as adding any participant.

Implementers building v1 MUST NOT make assumptions that preclude a later MLS group path (e.g., hard-coding two-party-only state shapes in the wire format).

---

## 13. AI Agent Participation

### 13.1 Four-participant model

A 1:1 PQRC conversation has exactly four participants: **Alice, Alice-AI, Bob, Bob-AI.** All four hold keys (humans: identity keys; agents: derived agent keys per §3.2). All four can read the conversation's decrypted plaintext on their respective devices. The AIs are tightly coupled so that having a human in the chat guarantees their AI is available in the chat.

### 13.2 Silent by default

By default, **agents are silent**: they read all decrypted plaintext on-device (enabling context-aware assistance to their own human) but **never send messages autonomously.** An agent message is only emitted when explicitly invoked by its human, or during an active always-on window (§13.3). This is a privacy default — the AI does not speak into the shared conversation unless deliberately enabled.

### 13.3 Always-on window (broadcast)

A human may enable always-on AI responding for a **defined time period** (e.g., 30 minutes). When enabled, the human's client broadcasts a **signed, in-conversation announcement to all parties** so everyone sees that this user's AI is currently driving responses:

```json
"ai_window": {
  "type": "ai_active",
  "active_until": "<unix_timestamp>",
  "enabled_by": "<identity_pubkey_hex>",
  "sig": "<signature_by_identity_key>"
}
```

All clients MUST display a visible indicator (e.g., "Alice's AI is active until 3:45 PM") for the duration. When the window expires, the agent returns to silent mode and clients clear the indicator. The announcement is signed by the human's identity key so the AI cannot self-activate — only the human can authorize an always-on window. The window timer is enforced on the enabling device, and the broadcast keeps all parties informed (transparency is a privacy property: no one is ever unknowingly talking to an AI).

### 13.4 Agent message authenticity

Every agent message is signed by the agent key and carries `participant_type: "agent"`. Recipients verify the agent key binds to the claimed human identity (§3.3) and display the message as AI-authored. There is no mechanism by which an agent message can be presented as human-authored; the signature makes this detectable.

### 13.5 Key custody

Agent signing keys are **device-bound** (derived from the device-bound identity key, never exported). AI inference may run on-device or via an external API/ACP endpoint, but the **signing key never leaves the device**. Truly asynchronous AI replies (when the app is backgrounded) are queued and signed when the app is next active, preserving the device-bound-key invariant. PQRC does NOT place agent keys on an API server.

---

## 14. Protocol Constants

| Constant | Value | Section |
|---|---|---|
| `pqrc_version` | `"1"` | all |
| Identity / agent signature | Ed25519 | §2 |
| Classical KA | X25519 | §2 |
| PQ KEM | ML-KEM-768 | §2 |
| Hybrid KEM | X-Wing (ML-KEM-768 + X25519) | §2 |
| AEAD | AES-256-GCM | §2 |
| KDF | HKDF-SHA256 | §2 |
| `PQ_REKEY_INTERVAL` | 50 messages | §6 |
| `MAX_SKIP` | 1000 messages | §5 |
| Padding buckets (bytes) | 256, 1024, 4096, 16384, 65536 | §7 |
| Inline size limit | 65536 bytes (64 KB) | §11 |
| Anchor relay `max_content_length` | ≥ 1 MB | §11 |
| Timestamp fuzz window | up to 2 days past | §8 |
| Agent HKDF salt | `"pqrc-v1"` | §3 |
| Agent HKDF info | `"pqrc-agent-v1"` ‖ identity_pubkey | §3 |
| Identity binding event kind | 10420 | §3 |
| Prekey bundle event kind | 10421 | §4 |
| Seal event kind | 13 (NIP-59) | §8 |
| Gift wrap event kind | 1059 (NIP-59) | §8 |
| DM relay list event kind | 10050 | §9 |

---

## 15. Implementation Notes

### 15.1 Libraries

- **Crypto:** Apple CryptoKit (iOS 26+) for all primitives; swift-crypto ≥ 4.3.1 for any server-side (relay/proxy) shared code.
- **Nostr plumbing:** `rust-nostr/nostr-sdk-swift` (UniFFI bindings) for event construction, signing, relay I/O, and NIP-17/44/59 gift-wrap handling. Write the PQRC ratchet in Swift; use the SDK only for transport.
- **Relay:** strfry (C++) or khatru (Go) for the anchor relay, AUTH-gated, kind-1059-restricted.
- **Media:** any Blossom server implementation; mirror across ≥2 for durability.

### 15.2 Licensing

AGPL-3.0 is recommended: it matches the privacy-first, FOSS ethos and ensures network-deployed forks stay open. If distributing via the App Store, include a GPL App Store linking exception (as Signal does). Note: if `libsignal` is ever used directly it is AGPL-3.0 already; PQRC's from-spec Double Ratchet avoids that dependency and keeps licensing flexible.

### 15.3 What to publish

- `SPEC.md` (this document)
- `THREAT_MODEL.md` — explicit about what PQRC does and does NOT protect (IP/network metadata via relays + APNs proxy; recipient metadata against a global observer absent ephemeral keys; no deniability in v1)
- Reproducible-build instructions
- Any third-party audit reports (pursue an OTF Security Lab audit once stable)

### 15.4 Security review path

Publish the spec and threat model before requesting review. Aspirational formal verification with Verifpal (accessible) or Tamarin/ProVerif (what Apple/Signal used for PQ3/PQXDH). Pursue a third-party audit via the Open Technology Fund Security Lab, which funds free audits for open-source internet-freedom tools.

---

## 16. Requirements Conformance Summary

A conforming PQRC v1 implementation MUST satisfy all of the following. Each maps to the user's stated requirements.

- [x] **Forward Secrecy** — Double Ratchet symmetric chain; per-message keys destroyed after use (§5).
- [x] **Post-Compromise Security** — DH ratchet per round-trip + periodic ML-KEM rekey (§5, §6).
- [x] **Post-Quantum** — X25519+ML-KEM-768 hybrid handshake + periodic ML-KEM rekey (PQ3 pattern) (§4, §6).
- [x] **Sender metadata hidden from relay** — NIP-59 gift wrap, random one-time outer signing key (§8).
- [x] **Recipient metadata hidden from relay** — AUTH-gated relays (baseline) + optional ephemeral receiving keys (strong) (§9).
- [x] **Timing/size metadata obfuscated** — timestamp fuzzing ±2 days + fixed-size bucket padding (§7, §8).
- [x] **Async delivery** — relay store-and-forward + Nostr-hosted prekey bundles for offline session setup (§4, §9).
- [x] **Group support** — MLS-over-Nostr in v2; v1 schema forward-compatible (§12).
- [x] **Decentralization** — Nostr public relay network + self-hosted anchor relay + BLE/Multipeer local path (§9, §10).
- [x] **Unlimited message size** — inline ≤64KB, Blossom pointer >64KB, chunking fallback (§11).

**Cardinal rule restated:** where any future extension creates tension between privacy and another goal, privacy wins. This is non-negotiable and binds all implementers.
