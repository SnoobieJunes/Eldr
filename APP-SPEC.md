# APP-SPEC.md — EldrChat / PQRC iOS Client v1

**Last reconciled: 2026-06-20** — refreshed to cover the June 18–20 build-out (the ACP-router architecture §24a, the at-rest key-custody reversal §3/§19 per DEVIATIONS AC31, the Private Cloud Compute tier, and the security fixes C-1…C-8 / G3 / G4). `docs/DEVIATIONS.md` remains the live, authoritative changelog; this document is the product/architecture view.

What to build. This document is subordinate to `pqrc-SPEC-v1_1.md` (protocol) and `NIP-XX-pqrc.md` (wire format). Where this document adds things the protocol does not define, the addition is tagged **[Dx]** and listed in §18 for `docs/DEVIATIONS.md`.

## 0. Product principles

1. **Privacy is the number one priority, without exception** (SPEC §0). Ties resolve toward privacy.
2. **Transparency of AI is a privacy property.** No one is ever unknowingly talking to an AI. Agent authorship is always visible, always verifiable.
3. **iMessage-grade feel.** Native, fluid, instant. The cryptography is invisible; the trust signals are not.
4. **Honest limitations.** What PQRC does not protect (IP metadata, recipient `p`-tag against a global observer, no *message* deniability, single device) is stated plainly in-app, not hidden. Account deniability protects each account's **contents** and the passphrase→data mapping against a live coercer (duress/decoy, §19) — it does **not** hide the *count* of accounts from a forensic disk image, because each account now carries its own Secure-Enclave-wrapped key blob (an accepted limit per DEVIATIONS AC31, not a pending TODO; see §3, §19 and THREAT_MODEL §2.3a/§2.12).
5. **Router, not a coding agent.** EldrChat owns identity, E2EE, secure transport, session history, consent, and the **router** that targets a backend; the actual development work is delegated to interchangeable, swappable ACP harnesses (Xcode ACP, OpenClaw, Claude Code, Codex, Gemini CLI, …). ACP is to agents what HTTP is to the web; EldrChat speaks it to everything (§24a, `docs/ACPRouterplan.md`).

## 1. Scope

**In v1:** onboarding/key generation, 1:1 conversations, group conversations **[D1]**, shared AI threads, AI drafting + `ai_window`, large content via relay chunking, message requests, contact verification, block & report, Local Universe demo mode, full test suite.

**Shipped since the original v1 cut** (detailed in §§19–24 below and in DEVIATIONS;
this is the source of truth for the rapid build-out after the first pass):
- Deniable multi-account **silos** — passphrase→KEK, bare lock screen, account swap,
  legacy migration, biometric/Face-ID convenience tier, duress decoy **[A23–A26, A33]** (§19).
- **Multi-AI tethering**: several AIs per account, each with a per-AI on/off toggle,
  per-AI Keychain key, and a context profile (instructions / gather-policy / depth /
  output mode); a "solo AI chat"; the in-chat **"AI here" context chip** and a unified
  context vocabulary; backends Claude / OpenAI / Gemini / **OpenRouter** / **Groq** /
  **self-hosted (OpenAI-compatible)** / **Apple Private Cloud Compute** **[A40]** /
  **`acp` Mac coding harness** (§24a), with reasoning-trace stripping **[A20, A27, A30, A31, A34]** (§20).
  The backend list is now **data-driven** from `BackendRegistry.all` (`App/PQRC/Engine/BackendRegistry.swift`).
- The **egress firewall**: codename redaction + a 64 KB bound applied to everything
  sent to an off-device AI (§21).
- The **device-hosted relay hub** over Multipeer (a "pocket relay") plus host-AI
  sharing (Tier 2 LLM over the radio) **[A31]** (§22).
- **Agent-to-agent thread skills** — base PQRC guardrail injection + a pinned-skills
  catalog, pure prompt composition, no new wire format **[A32]** (§23).
- A local **MCP server** exposing secure chat read-only **[A35]** and an **ACP agent**
  that lets the on-device model pilot Xcode **[A36]** (`PQRCMCP`, `PQRCACP`). The MCP
  server is now **hosted in-app** over a loopback Unix socket behind an OFF-by-default,
  token-gated, stops-on-lock Settings toggle (Phase 2 shipped — §24). **MCP is still
  shipped** — the ACP-router plan's "remove MCP" step has *not* been executed (§24).
- **EldrChat as a secure, universal ACP router** **[AC33–AC35]** — the phone is an ACP
  *client*; coding work is delegated to a swappable harness on an "Eldr node" (Mac or
  the standalone `eldr-node` daemon), reached over the **same** E2EE mesh as chat. Ships:
  the phone `ACPClient` + transport seam, a data-driven backend registry, sealed
  Nearby + relay-carried ACP transports, an owner-gated node host, and a task-routing
  policy seam (§24a). Mac runtime is **Mac Catalyst** **[A41]**; OpenClaw is a first-class
  ACP client **[A42]** and an optional contextgraph backend exists **[A43]**.
- **NIP-40 expiry** on gift-wraps **[A22]**, relay **chunking** for large text
  **[N26, A25]**, native markdown/HTML rendering + full-screen reader **[A17, A19, A22]**,
  friendly local codenames **[A19]**, and a responsive iPad/Mac `NavigationSplitView` pass.

**Out (documented in THREAT_MODEL/DEVIATIONS):** multi-device, key backup/recovery,
push notifications **[D6]**, read/delivery receipts **[D5]**, NIP-17 fallback, real MLS
groups, Tor/IP privacy, cryptographic *message* deniability (account-existence
deniability via silos now ships — §19), published profiles (kind 0) **[D11]**, and
images/video (text-only by design — "use iMessage for that"). The BLE/Multipeer
local-first transport (SPEC §10), once a stretch goal **[S1]**, is now **implemented**
and user-toggleable (Settings → Nearby).

## 2. Architecture

```
┌──────────────── AccountGate (lock screen, §19) ───────────────────┐
│ passphrase → PBKDF2 → {siloID, KEK} · Face-ID convenience tier    │
│ never auto-boots; a wrong passphrase = a different (empty) silo    │
└──────────────┬────────────────────────────────────────────────────┘
┌──────────────▼─────────────── App (SwiftUI) ──────────────────────┐
│ ConversationList · ConversationView · ThreadView · Composer       │
│ "My AI" solo chat · "AI here" context chip · Skills picker        │
│ Onboarding · Settings · Verification · Debug/LocalUniverse        │
│ EgressFirewall (codename redaction + 64 KB bound, §21) on off-    │
│ device-AI calls · PersonaRuntime (per-silo engine) · AppModel     │
└──────────────┬────────────────────────────────────────────────────┘
               │ @Observable view models (MainActor)
┌──────────────▼───────────── PQRCAgent ────────────────────────────┐
│ AgentProvider → Mock | FoundationModels | Anthropic | OpenAI |    │
│   Gemini | OpenRouter | Groq | Custom(self-hosted) | PCC | hub |  │
│   acp (ACPAgentProvider → external harness over a sealed transport)│
│ AgentEngine: silent-by-default gate, ai_window/ai_invite/grant    │
│   enforcement, thread turn loop + loop guard · AgentSkills (§23)  │
│ AISelectionPolicy / CapabilityRoutingPolicy: task-type→engine seam │
│ ConfiguredAI: per-AI profile (instructions/policy/depth/output)   │
│   driven by data-driven BackendRegistry (App/PQRC/Engine)         │
└──────────────┬────────────────────────────────────────────────────┘
┌──────────────▼───────────── PQRCCore (actors) ────────────────────┐
│ IdentityManager · AgentKeyDeriver · BindingVerifier (10420)       │
│ PrekeyManager (10421) · PQXDH · DoubleRatchet · PQRekey           │
│ Padding · Envelope codec (rumor→seal→gift wrap) · SessionStore    │
│ SiloKey (passphrase→KEK derivation, §19)                          │
└──────┬──────────────────────────────┬─────────────────────────────┘
┌──────▼──────── PQRCNostr ────┐ ┌────▼──────── Persistence ────────┐
│ NostrEvent (NIP-01) · BIP340 │ │ MessageStore (protocol)          │
│ RelayTransport (protocol)    │ │  → SwiftData impl (app)          │
│  → LocalRelaySimulator       │ │  → InMemory impl (tests)         │
│  → NostrWebSocketTransport   │ │ EncryptedStore: AES-GCM blobs    │
│  → MultipeerRelayClient      │ │ under per-silo SE/KEK-wrapped    │
│ NearbyRelayHub / Host (§22)  │ │ master key (SPEC §3.4; §19)      │
│ MultipeerLinkTransport (S1)  │ │ per-silo store file silo-*.store │
│ pqrc-relay (dev exe)         │ └──────────────────────────────────┘
└──────────────────────────────┘

Agent-interop + ACP-router packages (§24 / §24a):
  PQRCMCP  — MCP server: EldrChat as a read-only secure-chat source (exe pqrc-mcp)
  PQRCACP  — ACP: eldr-acp agent + phone ACPClient + ACPTransport seam
             + ClientConnection/ToolExecutor (path-jailed, permission-gated)
  EldrNode — standalone macOS eldr-node daemon (EldrNodeCore.serve, owner-gated)
  PQRCNostr/{NearbyACPTransport (per-line sealed), RelayACPTransport (relay-carried)}
  App/PQRC/Engine/{BackendRegistry, PairedPubkeySnapshot}
  Apps/EldrACPConfigurator — the "Eldr node + setup hub" (ACPNodeHost, ACPRelayHost,
             RelayProvisioner) — Mac Catalyst
```

A chat→node ACP turn becomes a `session/prompt` carried as ordinary gift-wrapped +
Double-Ratcheted ciphertext over the **same** mesh as chat; a relay sees only
`ACP1|…`-framed ciphertext, indistinguishable from a normal message (§24a).

**Send pipeline** (mirrors SPEC §0 diagram ①–⑥): compose → pad to bucket → ratchet-encrypt (AD per SPEC §8.3, with the fuzzed timestamp chosen *before* encryption and reused on the wrap) → rumor(1420, unsigned) → seal(13, sender Nostr key) → gift wrap(1059, fresh random key, fuzzed `created_at`) → outbox → `RelayTransport.publish` to recipient's kind-10050 relays. **Receive pipeline:** subscribe `{kinds:[1059], #p:[me]}` → dedupe by event id → unwrap → unseal → blocklist check on revealed sender **[D8]** → session lookup (or handshake / message-request path) → ratchet-decrypt → unpad → store → UI.

**Concurrency:** one actor per session; `RelaySync` actor drains envelopes on foreground/scenePhase change and pull-to-refresh (no background fetch in v1 **[D6]**).

## 3. Persistence & key custody

Keychain items (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, **never** iCloud-synced): Nostr private key, PQRC identity private key, prekey private halves, SE-wrapped master storage key, and per-AI provider API keys (`apikey.<id>`, with a legacy shared account read as fallback — A31). The agent seed is re-derived on demand (SPEC §3.2), never stored.

**Per-silo isolation & at-rest key custody (§19; DEVIATIONS AC31, T1, commits KS-1…KS-4).**
> **Corrected June 2026.** The earlier `passphrase → PBKDF2 (fixed salt) → KEK` model — where the passphrase *derived* the at-rest key — was **reverted** because a fixed-salt PBKDF2 KEK is offline-brute-forceable from a stolen disk image, violating invariant 10. The current model:

Each account's silo key is a **random 256-bit key, hardware-wrapped by the Secure Enclave** (P-256, non-exportable). The passphrase is **not** the basis of the key — it is, at most, an optional second factor *nested under* the SE wrap, and otherwise only the opaque deniable namespace selector. From `AccountVault.swift`:
- **`.secureEnclave`** (default account): `wrapped = SE.wrap(siloKey)`.
- **`.passphrase(p)`** (hidden account): `wrapped = SE.wrap( AES-GCM(PBKDF2(p), siloKey) )` — passphrase nested *inside* the hardware wrap.

`SiloKey.swift` derives **only** the namespace `siloID` from the passphrase (`siloID(for:)`) plus the optional inner `passphraseKEK`; it never derives the storage key. **Security property:** a disk image without the live, non-exportable SE key cannot unwrap either form *even with the correct passphrase* — there is no offline-brute-force surface. A **SE-availability tripwire** (`SecureEnclaveKeyWrapper.swift`, G3) fires `assertionFailure` (debug) / OSLog `.fault` (release) if the software-KEK fallback is ever reached on SE-capable hardware, logging no key bytes.

**Two account shapes (AC31):** (1) a passphrase-less **default** account (≤1 per device, namespace `"default"`, opened on Face ID / device unlock, openly present — *not* deniable) and (2) any number of passphrase-gated **hidden** accounts (passphrase derives the deniable namespace + nests under the SE wrap). **Biometric is restricted to the default account** — caching a hidden account behind Face ID would reveal it exists. A wrong passphrase derives a different, non-existent namespace — indistinguishable from "no account". **No migration:** the legacy passphrase-silo path was removed via pre-launch wipe, not migrated.

Per-account *preferences* (relay list, AI context domain, per-conversation context mode, per-thread skills, contact-activity map, display name) are namespaced `<base>.<siloID>` in UserDefaults so a second silo's runtime can't read the first's; `bootSilo` migrates any legacy flat keys into the booting silo and deletes the originals. (Accepted limit: the *count* of accounts is inferable from a forensic image because each carries its own SE-wrapped key blob — AC31 resolved count-hiding as **do-not-build**, not a pending TODO.)

`EncryptedStore` **[D9]**: the random per-silo master key (above) is unwrapped into memory after the silo unlocks. Message plaintext, session/ratchet state, skipped-key cache, and thread records are stored as AES-256-GCM blobs under per-record derived keys (HKDF over master key + record UUID). The SwiftData container additionally uses `completeUntilFirstUserAuthentication` file protection (A15 — downgraded from `.complete`, which made the DB unreadable while locked; the envelope encryption under the wrapped key is the actual at-rest guarantee). SwiftData models: `Contact` (npub, identity pub, agent pub, local nickname, friendly codename, verified flag, blocked flag), `Conversation` (type 1to1|group, group meta), `Message`, `Thread`, `ThreadMessage`, `OutboxEnvelope`, `ProcessedEventID`, `SessionRecord` (opaque encrypted blob), `PrekeyState`.

## 4. Transport

`RelayTransport` protocol: `publish(_ event:) async throws -> PublishAck`, `subscribe(_ filters:) -> AsyncThrowingStream<NostrEvent, Error>`, `authenticate(challenge:)`. **This is the swap point for the real Nostr network later — nothing above this protocol may know which implementation is live.**

`LocalRelaySimulator` (actor): implements the NIP-01 subset (EVENT/REQ/EOSE/OK/CLOSE) plus NIP-42 AUTH; stores events; **serves kind-1059 only to the AUTHed `p`-tagged recipient** (anchor-relay behavior, SPEC §9.1); replaceable-event semantics for kinds 10420/10421/10050; store-and-forward for offline recipients; configurable `ChaosOptions` (latency jitter, drop %, duplicate %, reorder window) for the test matrix. Debug builds may additionally expose it through an `NWListener` WebSocket speaking the same NIP-01 subset on localhost, so two iOS simulators can demo against one relay **[S2, Debug-only, compiled out of Release]**.

`LocalBlossomSimulator`: content-addressed put/get by SHA-256 with a second instance acting as mirror, exercising the `ptr` path of SPEC §11.

## 5. Identity & onboarding

**Lock screen first (§19).** The app **always** launches to a bare passphrase screen (`AccountGateView`) and **never auto-boots** — auto-booting would reveal an account exists. Face ID / Touch ID is the default convenience unlock for the *first* account (auto-prompted at launch); the passphrase is the labelled-secondary path and the only way into a hidden account. A correct passphrase derives `{siloID, KEK}` and boots that silo; a wrong one derives a different, non-existent silo (looks like "no account yet").

Account creation (AC31 / KS-4): the **primary path creates the passphrase-less default account** (display name + the unskippable no-recovery acknowledgement → create; opened thereafter on Face ID / device unlock). Entering a *new passphrase* at the gate instead creates a **hidden** account mapped to that passphrase's deniable namespace. Either way: pick a **display name** (and, for a hidden account, the **passphrase**) → generate Nostr key + PQRC identity key → derive agent key → friendly explainer screens (no phone/email/wallet; keys live only on this device) → **explicit, unskippable "No recovery — by design" warning** (lose the passphrase = that account and all its history are gone forever; recovery is a non-goal, SPEC §0) → publish kind 10420 binding + kind 10421 bundle + kind 10050 relay list to the configured relays → land on empty conversation list. Face ID is silently best-effort enabled on creation (no device passcode/biometric → the account stays passphrase-only). Settings exposes my npub as text + QR and an account **swap** (lock + return to the gate to open a different silo). New chats: paste npub or scan QR (camera permission requested just-in-time); client fetches peer's 10420/10421, verifies the binding **both directions**, and verifies prekey signatures before any handshake. Peer without a valid 10420/10421 → "hasn't set up PQRC yet" invite state, no fallback **[scope]**.

## 6. Conversations

**6.1 List** — iMessage-style rows: avatar (generated identicon from identity pub), name, last message preview, relative time, unread badge, swipe to pin/delete, pull-to-refresh syncs relays. A separate **Message Requests** section holds handshakes from unknown senders; nothing from an unknown sender renders as a conversation until accepted **[D12]**. Displayed names use a **local friendly codename** (A19) — `adjective-noun-verb-###`, generated on-device (Core AI when available, else a deterministic FNV seed), stored only in the encrypted `ContactRecord`, **never** sent on the wire — so the UI never shows a raw key. Display order: local rename > peer's self-chosen alias (N21, channel-private) > friendly codename > key. A separate **brain icon** opens "My AI" — the solo AI chat (§20).

**6.2 Message view** — bubbles:
- Outgoing human: filled accent, trailing. Incoming human: secondary fill, leading.
- **Agent messages (SPEC §13.4 MUST):** aligned with their human's side but unmistakably distinct — tinted outline + `sparkles` badge + caption label "⟡ Alice's AI" — and `accessibilityLabel` prefixed "AI message from Alice's assistant". A `participant_type:"human"` payload under an agent-bound seal is rejected by the engine and surfaced as a red "protocol violation" system row.
- Local-only status on outgoing: Queued → Sent to relay (on OK). No remote delivery/read state exists **[D5]**, and UI copy says "sent to relay", never "delivered".
- System rows: ai_window start/expiry, safety-code change warnings (peer republished 10420/10421 with different keys → persistent warning banner until re-verified), thread anchors.

**6.3 Composer** — multiline field, AI controls (§9: a **Draft with AI** sparkles button and, in any conversation, the AI-window / thread / Skills entry points). **Large paste:** pasting a big block collapses into an inline chip — "Large text · 218 KB" — so the field never visibly chokes. Large text sends via **relay chunking** (N26/A25), not a blob server: the message is split across several ratcheted gift-wrap envelopes (each a one-time key) and rejoined on receipt; relays see only bucket-padded per-envelope sizes. Chunk budget is **adaptive** — derived from the relay set's smallest NIP-11 `max_content_length` and lowered if a relay rejects "content too large" — so a permissive relay uses the full 64 KB bucket and strict relays stay at 16 KB; the in-process/offline relay reports no limit, so over Nearby the full 64 KB bucket is used. (This is the text-only product's answer to SPEC §11; the `ptr`/Blossom path is reserved for binary attachments once a networked blob server lands — not in scope for v1's text-only design.)

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

`AgentProvider` protocol: `draftReply(context:) async throws -> Draft` and `threadTurn(context:) async throws -> AgentTurn?` (where `AgentTurn` is zero or more messages — the only way agent output enters the world). The provider list and per-AI profiles have grown substantially since the original cut — see **§20 (multi-AI)** for the full backend list, the per-AI profile model, the solo-AI chat, the "AI here" context chip, and the default-context rules; **§21** for the egress firewall; **§23** for thread skills; **§24a** for the ACP router (the `acp` backend that delegates to an external coding harness). Which AI handles a draft / autonomous turn is now a pluggable **`AISelectionPolicy`** (`PersonaRuntime.setAISelectionPolicy`; default `DefaultAISelectionPolicy`; opt-in `CapabilityRoutingPolicy` routes by *declared* capability, never message content). The egress firewall now also **scrubs credentials** on the remote path (G4, §21). The protocol-level gating below is unchanged.

Providers in v1: **MockAgentProvider** (deterministic, for tests + Local Universe) · **FoundationModelsAgentProvider** (on-device iOS 26, availability-gated, default when available) · **AnthropicAPIProvider [D3]** and the other remote/self-hosted backends in §20. Every `isRemote` provider is **off by default** behind an explicit consent screen (*"Decrypted conversation context will be sent to a remote API … message content does [leave the device]. This trades privacy for capability."*); its key lives only in the Keychain; it sends only the firewall-redacted, bounded context window.

**Silent by default (SPEC §13.2):** outside an active window/invite, providers may be consulted only to produce private drafts for their own human; nothing is ever sent autonomously. Drafting UX: composer **Draft with AI** (sparkles) → the AI writes an editable reply into the box — **never auto-sent**, and local-only (drafting needs no window; only *sending as AI* does). From there: **Send as my AI** (signed by agent key, `participant_type:"agent"`) or **Edit & send as me** (human-signed). **ai_window (conversation-scope):** toggle with bounded durations; broadcasts the SPEC §13.3 rumor; all clients pin a banner "Alice's AI is active until 3:45 PM" with countdown; expiry clears it and closes the autonomous-send gate (fail-closed, test-enforced). **Context grants (N24):** a peer's marked context reaches your AI only when **both** humans hold a live `ai_context_grant` in scope (bidirectional default, a tie broken toward privacy).

## 10. Settings

- **Account (§19)** — Face ID / Touch ID toggle (ON by default; OFF = passphrase-only high-security), account **swap** (lock + return to the gate).
- **Identity** — npub + QR + Share, safety-code explainer, **no key export — by design**.
- **Contacts** — rename anyone (your name always wins), copy key, message, block management; every person and their AI carries a local friendly **codename** (§6.2, never broadcast).
- **Servers / Relays** — add/remove any `ws(s)://` URL (per-account, namespaced per silo), live socket status; the keywords **`local`** (in-process simulator), **`host`** (run a pocket relay, §22) and **`nearby`** (join one) are accepted here; Debug: chaos sliders.
- **Nearby** — the Multipeer local-first link (default ON in Debug, OFF in Release); the Local Network prompt only fires when on.
- **Prekeys** — one-time count, "Republish bundle".
- **AI (§20–21)** — tethered-AI list (add/remove, per-AI **on/off**, per-AI key, backend picker incl. **PCC** and **`acp`**), per-AI **Context & behavior** profile (instructions / gather-policy / depth / output mode; PCC adds a reasoning-depth control), the **egress firewall** toggle, a **per-conversation firewall override** (`off|marked|full`, default inherits the account default — AC32), the off-device-AI **consent flow**, default invite duration, **This workstation's context domain** (§23), and transparency views — **What your AI sees / View tethered LLM context** + **Test primary AI now**.
- **Mac coding agent (ACP) (§24a)** — pair an Eldr node so its harness can answer in a conversation under the owner's AI window; **remote dev-control consent** is OFF by default, per-node, per-silo (gates whether a paired node may be driven over the relay). The standalone `eldr-acp`-in-Xcode case is still configured in Xcode, not here.
- **Privacy** — ephemeral receiving keys toggle (present, **off, marked experimental** per SPEC §9.3); blocklist; Reachability (open inbox for a bounded window, A12).
- **Data** — delete conversation, wipe identity (double confirm).
- **About** — version, AGPL-3.0 license, THREAT_MODEL summary: "Relays can see your IP and that *someone* messaged you. They cannot see who sent it or what it says."

## 11. Visual & interaction design

iOS 26 Liquid Glass via standard components; the app uses a **`NavigationSplitView`** (conversation list + detail) so iPad / Mac / iPhone-landscape show list-and-detail side by side and iPhone-portrait collapses to a stack — reading-width content is constrained so bubbles/forms don't sprawl on a wide display. Orientations are enabled app-wide; `FullScreenReaderView` (markdown/HTML, pinch-zoom, landscape) is the reference for responsive behavior. Reserve explicit `glassEffect` for the ai-window banner and thread header so "AI is present" reads as a distinct material. SF Symbols: `sparkles` (agent), `key.viewfinder` (verify), `shield.checkered` (verified), `clock.badge.exclamationmark` (window expiring). Spring-default motion with Reduce Motion variants; haptics on send, on window start/expiry, on safety-code change. Dynamic Type through accessibility sizes; 44 pt minimum targets; both color schemes; agent styling must survive grayscale (shape + badge, not color alone). Run `performAccessibilityAudit()` in UI tests.

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

Seeded personas Alice & Bob (+ derived agents) over an in-process simulator with a persona switcher, plus a scripted demo: greeting exchange → AI-drafted reply → 30-min ai_window with banner → shared AI thread where both agents exchange two context messages and hit the loop guard → large paste (now via the relay-chunking path, §6.3) → group of 4 fan-out. Document in `docs/DEMO.md`; UI tests replay this script. (The Local Universe predates silos: it boots a fixed test silo with the bare empty-siloID keys, so the demo and existing suite are unaffected by the multi-account work.)

## 16–17. (reserved)

---

# Sections added after the original v1 cut

These document features built during the rapid post-v1 push. Each is grounded in
`docs/DEVIATIONS.md` (the per-change changelog, the source of truth) and the code;
the relevant DEVIATIONS IDs are cited inline. Where a feature is only partially
landed it is marked **(in progress)**.

## 19. Deniable multi-account silos  [A23–A26, A33; superseded key model in **AC31**]

One device holds **N isolated accounts** ("silos"): one passphrase-less **default**
account and any number of passphrase-gated **hidden** accounts. The mechanism (corrected
per AC31 — see §3 for the full rationale; `AccountVault.swift` + `SiloKey.swift`):
the passphrase derives **only** the opaque deniable namespace `siloID` (`SiloKey.siloID(for:)`),
**not** the at-rest key. Each silo's storage key is a **random 256-bit key wrapped by the
Secure Enclave**; for a hidden account the passphrase adds a layer *nested inside* that
hardware wrap. A silo is unreadable — **and a hidden account's existence unprovable from
the running app** — without both the live SE key and (for hidden accounts) the passphrase.
The earlier `passphrase → PBKDF2 → KEK`-derives-the-key model was reverted (it was
offline-brute-forceable). Isolation is **cryptographic, not OS-enforced** (iOS gives one
app a single sandbox; there is no Android-style secure island).

- **Lock screen, never auto-boot (§5).** The app always launches to `AccountGateView`.
  A wrong passphrase maps to a *different, non-existent* silo — indistinguishable from
  "no account". This is what makes the count/contents of accounts deniable from the
  running app.
- **Biometric convenience tier [A24].** Face ID / Touch ID is ON by default and the
  primary unlock — but **only for the FIRST account**, whose `{siloID, KEK}` sits
  behind a `.userPresence` Keychain item. Additional/hidden silos stay passphrase-only
  and fully deniable. The passphrase is always available (the only way into a hidden
  account) and always works; **lose it = data lost forever** (honest no-recovery,
  SPEC §0). Toggle OFF in Settings ▸ Account for passphrase-only high-security. (The
  tradeoff: a Face-ID prompt at launch implies the *primary* account exists; the
  product owner chose this convenience over launch-time deniability for the primary.)
- **Account swap.** Lock and return to the gate to open a different silo.
- **Duress = decoy [A25].** Because every passphrase opens its own silo, a duress
  account needs no special code: create one with a memorable passphrase, stock it with
  innocuous chats, reveal that passphrase under coercion. A *destructive* duress (wipe
  on a trigger) is intentionally **not** shipped (accidental-wipe risk > benefit when a
  plausible decoy exists).
- **Per-silo namespacing [A33].** Per-account preferences are keyed `<base>.<siloID>`
  (§3) so a cover silo never surfaces a hidden silo's relays/contacts; `bootSilo`
  migrates legacy flat keys in and deletes the originals.
- **Accepted limit [A26 / AC31] (not a TODO):** the *number* of accounts is inferable
  from a forensic image (per-silo `silo-*.store` files / `.<siloID>` UserDefaults suffixes,
  and now each account's own SE-wrapped key blob). AC31 **resolved count-hiding as
  do-not-build**: it is incompatible with per-account SE-wrapping and buys ≈zero benefit
  against a coercer who can already see the device — deniability protects each account's
  *contents* and the passphrase→data mapping (duress/decoy), not the count. This is a
  documented, accepted property, not pending Phase-2 work.

## 20. Multi-AI tethering, profiles, and context control  [A20, A27, A28, A30, A31, A34]

An account can **tether several AIs at once** (on-device + token APIs + self-hosted),
each independently configured.

**Backends** (data-driven from `BackendRegistry.all`). On-device **Core AI**
(FoundationModels) · **Claude** (Anthropic) · **OpenAI** · **Gemini** · **OpenRouter**
(one key, many model slugs, A27) · **Groq** (fast, A30) · **Custom / self-hosted** —
*any* OpenAI-compatible server (Ollama / LM Studio / vLLM or another vendor; API key
OPTIONAL, base URL required; the URL builder accepts a bare `host:port`, a `…/v1`, or a
full path, A30/A31) · **Apple Private Cloud Compute** (`pcc`, A40 — `isRemote` + consent,
but **exempt from the egress firewall** because it is attested + no-retention; gated
behind `ELDR_PCC_SDK`, currently OFF because the SDK symbols are absent — see statusreport
§1.3) · **`acp`** (Mac coding harness, §24a — `isRemote` + firewalled + `routingCapabilities==["code"]`;
falls back to a Demo stub until a node is paired+consented, then swaps in `ACPAgentProvider`) ·
**hub** (the nearby host's shared AI, §22) · **Demo** (stub replies). A new classifier
**`appliesEgressFirewall`** decouples "firewalled" from "isRemote" (so PCC can be remote
yet firewall-exempt). Local plaintext `http://` is
permitted to private addresses only via `NSAllowsLocalNetworking`; the public internet
still requires HTTPS. **Reasoning-trace stripping [A34]:** `<think>…</think>` and
Harmony/channel-tagged chain-of-thought (gpt-oss, Gemma QAT, qwen3/DeepSeek-R1) are
stripped from every reply so a bubble never shows raw scratchpad; the self-hosted
token budget is raised 512→1024 so a reasoning model still reaches its answer.

**Per-AI controls.**
- Independent **on/off** `enabled` toggle per AI; per-AI Keychain key (`apikey.<id>`)
  so two AIs of the *same* provider can hold different keys (A31).
- A **context profile** on each `ConfiguredAI` (all fields optional, so old configs
  still decode — A30): custom **`instructions`** (a persona, *augmenting* not replacing
  the draft/PASS conventions); a **gather `contextPolicy`** (`active` | `strict` =
  marked-only-even-when-active | `off`); a **`contextDepth`**; and an **`outputMode`**
  (`participate` | `draft-only` = never auto-posts | `summarize`).
- A **per-conversation override** (`off` | `marked` | `full`) wins over the per-AI
  policy; `off` suppresses ALL AI activity in that conversation (loop guards + empty
  context).

**Solo AI chat [A20, A28].** The **brain icon** (and a member-less **New Group**) opens
a private chat with just **you + your tethered AIs**. Your AIs reply there **without a
window**, because there is no other human for the autonomous-send gate to protect
(SPEC §13.3 is unchanged for any conversation that has other humans — verified by the
AgentIntegrity suite). `aiActiveSince` is set at creation so the AIs ingest from the
start. Adding a real human reverts it to a normal window/invite-gated group.

**Default context rules [A21].** Unless an AI is *actively engaged* (a live `ai_window`
/ thread `ai_invite`, or the solo chat), the context handed to a provider contains
**only** messages the human explicitly marked "Add to AI Context" (mine always; a
peer's only under an active bilateral grant, N24). It never auto-ingests the rest of
the conversation — a tie broken toward privacy at the cost of a less-informed default
draft. Marking travels inside the ciphertext (`ai_context`, N23) and is resolvable
cross-device via the stable `message_id` (A29).

**Transparency UI.** An in-chat **"AI here" context chip** surfaces which AI is present
and what it can see; **Settings ▸ AI ▸ What your AI sees / View tethered LLM context**
shows the exact (read-only) context, and **Test primary AI now** runs a live round-trip
showing the real reply or the exact error. Each AI's reply is labeled with its own
local codename via a LOCAL-ONLY `StoredMessage.agentName` (never on the wire).

## 21. The egress firewall  [firewall]

Everything sent to an **off-device** AI passes an egress firewall (`EgressFirewall`,
applied in `PersonaRuntime`; default ON, toggle in Settings ▸ AI):
- **Codename redaction** — contact names/aliases are replaced with their local
  codenames before the text leaves the device, so a provider never receives a raw
  human identity.
- **64 KB bound** — the outbound context is hard-capped, bounding how much conversation
  any single call can exfiltrate.

The firewall covers every `isRemote` backend (Claude/OpenAI/Gemini/OpenRouter/Groq/
custom) **and** the `hub` path (§22), and the off-device-AI consent alert fires before
any of them is used. (UI fix in A30: the toggle re-arms only on OFF via a custom
binding, so confirming the warning no longer wedges it permanently on.)

## 22. Device-hosted relay hub (pocket relay) + host-AI sharing  [A31]

For crowded places with no trusted network, a device can act as a **pocket relay**
(`NearbyRelayHub` in PQRCNostr) over Multipeer — no router, no public relay, no third
party. One device types **`host`** in Settings ▸ Servers (it runs the existing
`LocalRelaySimulator` engine and bridges it over a `NearbyLink` via `NearbyRelayHost`,
a distinct `_pqrc-relay` Bonjour service); companions type **`nearby`**
(`MultipeerRelayClient`, a `RelayTransport` over the radio).

- **Delivery path is content-free.** The kind-1059 anchor-relay rule still holds over
  the hub (a wrap is served only to the AUTHed, p-tagged recipient), so the host — a
  trusted peer's device — sees only sealed ciphertext + p-tags, exactly what any relay
  sees. Strictly better than café Wi-Fi or a public relay.
- **Host-AI sharing is the one content exception (Tier 2).** The host can **share its
  on-device AI** via `ai_request`/`ai_response` frames (the "Tier 2 LLM over Multipeer"
  goal, realized iPhone-to-iPhone). A companion that opts in sends its own
  (firewall-redacted) message text to the host's model — content, by the companion's
  **explicit consent** (the off-device-AI consent alert fires for the `hub` backend
  too), AUTH-gated so only an authenticated companion can request it. The delivery path
  stays content-free; only this opt-in path carries words.

The whole protocol runs against `LocalLinkSimulator` (headless tests, `NearbyRelayHubTests`);
only the MC radio adapter needs hardware. **(Honest-consent correction: an earlier pass
let the hub AI see content without the same consent gate as a cloud provider; corrected
so the `hub` backend now fires the consent alert — DEVIATIONS A31.)**

## 23. Agent-to-agent thread skills  [A32]  (see docs/eldrchat-agent-skills.md)

A thread-turn AI (§8) receives a fixed **base injection** of PQRC guardrails (channel /
scope / scoped-context boundary / bounded autonomy / transparency / the shared `⟡⟡`
envelope) plus any **skills** the humans pinned to that thread, from a 20-entry catalog
(plan-sync, tech-spec, code-debug, context-export, conflict-resolve, …). It is **pure
prompt composition** (`AgentSkills` in PQRCAgent): the runtime builds the thread-turn
system prompt and passes it as `AgentContext.systemPromptOverride` — **no new wire
format, event kind, or privacy exception** (the envelope is just message text recorded
by the existing thread output path; `context-export` is the AI half of the existing
`AIContextGrant`). UI: a **Skills** picker in the thread + a **context-domain** field in
Settings ▸ AI (each side advertises what its workstation brings — "iOS / Xcode",
"backend / staging" — so the two divide work without dumping private context). Per-thread
pinned-skill lists and the per-account context domain live in (per-silo) UserDefaults.

## 24. Agent-interop packages: MCP server & ACP agent  [A35, A36]

Two **standalone SPM packages** (no app/crypto/SwiftUI deps; `swift test` headless,
network-free) that adopt existing open protocols rather than inventing one.

> **MCP status (June 2026):** the ACP-router plan (`docs/ACPRouterplan.md` step 6)
> proposes *removing* MCP once ACP supersedes it. As of this writing **MCP is still
> shipped and green** — `PQRCMCP` (15/15 tests), the in-app `LocalMCPServer` /
> `RuntimeSecureChatBridge`, the "Local agent access (MCP)" Settings toggle, and the
> PQRCMCP CI lane are all present. ACP is being built out **alongside** MCP (§24a), not
> as a completed drop-in replacement. Removal is a future decision, not done.

- **`PQRCMCP` — local MCP server [A35].** EldrChat as a **read-only secure-chat source**
  for any spec-compliant MCP client (Goose, Xcode, Claude, …) over **stdio JSON-RPC**.
  `MCPServer` exposes `initialize/ping/tools/list/tools/call/resources` behind a
  `SecureChatBridge` the app implements over `PersonaRuntime`, returning
  **already-firewall-redacted** data (codenames, 64 KB-bounded) — the server never sees
  raw identities. **Phase 1 is read-only BY CONSTRUCTION:** the bridge has no
  `post`/`send`, so no MCP client can make EldrChat speak on the wire — the §13
  autonomous-send invariant holds with nothing new to enforce. Tools:
  `list_conversations`, `read_conversation`, `search_messages`, `get_context_preview`.
  A `DemoSecureChatBridge` + `pqrc-mcp` executable let any client connect to fixture data.
  **Phase 2 SHIPPED:** the app hosts the MCP server **in-process** over a **loopback
  Unix-domain socket** (never a TCP bind) while a silo is unlocked and the
  OFF-by-default **Settings ▸ Local agent access (MCP)** toggle is on; a tiny external
  `pqrc-mcp-bridge` shim is what the editor spawns and pipes stdio to that socket
  (`RuntimeSecureChatBridge` reads the real `PersonaRuntime`, redacted). It is
  **token-gated** (32-byte Keychain pairing token, required as the first line,
  constant-time compared), has **no persisted "expose me" flag**, and **stops on lock**.
  (Phase 3) window-gated action tools.
- **`PQRCACP` — ACP agent [A36].** The dual: EldrChat's **on-device LLM acts as a coding
  agent** an ACP client (Xcode 27) spawns over stdio to write code, build, and run
  simulator tests. Standard **Agent Client Protocol** (JSON-RPC 2.0 over stdio),
  EldrChat as the agent. Decisions: no `authenticate` (a locally-spawned subprocess is
  already trusted); in-memory sessions; mutating tools (`write_file`, `run_shell`)
  request permission first, **defaulting to ALLOW** if the client doesn't answer (the
  client deliberately spawned us; this trades fail-closed for usability *within the
  local-dev blast radius only* — no secure-chat content or Nostr wire is involved, so
  §13 is out of scope here). `run_shell` honors `DEVELOPER_DIR`/`ELDR_WORKDIR`;
  `String.strippingReasoningTrace()` is **vendored** (not imported) to keep the CLI
  dependency-free; the brain is behind an `LLMClient` protocol (OpenAI-compatible,
  configured via `ELDR_LLM_URL`/`ELDR_LLM_TOKEN`/`ELDR_LLM_MODEL`; `ELDR_ACP_FAKE_LLM=1`
  for a model-free run). Library `PQRCACP` + executable `eldr-acp` + tests. **Shipped:**
  the agent now also compiles into the iOS app as the phone-side ACP **client** (§24a);
  the standalone `eldr-acp`-in-Xcode case remains the dual.

## 24a. EldrChat as a secure, universal ACP router  [AC33, AC34, AC35; plan in `docs/ACPRouterplan.md`]

The product's biggest June-2026 addition. **EldrChat is a secure ACP _router_:** the phone
is an ACP **client**; the actual coding work is delegated to swappable ACP harnesses
(Xcode ACP, OpenClaw, Claude Code, Codex, Gemini CLI, …) running on an **Eldr node**
(a Mac, or the standalone `eldr-node` daemon), reached over the **same** E2EE mesh as
chat. EldrChat owns identity, E2EE, transport, history, consent, and the router; the
harness owns the model and the tools.

1. **Phone ACP client** — `ACPClient` actor over an `ACPTransport` seam (`Packages/PQRCACP`):
   `initialize` / `session/new` / `session/prompt`, parses `session/update` into a UI
   stream, answers `session/request_permission`. The phone advertises **no** fs/terminal
   capabilities (it is remote control; the harness runs on the node).
2. **Selectable ACP backend** — `ACPAgentProvider` (`Packages/PQRCAgent`) answers a chat
   as an ordinary `AgentProvider`; tool activity folds into the reply as plain text.
   Selected via the `acp` entry in `BackendRegistry`.
3. **Two sealed transports** (`Packages/PQRCNostr`): **`NearbyACPTransport`** — per-line
   `pqrc-seal-v1` (secp256k1 ECDH + ChaChaPoly) + an identity-bound challenge-response
   hello over Multipeer; frames from unproven peers dropped. **`RelayACPTransport`** —
   ACP lines carried as ordinary ratcheted gift-wrap ciphertext over the relay; envelope
   `ACP1|<lineId>|<seq>|<total>|<b64url>`, reassembled and re-ordered by a monotonic
   per-send index; an `isACPFrame` magic prefix discriminates ACP from chat.
4. **Node host** — `ACPNodeHost` (sealed Nearby) and `ACPRelayHost` (relay) run
   `runACPAgent` on the Mac (`Apps/EldrACPConfigurator`, the "Eldr node + setup hub",
   Mac Catalyst); the headless **`eldr-node`** daemon (`Packages/EldrNode`,
   `EldrNodeCore.serve`, `--owner` required, fail-closed) is the standalone equivalent.
5. **Task routing** — `CapabilityRoutingPolicy` (`AISelectionPolicy.swift`) routes by a
   per-AI **declared** `routingCapabilities` vs a host-supplied scope→requirement
   classifier; it **never reads message content** (privacy) and is **opt-in**.
6. **Security gates (MUST):** **C-3** — relay/Nearby intake admits a frame to the agent
   only when `isACPFrame(body) && sender == ownerIdentityHex` (the verified,
   both-direction-bound contact identity). **C-1** — mutating tools (`write_file` /
   `run_shell`) are permission-gated, **deny-on-timeout / deny-on-error**; the node never
   sets `allowUngatedTools`. **C-2** — file tools jailed to the session working dir
   (symlinks resolved before the prefix check). Remote dev-control consent is **OFF by
   default**, per-node, per-silo. *(Known gaps as of this writing — see `statusreport.md`:
   the in-app `acp` provider auto-grants tool permission; the cancel-vs-permission
   ordering has an intermittent fail-open; the G4 credential scrub is not on the
   PQRCACP→LLM path; the standalone daemon does not yet bootstrap the owner contact.)*

---

## 18. Decisions registry → copy into docs/DEVIATIONS.md

> Note: `docs/DEVIATIONS.md` is the live changelog (appended by the feature work) and is
> now the authoritative registry, including all post-v1 entries (A19–A43, AC1–AC35,
> N17–N26). The table below is the original seed; see DEVIATIONS for everything since.
> **ID-namespace caution:** the `A`-series and `AC`-series are distinct — e.g. **A33**
> (per-silo namespacing) ≠ **AC33** (relay-carried ACP). Cite the exact prefix.

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
