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
  Split budget is `maxChunkTextBytes = 15000`, measured as **JSON-escaped**
  bytes (not raw UTF-8), so each chunk's encoded `MessageBody` lands in the
  **16384** padding bucket — never the 65536 bucket. This is load-bearing: each
  gift-wrap layer (rumor → seal → wrap) base64-expands the payload ~1.33×, so a
  65536-bucket message becomes a ~156 KB event, whereas a 16384-bucket message
  stays ~40 KB. Common relays (e.g. khatru) cap event content at **65535
  bytes** and reject anything larger ("content is too large"), which silently
  broke every >~8 KB paste until this sizing was corrected (the relay even
  advertised a 1 MB limit in NIP-11 while enforcing 65535). Measuring escaped
  size makes the bound hold for escape-heavy content (code, quotes). Guarded by
  `EnvelopeTests.giftwrap_for16384BucketMessage_staysUnderRelayContentLimit` and
  `ChunkingTests.everyChunkBody_fitsThe16384Bucket_evenEscapeHeavy`. Binary
  attachments (images/video) will use the Blossom pointer path once a networked
  blob server + HTTP `BlobStore` land. `[upstream-NIP]`

### App behavior `[app-only]`

- **A19 — Full-screen markdown/HTML reader + AI-draft-into-composer**
  (2026-06-13): rich messages (`MessageContent.isRich`) show an expand glyph and
  a "View full screen" long-press item that opens `FullScreenReaderView` —
  pinch-to-zoom (0.5–4×), two-axis scroll, a Rendered⇄Source toggle (raw,
  fully-selectable text so very large docs that the in-bubble cap truncates are
  still readable), and landscape (already enabled app-wide). Still 100% native,
  no web view. Separately, the composer gains a "Draft with AI" sparkles button
  + long-press item (beside Paste) that reuses the existing draft path
  (`draftReply` → `agentContext`, which already includes `ai_context`-marked
  messages) to inject an editable reply into the box — never auto-sent, and
  local-only (drafting needs no `ai_window`; only *sending* as AI does, SPEC §13).

- **A25 — Adaptive chunk sizing + concurrent chunk publish** (2026-06-14): for
  large/LLM-context text shares, three tunings on top of the §11 chunking path
  so it scales without any storage server (text-only by design; media stays out
  of scope). (1) **Adaptive sizing**: the chunk budget is derived from the relay
  set's smallest content limit — read from each relay's NIP-11
  `max_content_length` (`RelayTransport.maxContentLength()`), and *lowered* if a
  relay ever rejects with "content is too large: …, max is N" (relays that
  advertise more than they enforce are self-corrected after one rejection). So a
  permissive relay (≥~170 KB events) uses the full 64 KB bucket — 4× bigger
  chunks — while strict relays stay at the safe 16 KB bucket. (2) **Bigger
  ceiling**: `maxChunksPerMessage` 256 → 512, still under the ratchet
  `maxSkip = 1000` so reordered chunks can't overrun the skipped-key cache —
  enough for a frontier-LLM-sized (~1M-token) context in one logical message.
  (3) **Concurrent publish**: `PQRCMessenger.sendBatch` encrypts chunks in order
  (the ratchet is stateful) then publishes the wrapped events with bounded
  (8-wide) concurrency, so a big share isn't gated on N serial OK round-trips;
  out-of-order arrival is fine (each chunk is a distinct message number,
  reassembled by index). Guarded by `ChunkingTests.chunkTextBudget_…`.
  The in-process/offline relay (`local` in Settings) reports no wire limit, so
  when it's the only server, chunking uses the full 64 KB bucket — delivery is
  then Nearby (Bluetooth/Wi-Fi Direct), which has no size cap. A real relay
  mixed in still wins (the budget takes the minimum), preserving the
  local→relay fallback (§10): chunks stay small enough that a Nearby send that
  drops can fail over to the relay.

- **A24 — Reactive NIP-42 AUTH + WebSocket keepalive** (2026-06-13, relay
  message-delivery fix): the receive pump used to authenticate eagerly and SKIP
  subscribing if AUTH failed — assuming the relay sends an unprompted `["AUTH",
  challenge]` on connect. The deployed anchor relay (khatru, `auth_required:
  false`, gating only kind-1059 reads) sends the challenge ONLY in response to
  the gated REQ, so the eager auth timed out and the client never subscribed:
  writes worked and keys published, but nothing was ever received. Now the pump
  subscribes first and authenticates **reactively** — when the relay closes the
  sub with `auth-required`, it authenticates with the challenge just sent and
  re-subscribes (a best-effort upfront auth is still attempted for relays/the
  in-process simulator that gate silently or challenge on connect). The loop
  also re-establishes the read after a socket drop, and the transport sends a
  30 s WebSocket ping so an intermediary (Cloudflare proxies idle WebSockets out
  after ~100 s) can't silently kill delivery. Test: `ReactiveAuthTests`.

- **A20 — Adaptive relay reconnect cooldown** (2026-06-13): the websocket
  transport's post-failure cooldown was a flat 30 s, which locked out all
  send/receive for 30 s after even a momentary blip. Now exponential —
  `min(base·2^N, max)` (default base 1 s, cap 30 s) — reset to 0 the instant a
  relay frame proves the socket live. A single blip recovers in ~1 s; a genuine
  outage still backs off to the cap and stops hammering.

- **A21 — Key publish moved off the receive critical path** (2026-06-13,
  regression fix): the need-based prekey-low republish (A23) was awaited inline
  in `handleReceived`, so a slow relay publish stalled inbound message delivery
  (relay AND Nearby both funnel through it). It now runs as a detached task —
  message rendering never waits on a network publish.

- **A22 — Block-level markdown + sanitized HTML rendering** (2026-06-13):
  `MessageContent` renders headings, lists, fenced code, blockquotes, tables,
  and rules natively (not just inline bold/italic), and normalizes a safe HTML
  subset into the same markdown pipeline. Rendering is 100% native SwiftUI —
  no web view is ever instantiated and no remote resource is loaded, so a
  message cannot leak the reader's IP or run script (cardinal rule, SPEC §0).
  `script`/`style`/comments are dropped with their contents and only
  `http(s)` link schemes survive; everything else degrades to plain text.

- **A23 — Observable, need-based key publishing + honest reachability errors**
  (2026-06-13): the launch key publish (10420/10421/10050) records its outcome
  as a `KeyPublishStatus` shown in Settings ("My keys on relay"), and a
  successful publish doubles as the relay-liveness signal. Republishing is
  strictly need-based — launch, relay-list change, and one-time-prekey
  replenishment (invariant 11) — and NEVER on a timer or every foreground, so
  publishing can't become an online-presence beacon (cardinal rule, SPEC §0;
  THREAT_MODEL §2.1a). The peer-key fetch is time-bounded (drops the
  subscription after a few seconds, limiting how long a relay sees interest in
  a pubkey) and throws distinguished `relayUnreachable` vs `peerKeysNotPublished`
  errors — decided from the transport's connection state — so "New chat" tells
  the user the true reason a contact can't be reached.

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
- **A19 — Local friendly codenames, never broadcast** (2026-06-14): every person
  AND their AI gets a locally-generated `adjective-noun-verb-###` codename so the
  UI never shows a raw key. Generation is on-device Core AI when available, else a
  deterministic FNV-seeded local generator — it NEVER goes off device. The name is
  stored only in the encrypted local `ContactRecord` (`autoName` / `autoAIName`)
  and is NEVER written to the wire (SPEC §0; "DO NOT broadcast the names"). Display
  order: local rename > peer's self-chosen alias > friendly codename > key.
- **A20 — Multi-AI tethering + solo AI chat** (2026-06-14): a person can tether
  several AIs at once (on-device + token API). Each AI's reply is labeled with its
  own local codename via a LOCAL-ONLY `StoredMessage.agentName` (never on the
  wire). A "solo AI chat" is a group with only me; my AIs reply to me there by
  default *without* a window, because there is no other human for the autonomous-
  send gate to protect (SPEC §13.3 gate is unchanged for any conversation that has
  other humans — verified green by the full AgentIntegrity suite). Adding a real
  contact turns it into a normal group and the window/invite rules resume.
- **A21 — AI ingests only marked context by default** (2026-06-14): unless my AI
  is actively engaged in a conversation (my `ai_window` / thread `ai_invite` is
  live, or it's the solo AI chat), the context handed to the provider contains
  ONLY messages the human explicitly marked "Add to AI Context" (mine always; a
  peer's only under an active bilateral grant). It never auto-ingests the rest of
  the conversation. Ties to privacy (SPEC §0) at the cost of a less-informed
  default draft.
- **A22 — NIP-40 expiration on gift-wraps (7-day retention)** (2026-06-14): every
  kind-1059 wrap carries `["expiration", created_at + 7d]` so a NIP-40 relay
  auto-deletes it (minimized server footprint; privacy SPEC §0). The value is
  anchored to the FUZZED `created_at`, not real now, so it reveals no timing the
  public `created_at` doesn't already (`expiration − window == created_at`).
  Effective relay retention is 5–7 days (the fuzz is up to 2 days into the past).
  `PQRCConstants.expirationWindowSeconds`; the frozen `giftwrap.json` vector was
  regenerated for the new tag.
- **A23 — Deniable multi-account silos** (2026-06-14): one device holds N
  passphrase-isolated accounts. `passphrase → PBKDF2 (fixed app salt) → siloID +
  KEK` (`SiloKey.swift`); each silo's Keychain secrets are AES-GCM-sealed under
  the KEK and its store master key is wrapped under it, so a silo is unreadable —
  and its existence unprovable — without the passphrase. The app always launches
  to a bare passphrase screen and never auto-boots (auto-booting would reveal an
  account exists). A wrong passphrase derives a different, non-existent silo,
  indistinguishable from "no account". Isolation is CRYPTOGRAPHIC, not
  OS-enforced — iOS gives one app a single sandbox (no Android secure island).
- **A24 — Biometric convenience tier (Face ID first, ON by default)** (2026-06-15,
  revised twice): the primary account stores its {siloID, KEK} behind a
  `.userPresence` Keychain item (Face ID / Touch ID / device passcode) and that is
  the **default** unlock — the lock screen shows Face ID first and auto-prompts it
  at launch (`AccountGateView.task`); the passphrase is the labelled-secondary
  path ("Or use a passphrase"), always available and the only way into a hidden
  account. (Product owner chose Face-ID-first convenience over launch-time
  deniability; an earlier same-day pass had defaulted it OFF, now flipped back per
  "we want faceID first and passphrase if you enable".) Settings ▸ Account toggles
  it OFF → passphrase-only high-security. Auto-enable on account creation is
  silent best-effort: if the device has no passcode/biometric the account simply
  stays passphrase-only (the failure surfaces only when the user enables it
  manually in Settings). The launch auto-prompt is silent on cancel, so a hidden
  account's passphrase can still be typed. The passphrase always works regardless;
  lose it = data lost forever (honest no-recovery, SPEC §0). The deniability
  tradeoff is bounded: only the FIRST account is ever stored biometrically, so
  additional/hidden silos remain passphrase-only and deniable even though the
  primary's existence is now implied by the Face ID prompt.
- **A27 — OpenRouter as a tethered-AI backend** (2026-06-15): added `openrouter`
  alongside Claude/OpenAI/Gemini — one API key, many models (OpenAI-compatible
  `chat/completions` at `openrouter.ai/api/v1`, model slugs like
  `openai/gpt-4o-mini`). It is `isRemote`, so it inherits the full remote-AI
  treatment unchanged: explicit consent gate, Keychain-stored key
  (`openrouter-api-key`, per-silo service), egress firewall (name redaction +
  byte bound) on by default, and Demo-stub fallback when no key is set. Only
  the optional `HTTP-Referer`/`X-Title` ranking headers differ from the OpenAI
  provider; they carry no conversation content.
- **A28 — Solo group = AI on from creation** (2026-06-15): New Group no longer
  requires picking another member — a member-less group is a private "solo AI
  group" (you + your tethered AIs), the same staging ground as the brain-icon AI
  chat. `createGroup` sets `aiActiveSince` for a member-less group so the AIs
  ingest from creation; without this the context filter started at `Int64.max`
  and the AI replied while *seeing nothing you typed* ("AI context is weird").
  Adding a real human later reverts it to a normal window/invite-gated group.
- **A29 — Stable cross-device `message_id` (fixes marked-context sharing)**
  (2026-06-15) `[upstream-NIP]`: the decrypted `MessageBody` now carries an
  optional `message_id` (the sender's local id), and the recipient stores it
  verbatim instead of minting its own UUID. Before this, the same message had a
  DIFFERENT id on each device, so the `ai_context_mark` retro-flag (N25) — which
  references a message by id — could never resolve the peer's copy: curated
  "Add to AI Context" sharing was silently broken across devices (found by the
  new two-device E2E test). The id lives INSIDE the ciphertext (relays never see
  it), is a random UUID (encodes nothing), and is optional/back-compatible (older
  senders omit it → receiver falls back to a fresh id; frozen vectors unchanged
  since nil is omitted). Bonus: it makes own-message/relay-echo dedup id-stable.
  Live-window/thread AI context never depended on this (it reads by activation
  time, not marks) and already worked; this fixes the curated-marking path.
- **A30 — Per-AI context profiles + Groq/self-hosted backends + toggle fixes**
  (2026-06-15): each tethered AI now carries a profile — custom `instructions`
  (a persona, augmenting not replacing the draft/PASS conventions), a gather
  `contextPolicy` (active | strict=marked-only-even-when-active | off), a
  `contextDepth`, and an `outputMode` (participate | draft-only=never-auto-posts |
  summarize). A per-conversation override (off | marked | full) wins over the
  per-AI policy and, when "off", suppresses ALL AI activity there (loop guards +
  empty context). All profile fields are optional on `ConfiguredAI` so older
  configs still decode. New backends: **Groq** (OpenAI-compatible, fast) and
  **Custom/self-hosted** — ANY OpenAI-compatible server (Ollama / LM Studio /
  vLLM on the user's own machine, or another vendor). The custom backend's API
  key is OPTIONAL (local servers have none → no Authorization header, and it does
  NOT throw `notConfigured`); a base URL is required. To make a local server
  usable, `Info.plist` adds `NSAppTransportSecurity.NSAllowsLocalNetworking` —
  plaintext `http://` is permitted to local/private addresses ONLY; the public
  internet still requires HTTPS (every hosted endpoint already is). Two UI bug
  fixes: the egress-firewall toggle used `onChange` to re-arm on every change, so
  confirming the warning re-triggered the re-arm and it could never turn off (now
  a custom binding that only opens the confirm on OFF); the Face ID toggle read a
  computed Keychain property `@Observable` can't track, so it never re-rendered
  when flipped (now mirrored into `@State`, re-synced after each toggle so an
  enable that fails — no device passcode — snaps back and shows the reason).
- **A31 — Device-hosted relay over Multipeer + per-AI controls** (2026-06-15):
  a **pocket relay** for crowded places with no trusted network (`NearbyRelayHub`
  in PQRCNostr). One device types `host` in Settings ▸ Servers → it runs the
  existing `LocalRelaySimulator` engine and bridges it to companions over a
  `NearbyLink` (`NearbyRelayHost`); companions type `nearby` → a `RelayTransport`
  over the radio (`MultipeerRelayClient`). No router, no public relay, no third
  party. The kind-1059 anchor-relay rule (serve a wrap only to the AUTHed,
  p-tagged recipient) still holds over the hub, so on the **message-delivery
  path** the host (a trusted peer's device) sees only sealed ciphertext + p-tags,
  never content — strictly better than café Wi-Fi or a public relay. The host can
  also **share its on-device AI** via `ai_request`/`ai_response` frames (the
  "Tier 2 LLM over Multipeer" request — realized iPhone-to-iPhone, no Mac needed).
  This AI-sharing path is the **one exception** to "host never sees content": a
  companion that opts into the host's AI sends its own (firewall-redacted) message
  text to the host's model — content, by the companion's explicit consent (the
  off-device-AI consent alert now fires for the `hub` backend too), AUTH-gated so
  only an authenticated companion can request it. The delivery path stays
  content-free; only the opt-in AI path carries words. The whole protocol runs against
  `LocalLinkSimulator` (6 headless tests); only the MC radio adapter needs
  hardware (a new `pqrc-relay` Bonjour service, distinct from direct-Nearby's
  `pqrc-local`). **Per-AI controls:** each tethered AI has an independent on/off
  `enabled` toggle, and its API key now lives in a **per-AI** Keychain account
  (`apikey.<id>`, with the legacy shared account read as a fallback) so two AIs of
  the SAME provider can hold DIFFERENT keys. **Self-hosted robustness:** the custom
  provider's URL builder accepts a bare `host:port` (→ `/v1/chat/completions`), a
  `…/v1`, or a full path, so LM Studio / Ollama "just work".
- **A32 — Agent-to-agent skills for shared threads** (2026-06-15, per
  docs/eldrchat-agent-skills.md): a thread-turn AI now gets a fixed **base
  injection** of PQRC guardrails (channel / scope / scoped-context boundary /
  bounded autonomy / transparency / the shared `⟡⟡` envelope) plus any **skills**
  the humans pinned to that thread, from a 20-entry catalog (plan-sync, tech-spec,
  code-debug, context-export, conflict-resolve, …). It's pure prompt composition
  (`AgentSkills` in PQRCAgent): the runtime builds the thread-turn system prompt
  and passes it as `AgentContext.systemPromptOverride`, which the providers use in
  place of the built-in turn prompt — NO new wire format, event kind, or privacy
  exception (the envelope is just message text, recorded by the existing thread
  output path; `context-export` is the AI half of the existing `AIContextGrant`).
  Per-account "context domain" (the asymmetry knob) and per-thread pinned-skill
  lists live in UserDefaults (`nonisolated` AppSession statics). UI: a **Skills**
  picker in the thread + a context-domain field in Settings ▸ AI. Tested:
  PQRCAgent `AgentSkills` (catalog/base-injection/composition) + an app test that
  a pinned skill reaches the AI's thread-turn context.
- **A25 — Duress = decoy account** (2026-06-14): because every passphrase opens
  its own separate silo, a duress/decoy account needs no special code — create an
  account with a memorable "duress" passphrase, stock it with innocuous chats,
  and reveal that passphrase under coercion. A *destructive* duress (wipe on a
  trigger passphrase) is intentionally NOT shipped — accidental-wipe risk
  outweighs the benefit when a plausible decoy already exists.
- **A26 — Known limit: silo COUNT is not yet hidden** `[tech-debt]` (2026-06-14):
  v1 hides each silo's contents, keys, and (via the unprovable-passphrase
  property) whether a *given* passphrase maps to data. But a full forensic image
  can still infer the NUMBER of accounts from the count of `silo-*.store` files /
  Keychain item-groups. Robust count-hiding needs a single POOLED store of opaque
  per-silo records (the only approach that doesn't leak count); naive decoy files
  are distinguishable (a real store has a valid SQLite header, random padding
  doesn't), so they are deliberately NOT shipped — false deniability is worse
  than a documented limit. Tracked for Phase 2. **Same residual surface, after
  A33:** per-account settings now carry a `.<siloID>` suffix in the (unencrypted)
  UserDefaults plist, so the *set of distinct siloID suffixes* there is one more
  place a forensic image can count accounts — the same count leak as the store
  files, not a new content leak (the values are scoped per silo). In practice the
  count is *certain*, not probabilistic: `configuredAIs.<siloID>` is written on
  every boot and `displayName.<siloID>` at creation, so each account always leaves
  at least one suffixed key — this matches the existing per-silo store-file count
  leak exactly and adds nothing beyond it. The Phase-2 pooled-store design
  subsumes it (opaque records, no siloID in the clear).
- **A33 — Per-silo UserDefaults namespacing (deniable-account isolation)**
  `[app-only]` (2026-06-15): the deniable-silo work (A23–A26) sealed each
  account's *secrets* and *store* per-silo, but several app preferences were
  still written under flat, device-global UserDefaults keys — so a second silo's
  runtime read the first's, and a forensic image read all of them at rest. That
  broke the core promise: a hidden account must leave no trace a cover account
  (or file access) can correlate. The leaking keys were `relayURLs`, the
  `aiContextDomain` asymmetry knob, the per-conversation `aiContextMode.<convID>`
  override, per-thread `threadSkills.<threadID>`, and the `lastReadAt`
  contact-activity map (the worst — a plaintext list of who you talk to). Plus
  Settings wrote a flat `displayName` that boot never read (dead *and* leaky).
  Fix: every per-account default is namespaced `<base>.<siloID>` via
  `AppSession.siloDefaultsKey`; the runtime carries its `siloID`, `AppModel`
  carries its `siloID`, and the Settings/Thread/Conversation views pass it
  through. `bootSilo` runs a one-time `migrateFlatDefaults` that pulls any legacy
  flat `relayURLs`/`aiContextDomain`/`lastReadAt` into the booting silo's
  namespace and *deletes the flat originals*, and the alias editor now writes the
  per-silo `displayName.<siloID>` boot already reads (also fixes a real "alias
  doesn't persist" bug). Relay lists are treated as **per-account**, not
  device-global, as the privacy-maximizing choice (a hidden silo's custom relay
  must not surface in a cover silo's Settings). Tests/demo use the bare
  (empty-siloID) keys, so the existing suite is unchanged; the residual
  count-leak from the `.<siloID>` suffixes is folded into A26.
- **A34 — Reasoning-model output is cleaned for the chat** `[app-only]`
  (2026-06-15): self-hosted and OpenAI-compatible servers increasingly run
  *reasoning* models (qwen3, DeepSeek-R1) that emit a private `<think>…</think>`
  chain-of-thought before the answer. Two consequences EldrChat now handles:
  (1) the trace is **stripped** from every OpenAI-compatible provider's reply
  (`String.strippingReasoningTrace`, applied in Custom/OpenAI/OpenRouter/Groq),
  including an unclosed block left by a length-truncated response — so a chat
  bubble never shows raw scratchpad; and (2) the **self-hosted** (`custom`)
  provider's token budget is raised 512 → 1024, because a reasoning model can
  spend the whole budget thinking and never reach its answer (observed: a 35B
  qwen3 burned 681 reasoning tokens before answering). Hosted providers stay at
  512 (they're metered/paid; the user picks a model). Verified live against an
  LM Studio server + a `strippingReasoningTrace` unit test. NOTE: a reasoning
  model is still a poor fit for short-message chat — an instruct model is the
  better self-hosted choice; this just keeps the output sane either way. **Update
  (same day):** extended to also strip Harmony / channel-tagged reasoning
  (`<|channel>thought … <channel|> ANSWER`, and real Harmony
  `<|channel|>final<|message|>`) used by gpt-oss and some Gemma QAT builds — keep
  only the final-answer channel, drop the thought/analysis channel (an unfinished
  thought with no final transition → empty). Verified live against a Gemma-4-26B
  LM Studio server. Also applied the strip to Anthropic + Gemini for uniformity.
- **A35 — Local MCP server (EldrChat as an agent-readable secure-chat source)**
  `[app-only]` (2026-06-15, per the architecture review): a developer running
  EldrChat on their workstation can let a LOCAL agentic harness (Goose, Xcode,
  Claude, OpenClaw — any spec-compliant MCP client) read their secure chat. The
  decision was **adopt, don't invent**: standard **Model Context Protocol** over
  **stdio JSON-RPC**, EldrChat as the **server**. NO custom agent protocol, NO
  Nostr/wire change, NO new event kind, NO cloud exposure (ACP and remote/HTTP
  MCP were considered and declined/deferred for v1). New SPM package
  `Packages/PQRCMCP` (no app/crypto deps; `swift test` headless): `MCPServer`
  (initialize/ping/tools/list/tools/call/resources, JSON-RPC errors) behind a
  `SecureChatBridge` the app implements over `PersonaRuntime` returning
  **already-firewall-redacted** data (codenames, 64 KB-bounded) — the server
  never sees raw identities. **Phase 1 is read-only BY CONSTRUCTION:** the bridge
  has no `post`/`send`, so an MCP client cannot make EldrChat speak on the wire —
  the "no autonomous send outside a human-signed `ai_window`" invariant (SPEC §13)
  holds with nothing new to enforce. Tools: `list_conversations`,
  `read_conversation`, `search_messages`, `get_context_preview`. A
  `DemoSecureChatBridge` + `pqrc-mcp` executable let any MCP client connect today
  (verified: 9 protocol tests + a full stdio handshake + a live Goose session
  driven by the local LM Studio model). **Still to build (Phase 2):** the real
  `PersonaRuntime`-backed bridge + an OFF-by-default Settings toggle + a
  pairing-token consent gate; and (Phase 3, opt-in) window-gated action tools.
  ACP stays explicitly out of v1; if ever wanted it is a parallel `PQRCACP`
  client following the same read-only-then-window-gated discipline.

- **A36 — ACP AGENT (EldrChat's self-hosted LLM pilots Xcode)** `[app-only]`
  (2026-06-15): the dual of A35. Where the MCP server exposes secure chat *to* a
  harness (EldrChat as data source), this lets EldrChat's local model *act* as a
  coding agent that an ACP client (Xcode 27) spawns over stdio to write code,
  build, and run simulator tests. Decision was again **adopt, don't invent**:
  standard **Agent Client Protocol** (JSON-RPC 2.0 over stdio), EldrChat as the
  **agent**; Xcode is the client. New SPM package `Packages/PQRCACP` (library
  `PQRCACP` + executable `eldr-acp` + tests; Swift 6 strict concurrency; no
  app/crypto/SwiftUI deps; `swift test` headless, network-free via a mock LLM).
  Ambiguities resolved:
  • **No `authenticate`** — we advertise `authMethods: []` (a locally-spawned
    subprocess is already trusted; auth would add friction with no security gain).
  • **`loadSession: false`, no `session/load`** — sessions are in-memory per run.
  • **Permission model:** mutating tools (`write_file`, `run_shell`) call
    `session/request_permission` first; read tools don't. If the client doesn't
    answer (transport failure), we DEFAULT TO ALLOW — the client deliberately
    spawned us to act, and a hung prompt shouldn't wedge the turn. (Privacy note:
    this agent runs entirely on the developer's own machine against their own
    files/Xcode and a local model; no secure-chat content or Nostr wire is
    involved, so the §13 autonomous-send invariant is not in scope here — there is
    no relay path. The permission default trades a hard fail-closed for usability
    *within that local-dev blast radius only*.)
  • **`run_shell` honors `DEVELOPER_DIR`** from env (and `ELDR_WORKDIR` for cwd) so
    `xcodebuild`/`xcrun simctl` target Xcode 27 beta; commands run via
    `/bin/zsh -lc`. Prefers the client's `terminal/*` (so commands show in Xcode),
    falls back to Foundation `Process`. `write_file`/`read_file` prefer the
    client's `fs/*` (edits show in the editor), fall back to `FileManager`.
  • **`String.strippingReasoningTrace()` VENDORED**, not imported from PQRCAgent:
    depending on PQRCAgent drags in PQRCCore + PQRCNostr → swift-crypto +
    swift-secp256k1 (a heavy C build with a build-tool plugin, cf. T6) into an
    otherwise dependency-free CLI agent, for a ~40-line string helper. The two
    copies must be kept in sync (noted in the vendored file's header).
  • **BRAIN behind an `LLMClient` protocol** (OpenAI-compatible Chat Completions
    *with* tool/function calling); config via `ELDR_LLM_URL` (default
    `http://127.0.0.1:1337/v1`), `ELDR_LLM_TOKEN`, `ELDR_LLM_MODEL`
    (default `local-model`). Tests inject a mock; `ELDR_ACP_FAKE_LLM=1` selects a
    built-in echo LLM so the executable runs with no model server.
  The turn loop caps at 20 tool iterations and honors `session/cancel`. Verified:
  35 headless tests (handshake, streamed `agent_message_chunk` + `stopReason`, a
  `read_file` tool round-trip to `tool_call_update: completed`, cancel, the
  bidirectional outbound-request correlation) + a piped stdio smoke test.

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
