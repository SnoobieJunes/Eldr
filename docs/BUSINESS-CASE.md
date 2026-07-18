# Eldr — Business Case

Market research and monetization plan, current as of **2026-07-17**. House rule:
evidence over enthusiasm. Every external claim carries a bracketed source resolved in
[§ Sources](#sources); all URLs accessed 2026-07-17. Repo claims cite repo files.
Companion doc: `docs/ENTERPRISE-PITCH.md`; its *Shipped* vs *Rolling out* honesty rule
governs here too. Ground truth about the asset: 8 SPM packages (incl. SwiftA2A), ~82k lines of git-tracked Swift, ~886 test methods
(67,012 / 689 on `origin/main` at the 2026-07-10 audit —
`docs/lerants-agentic-writeup-notes.md`), built in ~5 weeks by one founder
pair-programming with Claude. Not security-audited. Alpha. No LICENSE file committed.
Not yet on TestFlight or the App Store.

**Revised 2026-07-18 (v2).** Two changes of substance: the Budget section now carries
two tracks — the survival floor is kept as the fallback, but the **plan of record is a
$1.25–1.5M pre-seed/seed** — and a new **Componentization** section maps the piecemeal
enterprise offering onto the *verified* package dependency graph (checked against
`Package.swift` files and cross-package imports, not the architecture diagram).

## TL;DR

- Eldr is the only messenger we found that combines PQ-E2EE + decentralized transport + user-owned, consent-boxed AI. Each piece has competitors; the combination has none.
- The wedge is the AI layer, not the crypto: signed time-boxed AI windows, protocol-enforced AI authorship labels, per-chat egress firewall, and a PQ-E2EE transport for A2A. No incumbent ships any of these.
- Signal, iMessage, and White Noise beat Eldr on audits, multi-device, and scale. Say so in public; sell the combination, never "more secure than Signal."
- Fastest product dollar: free EldrChat TestFlight + paid **Huginn Pro** early-supporter license sold direct (notarized DMG, no App Store gate). First dollar ~week 3–5.
- Biggest 90-day cash line: grants — OpenSats funds Nostr messengers today; HRF funded a Nostr E2EE messenger *and its audit*; OTF is rolling at $10k–900k. No consulting anywhere in the plan.
- License: BSD-3 for all eight packages, AGPL-3.0 + CLA for the two apps. Commit LICENSE files this week.
- (v2) The plan of record is a **$1.25–1.5M pre-seed/seed** — deliberately *below* the 2026 medians (pre-seed $1M, seed ≈$3.1M, cybersecurity seed $3–4M [S52][S53]) — buying 18 months: a second engineer, two staged audits, SOC 2, componentized enterprise products, and the revenue ladder already in motion. The ≈$40/mo survival floor stays documented as the fallback, not the ambition.
- (v2) The asset splits into piecemeal enterprise products along verified seams: the PQ messaging SDK, the agent-conduit stack (already dependency-free of the crypto core, by design), SwiftA2A, the codename context server, and the co-signed human/AI **provenance layer** — which maps directly onto EU AI Act **Article 50** duties applicable **2026-08-02** (fines to €15M / 3% of turnover) [S50]. See § Componentization.
- Grants stay layered in as dilution reducers (OpenSats/HRF/OTF precedents unchanged); angel/pre-seed checks in this category are real (SimpleX raised $370k pre-seed, later Dorsey/Asymmetric [S5][S6]).
- 90-day marks: TestFlight live, 3 grant applications filed, Huginn Pro on sale, Show HN done, A2A extension submitted upstream, App Store submission in review.

## The wedge — what has no incumbent

Four capabilities have no real competitor as of July 2026:

1. **Cryptographic AI consent windows + honest labeling.** A human signs a time-boxed
   `ai_window`; every client shows a countdown banner; agents cannot self-activate and
   autonomous sends outside a window fail closed; agent-signed messages MUST carry
   `"agent"` — a human label under an agent signature is rejected as a protocol
   violation (SPEC §8.2, §13). Nothing on the market does this; platform AI is the
   opposite design (feature 3 below).
2. **PQ-E2EE on Nostr.** The Nostr-native E2EE clients — 0xchat (NIP-17/59), White
   Noise (Marmot/MLS) — run classical crypto; post-quantum MLS ciphersuites are still
   an IETF draft [S44]. Eldr's hybrid X25519+ML-KEM-768 PQXDH, Double Ratchet, and
   50-message PQ rekey have no competitor on this network.
3. **A PQ-E2EE serverless transport for A2A.** A2A v1.0 (Linux Foundation, 150+ orgs)
   binds to JSON-RPC/gRPC/REST over HTTPS; payloads are plaintext inside the TLS
   channel and E2EE is out of protocol scope [S20][S21]. v1.0.1's extension mechanism
   [S22] is exactly the door "A2A over PQRC" walks through. We found nobody else
   building an E2EE, serverless, post-quantum A2A binding.
4. **Codename-only chat-context MCP and unpair-shreds-key AI memory.** MCP security
   products do enterprise tool governance [S30]; none offers chat context with
   identity redaction by construction, and no local-agent product ties memory
   readability to a Secure-Enclave key destroyed on unpair.

Near-wedge (incumbents exist, trust model differs): phone-driven coding agents
(feature 5) and self-hosted-AI reachability (feature 4) — the delta is *who holds the
relay and the permission gate*, not the capability.

**Table stakes where Eldr trails — never spin these:** independent audit (Signal,
Threema, Wire, vodozemac, and even White Noise have one [S13]; Eldr has none);
multi-device and account recovery (single-device by design); group scale; media
(deliberately text-only); message deniability (v1 signs messages —
`docs/THREAT_MODEL.md` §2.3); push notifications (not built yet); network effects.

## Competitive landscape — feature by feature

### 1) Post-quantum E2EE messaging, no phone number, no server that stores content

- **Signal** — free. PQXDH since 2023; now rolling out SPQR, a sparse PQ ratchet
  composed with the Double Ratchet ("Triple Ratchet"), deployed gradually until
  enforced on every session [S1][S2]. On ratchet-layer PQ Signal is *ahead* of Eldr's
  every-50-messages rekey; on decentralization, account-less identity, and AI it
  offers nothing, and it requires a phone number. Its budget post projects ~$50M/yr
  operating cost covered by donations [S40] — the structural contrast to Eldr's ≈$0
  store-and-forward relay (khatru behind Cloudflare; README).
- **iMessage PQ3** — free, shipped since iOS 17.4 (2024), formally verified (USENIX
  Sec '25); PQ rekey every ~50 epochs, the cadence pattern Eldr adopted [S3][S4].
  Centralized, Apple-bound, closed.
- **SimpleX Chat** — free. PQ double ratchet since v5.6 (2024); no user identifiers;
  UK company on ~$370k pre-seed plus later investment incl. Jack Dorsey [S5][S6].
  Closest philosophical competitor; no AI layer; its own relay protocol rather than
  an open network.
- **Session** — free. Historically no forward secrecy; Protocol V2 (ML-KEM + PFS) is
  announced, explicitly **not finalized**, details promised during 2026 [S7][S8].
- **Threema** — $6 one-time app; Threema Work $3–5/user/mo [S9]. Classical crypto;
  its relevance is commercial proof that individuals and companies pay.
- **Matrix/Element** — free clients; hosting $3–4/monthly-active-user [S10]. No PQ
  E2EE; vodozemac drew public cryptanalytic criticism in Feb 2026 [S11][S12].
- **Wire** — enterprise, quote-based per-user tiers; first platform fully on MLS
  [S45], whose deployed ciphersuites are classical [S44].

*Eldr delta:* only entrant with PQ + decentralized relays + keys-as-identity together.
*Honest deficit:* every name above except 0xchat has shipped longer, most are audited,
Signal/iMessage have formal verification. Eldr's crypto claims are spec + test-suite
proofs, not third-party review (`docs/lerants-agentic-writeup-notes.md`, guardrails).

### 2) Metadata resistance (gift wrap, fuzzed timestamps, bucket padding, chunking)

Incumbent approaches: Signal's sealed sender, SimpleX's identifier-less queues,
Session's onion routing; 0xchat uses the same NIP-17/59 gift-wrap primitives Eldr
builds on [S14]. Eldr adds bucket padding, 2-day timestamp fuzz, per-message throwaway
outer keys, and NIP-42 AUTH-gated serving — but `docs/THREAT_MODEL.md` §2.1–2.2 is
blunt: relays see IPs, keepalives signal liveness, recipient `p`-tags are visible to a
global passive observer, chunk bursts reveal large sends. Not a mixnet; marketing must
not imply otherwise.

### 3) AI as an honest, consent-gated participant

No incumbent — this is the wedge. What platforms actually ship:

- **Meta AI in WhatsApp** — cannot be fully disabled; "Advanced Chat Privacy"
  excludes a chat from AI processing but the assistant stays embedded [S15][S17]; as
  of Dec 2025, AI-chat data feeds ad personalization outside the EU/UK/South Korea
  [S16]. Private Processing / incognito modes are Meta-operated enclaves —
  trust-the-platform, not user-owned [S15].
- **Telegram** — $300M cash-and-equity deal to distribute xAI's Grok in-app plus 50%
  of subscription revenue [S18]: the AI is a platform-owned monetization surface.
- **Apple Intelligence in Messages** — summaries/smart replies via on-device models
  and Private Cloud Compute, which since June 2026 extends to Google Cloud with
  Gemini-derived Apple models [S19]. Best-in-class platform privacy engineering,
  still platform-selected and platform-controlled.

In all three the *platform* chooses the model, holds the consent switch, and controls
labeling. In Eldr the *user* picks the model per persona, a human signature opens the
only window in which an AI may speak, every participant sees the window, and AI
authorship is enforced at the protocol layer. Shared AI threads (multiple people's
AIs collaborating under invites, with loop guards) have no analogue anywhere we
looked.

### 4) Bring-your-own AI + per-chat egress firewall

Incumbents for "reach my self-hosted model from my phone": Open WebUI (free; custom
license since Apr 2025; enterprise tier) [S23], LM Studio and Ollama servers, usually
over Tailscale (free personal tier; paid from $6/user/mo) [S24]. Mature single-user
chat UIs — but none is a messenger, none redacts identities before cloud calls, none
has consent windows; Eldr's egress firewall (names → codenames, bounded context,
per-chat toggle) is unique here. Honest deficit: those tools have years more polish.

### 5) Phone→Mac coding agent ("conduit mode")

A crowded, monetizing category — the strongest evidence in this document that people
pay for what Eldr built. Omnara: free tier + ~$9/mo, YC S25, 20k+ users, iOS/Android/
Watch client for Claude Code and Codex [S25][S26]. Happy: free, open source, E2EE
(TweetNaCl) — but through *their* relay; closest architecture to Eldr's conduit
[S27]. Claude Code on web/iOS: bundled with Pro $17–20/mo, Max from $100/mo [S28].
Cursor background agents: $20–200/mo; Copilot coding agent: $10–39/user/mo tiers
[S29].

*Eldr delta:* no third-party relay or SaaS in the loop (self-hosted relay, or none —
Multipeer); PQ-E2EE transport; protocol-level fail-closed permission prompts (Allow
once/always/Deny, deny-on-timeout), path jail, kill switch; the agent lives inside
your messenger as a labeled participant; `eldrctl` provisions a second Mac over SSH.
*Honest caveats:* Happy already markets "E2EE + open source" — Eldr's differentiation
(PQ + no-vendor-relay + messenger integration) must be argued, not asserted.
Conduit/eldrctl are proven headlessly, not yet end-to-end on hardware
(`docs/meatsuittasks.md`); only eldr-acp, Xcode, and OpenClaw backends are wired
(Claude Code/Codex/Gemini rows are scaffold-only — do not advertise them).

### 6) Chat-context MCP, codenames only

MCP gateways (MintMCP, Lasso, Obot, MCP Manager) sell enterprise governance of tool
servers [S30]; iMessage/WhatsApp MCP servers in the wild expose raw chat content. No
product we found gives an agent chat context as *codenames with no real keys/names,
size-capped, loopback-only, token-gated, off-by-default* (USER-GUIDE "For developers").
Small market today; strong story for the security narrative.

### 7) Encrypted at-rest AI memory; unpair shreds the key

Cloud analogues attest non-retention (Apple PCC [S19]); local tools keep plaintext
history on disk. Eldr's Mac-side memory is per-conversation, Secure-Enclave-wrapped,
destroyed on unpair. Caveat from USER-GUIDE, to be repeated wherever this is marketed:
a sybilclaw backend keeps its own plaintext history outside Eldr's control — only the
built-in eldr-acp path is fully encrypted at rest.

### 8) Existence-deniable multi-account silos

Nearest neighbors are Android-only (Molly's passphrase lock) or app-level hidden
chats; no mainstream iOS messenger offers passphrase-isolated, existence-deniable
accounts. Small audience (border crossings, coercion threat models); THREAT_MODEL
§2.3a documents exactly what is and isn't hidden. A credibility feature, not a
headline.

### 9) A2A v1.0 support + draft E2EE transport extension

A2A v1.0 is the Linux Foundation's agent-interop standard: 150+ orgs, cloud-platform
landings, enterprise production use in year one [S20]. Its bindings are server-centric
HTTPS; academic threat-modeling of MCP/A2A notes payloads travel plaintext within the
secure channel [S21], and MCP's 2026 hardening went to OAuth 2.1 — transport auth, not
E2EE [S30]. Adjacent Nostr work (AI clients/providers discovery with bitcoin payments)
just took an OpenSats grant [S33]: the agent-over-Nostr economy is forming with no
E2EE transport story. Eldr's SwiftA2A + PQRC extension, submitted upstream, is both a
wedge and free distribution.

### 10) Zero-infrastructure operation

BitChat-style BLE mesh exists on iOS and 0xchat is integrating BLE relaying [S14];
Briar is Android-only. Eldr's difference: one identity and one PQ ratchet across
relay, LAN Multipeer, and pocket-relay modes — not a separate mesh app with a separate
identity. Caveats: radio paths need real hardware and one nearby-mode bug is logged in
USER-GUIDE (6/26 entry). The bootstrap relay costs ≈$0 to run (khatru behind
Cloudflare), against Signal's ~$50M/yr centralized cost base [S40].

## Value propositions

**One paragraph.** Eldr is the messenger for people who want AI in their conversations
without a platform in their conversations: post-quantum end-to-end encryption over
relays anyone can run, and an AI layer where you own the model, you sign the window in
which it may speak, everyone in the chat can see that window, everything it says is
cryptographically labeled as AI — plus a phone-to-Mac conduit that drives your coding
agent with per-action approvals instead of handing a third party shell access.

Per segment, with willingness to pay:

1. **Privacy-conscious individuals / Nostr+Bitcoin community.** The only PQ-E2EE
   option on the network they already live on; keys-not-accounts; self-hostable.
   WTP: low but real — Threema's $6 one-time precedent [S9], zaps, OpenSats-style
   patronage [S31]. Also the contributor and evangelist pool.
2. **AI power users who self-host models.** Already run LM Studio/Ollama/Open WebUI
   [S23]; Eldr adds E2EE reach from anywhere, group sharing under consent windows,
   and a redaction firewall for cloud fallback. WTP: $5–15/mo (Tailscale-class
   convenience money [S24]).
3. **Developers driving coding agents from a phone without giving a third party
   shell access.** Category WTP proven at $9–200/mo [S25][S28][S29]. Eldr's buyer is
   the subset that refuses a vendor relay; overlaps segment 2. WTP: $10–20/mo or a
   one-time Pro license. This is Huginn Pro's market.
4. **Small teams with confidentiality obligations (legal, finance, security).** Comps
   pay $3–5/user/mo (Threema Work, Element) [S9][S10]. Eldr's add: AI in the room
   with an unforgeable AI-vs-human record (ENTERPRISE-PITCH Layer 1). Do not sell
   here pre-audit — "design partner pilot" only. WTP post-audit: $5–15/user/mo.
5. **Agent-economy builders.** Need agent↔agent channels crossing org boundaries
   without exposing payloads to an intermediary; A2A today gives them TLS to a server
   [S21]. Eldr sells the transport SDK (SwiftA2A+PQRC). WTP: per-OEM licensing,
   $10k+ deals; longest timeline, biggest ceiling.

## Monetization, ranked by time-to-first-dollar

Open source stays open source in every path below, and nothing here is consulting —
no time-and-materials, no statements of work. The "support subscription" (#6) is
product-shaped (signed builds, priority patches, provisioning tooling), the model
investors do fund: SimpleX and Omnara are product companies with checks behind them
[S5][S25].

1. **Donations: GitHub Sponsors + Lightning zaps.** First dollar: days. Effort: hours.
   Fees: 0% from personal sponsors on GitHub [S34] (Open Collective would take ~10%
   [S34] — skip). Ceiling: $100s–$1k/mo; ambient support, never the plan.
2. **Huginn Pro early-supporter license — the "start this week" pick.** One-time
   $29–49 intro, sold direct via Paddle/Lemon Squeezy as a notarized DMG; free
   EldrChat TestFlight is the front door. First dollar: ~3–5 weeks (TestFlight must
   exist first — Huginn without the phone app is inert). Effort: low-medium;
   notarization is free with the $99 program [S38]. Ceiling: $10–50k/yr early. Why
   first: product revenue with no gatekeeper, aimed at the segment already paying
   $9–200/mo [S25][S29]; early-supporter framing absorbs alpha roughness. Pro =
   signed auto-updating builds + multi-node/priority features; AGPL source stays
   public (license section below).
3. **Grants (non-dilutive cash, weeks-to-months).** OpenSats: rolling, worldwide,
   nym-friendly; its Nostr Fund pays for messaging clients (0xchat) and AI-over-Nostr
   work today (17th wave, May 2026) [S31][S33]. HRF BDF: quarterly waves (~$455k/12
   projects Feb 2026; 1.5B sats/20 Apr 2026), and it funded a Nostr E2EE-messaging
   developer *including a security audit* [S32] — the template for Eldr's audit money.
   OTF: rolling two-stage, $10k–900k, ideal $50k–200k, ~6–8 weeks to first response
   [S48]. Effort: days of writing. EV: $25–100k inside two quarters; timing not
   controllable.
4. **iOS paid tier under the App Store Small Business Program.** Free app + "Eldr
   Supporter" IAP (later a paid Plus tier); 15% commission under $1M/yr [S37]. First
   dollar: 8–12 weeks (App Review; 4.2.7 remote-control framing per
   `docs/meatsuittasks.md`, Termius/Moshi precedent). Ceiling: the long-term consumer
   line — Threema built a business on exactly this [S9].
5. **"Eldr Plus": managed relay + push notifications, $2–5/mo.** Push is the honest
   paywall: iOS delivery needs an APNs server keyed to the app's bundle ID — only the
   developer can run it (notepush is the reference pattern [S41]). COGS ≈ one
   $4.49/mo VPS for thousands of users [S42]. First dollar: 2–3 months. Recurring,
   sticky, privacy-honest (push proxy sees envelope-arrival metadata only — disclose
   in THREAT_MODEL §2.1 terms).
6. **Team/self-host subscription (product-shaped, explicitly not consulting).**
   Signed builds + priority updates + `eldrctl` fleet provisioning + named support
   channel, $4–8/user/mo against Threema Work/Element comps [S9][S10]. First dollar:
   3–6 months, realistically post-audit for the regulated buyers it targets. Ceiling:
   $50k+/yr per ten small firms.
7. **SDK / white-label licensing of the PQ agent transport (SwiftA2A + PQRC).** Sell
   the E2EE channel to agent vendors and MCP/A2A security platforms [S30]; the
   upstream extension submission is the marketing. First dollar: 6–12 months.
   Ceiling: largest, least certain. BSD-3 packages make adoption frictionless; the
   commercial product is support, certification, and hosted rendezvous.

**This week:** start #2's clock (TestFlight submission is its prerequisite) and file
the OpenSats application from #3 the same week — half a day of writing against the
quarter's highest expected value. If forced to name one: #2, because it is the only
path that is simultaneously fast, gatekeeper-free, and legible to investors as product
revenue rather than patronage.

## License recommendation

**One recommendation: BSD-3-Clause for all eight SPM packages; AGPL-3.0-only for the
two app targets (App/EldrChat, Apps/Huginn), with a CLA granting the founder
relicensing rights. Commit the LICENSE files this week — the repo currently has none,
and the README references a LICENSE file that does not exist.**

- **Packages BSD-3.** The A2A upstream play and SDK path (#7) die under copyleft — an
  E2EE transport nobody can embed is a transport nobody adopts. Matches the README's
  drafted intent and the swift-crypto/secp256k1 dependency chain.
- **Apps AGPL-3.0 + CLA.** All-BSD invites the concrete failure mode: someone ships
  "EldrChat, now with telemetry" to the App Store. AGPL blocks closed forks; the CLA
  lets the founder sell App Store builds, Huginn Pro, and commercial licenses.
  Precedents: Signal (GPL/AGPL apps + CLA), Element (Apache→AGPL+CLA in 2023 to
  enable dual licensing), Bitwarden (GPL/AGPL + commercial modules + CLA).
- **App Store friction is manageable.** GPL-family trouble on the App Store bites
  third-party redistributors, not the copyright holder shipping their own code; the
  CLA preserves that position as contributors arrive. If outside code enters the
  apps, add an explicit App Store exception (Nextcloud-iOS pattern).
- **Grant eligibility preserved.** OpenSats requires code "publicly available for
  access, edit, and redistribution free of charge and without restrictions" [S36];
  Sovereign Tech requires OSI/FSF-approved licenses [S43]. BSD-3 and AGPL-3.0 both
  qualify; source-available (BUSL and kin) fails [S36] and burns Nostr-community
  trust — rejected.
- **Tradeoff, stated honestly:** AGPL+CLA deters some contributors. Acceptable — the
  apps are the product; the packages, where protocol contributors matter most, stay
  maximally open.

## Componentization — the piecemeal enterprise strategy (v2, 2026-07-18)

Enterprise buyers don't buy a messenger; they buy the piece that fixes their problem.
The codebase splits better than its own docs suggest — the following is verified
against the actual `Package.swift` dependency declarations and cross-package imports:

```
swift-crypto ─▶ PQRCCore ─▶ PQRCNostr ─▶ PQRCAgent          (messaging line)
                                │
                                ⚠ 3 bridge files import PQRCACP (the only violation)
SwiftA2A ─▶ PQRCACP ─▶ { EldrNode, Huginn }                  (agent line)
PQRCMCP   — zero internal deps (protocol seams; the app injects the chat bridge)
Eldrctl   — zero internal deps
```

Two verified facts drive the whole strategy:

1. **The agent line is already severed from the crypto core — deliberately.**
   `PQRCACP` declares exactly one dependency (`SwiftA2A`), and a comment in
   `ACPEvents.swift` documents that it *can't* import PQRCCore. The Mac-tether stack
   can leave the building tomorrow.
2. **The messaging line has one layering violation, three files wide.** `PQRCNostr`
   (transport) imports `PQRCACP` only in `RelayACPTransport.swift`,
   `RelayMCPTransport.swift`, and `NearbyACPTransport.swift` — the tunnels that carry
   agent frames over the relay/nearby links. Moving those three into a small adapter
   package that depends on both sides restores clean layering. Days of refactor; the
   chaos-matrix suite re-proves the transport afterward.

### The five sellable components

| Component (repo) | Contents today | What the split takes | Who buys, and what |
|---|---|---|---|
| **swift-a2a** | `SwiftA2A`: A2A v1.0 types, JSON-RPC, client/server/HTTP; zero deps; 4 test suites | Days — LICENSE, README, CI, SemVer tags. The upstream extension submission wants it standalone anyway | BSD-3, free. The funnel and standard-setting play; support revenue later. Ambition: the de-facto Swift A2A SDK |
| **pqrc-swift** (the p2p/relay piece) | `PQRCCore` + `PQRCNostr` minus the 3 bridge files, plus `pqrc-SPEC-v1_1`, `NIP-XX-pqrc`, and the frozen TestVectors | ~1–2 weeks — the adapter-package refactor, repo hygiene, vector ownership | Enterprises embedding PQ-E2EE in their own products. Audited-release + support subscription; the component audits attach to first |
| **eldr-conduit** (the Mac-tether piece) | `PQRCACP` + `EldrNode` + `Eldrctl`; Huginn remains the AGPL app product on top | ~1–2 weeks — own CI, config docs, harness matrix. Already crypto-core-free | Engineering orgs driving org-owned coding agents with fail-closed permission gates, path jail, PTY kill switch. Per-seat: Huginn Pro → Team |
| **codename-context** | `PQRCMCP`: chat context as codenames only; size-capped, token-gated; zero internal deps | Days | More a proof-point of the provenance story than a standalone SKU — but its own repo strengthens the security narrative |
| **ai-provenance** (the co-signed AI–human tether) | Interleaved in `PQRCCore` today (`Identity/IdentityBinding.swift`, agent derivation, the `ai_window` types in `Envelope/Rumor.swift`) + enforcement in `PQRCAgent` | The real project: (1) extract the **profile spec** from SPEC §3.3/§8.2/§13 + the NIP kinds — days; (2) a verification-only library ("is this window human-signed; is this label honest; is this agent bound to this human") with its own vectors — 2–4 weeks; carries a secp256k1 dependency for Nostr identities | The regulatory buy. EU AI Act **Article 50** applies **2026-08-02**: interactive AI must disclose itself, and AI-generated content needs machine-readable marking (systems already on the market get until 2026-12-02 for the marking duty under the AI Omnibus); fines to €15M or 3% of worldwide turnover [S50]. Eldr's human-signed windows + protocol-enforced AI labels *are* machine-readable AI disclosure, with signatures. No incumbent (see § The wedge, item 1) |

### How to run the split without killing velocity

- **Monorepo stays the source of truth.** Publish per-component **read-only mirror
  repos** (automated subtree split in CI), each with its own README, LICENSE, SemVer
  tags, and security policy. A component graduates to a true standalone repo only when
  it has external consumers/contributors — SwiftA2A first (the upstream submission
  forces it), pqrc-swift when the first embedding customer appears.
- **Costs, stated honestly:** per-repo CI and release trains; cross-repo version
  pinning (a protocol change now fans out across tagged releases instead of one
  commit); vectors travel with the component that owns them; the support surface
  multiplies with every public repo. This is a large part of what Track B's second
  engineer exists to own.
- **License per repo** follows the recommendation above: BSD-3 for the package
  mirrors, AGPL+CLA for the two apps. The provenance *spec* publishes openly —
  standards don't sell; implementations, conformance suites, and certification do.
- **Sequencing, tied to the revenue ladder:** swift-a2a mirror + upstream PR (weeks
  6–7 of the 90-day plan) → **ai-provenance profile spec published before the
  2026-08-02 Article 50 date** while it owns the news cycle → pqrc-swift mirror when
  the first audit engagement scopes it → eldr-conduit repo alongside the Huginn Pro
  launch.

## Budget — two tracks (v2)

### Track A — the survival floor (kept as the fallback, no longer the plan)

| Item | Cost | Basis |
|---|---|---|
| Apple Developer Program (TestFlight 10k testers, notarization, APNs) | $99/yr | [S38][S39] |
| Notarizing Huginn's DMG | $0 | included [S38] |
| Relay VPS — today runs ≈$0 on existing infra (khatru + Cloudflare) | $0 now; $4.49–8/mo if dedicated | [S42]; README |
| Push server (notepush-pattern APNs relay), same VPS | +$0–5/mo | [S41] |
| Domain + email (lerants.com exists; add eldr.chat) | ~$15–40/yr | registrar list |
| LLC (avg filing $132; $0-annual-report states exist; self as agent $0) | $35–500 once, $0–300/yr | [S46] |
| Payment rails (Paddle / Lemon Squeezy) | % of sales only | vendor pricing |
| App Store assets (simulator screenshots, DIY) | $0 | — |
| **Minimum monthly burn, infra only** | **≈ $15–40/mo** | above |
| **Year-one cash floor (ship + sell, audit deferred)** | **≈ $1,300** | above |
| Full independent messenger/crypto audit | $30k–200k | OSTIF's stated range [S35] |
| Staged alternative: scoped review of PQRCCore+PQRCNostr only | ≈ $30–60k | [S13][S35] |
| **Smallest total that reaches a shipped, audited 1.0** | **≈ $60k** | sum |

Track A's role in v2: it proves the project cannot be killed by a failed raise — and
it is what the company reverts to, not what it aims at.

### Track B — the funded plan (the plan of record)

Market context: the median US pre-seed is $1M (Carta, Q1 2026 [S52]); the median seed
≈$3.1M, with cybersecurity seeds at $3–4M [S53]. The ask below is deliberately
below-median — sized bottom-up from what the work costs, not top-down from what the
market allows.

**Raise $1.25–1.5M (SAFE), 18 months of runway. Use of funds:**

| Line | ≈ Cost (18 mo) | Notes |
|---|---|---|
| Founder + one senior Swift/crypto engineer, full-time | $650–700k | The second engineer owns componentization, release trains, and the conduit/provenance extraction |
| Fractional devrel + design (contract) | $60–100k | Docs, demos, the Nostr/AI conference circuit |
| Security: two staged audits + remediation re-review | $100–140k | (1) pqrc-swift core+transport; (2) conduit + provenance kit. OSTIF band $30–200k [S35]; HRF-style grants offset directly [S32] |
| SOC 2 Type I → Type II | $50–75k | Platform + partner auditor; startup first-year totals run $25–50k, Type II adds the observation window [S51] |
| Legal: CLA, dual-licensing, trademarks, export counsel | $30–45k | |
| GTM: design-partner program, content, events, App Store assets | $40–60k | |
| Infra: relays, push, CI, build hardware | $10–15k | |
| Contingency (~12%) | $130–160k | |
| **Total** | **≈ $1.1–1.3M** | Raise $1.25–1.5M; a realistic $50–150k grant pipeline reduces dilution, not the plan |

**Month-18 exit criteria (what the money must have bought):** audited pqrc-swift and
conduit; SOC 2 Type II observation window underway; EldrChat 1.0 on the App Store with
Huginn Pro/Team and Eldr Plus recurring; the five component repos live; the A2A
extension upstreamed; the provenance kit launched against the Article 50 window; 3–5
design partners in confidentiality-bound verticals (legal/finance/security); blended
**$10–25k MRR**. That is a Series-A-optional position: seed metrics if growth capital
is wanted, a self-sustaining company if not.

**Why raise at all (v1 said don't):** $60k buys a survivable audit, not a company.
Solo-founder velocity is today's story and tomorrow's concentration risk (§ Honest
risks); the componentization strategy needs a second engineer and a real GTM motion to
land before Signal's SPQR and White Noise close the crypto gap and someone else builds
the consent layer. The constraint stands: no consulting anywhere — every dollar funds
product, proof (audits, SOC 2), or distribution.

**Staged alternative** if a full round drags: close $500–750k of the same SAFE now
(median pre-seed territory [S52]) to fund the engineer + first audit + Article 50
launch, and complete the round on the Huginn Pro / design-partner traction it buys.

## First 90 days (2026-07-20 → 2026-10-17)

- **Week 1 (Jul 20).** Commit LICENSE files (BSD-3 packages / AGPL apps + CLA). Stand
  up GitHub Sponsors + Lightning address. TestFlight internal build up. Write and
  submit the **OpenSats** application (rolling; cite the test suite, DEVIATIONS
  ledger, and THREAT_MODEL as engineering evidence) [S31].
- **Week 2 (Jul 27).** External TestFlight submitted (first build gets a review,
  typically ~1–2 days [S39]); pre-empt the known a11y-audit failure and 30–60s
  universe-seed latency first. File the **HRF BDF** application for the Q3 wave, the
  security audit as the named line item [S32].
- **Week 3 (Aug 3).** Publish the lerants.com AI-assisted-engineering writeup (source
  notes ready and verified — `docs/lerants-agentic-writeup-notes.md`; respect its
  guardrails, don't overclaim autonomy). Nostr soft launch from the project npub:
  demo clip of an `ai_window` + a conduit session; ask 0xchat/Marmot devs for
  NIP-XX-pqrc feedback.
- **Week 4 (Aug 10).** **Show HN**, led by the writeup + public TestFlight link (the
  process discipline is the story; the app is the proof). File the **OTF** concept
  note (~6–8 weeks to reply) [S48].
- **Week 5 (Aug 17).** **Huginn Pro on sale**: notarized DMG, early-supporter $29–49
  one-time, Paddle/Lemon Squeezy. Target: first 10–50 units. First product revenue,
  ~30 days in.
- **Weeks 6–7 (Aug 24–Sep 6).** Finish and submit the **"A2A over PQRC" extension**
  upstream; present it in the LF A2A community [S20][S22]. Blog post alongside — the
  credibility beat for segment 5 and the SDK path.
- **Weeks 8–9 (Sep 7–20).** **App Store submission**: free app; review notes per
  `docs/meatsuittasks.md` (4.2.7 "remote control of YOUR own Mac," Termius/Moshi
  precedent; `ITSAppUsesNonExemptEncryption = YES`; ENC 5D992.c; privacy labels;
  report/block path). Enroll in the Small Business Program at submission [S37];
  calendar the BIS self-classification (Feb 1).
- **Weeks 10–11 (Sep 21–Oct 4).** "Eldr Supporter" IAP live if approved. Push spike:
  notepush-pattern APNs server [S41] behind an **Eldr Plus** ($2–5/mo) flag, beta'd
  with the TestFlight cohort. Second content beat: "a $0/month messenger backbone,"
  with THREAT_MODEL candor.
- **Weeks 12–13 (Oct 5–17).** Audit RFP to Least Authority / Cure53 / OSTIF intake
  with grant status attached [S13][S35]. 90-day transparency post (installs, revenue,
  grant pipeline) — Nostr first. Gate: grant landed → book the scoped review; not →
  double down on Pro + Plus and the next HRF wave.

Checkpoint targets for Oct 17: 300+ TestFlight installs; 25+ paid Huginn Pro; 3 grant
applications filed and ≥1 in second-stage review; ≥$25k grant money committed
(stretch); ≥$300 MRR including donations; A2A extension PR open upstream.

**(v2) The raise runs in parallel, not instead:** data room ready by week 2 (this
document + DEVIATIONS + THREAT_MODEL + the test/vector evidence — the diligence
artifacts already exist as engineering artifacts); publish the **ai-provenance profile
spec in week 2–3, ahead of the 2026-08-02 Article 50 date**, as the timing hook for
both press and partner conversations; first investor conversations after the Show HN
beat (week 4+), leading with the wedge and live Huginn Pro revenue; target a signed
lead by the week-13 checkpoint. Grants proceed unchanged — they reduce dilution.

## Funding sources beyond product revenue

| Source | Fit for Eldr | Size / cadence | Status (2026-07-17) |
|---|---|---|---|
| OpenSats — Nostr Fund | Direct precedent: funds 0xchat and AI-over-Nostr work | Per-grant sizes unpublished; waves ~5 projects; LTS grants exist | Open, rolling, worldwide, nym-friendly [S31][S33][S36] |
| HRF Bitcoin Development Fund | Funded Nostr E2EE messaging dev incl. its security audit | ~$455k/12 projects (Feb 2026); 1.5B sats/20 (Apr 2026); quarterly | Open [S32] |
| OTF Internet Freedom Fund | Secure messaging is core remit | $10k–900k; ideal $50–200k; rolling; ~6–8 wk first reply | Open [S48] |
| Sovereign Tech Fund / Agency | Protocol/package layer fits "base technologies" | ≥€50k, up to ~€1M; OSI/FSF licenses required | Programs active in 2026 [S43] |
| NLnet / NGI Zero | Final Commons Fund call closed 2026-06-01; remainder is Taler/Fediversity-specific; non-EU applicants need a "clear European dimension" | €5–50k historical | Poor fit now — deprioritize [S47] |
| Spiral (Block) | Bitcoin-adjacent FOSS grants, Nostr-friendly orbit | Full-time developer grants | Open [S49] |
| Pre-seed/seed equity — **v2 plan of record** (Budget, Track B) | $1.25–1.5M SAFE, below 2026 medians (pre-seed $1M, seed ≈$3.1M) [S52][S53] | Aggregated from $100–500k angel checks in this category | SimpleX precedent: pre-seed + Dorsey/Asymmetric [S5][S6] |

## Honest risks

- **Unaudited cryptography.** Every security claim is spec-plus-test-suite evidence,
  not independent review; competitors are audited, two formally verified
  [S1][S4][S13]. Mitigations: banner stays up, audit-earmarked grants, staged scoped
  review, OSTIF intake.
- **Alpha, with named features unproven on hardware.** Conduit/eldrctl end-to-end,
  multi-party node fan-out redaction (a slip would leak owner plaintext), nearby-mode
  bug, PCC tier scaffolding (`docs/meatsuittasks.md`, USER-GUIDE). Marketing must
  track *Shipped* vs *Rolling out* exactly as ENTERPRISE-PITCH mandates.
- **Structural limits are permanent trade-offs, not roadmap gaps.** Single device, no
  recovery, no message deniability, relay-visible IPs and `p`-tags, liveness-visible
  keepalives (THREAT_MODEL §2). These cap segments 1 and 4 at the high-threat end.
- **The crypto lead compresses.** Signal's SPQR makes a full PQ ratchet table stakes
  [S1]; White Noise is audited on the same network [S13]; Session and Matrix have PQ
  on their slides [S7]. The durable differentiation is the AI-consent layer and the
  combination — ship and upstream it before it's copied.
- **Conduit niche is contested now.** Happy is free, open source, E2EE-marketed
  [S27]; Omnara has YC backing and 20k users [S25]. Eldr wins only where
  "no third-party relay, PQ, in my messenger" matters.
- **Distribution gatekeepers.** App Store 4.2.7 interpretation risk for conduit mode;
  the Xcode 27 beta toolchain requirement (README) is a real shipping dependency.
- **Solo founder; AI-assisted velocity is both story and concentration risk.** The
  writeup markets the method; DEVIATIONS/test discipline and the CLA partially
  mitigate the bus factor. Grant timing is uncontrollable and early Pro sales start
  small; the ~$40/mo floor keeps survival independent of both.

## Sources

All URLs accessed 2026-07-17; [S50]–[S53] added in the v2 revision, accessed 2026-07-18.

- [S1] Signal blog — SPQR / Triple Ratchet: https://signal.org/blog/spqr/
- [S2] signalapp/SparsePostQuantumRatchet: https://github.com/signalapp/SparsePostQuantumRatchet
- [S3] Apple Security Research — iMessage PQ3: https://security.apple.com/blog/imessage-pq3/
- [S4] USENIX Security '25 — A Formal Analysis of iMessage PQ3: https://www.usenix.org/conference/usenixsecurity25/presentation/linker
- [S5] Wikipedia — SimpleX Chat (funding history): https://en.wikipedia.org/wiki/SimpleX_Chat
- [S6] SimpleX blog — network model, non-profit protocols, v5.6 PQ: https://simplex.chat/blog/20240323-simplex-network-privacy-non-profit-v5-6-quantum-resistant-e2e-encryption-simple-migration.html
- [S7] Session — Protocol V2 (PFS + ML-KEM): https://getsession.org/blog/session-protocol-v2
- [S8] Privacy Guides (2025-12-03) — Session V2 "not yet finalized… details in 2026": https://www.privacyguides.org/news/2025/12/03/session-messenger-adds-pfs-pqe-and-other-improvements/
- [S9] Threema pricing — $6 one-time; Work $3–5/user/mo: https://threema.com/en/pricing
- [S10] Element pricing — $3–4/MAU/mo: https://element.io/en/pricing
- [S11] Soatok (2026-02-17) — Cryptographic Issues in vodozemac: https://soatok.blog/2026/02/17/cryptographic-issues-in-matrixs-rust-library-vodozemac/
- [S12] Matrix.org — Analysis of reported vodozemac issues: https://matrix.org/blog/2026/02/analysis-of-reported-issues-in-vodozemac/
- [S13] Least Authority — White Noise (whitenoise-rs) audit, final report 2026-04-01: https://leastauthority.com/blog/audit-of-white-noise-whitenoise-rs/
- [S14] 0xchat (NIP-17/59 client; BLE mesh integration): https://0xchat.com/ ; Marmot protocol (MLS over Nostr): https://github.com/marmot-protocol/marmot
- [S15] WhatsApp Help — About Meta AI: https://faq.whatsapp.com/2257017191175152
- [S16] Metricool — Meta AI opt-out limits; AI-chat data in ads ex-EU/UK/KR (Dec 2025): https://metricool.com/opt-out-meta-ai-training/
- [S17] EFF (2025-09) — What WhatsApp's "Advanced Chat Privacy" Really Does: https://www.eff.org/deeplinks/2025/09/what-whatsapps-advanced-chat-privacy-really-does
- [S18] TechCrunch (2025-05-28) — xAI to pay Telegram $300M to integrate Grok: https://techcrunch.com/2025/05/28/xai-to-pay-300m-in-telegram-integrate-grok-into-app/
- [S19] Apple Newsroom (2026-06) — Apple Intelligence features: https://www.apple.com/newsroom/2026/06/apple-intelligence-brings-powerful-ai-capabilities-into-everyday-experiences/ ; Apple Security — Expanding Private Cloud Compute: https://security.apple.com/blog/expanding-pcc/
- [S20] Linux Foundation — A2A surpasses 150 organizations: https://www.linuxfoundation.org/press/a2a-protocol-surpasses-150-organizations-lands-in-major-cloud-platforms-and-sees-enterprise-production-use-in-first-year
- [S21] arXiv — Security Threat Modeling for AI-Agent Protocols (MCP/A2A plaintext-in-channel): https://arxiv.org/pdf/2602.11327
- [S22] A2A v1.0/v1.0.1 layering and extension mechanism (adoption overview): https://agentndx.ai/blog/a2a-protocol-adoption-mid-2026/
- [S23] Open WebUI — license (Apr 2025 change) and enterprise tier: https://docs.openwebui.com/license/
- [S24] Tailscale pricing (free Personal; Starter $6/user/mo): https://www.vendr.com/marketplace/tailscale
- [S25] Omnara — pricing (free tier; ~$9/mo) and YC S25 profile: https://www.omnara.com/pricing ; https://www.ycombinator.com/companies/omnara
- [S26] Omnara iOS app: https://apps.apple.com/us/app/omnara-claude-codex-mobile/id6748426727
- [S27] Happy — open-source E2EE Claude Code/Codex client, relay architecture: https://github.com/slopus/happy ; https://happy.engineering/docs/security/
- [S28] Claude plans — Pro $17–20/mo incl. Claude Code; Max from $100/mo: https://claude.com/pricing
- [S29] Copilot tiers ($10/$39/$100; Business $19/user) and Cursor ($20–200/mo): https://www.nxcode.io/resources/news/github-copilot-complete-guide-2026-features-pricing-agents ; https://www.morphllm.com/comparisons/cursor-vs-copilot
- [S30] MCP gateway/security landscape 2026 (MintMCP, Lasso, Obot; OAuth 2.1 direction): https://www.integrate.io/blog/best-mcp-gateways-and-ai-agent-security-tools/
- [S31] OpenSats — Apply (rolling, worldwide, nym-friendly): https://opensats.org/apply ; 0xchat grant page: https://opensats.org/projects/0xchat
- [S32] HRF Bitcoin Development Fund — $455k to 12 projects (Feb 2026): https://hrf.org/latest/hrf-bitcoin-development-fund-grants-455000-to-12-projects-worldwide/ ; 26-project wave incl. Nostr E2EE dev + audit funding: https://hrf.org/latest/hrfs-bitcoin-development-fund-announces-support-for-26-projects-worldwide/
- [S33] OpenSats — Seventeenth Wave of Nostr Grants (2026-05-20): https://opensats.org/blog/seventeenth-wave-of-nostr-grants
- [S34] GitHub Sponsors fees (0% from personal accounts): https://docs.github.com/en/sponsors/sponsoring-open-source-contributors/about-sponsorships-fees-and-taxes ; Open Collective ~10% host fees: https://docs.oscollective.org/campaigns-and-partnerships/github-sponsors
- [S35] OSTIF — Get an Audit ("$30k to $200k" initial audits): https://ostif.org/get-an-audit/
- [S36] OpenSats — license requirement wording (free access/edit/redistribution): https://opensats.org/apply
- [S37] Apple — App Store Small Business Program (15% under $1M): https://www.apple.com/newsroom/2020/11/apple-announces-app-store-small-business-program/ ; 2026 mechanics: https://www.revenuecat.com/blog/engineering/small-business-program
- [S38] Apple Developer Program — $99/yr, what's included: https://developer.apple.com/programs/whats-included/
- [S39] TestFlight — 10k external testers; first-build beta review: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/
- [S40] Signal — "Privacy is Priceless, but Signal is Expensive" (~$50M/yr by 2025): https://signal.org/blog/signal-is-expensive/
- [S41] damus-io/notepush — self-hostable Nostr→APNs push relay: https://github.com/damus-io/notepush
- [S42] Hetzner Cloud — entry instances from $4.49/mo: https://www.hetzner.com/cloud
- [S43] Sovereign Tech Fund — ≥€50k investments; OSI/FSF license requirement: https://www.sovereign.tech/programs/fund
- [S44] IETF — draft-ietf-mls-pq-ciphersuites (PQ MLS still an Internet-Draft): https://datatracker.ietf.org/doc/draft-ietf-mls-pq-ciphersuites/
- [S45] Wire — pricing (quote-based) and MLS position: https://wire.com/en/pricing ; https://wire.com/en/messaging-layer-security
- [S46] LLC University — costs by state (avg $132 filing; agent $100–300/yr): https://www.llcuniversity.com/llc-filing-fees-by-state/
- [S47] NLnet — NGI Zero Commons Fund (final call closed 2026-06-01) and eligibility (European dimension for non-EU): https://nlnet.nl/commonsfund/ ; https://nlnet.nl/commonsfund/eligibility/
- [S48] OTF — Internet Freedom Fund ($10k–900k; rolling; ~6–8 wk reply): https://www.opentech.fund/funds/internet-freedom-fund/
- [S49] Spiral — grant program: https://spiral.xyz/about/
- [S50] EU AI Act Article 50 — text: https://artificialintelligenceact.eu/article/50/ ; applicability 2026-08-02, obligations, fines, and the AI-Omnibus marking grace to 2026-12-02: https://datamatters.sidley.com/2026/06/24/eu-ai-act-transparency-obligations-preparing-for-compliance-by-2-august-2026/ ; Code of Practice on AI-generated content: https://digital-strategy.ec.europa.eu/en/policies/code-practice-ai-generated-content
- [S51] SOC 2 costs 2026 — startup Type II audit fees $15–45k, first-year totals $25–50k: https://soc2auditors.org/insights/soc-2-type-2-audit-cost/ ; https://www.vanta.com/collection/soc-2/soc-2-audit-cost
- [S52] Carta — State of Pre-Seed Q1 2026 (median pre-seed round $1M): https://carta.com/data/state-of-pre-seed-q1-2026/
- [S53] Seed medians 2026 (~$3.1M overall; cybersecurity $3–4M): https://www.pitchwise.se/blog/median-seed-round-size-by-industry-in-2026-data ; https://www.flowjam.com/blog/seed-round-valuation-2025-complete-founders-guide

[S21]: link