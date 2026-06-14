# DEVIATIONS.md — every judgment call in the v1 implementation

Tags: `[upstream-NIP]` — wire-format/protocol decision that belongs in the NIP
and affects interop; `[app-only]` — client behavior, no wire impact;
`[tech-debt]` — accepted shortcut with a follow-up owed.

## Seeded from APP-SPEC §18

| ID | Decision | Tag |
|---|---|---|
| D1 | Groups v1 = pairwise fan-out of PQRC sessions; `conversation_type:"group"`, `group_create` rumor with monotonic `revision`; MLS in v2 per SPEC §12 | upstream-NIP |
| D2 | Handshake suite = explicit PQXDH hybrid (`"suite":"hybrid-v1"`); X-Wing disabled — the two paths derive different SK, interop needs explicit negotiation | upstream-NIP |
| D3 | Remote (Anthropic API) agent inference off by default behind an explicit consent alert; on-device FoundationModels preferred, Mock for tests/demo | app-only |
| D4 | Handshake rumor carries `spk_used`/`otp_used`/`otp_pq_used` (SHA-256 of the public key) + `lrp_used` flag so the responder knows which prekeys were consumed | upstream-NIP |
| D5 | No read/delivery receipts; outgoing status is local-only ("Queued"/"Sent to relay") | app-only |
| D6 | No push notifications; foreground sync only | app-only |
| D7 | Thread wire extension: `thread` ref, `thread_create`, `ai_invite` (thread-scoped ai_window, signature bound to the thread id) | upstream-NIP |
| D8 | Block drops post-unseal with no trace and no notification; voluntary report/export flow (Guideline 1.2) | app-only |
| D9 | EncryptedStore: SE-wrapped 256-bit master key, per-record HKDF keys, AES-GCM blobs in SwiftData, `completeUntilFirstUserAuthentication` file protection | app-only |
| D10 | Handshake rumor piggybacks message #0 | upstream-NIP |
| D11 | No published kind-0 profiles; local-only nicknames (encrypted at rest) | app-only |
| D12 | Message-requests inbox gates unknown-sender handshakes | app-only |
| D13 | Safety-code verification screen: 60 digits in 12 groups from SHA-256 over both identity pubkeys (sorted), QR compare, local "verified" flag | app-only |
| D14 | Thread agent loop guard: 6 consecutive agent messages → pause until a human message | app-only |
| S1 | ~~BLE/Multipeer local link: seam only~~ → **Implemented** (2026-06-12): `MultipeerLinkTransport` over MultipeerConnectivity, seal-frame wire format, automatic relay fallback. See N17–N20, A9. | upstream-NIP |
| S2 | ~~Localhost WebSocket relay frontend: not shipped~~ → **Implemented** (2026-06-12): `pqrc-relay` executable (NWListener WS over `LocalRelaySimulator`) + `NostrWebSocketTransport` client. See A10, T9–T10. | app-only |

## New calls made during implementation

### Protocol / wire `[upstream-NIP]`

- **N1 — The NIP document itself.** `docs/NIP-XX-pqrc.md` was absent from the
  handoff (the runbook expected it from a separate source). It was authored
  here as the normative wire format, derived from SPEC.md plus CLAUDE.md's
  field-name contract. All entries below are reflected in it.
- **N2 — Two long-term keys + bidirectional binding.** SPEC §3.3 shows kind
  10420 signed by the Ed25519 identity key, but Nostr events require BIP-340.
  Resolution: a secp256k1 Nostr key signs the outer event; the Ed25519 identity
  key cross-signs `"pqrc-binding-v1"‖nostr‖identity‖agent` in a `binding_sig`
  tag. Both directions must verify before any key is trusted.
- **N3 — Dedicated identity-DH key (`ik_dh`).** Ed25519→X25519 conversion is
  not exposed by CryptoKit and writing it would be a custom primitive (SPEC §2
  violation). The bundle carries a separate X25519 identity-DH key signed by
  the identity key; `dh1 = X25519(ik_dh_A, spk_B)`.
- **N4 — One-time PQ prekeys (`otp_pq`) + KEM target selection.** CLAUDE.md's
  field list names `otp_pq`; the handshake encapsulates to a one-time PQ prekey
  when available, else the medium-lived `pqpk`. **Rekey-target invariant:** the
  initiator's first rekey targets the KEM key the handshake actually consumed —
  fixed after the chaos suite caught the mismatch stalling sessions at message 50.
- **N5 — `lrp` optional; dh3 omissible.** A bundle without one-time prekeys
  and without a last-resort key yields a 2-DH handshake (TEST-PLAN's
  "without OTP" case). With `lrp` present, exhaustion falls back to it,
  flagged `lrp_used` (linkability caveat documented in THREAT_MODEL §2.8;
  never a confidentiality downgrade).
- **N6 — Deferred root folds for the PQ rekey.** SPEC §6.2's fold-into-root,
  applied eagerly, desynchronizes the root chain whenever a rekey crosses
  concurrent bidirectional traffic (found by a failing end-to-end test). v1
  semantics: the rekey secret refreshes the ACTIVE chain immediately (this is
  what quantum-heals subsequent messages) and folds into the root at the next
  DH boundary at a position both parties agree on (NIP-XX §6). The pq_rekey
  vector was regenerated for these semantics during development, pre-freeze.
- **N7 — Rekey `tgt` + KEM key history.** Rekeys cross in flight under load;
  with a single previous-generation fallback the chaos matrix stalled. The
  rekey header names its target key by hash and receivers keep a bounded (8)
  history of their recent KEM private keys.
- **N8 — Rekey counter counts both directions.** "Every 50 messages" =
  messages sent or received since the party's last rekey; the send reaching 50
  carries the rekey. Receivers reset on applying an inbound rekey.
- **N9 — `agent_sig`.** Agent keys (Ed25519) cannot sign Nostr seals, so agent
  authorship is proven inside the encryption: signature over
  `"pqrc-agent-msg-v1"‖ciphertext`, required iff `participant_type=="agent"`,
  forbidden under a human label. `participant_type` is also bound into the
  AEAD AD (CLAUDE.md invariant 5 names participant_type; SPEC §8.3's prose
  says sender_role — participant_type was chosen as the stricter, displayed
  value).
- **N10 — `pqrc-seal-v1` instead of NIP-44 v2.** NIP-44 needs raw ChaCha20;
  CryptoKit only exposes ChaCha20-Poly1305. Same shape (secp256k1 ECDH x-only
  → HKDF → AEAD), strictly stronger integrity, NOT interoperable with NIP-44
  clients yet. ECDH uses the x-coordinate only (even-Y lifting can negate the
  point between directions).
- **N11 — Prekey bundle as JSON `content`,** not tag arrays: per-key
  signatures and nested arrays fit JSON; tags carry `pqrc_version` only.
- **N12 — Rumor kind 1420** (APP-SPEC §2's send pipeline names it); rumor
  `pubkey` must equal the seal `pubkey`.
- **N13 — Message-key → key+nonce derivation.** AES-GCM nonces for ratchet
  messages are HKDF-derived from the (single-use) message key, never
  transmitted — the Signal pattern. The injected `NonceSource` governs every
  other AEAD (seal/wrap, blobs, at-rest records), satisfying TEST-PLAN §1
  without inventing nonce transport.
- **N14 — Padding length prefix outside the bucket.** `u32be(len)` precedes
  the plaintext and the zero fill extends to bucket+4 total, so exactly-64 KB
  plaintexts stay inlineable and ciphertexts collapse to bucket+20 bytes.
- **N15 — One fuzzed timestamp per message,** drawn before encryption, used in
  the AD and as `created_at` on both seal and wrap (test-enforced).
- **N16 — Out-of-order across a pending rekey** fails AEAD cleanly and is held
  in a bounded (256) retry queue, re-presented after each successful decrypt;
  the queue deliberately has no per-envelope attempt cap (a cap quarantined
  healthy traffic under heavy chaos). Overflow quarantines oldest-first.
- **N17 — Local-link frame = the kind-13 seal, not a bare rumor.** SPEC §10
  says only the gift wrap is unnecessary on a point-to-point link. The seal is
  kept because MultipeerConnectivity's encryption authenticates nobody
  (anonymous DTLS, MITM-able): the seal supplies sender authenticity and keeps
  rumor metadata (`participant_type`, ratchet header) confidential against a
  link MITM, reusing the already-vetted `GiftWrap`/`SealCipher` path. The
  seal's `created_at` doubles as the fuzzed AD timestamp, so the local wire
  needs no extra fields. Local dedupe key: `local:<seal-id>`.
- **N18 — Local-link hello: challenge-response signed by the identity key.**
  Routing (identity → radio peer) is established by signing the peer's fresh
  32-byte challenge under domain `"pqrc-local-hello-v1"`. One proof attempt
  per connection (the challenge is consumed). A forged claim cannot attract a
  victim's traffic — sends to unproven identities fall back to the relay
  path. Confidentiality never depends on the hello (the seal is encrypted to
  the verified contact's key from the 10420 binding, not to hello claims).
- **N19 — Multipeer discovery is anonymous.** Random 16-hex `MCPeerID`, nil
  `discoveryInfo`, service type `pqrc-local`. A local observer learns
  co-presence of *a* PQRC user, never which one (THREAT_MODEL §2.9). Invite
  tie-break: lexicographically smaller display name invites; invitations are
  auto-accepted (safe per N18 — unproven peers get no traffic).
- **N20 — `LocalLinkTransport` seam re-typed** from
  `send(RumorContent, to:)` to `send(seal: NostrEvent, to peerIdentity:)`:
  the rumor alone cannot carry the AD timestamp or sender authenticity (N17).
  The seam had no implementations, so this is not a breaking change.
- **N21 — Optional `alias` field in `MessageBody`** (2026-06-12): a
  sender-chosen display alias travels INSIDE the ratchet ciphertext, so only
  already-established contacts ever learn it — no public profile exists (D11
  preserved). Older clients ignore the unknown key (SPEC §12). Receiver rule:
  the user's local rename always wins over the peer's self-chosen alias.
  Queued for the NIP.
- **N22 — Two receive-path gates hardened at the messenger** (2026-06-12,
  from the compliance review): (a) M-1 — an `ai_window` whose `enabled_by` ≠
  the sender's binding-verified identity key, or whose signature fails, is
  stripped before `ReceivedMessage` is emitted and flagged as a protocol
  violation (SPEC §13.3 now enforced at, not above, the protocol layer; the
  AgentEngine still re-checks). (b) L-4 — rumors with `pqrc_version ≠ "1"`
  quarantine immediately with a legible reason instead of cycling the retry
  queue to overflow.
- **N23 — `ai_context` marker in `MessageBody`** (2026-06-13): a human-applied
  "this message is AI-shareable context" flag (wire `ai_context`), set via
  "Add to AI Context". Distinct from `is_context` (the agent-authored render
  hint). Travels INSIDE the ratchet ciphertext only — never on the public
  event, so which messages a user flagged is not observable. Older clients
  ignore the key (SPEC §12). Queued for the NIP §7 body-field list.
- **N24 — `ai_context_grant` signed grant** (2026-06-13): a third member of the
  `ai_window`/`ai_invite` family, authorizing the *consume* axis only (the
  other party's agent may ingest the granter's `ai_context`-marked messages,
  and reciprocally). Human-identity-signed, bounded duration
  {15m,30m,1h,2h} ≤ 2h, scope = `conversation`|`thread` (+id). Uses a DISTINCT
  domain string `pqrc-ai-context-grant-v1` with the scope bound in, so a grant
  signature can never be replayed as a window/invite or across scopes.
  Invariant 9 preserved: consume-authorization carries its own human signature,
  is verified in `AgentEngine.receiveContextGrant`, and forged grants are
  stripped + flagged at the messenger (the N22/M-1 doctrine). It NEVER widens
  the send axis. Default consumption policy is **bidirectional** (both humans
  must have a live grant in scope) — a tie broken toward privacy. Queued for
  the NIP §2 (signature row) and §7.
- **N25 — `ai_context_mark` retro-flag control** (2026-06-13): a content-free
  `{message_id, value}` control inside an encrypted `MessageBody` that lets a
  sender (re)flag their OWN prior message as shareable context. Renders no
  bubble. Receiver MUST reject a mark for any message it did not receive from
  that same sender (no flagging someone else's words). Reveals only "sender
  flagged one prior message," and only to established contacts — the
  privacy-maximizing alternative to re-sending the message body.

- **N26 — `chunk` reassembly field in `MessageBody`** (2026-06-13): an optional
  `{id, index, total}` carried INSIDE the ciphertext so a message larger than
  the inline limit can be split across several ratcheted envelopes and rejoined
  on receipt. This is the SPEC §11 chunking alternative to a Blossom pointer —
  chosen for text because it needs no shared blob server and therefore works on
  a bare relay (the in-process `LocalBlossomSimulator` cannot serve a second
  device, so the pointer path silently failed cross-device). Relays see only
  bucket-padded per-envelope sizes; the chunk count and total length never
  appear in the clear. Each part is a one-time message key like any other.
  Split budget is `maxChunkTextBytes = 24 KB` of raw UTF-8, well under the
  64 KB inline limit so the JSON-escaped body always fits the top padding
  bucket under realistic (~2×) escape expansion; pathological all-control-char
  input that would expand ~6× is treated as an error at send, never silent
  loss. Binary attachments (images/video) will still use the Blossom pointer
  path once a networked blob server + HTTP `BlobStore` land. `[upstream-NIP]`

### App behavior `[app-only]`

- **A12 — Block-level markdown + sanitized HTML rendering** (2026-06-13):
  `MessageContent` renders headings, lists, fenced code, blockquotes, tables,
  and rules natively (not just inline bold/italic), and normalizes a safe HTML
  subset into the same markdown pipeline. Rendering is 100% native SwiftUI —
  no web view is ever instantiated and no remote resource is loaded, so a
  message cannot leak the reader's IP or run script (cardinal rule, SPEC §0).
  `script`/`style`/comments are dropped with their contents and only
  `http(s)` link schemes survive; everything else degrades to plain text.

- **A1 — No payload logging at all.** Stronger than OSLog `privacy: .private`:
  in-process OSLogStore reads reveal private interpolations, so the logging
  API simply cannot accept message text (canary test enforces end-to-end).
- **A2 — Plaintext timestamps never stored.** SwiftData rows carry only a
  local monotonic sequence for ordering; real times live inside the encrypted
  payload blobs.
- **A3 — Window replies route to the conversation the window was started in**
  (one active window scope per user in v1).
- **A4 — Bounded AI durations** {15, 30, 60, 120 min}; incoming announcements
  beyond 2 h are rejected as unbounded.
- **A5 — Local Universe** ships five personas including Eve (unknown sender)
  to exercise the message-request gate; demo agents are scripted
  MockAgentProviders so the demo is deterministic.
- **A6 — Received large content renders as a bounded preview** (first 600
  chars + size note): inlining a 218 KB text produced a ~176,000-point bubble
  that broke the message list. The full plaintext remains available via the
  pointer; a dedicated attachment viewer is future work.
- **A7 — Accessibility audit scope.** `performAccessibilityAudit` runs on all
  primary screens with `.dynamicType` and `.textClipped` excluded (the auditor
  false-positives on combined `privacySensitive` bubbles whose system-font
  text scales by construction) and borderline "nearly passed" contrast
  grades ignored (it flags even system section-header styling). Two further
  narrow contrast exclusions (2026-06-12), both occlusion artifacts rather
  than color problems — the auditor hard-fails any text whose background it
  cannot sample, regardless of the actual colors: (a) elements partially
  outside the window (scrolled past the fold — missing pixels sample black),
  and (b) message rows partially under an overlaying bar/safe-area inset.
  Fully visible elements stay enforced, and every excused issue is printed to
  the test log. Hard failures fail CI. Real findings it produced were fixed:
  darker accent for white-on-accent bubbles AND badges, opaque thread-chip /
  agent-bubble / loop-guard fills (translucent fills defeat its background
  sampling), opaque navigation bar and thread header (glass shadow spill),
  hard scroll-edge style on message lists, darkened destructive button tint,
  opaque-capsule system rows.
- **A8 — Conversations open scrolled to the newest message**
  (`defaultScrollAnchor(.bottom)`), found by the round-trip UI test.
- **A9 — Local link is local-first.** When a verified peer is co-present, the
  seal goes over the radio and NOTHING is published to any relay (the
  privacy-maximizing order per SPEC §0 — a local message is invisible to all
  relay observers). Any local-link failure falls back to gift-wrap + relay
  silently and automatically (SPEC §10). ~~App exposure is Debug-only~~ →
  **Graduated** (2026-06-12): user-toggleable (Settings → Nearby, default ON
  in Debug, OFF in Release). The shared Info.plist now carries the
  local-network strings in all configurations, but the radios — and therefore
  the iOS Local Network permission prompt — only start when the toggle is on.
- **A10 — Single-persona relay selection.** `bootSingle` resolves its relays
  from `PQRC_RELAY_URL` (env) → the `relayURLs` UserDefaults list (Settings →
  Servers: add/remove any `ws(s)://` URL) → the deployed anchor relay
  default; the literal value `local` is the in-process simulator. UI tests
  always run the Local Universe and never touch the network.
- **A11 — Persistence wiring** (2026-06-12, fixes "everything vanished on
  relaunch"): contacts persist as one encrypted `ContactRecord` blob per
  identity (the stored binding is re-run through `BindingVerifier.verify` on
  every restore — invariant 7 survives persistence; an unverifiable record's
  keys are never trusted); ratchet snapshots persist after every
  send/receive; prekey state persists in the Keychain (T2 resolved); group
  rosters, thread metadata and the processed-envelope dedupe set persist in
  the encrypted store; the conversation list + history reload at boot.
- **A12 — Message-request acceptance + open inbox** (2026-06-12): unknown-
  sender envelopes are held (bounded: 32 senders × 16 envelopes, oldest
  evicted) so accepting a request can fetch + verify the sender's 10420 and
  replay the held handshake — the conversation materializes ready to type.
  Declining drops the held envelopes without blocking. Separately, Settings →
  Reachability can open the inbox to anyone for a bounded window
  (15 min / 1 h / 8 h, auto-expiring, survives relaunch): requests auto-accept
  during the window. Privacy trade documented in THREAT_MODEL §2.10.
- **A13 — `pqrc:` URL scheme** (2026-06-12): the Settings QR encodes
  `pqrc:add?npub=…` so the system Camera deep-links into New Conversation
  with the address prefilled (previously the QR was a bare npub and scanning
  opened a browser/search). The scheme handler accepts only `npub1…` values.
- **A14 — Remote AI provider wired** (2026-06-12, resolves review M1): the
  Settings provider picker is honored at boot and on change; the Anthropic
  key is entered in Settings and stored ONLY in the device Keychain
  (`anthropic-api-key`, never UserDefaults, wiped with the identity); the
  consent alert actually gates activation. Without a key, "remote" falls back
  to the deterministic mock rather than failing.
- **A15 — System rows & list affordances** (2026-06-12, closes review
  M3/L2 items): window-start / group-created / thread-started messages render
  as neutral centered system rows on both ends; "Mark as verified" persists
  to the contact record and drives the list shield badge; conversation rows
  show relative timestamps + unread badges; swipe to pin/delete; the SwiftData
  store files additionally get `FileProtectionType.completeUntilFirstUserAuthentication`
  (review M6; downgraded from `.complete`, which made the DB unreadable while
  the device was locked and caused open/write failures on real hardware — the
  envelope encryption under the SE-wrapped key is the actual at-rest guarantee).
- **A16 — Export-compliance declaration** (2026-06-13): the app honestly
  declares `ITSAppUsesNonExemptEncryption = YES` (E2EE is not an exempt case),
  set ONCE as a build setting on the app target (Debug + Release) — NOT also in
  the custom `Info.plist`, since a duplicate fails archive validation (commit
  `a723557`). It qualifies for the EAR §740.17(b)(1) mass-market exemption
  because every primitive is standard/published (SPEC §2). The compliance code
  key is deliberately omitted until Apple issues one. Submission answers and
  the annual BIS self-classification filing are in `docs/EXPORT-COMPLIANCE.md`.
- **A17 — Sanitized native rich rendering** (2026-06-13): message bubbles render
  markdown (inline styling) and a SAFE subset of HTML via a hand-written
  `HTMLRenderer` → `AttributedString`. We deliberately do NOT use
  `NSAttributedString(.html)` or a `WKWebView`: those are WebKit-backed and load
  remote resources / run scripts, which would leak the reader's IP and create an
  exfiltration vector. The renderer strips `<script>`/`<style>`/comments with
  their contents, ignores unknown tags, blocks remote images, and only keeps
  `http(s)` links (no `javascript:` etc.). Fidelity (complex CSS/layout) is
  traded for privacy — the cardinal rule (SPEC §0).
- **A18 — Live relay status is observational only** (2026-06-13): the Settings
  green-check / red-x per relay reflects socket health surfaced from the
  transports; it never gates delivery (the messenger outbox remains the recovery
  path) and adds no metadata to the wire.

### Tech debt `[tech-debt]`

- **T1 — Secure Enclave fallback.** Where `SecureEnclave.isAvailable == false`
  (some simulators), the master key wraps under a Keychain-held software KEK
  (still device-only/unlocked-only). Hardware builds always use the SE path.
- **T2 — ~~Prekey private state is not persisted across launches~~ →
  Resolved** (2026-06-12): `PrekeyState` snapshot/restore on `PrekeyManager`,
  persisted in the Keychain, replenished to 16 at boot, consumed hashes kept
  forever (replay of a consumed prekey stays rejected across launches).
  Covered by the `Prekey persistence (T2)` suite.
- **T3 — Safety-code-change detection** is implemented UI-side (persistent red
  banner until re-verified) and runtime-signaled, but automatic re-fetch +
  binding-diff against relays is not wired (no live re-publishing exists with
  the in-process relay). The UI path is test-covered via a synthetic trigger.
- **T4 — Ephemeral receiving keys** (SPEC §9.3 strong mitigation): settings
  toggle present, disabled, marked experimental. Honest copy in-app.
- **T5 — Chunking fallback (SPEC §11.2)** not implemented; the Blossom pointer
  path covers >64 KB. Needed when a real relay's `max_content_length` bites.
- **T6 — `xcodebuild` requires `-skipPackagePluginValidation`** (or one-time
  IDE approval) because swift-secp256k1 ships a build plugin. Encoded in CI.
  Pin the simulator OS in destinations (`OS=26.5`) on machines that also have
  beta runtimes installed — an ambiguous name can silently resolve to a beta.
- **T7 — Read-side message pagination**: the UI loads conversations into
  memory; fine at demo scale, needs windowed fetches beyond ~10k messages
  (scroll perf test covers the 10k case).
- **T8 — Handshake `ik_dh` not cross-checked against a published binding
  field**: the binding covers identity+agent keys; `ik_dh` is authenticated by
  the bundle's identity signature. Adding it to the 10420 assertion would
  tighten the dance and is queued for the NIP.
- **T9 — Loopback/deployed-relay tests are opt-in.** The WebSocket transport
  and `pqrc-relay` server are proven by the TEST-PLAN §7 conformance suite,
  but those runs open (loopback) sockets, so they are gated behind
  `PQRC_LOOPBACK_TESTS=1` / `PQRC_RELAY_URL=…` to honor the "no unit test
  touches the network" rule in the default run. CI should add a gated job.
- **T10 — `pqrc-relay` is in-memory dev tooling.** No persistence, no rate
  limiting, localhost-oriented. The production anchor relay remains
  AUTH-gated strfry/khatru (SPEC §9.1, §15); the deployed-relay conformance
  test is the acceptance gate for that deployment (it FAILS on a vanilla
  public relay that serves kind-1059 to everyone — by design).
- **T11 — `MultipeerNearbyLink` is verified on hardware, not in unit tests.**
  Everything above the `NearbyLink` seam runs against `LocalLinkSimulator`;
  the MC adapter itself needs real radios (SETUP-GUIDE §6 device checklist).
  MC's 8-peer session cap is fine for 1:1 + small groups; revisit for v2 MLS
  groups.

## Cardinal-rule resolutions (ties broken toward privacy)

- Payload logging removed entirely (A1) rather than relying on redaction.
- Clear-text timestamps kept out of the store (A2) at the cost of
  cross-launch ordering precision.
- Group send cost O(n) accepted (D1) rather than weakening per-link FS/PCS.
- "Sent to relay" wording (D5) rather than receipt metadata.
- AI context sharing defaults to **bidirectional active grants** (N24): a peer's
  marked context is consumed only when BOTH humans have a live grant in scope,
  rather than a single author-side grant exposing one party's content
  unilaterally. The looser single-side mode is not shipped.
