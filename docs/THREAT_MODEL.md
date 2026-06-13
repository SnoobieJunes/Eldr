# PQRC v1 — Threat Model

Generated per SPEC §15.3. This document is deliberately honest about what PQRC
does **not** protect. Privacy is the protocol's number one priority (SPEC §0);
honesty about its limits is part of that.

## 1. What PQRC protects

| Property | Mechanism | Verified by |
|---|---|---|
| Message confidentiality | PQXDH (X25519 + ML-KEM-768 hybrid) → Double Ratchet → AES-256-GCM | crypto suites, frozen vectors |
| Forward secrecy | per-message keys derived and destroyed; chain keys advance one-way | `forwardSecrecy_oldCiphertextsUndecryptableAfterAdvance` |
| Post-compromise security (classical) | DH ratchet per round-trip | `postCompromiseSecurity_snapshotCannotReadFuture` |
| Post-compromise security (quantum) | ML-KEM-768 rekey every 50 messages, chain refresh + deferred root fold | `pqRekey_firesAtExactly50_…HealsQuantumCompromise` |
| Harvest-now-decrypt-later | hybrid handshake: breaking SK requires breaking BOTH X25519 and ML-KEM-768 | `pqxdh_skDependsOnBothLegs` |
| Sender metadata vs relays | NIP-59 gift wrap; outer event signed by a fresh one-time key per message | `giftwrap_outerKeyIsFreshPerMessage`, `…LeaksNothing` |
| Recipient metadata vs non-recipients | NIP-42 AUTH-gated kind-1059 serving (anchor-relay behavior) | `auth_kind1059ServedOnlyToPTaggedAuthedRecipient` |
| Timing metadata | `created_at` fuzzed up to 2 days into the past on seal + wrap | `fuzz_timestampWithinTwoDaysPast_neverFuture` |
| Size metadata | bucket padding {256,1K,4K,16K,64K}; >64 KB via constant-size pointer | `ciphertextLengths_collapseToBucketSet` |
| Message integrity & context binding | AEAD AD = version‖participant_type‖n‖fuzzed_ts | `ad_bindsContext` |
| At-rest confidentiality | Secure-Enclave-wrapped master key, per-record AES-GCM, complete file protection | `atRest_noPlaintextInStoreFiles` |
| AI transparency | agent label cryptographically bound (AD + agent_sig); windows/invites signed by the human identity key only, time-bounded, fail-closed | agent integrity suite |

## 2. What PQRC v1 does NOT protect — read this

### 2.1 IP and network metadata
PQRC does not use Tor or a mixnet. **Relays see your IP address**, connection
times, and traffic volume. A future push proxy (none ships in v1) would see
that *an* envelope arrived for you, and when. If your threat model includes
network observers correlating IPs, use an external transport protection (VPN,
Tor) — PQRC does not provide it.

### 2.2 Recipient `p`-tag against a global passive observer
Every gift wrap carries the recipient's Nostr pubkey in a `p` tag — necessary
for delivery. AUTH-gated relays stop *non-recipients querying* for your
envelopes, but an observer who can read traffic of all public relays learns
**that you received messages and roughly when** (within the 2-day fuzz window).
Ephemeral receiving keys (SPEC §9.3) would mitigate this; in v1 the setting is
present but disabled and marked experimental. Senders are hidden even from
this observer (one-time outer keys).

### 2.3 No deniability
v1 signs messages (PQ3 pattern): the seal is signed by your Nostr key and
agent messages by your agent key. A recipient can cryptographically prove to a
third party that you authored a message. Deniability is explicitly deferred.

### 2.4 Single device, no recovery
Your identity lives in this device's Keychain/Secure Enclave and is never
exported, synced, or backed up. Losing the device loses the identity and all
history. This is a deliberate trade (no cloud copy to subpoena or steal), and
onboarding makes the user acknowledge it.

### 2.5 Your peer (and their AI) is in your trust domain
E2EE protects the transport, not the endpoints. Your peer can screenshot,
export, or republish anything you send. Their tightly-coupled AI agent reads
the decrypted conversation on their device (SPEC §13.1); PQRC guarantees
agents are *labeled* and *gated*, not that your peer's device-side tooling is
benign. If a peer enables the remote (Anthropic API) provider, the decrypted
context of conversations *they participate in* is sent to that API under
*their* consent, not yours.

### 2.6 Group rosters are not cryptographically agreed
v1 groups are pairwise fan-out (D1). A malicious member can show different
members different rosters; the UI therefore attributes rosters ("as asserted
by X") instead of presenting them as ground truth. Removed members simply stop
receiving; joiners see no history. MLS in v2 addresses membership agreement.

### 2.7 Local relay in v1
v1 ships with an in-process relay simulator; no traffic leaves the device, so
network threats are moot in the shipped configuration. The moment a real
relay/anchor goes live — including the S2 `NostrWebSocketTransport` pointing
at a deployed relay such as `wss://relay.lerants.com` or a localhost
`pqrc-relay` — §2.1–2.2 fully apply, and the operator's IP/retention policy
must be decided and published (TESTFLIGHT-GUIDE §D). The TEST-PLAN §7
conformance suite (`swapPoint_deployedRelayConformance`) verifies a deployed
relay enforces the AUTH-gated kind-1059 rule before it carries real traffic.

### 2.8 Prekey state lifetime
Prekey private state persists across launches (Keychain, device-only) and the
one-time pools replenish to 16 at boot, so handshakes addressed to a
previously published bundle resolve after a relaunch and consumed prekeys
stay consumed forever. Last-resort fallback semantics (unlinkability caveat:
two sessions initiated against the same `lrp` are linkable as such by the
recipient only) are implemented and tested.

### 2.9 Local link (Multipeer) co-presence is observable
The S1 local-first transport (SPEC §10; user-toggleable in Settings → Nearby,
default off in Release — radios and the Local Network prompt only start when
the toggle is on) advertises an
anonymous Bonjour service (`_pqrc-local`, random per-process peer name, no
identity in discovery). What a nearby observer still learns:

- **Co-presence**: *someone* within radio range runs PQRC. They cannot learn
  who — identities are only proven peer-to-peer via a signed challenge
  (DEVIATIONS N18), and message frames are seals (encrypted to the recipient,
  signed by the sender), so an active MITM on the link reads nothing and
  forges nothing (DEVIATIONS N17).
- **Traffic existence and timing** on the link, as with any radio. Padding
  buckets still mask plaintext sizes.
- What the local path REMOVES: a locally delivered message is never published
  to any relay — no `p` tag, no envelope, nothing for §2.2's global passive
  observer to collect. Co-present conversations are strictly more private
  against network observers, traded for this section's radio observability.
- MultipeerConnectivity's own link encryption (`.required`) runs between
  anonymous peers and is treated as a transport nicety, not a security
  boundary; every guarantee comes from the seal + ratchet layers above it.

### 2.10 Open inbox is an explicit reachability trade
By default, first contact from an unknown sender waits in Message Requests
and nothing renders (or is even fetched) until the user accepts. Settings →
Reachability can open the inbox to anyone for a bounded window (≤ 8 h,
auto-expiring): during it, any sender who knows your npub gets their binding
fetched and their handshake processed automatically. That means: (a) a
spammer who learns your address connects without review for the window's
duration, and (b) accepting performs relay fetches an observer of YOUR relay
connection could time-correlate. Both are bounded by the window and chosen
explicitly; blocking still works as usual afterward.

### 2.11 Aliases are channel-private, not authenticated names
A contact's self-chosen alias travels only inside the encrypted session, so
relays and strangers never see it — but it is a *claim*, not an identity:
anyone you accept can call themselves anything. Identity remains the key +
the 60-digit safety code; your local rename always overrides the alias, and
the UI shows the verified shield only after a safety-code verification.

## 3. Endpoint compromise

- **Before compromise**: FS holds — past messages' keys no longer exist
  (enforced by tests that scan serialized state for spent keys).
- **During**: an attacker with the device unlocked has everything the user
  has, including the ability to read new messages and send as the user. No
  E2EE protocol survives this.
- **After**: PCS heals classically after one full round-trip in which the
  compromised party introduces a fresh DH key, and against quantum
  decapsulation after the next ML-KEM rekey targeting a post-compromise KEM
  key (≤ 50 messages). Stolen Keychain blobs without the Secure Enclave
  hardware are useless (SE keys are non-exportable).

## 4. AI-specific threats

| Threat | Mitigation |
|---|---|
| Agent impersonating its human | distinct derived key; `participant_type` bound into AEAD AD; `agent_sig` required; human-label-with-agent-evidence rejected and surfaced as a red protocol-violation row |
| Agent self-activating | windows/invites valid only with the HUMAN identity-key signature; engine rejects agent-signed announcements |
| Stale windows | bounded durations (≤ 2 h), expiry enforced fail-closed at send time |
| Agent loops | hard cap: 6 consecutive agent messages per thread, then pause until a human speaks |
| Covert agent-to-agent channel | none exists: the engine's only output path posts signed, labeled thread messages (the recording guarantee); verified by the spy-sink suite |
| Agent key exposure | derivation is one-way from the identity key; exposure of the agent key does not expose the identity key |

## 5. Cryptographic assumptions

X25519, Ed25519, ML-KEM-768 (FIPS 203), AES-256-GCM, ChaCha20-Poly1305,
HKDF/HMAC-SHA256, secp256k1 Schnorr (BIP-340) — all from Apple
CryptoKit/swift-crypto (≥ 4.3.1, pinned for the X-Wing CVE-2026-28815 fix even
though v1 ships the explicit hybrid, not X-Wing) and bitcoin-core's
libsecp256k1 via 21-DOT-DEV/swift-secp256k1. No custom primitives anywhere;
the protocol composes them (HKDF chains, the Double Ratchet schedule, padding)
exactly as specified in NIP-XX.

## 6. Residual risks / future work

- Formal verification (Verifpal/Tamarin) of the rekey fold positions — the
  deferred-fold design (NIP-XX §6) was validated by adversarial chaos testing,
  not by machine-checked proof.
- Third-party audit (OTF Security Lab) before any non-demo deployment.
- Ephemeral receiving keys on by default; Tor/mixnet transport; deniability;
  MLS groups; multi-device — all tracked for v2.
