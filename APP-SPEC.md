# APP-SPEC.md — PQRC iOS Client v1

What to build. This document is subordinate to `pqrc-SPEC-v1_1.md` (protocol) and `NIP-XX-pqrc.md` (wire format). Where this document adds things the protocol does not define, the addition is tagged **[Dx]** and listed in §18 for `docs/DEVIATIONS.md`.

## 0. Product principles

1. **Privacy is the number one priority, without exception** (SPEC §0). Ties resolve toward privacy.
2. **Transparency of AI is a privacy property.** No one is ever unknowingly talking to an AI. Agent authorship is always visible, always verifiable.
3. **iMessage-grade feel.** Native, fluid, instant. The cryptography is invisible; the trust signals are not.
4. **Honest limitations.** What PQRC does not protect (IP metadata, recipient `p`-tag against a global observer, no deniability, single device) is stated plainly in-app, not hidden.

## 1. Scope

**In v1:** onboarding/key generation, 1:1 conversations, group conversations **[D1]**, shared AI threads, AI drafting + `ai_window`, large content via simulated Blossom, message requests, contact verification, block & report, Local Universe demo mode, full test suite.

**Out (documented in THREAT_MODEL/DEVIATIONS):** multi-device, key backup/recovery, push notifications **[D6]**, read/delivery receipts **[D5]**, NIP-17 fallback, real MLS groups, Tor/IP privacy, deniability, published profiles (kind 0) **[D11]**. BLE/Multipeer local-first transport (SPEC §10) is stretch goal **[S1]** — implement the `LocalLinkTransport` protocol seam regardless, so the payload path is transport-agnostic from day one.

## 2. Architecture

```
┌────────────────────────── App (SwiftUI) ──────────────────────────┐
│ ConversationList · ConversationView · ThreadView · Composer       │
│ Onboarding · Settings · Verification · Debug/LocalUniverse        │
└──────────────┬────────────────────────────────────────────────────┘
               │ @Observable view models (MainActor)
┌──────────────▼───────────── PQRCAgent ────────────────────────────┐
│ AgentProvider (protocol) → Mock | FoundationModels | AnthropicAPI │
│ AgentEngine: silent-by-default gate, ai_window/ai_invite          │
│ enforcement, thread turn loop + loop guard                        │
└──────────────┬────────────────────────────────────────────────────┘
┌──────────────▼───────────── PQRCCore (actors) ────────────────────┐
│ IdentityManager · AgentKeyDeriver · BindingVerifier (10420)       │
│ PrekeyManager (10421) · PQXDH · DoubleRatchet · PQRekey           │
│ Padding · Envelope codec (rumor→seal→gift wrap) · SessionStore    │
└──────┬──────────────────────────────┬─────────────────────────────┘
┌──────▼──────── PQRCNostr ────┐ ┌────▼──────── Persistence ────────┐
│ NostrEvent (NIP-01) · BIP340 │ │ MessageStore (protocol)          │
│ RelayTransport (protocol)    │ │  → SwiftData impl (app)          │
│  → LocalRelaySimulator       │ │  → InMemory impl (tests)         │
│  → (future) NostrNetwork     │ │ EncryptedStore: AES-GCM blobs    │
│ BlobStore (protocol)         │ │ under SE-wrapped master key      │
│  → LocalBlossomSimulator     │ │ (SPEC §3.4)                      │
│ LocalLinkTransport (seam)    │ └──────────────────────────────────┘
└──────────────────────────────┘
```

**Send pipeline** (mirrors SPEC §0 diagram ①–⑥): compose → pad to bucket → ratchet-encrypt (AD per SPEC §8.3, with the fuzzed timestamp chosen *before* encryption and reused on the wrap) → rumor(1420, unsigned) → seal(13, sender Nostr key) → gift wrap(1059, fresh random key, fuzzed `created_at`) → outbox → `RelayTransport.publish` to recipient's kind-10050 relays. **Receive pipeline:** subscribe `{kinds:[1059], #p:[me]}` → dedupe by event id → unwrap → unseal → blocklist check on revealed sender **[D8]** → session lookup (or handshake / message-request path) → ratchet-decrypt → unpad → store → UI.

**Concurrency:** one actor per session; `RelaySync` actor drains envelopes on foreground/scenePhase change and pull-to-refresh (no background fetch in v1 **[D6]**).

## 3. Persistence & key custody

Keychain items (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **never** iCloud-synced): Nostr private key, PQRC identity private key, prekey private halves, SE-wrapped master storage key, optional Anthropic API key. The agent seed is re-derived on demand (SPEC §3.2), never stored.

`EncryptedStore` **[D9]**: a 256-bit master key wrapped via Secure Enclave P-256 key agreement (SPEC §3.4), unwrapped into memory after first unlock. Message plaintext, session/ratchet state, skipped-key cache, and thread records are stored as AES-256-GCM blobs under per-record derived keys (HKDF over master key + record UUID). The SwiftData container additionally uses `completeFileProtection`. SwiftData models: `Contact` (npub, identity pub, agent pub, local nickname, verified flag, blocked flag), `Conversation` (type 1to1|group, group meta), `Message`, `Thread`, `ThreadMessage`, `OutboxEnvelope`, `ProcessedEventID`, `SessionRecord` (opaque encrypted blob), `PrekeyState`.

## 4. Transport

`RelayTransport` protocol: `publish(_ event:) async throws -> PublishAck`, `subscribe(_ filters:) -> AsyncThrowingStream<NostrEvent, Error>`, `authenticate(challenge:)`. **This is the swap point for the real Nostr network later — nothing above this protocol may know which implementation is live.**

`LocalRelaySimulator` (actor): implements the NIP-01 subset (EVENT/REQ/EOSE/OK/CLOSE) plus NIP-42 AUTH; stores events; **serves kind-1059 only to the AUTHed `p`-tagged recipient** (anchor-relay behavior, SPEC §9.1); replaceable-event semantics for kinds 10420/10421/10050; store-and-forward for offline recipients; configurable `ChaosOptions` (latency jitter, drop %, duplicate %, reorder window) for the test matrix. Debug builds may additionally expose it through an `NWListener` WebSocket speaking the same NIP-01 subset on localhost, so two iOS simulators can demo against one relay **[S2, Debug-only, compiled out of Release]**.

`LocalBlossomSimulator`: content-addressed put/get by SHA-256 with a second instance acting as mirror, exercising the `ptr` path of SPEC §11.

## 5. Identity & onboarding

First launch: generate Nostr key + PQRC identity key → derive agent key → friendly explainer screens (no phone/email/wallet; keys live only on this device) → **explicit, unskippable warning that losing the device loses the identity** (recovery is a non-goal, SPEC §0) → publish kind 10420 binding + kind 10421 bundle + kind 10050 relay list to the configured relays (simulator in v1) → set a **local-only** display name **[D11]** → land on empty conversation list. Settings exposes my npub as text + QR. New chats: paste npub or scan QR (camera permission requested just-in-time); client fetches peer's 10420/10421, verifies the binding **both directions**, and verifies prekey signatures before any handshake. Peer without a valid 10420/10421 → "hasn't set up PQRC yet" invite state, no fallback **[scope]**.

## 6. Conversations

**6.1 List** — iMessage-style rows: avatar (generated identicon from identity pub), name, last message preview, relative time, unread badge, swipe to pin/delete, pull-to-refresh syncs relays. A separate **Message Requests** section holds handshakes from unknown senders; nothing from an unknown sender renders as a conversation until accepted **[D12]**.

**6.2 Message view** — bubbles:
- Outgoing human: filled accent, trailing. Incoming human: secondary fill, leading.
- **Agent messages (SPEC §13.4 MUST):** aligned with their human's side but unmistakably distinct — tinted outline + `sparkles` badge + caption label "⟡ Alice's AI" — and `accessibilityLabel` prefixed "AI message from Alice's assistant". A `participant_type:"human"` payload under an agent-bound seal is rejected by the engine and surfaced as a red "protocol violation" system row.
- Local-only status on outgoing: Queued → Sent to relay (on OK). No remote delivery/read state exists **[D5]**, and UI copy says "sent to relay", never "delivered".
- System rows: ai_window start/expiry, safety-code change warnings (peer republished 10420/10421 with different keys → persistent warning banner until re-verified), thread anchors.

**6.3 Composer** — multiline field, PhotosPicker attachments (out-of-process; no photo-library permission string needed), AI button (§9). **Large paste:** pasting text whose UTF-8 size exceeds 16 KB collapses into an inline chip — "Large text · 218 KB · sends as encrypted attachment" — and routes through the blob path; the field never visibly chokes. Anything > 64 KB MUST take the `ptr` path (SPEC §11); the bucket/inline decision is invisible to the user.

**6.4 Verification** — per-contact screen showing a 60-digit safety code in 12 groups (SHA-256 over the two PQRC identity pubkeys, sorted) plus QR compare; "Mark as verified" sets a shield on the conversation **[D13, app-level]**.

**6.5 Block & report [D8]** — Block drops messages post-unseal (the relay layer cannot filter by sender — the sender is hidden by design) with no notification to the blocker's peer. Report opens a sheet explaining that messages are E2EE and nothing is auto-shared, offering the user a voluntary export of selected messages to email the maintainer. Both reachable from conversation details (App Review Guideline 1.2 expects this for user-generated content).

## 7. Groups [D1 — interim until MLS v2]

v1 implements groups as **client-side pairwise fan-out**: a group is a roster plus N−1 ordinary PQRC 1:1 sessions; sending encrypts the same padded plaintext once per member session. Every pairwise link retains full FS/PCS/PQ properties. Wire additions (inside the encrypted rumor only): rumor type `"group_create"` carrying `{group_id (uuidv4), name, members:[npub...], conversation_type:"group"}` sent pairwise to each member; subsequent messages carry `"group": {"id": ...}`. Roster changes are new `group_create` revisions from any current member; clients render roster-change system rows. **Honest limitations (state in THREAT_MODEL):** O(n) send cost, no cryptographic membership agreement (a malicious member can present inconsistent rosters — display "roster as asserted by X"), removed members simply stop receiving, joiners see no history. Schema is forward-compatible with SPEC §12 MLS migration; nothing here hard-codes two-party state shapes.

## 8. Shared AI Threads [D7 — the headline feature]

A human can spin up an embedded thread (Discord-style) inside any 1:1 or group conversation in which **both/all humans' AIs may interact with each other and share context — and every byte of that interaction is recorded in the thread for the humans to read.**

**Model.** `Thread {id, conversation_id, anchor_message_id?, title, created_by}`. Wire (inside encrypted rumors; unknown-field-tolerant per SPEC §12): new rumor type `"thread_create"`; all thread traffic is ordinary `"message"` rumors carrying `"thread": {"id": ...}`; and `"ai_invite"`:

```jsonc
{ "type": "ai_invite", "thread": {"id": "..."}, "active_until": <unix>,
  "enabled_by": "<pqrc_identity_pubkey_hex>", "sig": "<by identity key>" }
```

`ai_invite` is the thread-scoped analogue of `ai_window` (SPEC §13.3) and inherits all its rules: signed by the **human identity key only**, bounded duration, agent cannot self-activate, every client shows the active indicator, expiry returns the agent to silence.

**Participation rules.**
1. An agent may post in a thread only while its own human's `ai_invite` for that thread is active. Per-human opt-in; one human inviting their AI never activates the other's.
2. While invited, agents may converse autonomously **within the thread only** — replying to the other agent and to humans — never in the parent conversation.
3. **The recording guarantee:** there is no agent-to-agent channel other than thread messages. `AgentProvider` returns messages; `AgentEngine` posts them to the thread; no other output path exists in the API. Any context an agent contributes (a summary of its human's notes, a retrieved fact) necessarily appears as a normal, signed, agent-labeled thread message. Context-bearing posts SHOULD be prefixed "Context:" and render with a folder glyph for skimmability.
4. **Loop guard [D14]:** after 6 consecutive agent messages with no human message, agents pause and the thread shows "AIs paused — waiting for a human." Hard cap regardless of provider; enforced in `AgentEngine`, covered by tests.
5. Humans can post in threads at any time, end their own invite early, and the thread creator can close the thread (system row; agents stop).

**UI.** Anchored chip under the source message or in the conversation header: "✳︎ AI Thread · *title* · 12 messages", expanding to a full-screen `ThreadView` with a pinned header listing participants and live AI status per human ("Alice's AI active · 22m left"), countdowns, and an Invite/Withdraw-my-AI control with duration picker (15m/30m/1h/2h — bounded only, per SPEC §13.3).

## 9. AI integration

`AgentProvider` protocol: `draftReply(context:) async throws -> Draft` and `threadTurn(context:) async throws -> AgentTurn?` (where `AgentTurn` is zero or more messages — the only way agent output enters the world).

- **MockAgentProvider** — deterministic, scriptable; used by tests and Local Universe.
- **FoundationModelsAgentProvider** — on-device via the iOS 26 FoundationModels framework, availability-gated (`SystemLanguageModel` availability check); graceful "AI unavailable on this device" state. Default when available.
- **AnthropicAPIProvider [D3]** — optional, **off by default**. Enabling shows an explicit consent screen: *"Decrypted conversation context will be sent to a remote API for inference. Your signing keys never leave this device (SPEC §13.5), but message content does. This trades privacy for capability."* Key stored in Keychain; provider sends only the minimal context window.

**Silent by default (SPEC §13.2):** outside an active window/invite, providers may be consulted only to produce private drafts for their own human; nothing is ever sent autonomously. Drafting UX: AI button → "Draft a reply" → preview sheet → **Send as my AI** (signed by agent key, `participant_type:"agent"`) or **Edit & send as me** (the human's own message, human-signed). **ai_window (conversation-scope):** toggle with bounded durations; broadcasts the SPEC §13.3 rumor; all clients pin a banner "Alice's AI is active until 3:45 PM" with countdown; expiry clears it and closes the autonomous-send gate (fail-closed, test-enforced).

## 10. Settings

Identity (npub + QR, safety-code explainer, **no key export — by design**), Relays (list, add/remove, AUTH status; Debug: simulator chaos sliders), Prekeys (one-time count, "Republish bundle"), AI (provider picker, consent flow, default invite duration), Privacy (ephemeral receiving keys toggle — present, **off, marked experimental** per SPEC §9.3; blocklist management), Data (delete conversation, wipe identity with double confirm), About (version, AGPL-3.0 license, THREAT_MODEL summary — one honest screen: "Relays can see your IP and that *someone* messaged you. They cannot see who sent it or what it says.").

## 11. Visual & interaction design

iOS 26 Liquid Glass via standard components (toolbars, tab-free `NavigationSplitView` for iPad readiness); reserve explicit `glassEffect` for the ai-window banner and thread header so "AI is present" reads as a distinct material. SF Symbols: `sparkles` (agent), `key.viewfinder` (verify), `shield.checkered` (verified), `clock.badge.exclamationmark` (window expiring). Spring-default motion with Reduce Motion variants; haptics on send, on window start/expiry, on safety-code change. Dynamic Type through accessibility sizes; 44 pt minimum targets; both color schemes; agent styling must survive grayscale (shape + badge, not color alone). Run `performAccessibilityAudit()` in UI tests.

## 12. Performance budgets

| Path | Budget (p95, baseline-relative on CI simulator) |
|---|---|
| Cold launch → list interactive | < 800 ms |
| 1 KB message: pad+encrypt+wrap | < 10 ms |
| 64 KB inline path | < 50 ms |
| 1 MB paste → blob encrypted+stored | < 250 ms, UI never blocked |
| Scroll 10k-message conversation | hitch ratio < 5 ms/s (signpost metric) |
| Drain 500 queued envelopes | < 3 s, UI responsive |
| Memory during 10k-message scroll | < 250 MB |

First CI run records baselines; subsequent runs assert ≤ 10 % regression (TEST-PLAN §7).

## 13. Error handling & edge cases

Out-of-order within `MAX_SKIP` decrypts; beyond it → quarantined system row ("message arrived too far out of order"), never a crash. Duplicate envelopes deduped by event id. Failed decrypt/tampered AD → quarantine + log (private), session continues. Prekey exhaustion → `lrp` path with a DEVIATIONS-documented note. Offline sends queue in outbox with exponential backoff across all listed relays; one healthy relay suffices. Clock weirdness on inbound fuzzed timestamps is tolerated by design.

## 14. Privacy engineering checklist

No third-party SDKs, no analytics, no ads. OSLog `privacy: .private` on payload-adjacent values. `privacySensitive()` on message content for app-switcher snapshots. ATS strict; localhost WS exception Debug-only. `PrivacyInfo.xcprivacy`: no collection, no tracking, required-reason entries only for APIs actually used (e.g. UserDefaults → CA92.1). `ITSAppUsesNonExemptEncryption = YES` (see TESTFLIGHT-GUIDE §C).

## 15. Local Universe (demo mode, Debug)

Seeded personas Alice & Bob (+ derived agents) over an in-process simulator with a persona switcher, plus a scripted demo: greeting exchange → AI-drafted reply → 30-min ai_window with banner → shared AI thread where both agents exchange two context messages and hit the loop guard → 200 KB paste via blob path → group of 4 fan-out. Document in `docs/DEMO.md`; UI tests replay this script.

## 16–17. (reserved)

## 18. Decisions registry → copy into docs/DEVIATIONS.md

| ID | Decision | Tag |
|---|---|---|
| D1 | Groups v1 = pairwise fan-out of PQRC sessions; `conversation_type:"group"`, `group_create` rumor; MLS in v2 per SPEC §12 | upstream-NIP |
| D2 | Handshake suite = explicit PQXDH hybrid (NIP normative math); X-Wing behind `"suite"` field in handshake content (`"hybrid-v1"` default), disabled — the two paths derive different SK, so interop needs explicit negotiation | upstream-NIP |
| D3 | Remote (Anthropic API) agent inference off by default behind explicit consent; on-device FoundationModels preferred | app-only |
| D4 | Handshake rumor carries `spk_used` / `otp_used` (base64 key or SHA-256) so the responder knows which prekeys were consumed — gap in SPEC §4.2 | upstream-NIP |
| D5 | No read/delivery receipts in v1 (linkable traffic = metadata) | app-only |
| D6 | No push notifications in v1 (APNs = centralized metadata observer); foreground + pull-to-refresh sync | app-only |
| D7 | Thread wire extension: `thread` object, `thread_create`, `ai_invite` (thread-scoped ai_window) | upstream-NIP |
| D8 | Block post-unseal + voluntary report flow (Guideline 1.2) | app-only |
| D9 | EncryptedStore: SE-wrapped master key, per-record HKDF keys, AES-GCM blobs in SwiftData | app-only |
| D10 | Handshake rumor piggybacks message #0 ciphertext (Signal pattern) so first text rides along | upstream-NIP |
| D11 | No published kind-0 profiles in v1; local nicknames only | app-only |
| D12 | Message-requests inbox for unknown-sender handshakes | app-only |
| D13 | Safety-code verification screen (app-level; protocol-silent) | app-only |
| D14 | Thread agent loop guard: 6 consecutive agent messages → pause for a human | app-only |
| S1/S2 | Multipeer local-link transport / localhost WS relay frontend = stretch, Debug-only | tech-debt |
