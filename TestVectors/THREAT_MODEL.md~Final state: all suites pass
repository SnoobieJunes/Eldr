# PQRC Threat Model v1

**PQRC — Post-Quantum Ratcheted Conversations** (codename **Ratchet & Clank**)

Companion to `SPEC.md` (protocol identifier `pqrc-v1`). This document states plainly what PQRC protects, against whom, and — just as importantly — what it does not. A privacy tool that overstates its guarantees endangers the people who rely on it most. Where the spec resolves ties in favor of privacy, this document resolves ties in favor of honesty.

Status: Draft. This document MUST be updated whenever the spec changes and MUST be published alongside it.

---

## 1. Assets

What PQRC is trying to protect, in priority order:

1. **Message content** — text, media, AI-generated content, and shared context exchanged in a conversation.
2. **Long-term keys** — the Nostr key, the PQRC identity key, and the derived agent key.
3. **Session state** — ratchet keys, chain keys, cached skipped-message keys.
4. **Social graph** — who talks to whom.
5. **Conversation patterns** — when, how often, and how much people communicate.
6. **AI participation facts** — whether and when a user's agent is active, and the content the agent reads or writes.

---

## 2. Adversaries

| ID | Adversary | Capabilities assumed |
|---|---|---|
| A1 | **Passive relay operator** | Reads everything stored on / passing through their relay; logs IPs and timing |
| A2 | **Malicious relay operator** | A1, plus drops, delays, reorders, or refuses events; serves stale prekey bundles |
| A3 | **Global passive observer** | Reads all public relays simultaneously; correlates across them (state-level SIGINT posture) |
| A4 | **Network observer** | Sees the user's traffic at the ISP/AS level (encrypted TLS to relays, but endpoints and timing visible) |
| A5 | **Future quantum adversary** | Records ciphertext today; later runs Shor's algorithm against X25519/secp256k1 (harvest now, decrypt later) |
| A6 | **Device compromiser** | Obtains a snapshot of device state at time T (stolen unlocked device, malware, forensic extraction) |
| A7 | **Key compromiser** | Obtains specific long-term private keys without full ongoing device control |
| A8 | **Malicious conversation peer** | A legitimate participant acting in bad faith (screenshots, exfiltration, impersonation attempts) |
| A9 | **Blossom server operator** | Stores and serves large-content blobs; logs access patterns |
| A10 | **Malicious or compromised AI endpoint** | The API/ACP service performing agent inference behaves adversarially |

---

## 3. What PQRC protects, and against whom

### 3.1 Message confidentiality

| Adversary | Protection | Mechanism |
|---|---|---|
| A1, A2 (relays) | **Full.** Relays see only opaque gift-wrapped ciphertext | PQXDH + Double Ratchet + AES-256-GCM; rumor→seal→gift wrap (SPEC §4–§8) |
| A3 (global observer) | **Full** for content | Same |
| A5 (quantum HNDL) | **Strong.** Breaking recorded ciphertext requires breaking both X25519 **and** ML-KEM-768 | Hybrid handshake + ML-KEM rekey every 50 messages (SPEC §4, §6) |
| A6/A7 at time T | **Forward secrecy:** messages before T stay protected (their keys no longer exist). **Post-compromise security:** messages after the next round-trip and ML-KEM rekey re-secure | Double Ratchet + PQ rekey (SPEC §5, §6) |
| A9 (Blossom) | **Full.** Blobs are encrypted before upload; servers hold ciphertext and learn only size and access timing | Encrypt-then-upload, key inside ratchet payload (SPEC §11) |

**Bounded exposure guarantee:** even a successful compromise of ratchet state exposes at most one rekey window (≤ 50 messages) in either direction from the break point, never an entire history. This is the core improvement over static-key schemes (e.g., NIP-04/NIP-17), where one key compromise decrypts everything ever stored.

### 3.2 Sender anonymity (who sent this?)

Relays and observers cannot attribute a gift wrap to its sender: the outer event is signed by a random one-time key (SPEC §8.1). Holds against A1–A4. The recipient, of course, learns the sender upon decryption — that is the point of authenticated messaging.

### 3.3 Authenticity and impersonation resistance

- Prekey substitution by a malicious relay (A2) is detectable: all prekeys are signed by the PQRC identity key, which is cross-bound to the Nostr key in kind 10420 (SPEC §3.3, §4.1). A relay can withhold bundles (DoS) but cannot forge them.
- An agent cannot impersonate its human (A8, A10): agent and identity keys are distinct, the derivation is one-way, and agent messages are signature-verifiably tagged `participant_type: "agent"` (SPEC §3.2, §13.4). A human label on an agent-signed message is detectable by any conforming client.
- An agent cannot self-activate: the always-on window announcement must be signed by the human's PQRC identity key (SPEC §13.3).

### 3.4 Size and timing obfuscation (partial — see §4.3)

Fixed-bucket padding {256, 1024, 4096, 16384, 65536} prevents distinguishing message lengths within a bucket; large content rides Blossom so the on-relay envelope is constant-size regardless of payload (SPEC §7, §11). `created_at` is fuzzed up to 2 days into the past on seal and wrap (SPEC §8.4).

---

## 4. What PQRC does NOT protect (read this section twice)

These are honest, known limitations. None are hidden behind marketing language.

### 4.1 IP-level and network metadata — NOT protected

PQRC does not use Tor, a VPN, or a mixnet. Consequences:

- **Relays (A1, A2) see your connection IP, your connection times, and your fetch patterns.** A relay knows that *some device at this IP* fetched envelopes addressed to pubkey P at time T. If you fetch your own gift wraps from your own IP, the relay can link your IP to your recipient pubkey.
- **Your ISP / network observer (A4) sees that you connect to known Nostr relays and when**, though TLS hides the content.

**User guidance:** users who need network-layer anonymity should run the app over a trustworthy VPN or Tor (e.g., Orbot-style system-wide tunneling where available). PQRC composes cleanly with these; it just does not provide them.

### 4.2 Recipient visibility on public relays — PARTIALLY protected

The gift-wrap `p` tag must name a recipient pubkey for delivery. On a **public relay**, anyone — including a global observer (A3) — can enumerate how many envelopes are addressed to a given pubkey and when (fuzzed). This leaks conversation *existence and volume* for that pubkey, not content or sender.

Mitigations, in order of strength:

1. **AUTH-gated relays (baseline, shipped):** the anchor relay serves kind-1059 events only to the authenticated p-tagged recipient. Non-recipients cannot enumerate. This protects users whose envelopes route through AUTH relays, but not envelopes on open public relays.
2. **Ephemeral receiving keys (strong, OPTIONAL in v1):** rotating per-conversation receiving keys keep the long-term pubkey out of `p` tags entirely. Against A3 this is the real fix. It is opt-in in v1; the spec commits to working toward default-on.

**Honest summary against A3:** absent ephemeral receiving keys, a global observer can build a partial picture of *which pubkeys receive traffic and roughly when*. They cannot see content, senders, or (within a bucket) sizes. This is the deliberate trade for censorship-resistant, serverless availability; a single private relay would hide more from A3 and lose the availability properties.

### 4.3 Timing correlation — OBFUSCATED, not eliminated

Two-day timestamp fuzzing and padding raise the cost of correlation substantially, but a patient global observer (A3) running statistical traffic analysis across relays over long periods may still correlate active conversations, especially low-traffic ones. No store-and-forward relay design without cover traffic defeats this fully. PQRC does not generate cover traffic in v1.

### 4.4 Deniability — NOT a v1 goal

Seals are signed by the sender's Nostr key. A recipient (A8) who exfiltrates decrypted state can produce cryptographic evidence of authorship. (The unsigned inner rumor retains weak NIP-17-style deniability, but PQRC does not claim deniability as a property.) Users for whom repudiation is critical should know this.

### 4.5 Compromised endpoint — OUT OF SCOPE, with damage limits

If a device is fully and persistently compromised (A6 ongoing), the adversary reads what the user reads. No E2EE protocol survives a hostile endpoint. PQRC's contribution is *damage limitation*: forward secrecy bounds historical exposure, PCS re-secures after the compromise ends, Secure Enclave wrapping raises the bar for at-rest extraction, and `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps keys out of backups and iCloud.

### 4.6 Malicious peer — OUT OF SCOPE

A legitimate participant (A8) can screenshot, copy, or republish anything they can read. Cryptography cannot prevent betrayal by an authorized party.

### 4.7 Relay denial of service — NOT prevented, only routed around

Relays can drop, delay, or refuse PQRC events (A2). Mitigations are redundancy (publish to multiple relays, NIP-65 lists), the AUTH-gated anchor relay, and the BLE/Multipeer local path. Delivery is best-effort across the relay set; there is no delivery guarantee from any single relay.

### 4.8 Membership privacy of the kind-10420/10421 events

Publishing an identity binding and prekey bundle reveals that *this npub uses PQRC*. An observer can enumerate PQRC users. If mere protocol membership is sensitive in a user's context, that is a real exposure; the only current mitigation is publishing bundles solely to AUTH-gated relays, at the cost of discoverability.

---

## 5. AI-specific threat analysis

The agent model (SPEC §13) introduces surfaces that ordinary messengers do not have. Stated plainly:

### 5.1 The AI inference endpoint sees plaintext (A10)

The agent reads decrypted conversation plaintext to function. If inference runs **on-device**, plaintext never leaves the device and A10 collapses into A6. If inference uses an **external API/ACP endpoint, that provider necessarily receives whatever conversation context is sent to it.** PQRC's encryption protects content from relays and observers — it cannot protect content from a service the user's own client deliberately sends it to.

Requirements this imposes:

- Clients MUST make the inference location (on-device vs. which external endpoint) visible to the user.
- Clients SHOULD send the minimum context necessary, not the full history by default.
- The other party's consent surface: Bob's client displays that Alice has an agent (kind 10420 declares it) and sees every agent message labeled. Bob should understand that conversing with Alice may expose his messages to Alice's inference endpoint, exactly as it would to Alice's screen. This is a transparency obligation, not a solvable cryptographic problem.

### 5.2 Agent key compromise (A7)

One-way derivation means a stolen agent key does not yield the identity key (SPEC §3.2). Blast radius: the attacker can send messages *labeled as the victim's AI* until the binding is rotated. Clients SHOULD treat anomalous agent activity (agent messages outside any announced window) as a red flag and surface it.

### 5.3 Always-on window abuse

The window must be signed by the human identity key, so a compromised agent or endpoint cannot self-extend authority. Residual risk: a compromised *device* (A6) can sign anything, including windows — covered by §4.5. The broadcast indicator ensures the counterparty is never unknowingly in an AI-driven exchange; clients MUST NOT suppress it.

### 5.4 Context-sharing scope creep

When AIs exchange or summarize context across parties, the effective audience of a message grows beyond its original recipients. v1 keeps this human-mediated (agents are silent by default; sharing is explicit). Any future automated AI-to-AI context channel MUST come with its own consent surface and an update to this document.

---

## 6. Cryptographic assumptions

PQRC's guarantees hold if and only if:

1. **X25519 or ML-KEM-768 is secure** (hybrid: both must fall for the handshake/rekey to fall). ML-KEM-768 is FIPS 203, NIST Category 3.
2. **AES-256-GCM** is a secure AEAD (quantum-robust: Grover only halves the effective key space; 256-bit keys remain ample).
3. **HKDF-SHA256** behaves as a secure KDF/PRF.
4. **Ed25519** signatures are unforgeable. *Known limitation: Ed25519 and secp256k1 signatures are classical.* A future quantum adversary could forge signatures and impersonate identities going forward (it cannot retroactively decrypt content — confidentiality is hybrid-protected). Migration path: ML-DSA-65 is available in CryptoKit on iOS 26+ and is the planned v2 signature upgrade; the `pqrc_capabilities` tag in kind 10420 exists to negotiate it.
5. **Apple platform assumptions:** CryptoKit implementations are constant-time and correct; the Secure Enclave and Keychain enforce their documented properties; swift-crypto ≥ 4.3.1 (the X-Wing decapsulation fix, CVE-2026-28815) — earlier versions are explicitly unsafe.
6. **No novel cryptography exists in PQRC.** Every primitive is standardized and audited elsewhere; PQRC's risk concentrates in *composition and implementation*, which is precisely what the review path below targets.

---

## 7. Residual risk register

| # | Risk | Severity | Status |
|---|---|---|---|
| R1 | Global observer correlates recipient pubkeys + timing on public relays | Medium | Mitigate: AUTH relays now; ephemeral receiving keys toward default |
| R2 | IP linkage by relays / ISP | Medium | Out of scope; user guidance: VPN/Tor |
| R3 | Classical signatures forgeable by future quantum adversary | Medium (future) | Planned: ML-DSA-65 in v2 via capability negotiation |
| R4 | External AI endpoint sees plaintext context | High (if external inference used) | Transparency requirements §5.1; prefer on-device inference |
| R5 | Statistical traffic analysis over long periods | Low–Medium | Accepted in v1; cover traffic not implemented |
| R6 | PQRC membership enumerable from 10420/10421 | Low | Accepted; AUTH-only publishing available |
| R7 | Implementation bugs in ratchet/composition | Unknown until audited | Review path §8 |
| R8 | Relay DoS / selective dropping | Low (availability only) | Redundancy + anchor relay + local path |
| R9 | Last-resort prekey reuse links sessions | Low | Documented unlinkability downgrade only (SPEC §4.1) |

---

## 8. Security review status

- **Current status: UNAUDITED DRAFT.** No formal verification, no third-party audit, no production deployment. Do not rely on PQRC for high-risk use until this section says otherwise.
- Planned path, in order: publish SPEC.md + this document → reference implementation with test vectors → formal modeling (Verifpal first; Tamarin/ProVerif aspirationally, as used for PQ3/PQXDH) → third-party audit (Open Technology Fund Security Lab) → publish audit results unredacted.
- This document versions in lockstep with the spec. Any claim here that the implementation does not yet meet MUST be marked, not assumed.

---

## 9. Comparison honesty box

For users choosing a tool, the one-paragraph truth: **Signal** (with PQXDH + SPQR) offers stronger metadata protection against relay-level observers (sealed sender to a single operator, mature infrastructure) and an audited implementation today, at the cost of centralization and a phone number. **SimpleX** offers the best recipient-metadata story (no identifiers at all) with PQ encryption, at the cost of UX and Apple-native integration. **PQRC** offers the only combination of post-quantum E2EE + decentralized serverless transport + no identifier requirement + Apple-native + transparent AI participation — as an unaudited draft. Users facing state-level adversaries today should use Signal until PQRC's §8 status changes. That sentence stays in this document until it stops being true.
