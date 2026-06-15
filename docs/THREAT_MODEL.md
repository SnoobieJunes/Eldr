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
| At-rest confidentiality | Secure-Enclave-wrapped master key, per-record AES-GCM, `completeUntilFirstUserAuthentication` file protection on the store | `atRest_noPlaintextInStoreFiles` |
| AI transparency | agent label cryptographically bound (AD + agent_sig); windows/invites signed by the human identity key only, time-bounded, fail-closed | agent integrity suite |

## 2. What PQRC v1 does NOT protect — read this

### 2.1 IP and network metadata
PQRC does not use Tor or a mixnet. **Relays see your IP address**, connection
times, and traffic volume. A future push proxy (none ships in v1) would see
that *an* envelope arrived for you, and when. If your threat model includes
network observers correlating IPs, use an external transport protection (VPN,
Tor) — PQRC does not provide it.

### 2.1a Key-publish cadence is deliberately not a presence beacon
Your 10420 binding / 10421 prekey bundle / 10050 relay list are public by
design (a contact must fetch them to reach you). They carry a real `created_at`
(replaceable events can't be backdated — the newer must win) published from
your IP, so each publish is a timestamped, IP-attributable point. To avoid
turning this into a liveness/online signal, the client publishes **only when
there's a reason**: at launch, on a relay-list change, and when one-time
prekeys run low (invariant 11) — **never on a timer or on every foreground**.
"Is the relay up" is answered by the cheap connection check, not by re-writing
keys. Fetching a contact's keys holds the subscription only long enough to
collect them (seconds), then drops it, bounding how long a relay sees your
interest in that pubkey.

### 2.1b Other relay-observable patterns we DON'T hide (honest disclosure)
Three behaviors are visible to a relay (or a network observer of one) and are
**not** mitigated in v1 — disclosed here per the cardinal rule (SPEC §0):
- **WebSocket keepalive ping.** While a subscription is active, the client sends
  a zero-payload ping every ~30 s (so an intermediary like Cloudflare doesn't
  drop the idle connection). A relay can infer *you are online with an active
  subscription* from the ping cadence — a low-rate liveness signal. It reveals
  nothing about *which* conversations or *when* messages flow (one subscription
  covers all your gift wraps). Mitigation if this matters to you: a VPN/Tor in
  front. (A future build may jitter the interval.)
- **NIP-11 fetch.** When a relay is added/first used, the client makes one HTTP
  GET to its NIP-11 document (to size chunks to the relay's content limit). A
  network observer can correlate that request's timing with the connection. It's
  one-time per relay and cached.
- **Chunking reveals message *count*, not size.** A large message is split into
  several gift-wrapped envelopes; a relay sees N envelopes arrive in a burst and
  can infer "a large message was sent" and roughly how large from N. The chunk
  *metadata* (id/index/total) stays inside the ciphertext, and chunk size is set
  to the **strictest** relay in your set so every relay sees the same N — but the
  burst itself is observable. (DEVIATIONS N26, A25.)

### 2.2 Recipient `p`-tag against a global passive observer
Every gift wrap carries the recipient's Nostr pubkey in a `p` tag — necessary
for delivery. AUTH-gated relays stop *non-recipients querying* for your
envelopes, but an observer who can read traffic of all public relays learns
**that you received messages and roughly when** (within the 2-day fuzz window).
Ephemeral receiving keys (SPEC §9.3) would mitigate this; in v1 the setting is
present but disabled and marked experimental. Senders are hidden even from
this observer (one-time outer keys).

### 2.3 No *message* deniability
v1 signs messages (PQ3 pattern): the seal is signed by your Nostr key and
agent messages by your agent key. A recipient can cryptographically prove to a
third party that you authored a message. Cryptographic *message* deniability is
explicitly deferred. (Account-*existence* deniability — a different property — is
addressed by the passphrase silos in §2.3a.)

### 2.3a Deniable multi-account silos: what is and isn't hidden
One device can hold several **passphrase-isolated accounts** ("silos";
DEVIATIONS A23–A26, A33). `passphrase → PBKDF2 → siloID + KEK`; each silo's
Keychain secrets and store master key are sealed under its KEK, and the app
**never auto-boots** — it always opens to a bare passphrase screen. What this
protects, and what it does not:

- **Hidden from the running app:** with a wrong (or merely different) passphrase
  the app derives a *different, non-existent* silo — indistinguishable from "no
  account yet". So an adversary with the *unlocked phone* but not a passphrase
  cannot show that a *given* passphrase maps to data, nor enumerate accounts
  through the UI. A coerced user can reveal a **decoy** silo (A25) stocked with
  innocuous chats.
- **NOT hidden — biometric implies the primary exists (A24).** Face ID / Touch ID
  is the default unlock and is stored **only for the FIRST account**. The launch
  Face-ID prompt therefore implies *a* primary account exists (a deliberate
  convenience-over-deniability call by the product owner). Additional/hidden silos
  are passphrase-only and stay deniable. Turn Face ID off (Settings ▸ Account) for
  passphrase-only launch with no such implication.
- **NOT hidden — silo COUNT under forensic imaging (A26, tech-debt).** A full disk
  image can infer the *number* of accounts from the per-silo `silo-*.store` files
  and the `.<siloID>` UserDefaults suffixes. Contents and keys remain sealed, and
  whether a passphrase maps to data stays unprovable — but the count leaks. Robust
  count-hiding (a single pooled store of opaque records) is Phase 2; naive decoy
  files are distinguishable from real SQLite, so they are deliberately not shipped
  (false deniability is worse than a documented limit).
- **Isolation is cryptographic, not OS-enforced.** iOS gives one app a single
  sandbox; there is no secure-island separation between silos. The guarantee is the
  per-silo KEK sealing, not a hardware boundary.
- **No recovery.** Lose a silo's passphrase and that account is gone forever — there
  is no backup or reset (SPEC §0).

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

### 2.9a Device-hosted relay hub: delivery is content-free, AI-sharing is not
A device can act as a **pocket relay** (`host` in Settings → Servers) so
companions (`nearby`) exchange messages with no router or public relay
(`NearbyRelayHub`, a distinct `_pqrc-relay` Bonjour service). Two distinct paths
with two distinct exposures:

- **Message-delivery path — content-free.** The host runs the relay engine and
  forwards gift-wrapped events. The kind-1059 anchor-relay rule still applies (a
  wrap is served only to the AUTHed, p-tagged recipient), so the host — a trusted
  peer's device, not a public server — sees only sealed ciphertext + p-tags,
  exactly what any relay sees, and cannot fan a wrap to the wrong companion or
  read one. Strictly better than café Wi-Fi for the same reasons as §2.9.
- **AI-sharing path — the host SEES content, by design.** A companion may opt
  into the host's on-device AI (`ai_request`/`ai_response`). When it does, it
  sends its own message text to the host's model. That text is content the host
  device reads. It is gated three ways: the companion must AUTHenticate to the
  hub first (an unauthenticated `ai_request` is refused), the egress firewall
  redacts contact names to codenames before the text leaves (default on), and
  the off-device-AI **consent alert fires for the `hub` backend** just as for a
  cloud provider — so a companion is told its words go to another device before
  any are sent. This is the one place the "host never sees content" guarantee
  does not hold, and it holds nowhere else on the hub.

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

### 2.12 Off-device AI is a consented content-exfiltration channel
Any **off-device** AI you enable (Claude/OpenAI/Gemini/OpenRouter/Groq, a
self-hosted server, or the nearby host's `hub` AI) receives the **decrypted
message content** of the conversations it is used in — by design, behind an
explicit consent alert that fires before the first such call. Two mitigations
bound it, neither is a confidentiality guarantee against the provider itself:
- **Egress firewall (default ON, DEVIATIONS A21/firewall).** Contact names and
  aliases are replaced with local **codenames** before text leaves the device,
  and the outbound context is **hard-capped at 64 KB** — bounding both identity
  leakage and how much any single call can exfiltrate. Your signing keys never
  leave the device regardless.
- **Default context minimization (A21).** Unless the AI is actively engaged (a
  live window/invite or the solo chat), only messages you explicitly marked "Add
  to AI Context" are sent — not the whole history.

The provider still sees whatever content *is* sent. A self-hosted model on your
own machine keeps content on your devices; a cloud provider does not. Leave
off-device AI off to keep everything local. (The `hub` path additionally shares
content with another *user's* device — see §2.9a.)

### 2.13 Local MCP server / ACP agent (developer-facing, opt-in)
Two surfaces let a **local** agent on the same machine interact with EldrChat;
neither touches the Nostr wire or a network by itself (DEVIATIONS A35/A36):

- **In-app MCP server (A35 Phase 2 — now shipped).** When a silo is unlocked AND
  you turn on **Settings ▸ Local agent access (MCP)** (OFF by default), the app
  hosts a Model Context Protocol server **in-process** so a local MCP client
  (Goose, Xcode, Claude, …) can **read** your real conversations. This is a
  genuine **read exposure of your chat to whatever local agent you point at it** —
  the deliberate threat-model boundary, mitigated as follows:
  - **Loopback only.** The server binds a **Unix-domain socket** under the app
    container (no network interface at all — filesystem-namespaced, same-machine).
    It **never** falls back to a TCP bind, so nothing is reachable off-box. (The
    external `pqrc-mcp-bridge` shim *also* understands a `127.0.0.1` TCP fallback,
    but the app side only ever offers the UDS, so the TCP path is unreachable in
    practice.)
  - **Token-gated.** A client's **first line** must equal a 32-byte random pairing
    token (kept in the silo Keychain, `WhenUnlockedThisDeviceOnly`, surfaced in
    Settings); a mismatch/missing token drops the connection before any method
    runs. The comparison is length-checked and constant-time.
  - **Read-only + firewall-redacted.** The bridge serves the **same egress-firewall
    output** the remote-AI path produces — message senders are **local codenames,
    never identity hex or real display names**, text is **byte-bounded to 64 KB**
    (invariant 4), and the participant role is honest (an AI message is labeled
    AI). There is **no `post`/`send` tool** in the protocol, so an MCP client
    cannot make EldrChat speak on the wire — §13 holds by construction.
    *Honest nuance:* the conversation **title** (not message senders) is the
    contact's resolved local name; for a normal contact that is the
    auto-generated friendly codename, but the underlying name type retains a
    last-resort `"Contact <first-8-hex>"` fallback used only if a contact has no
    nickname, no peer alias, and no codename yet. Codenames are assigned
    synchronously on contact load/accept, so a *full or partial identity-key
    prefix as a title is not reachable in normal operation*; we call it out for
    completeness. Message bodies/senders never carry it.
  - **OFF by default; stops on lock.** There is **no persisted "expose me" flag** —
    a fresh launch never auto-re-exposes chat. Locking the silo or toggling off
    **tears the server down first** (before the redacted store becomes
    unreadable), hanging up every in-flight connection.

- **ACP agent (`eldr-acp`/PQRCACP).** Lets EldrChat's on-device LLM act as a coding
  agent an ACP client (Xcode 27) spawns over stdio to write code, build, and run
  tests **on the developer's own machine**. It involves **no secure-chat content
  and no relay path**, so §13 is out of scope — but note its real power within
  that local-dev blast radius:
  - It can **write files and run arbitrary shell** (`/bin/zsh -lc`) in its working
    directory — by design, on the user's own dev box, via a binary the user
    registers with their editor.
  - Mutating tools (`write_file`, `run_shell`) call **`session/request_permission`
    on the client first**. If the client answers, the user's decision is honored;
    if the client can't prompt or the request fails, the agent **defaults to
    ALLOW** (the client spawned it as a trusted local subprocess and the user
    expects it to act). A non-conformant or permission-less client therefore gets
    silent execution — a usability trade with no wire exposure, but a power worth
    knowing before you register the agent.
  - It **acts only on an explicit client `session/prompt` AND an LLM tool-call
    decision** — it never runs tools autonomously. The LLM token
    (`ELDR_LLM_TOKEN`) is sent only as the model endpoint's `Authorization`
    header and is **never logged** (diagnostics log the URL and model name only).

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
| Covert agent-to-agent channel | none exists: the engine's only output path posts signed, labeled thread messages (the recording guarantee); verified by the spy-sink suite. Thread "skills" (A32) are prompt composition only — no new channel |
| Agent key exposure | derivation is one-way from the identity key; exposure of the agent key does not expose the identity key |
| Off-device AI exfiltrating identities / bulk context | egress firewall (default ON): codename redaction + 64 KB outbound cap; default context = marked-only unless actively engaged; explicit consent before the first remote/hub call (§2.12) |
| Reasoning model leaking its scratchpad into chat | `<think>`/Harmony chain-of-thought stripped from every reply before it renders (A34) |

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
- **Silo count-hiding (A26):** a forensic image can still count accounts; a pooled
  opaque-record store is the Phase-2 fix (§2.3a).
- **MCP server hardening (A35):** the in-app `PersonaRuntime`-backed MCP bridge
  (loopback UDS, token-gated, OFF-by-default, redacted, stops-on-lock) now ships
  (§2.13). Open follow-ups: tighten the conversation-title fallback so it can
  never emit a key prefix even in a contrived state, and a peer-credential check
  (`SO_PEERCRED`/`LOCAL_PEERPID`) on the UDS to bind connections to expected
  local clients.
- Ephemeral receiving keys on by default; Tor/mixnet transport; cryptographic
  *message* deniability; MLS groups; multi-device — all tracked for v2. (Account-
  *existence* deniability via silos now ships — §2.3a.)
