# Gooseworld — Eldr as the secure way goosetowns connect

Plan of record draft, 2026-07-18. House rules from BUSINESS-CASE.md apply: evidence
over enthusiasm, *Shipped* vs *New* marked honestly, privacy ties resolve per SPEC §0.

## 1. What a goosetown is (verified today, not from memory)

Goosetown is the goose team's multi-agent orchestration layer on top of Block's goose
(now stewarded under the AAIF), a "much less sprawling riff" on Steve Yegge's Gas
Town. One machine runs an **Orchestrator** that decomposes work into research → build
→ review, **summons ephemeral delegates** (`delegate()`, skills define roles), tracks
durable state in **Beads** (a git-based local issue tracker), and coordinates
everything through the **Town Wall** (`./gtwall`) — an append-only, per-session
broadcast log with per-reader position tracking, `@name` targeting, and
priority-for-human messages. Telepathy pings delegates to go read the wall.

Two facts define the opening:

1. **A goosetown is an island.** README, AGENTS.md, and the launch post contain no
   multi-machine story, no networked towns, no cross-town delegation, and no trust
   model beyond "never push without approval." Coordination is local files + local
   processes.
2. **A goosetown is a shell.** Delegates edit files, run commands, clone repos. Any
   future inter-town link is therefore a *code-execution-adjacent* channel, not a
   chat channel. Whoever connects towns without solving identity, consent, and
   injection containment is building a worm distribution network.

Sources: [goosetown README](https://github.com/aaif-goose/goosetown),
[AGENTS.md](https://github.com/aaif-goose/goosetown/blob/main/AGENTS.md),
[Gas Town Explained](https://goose-docs.ai/blog/2026/02/19/gastown-explained-goosetown/),
[block/goose](https://github.com/block/goose), [AAIF](https://aaif.io/projects/goose/).

## 2. What gooseworld is

**Gooseworld = many goosetowns, owned by different humans on different machines,
collaborating over a channel where every message is PQ-E2EE, every agent is
cryptographically bound to a human owner and labeled as an agent, and every
autonomous conversation happens under a human-signed, visible, revocable grant.**

Eldr is that channel. This is not a pivot; it is the BUSINESS-CASE wedge (§ item 3,
"PQ-E2EE serverless transport for A2A") landing on its first concrete, distributable
ecosystem. The messenger remains the human window into the traffic.

Three planes, all mapped onto things this repo already has:

| Plane | Gooseworld meaning | Eldr mechanism | Status |
|---|---|---|---|
| **Task** | Town A's orchestrator delegates a bead to Town B's flock | A2A v1.0 over the gift-wrapped ratchet stream (`RelayA2ATransport`, `A2A1\|` frames), `A2AACPBridge` / `.a2aRemote` harness, per-task human approval in Huginn (deny/timeout → `REJECTED`) | **Shipped** (proven loopback + LocalRelaySimulator; live relay two-machine proof is Phase 0) |
| **Coordination** | A cross-town Town Wall — append-only, all towns' agents post/read | Shared AI thread + group fan-out: agents as labeled members under thread invites, loop guards, relay chunking for >64 KB posts | **Shipped for humans+own AIs; bridge to goose is New** |
| **Oversight** | Humans see everything, grant everything, can kill everything | `ai_window` / thread invites (SPEC §13), kind-10420 binding verified both ways, `participant_type` honesty (invariants 8–9), per-chat egress firewall, kill switch | **Shipped; standing grants are New (§5)** |

What we deliberately do NOT bring: media (text-only stance holds — walls, beads,
diffs, and task payloads are text; artifacts stay in git remotes, we transport
references and chunked text), a blob store (unchanged, permanent), and a public town
directory (v1 pairing is invite-based, privacy-maximizing).

## 3. The decentralization question, answered

The user's instinct ("not sure it needs to be decentralized") is right, and the
protocol already agrees:

- **PQRC treats the relay as hostile.** E2EE + PQ ratchet + gift wrap + fuzzed
  timestamps + bucket padding mean a single operator relay weakens *no*
  confidentiality or integrity property. Decentralization was never load-bearing for
  message security here.
- What a single hub **does** concentrate: availability (SPOF), censorship power, and
  the metadata THREAT_MODEL §2.1–2.2 is already honest about (IPs, recipient
  `p`-tags, timing/liveness). For always-on daemons owned by developers, that
  metadata class is materially less sensitive than for at-risk humans; for latency
  and ops simplicity a hub is strictly better.
- **Recommendation: centralized by default, decentralized by capability.** Ship a
  hosted **gooseworld hub relay** (the existing khatru/Cloudflare deployment,
  AUTH-gated, ≈$0) as the zero-config default every town joins. Keep what already
  exists and costs nothing to keep: kind-10050 relay lists, NIP-11-driven chunk
  sizing, self-host guide (RELAY-DEPLOY-CROSTINI.md pattern), LAN Multipeer for
  same-site towns. A privacy-maximal town runs its own relay and interoperates; we
  never *depend* on that. No new decentralization work is scheduled; none is removed.
- Business alignment: the hub is the "Eldr Plus"-shaped recurring line, and the
  open-relay capability is what keeps the goose/OSS community and grant funders
  (OpenSats/Spiral) on side. Both stances get to be true.

## 4. Threat model delta (write into THREAT_MODEL.md before Phase 1 ships)

New adversary classes, in priority order:

1. **Cross-town prompt injection → code execution.** The dominant risk. A remote
   town's wall post or task result is untrusted input flowing into an orchestrator
   that spawns shells. Mitigations, layered: wall/task content delivered as
   quarantined, quoted DATA with explicit untrusted framing (never interpolated as
   instructions); tool-scope minimization for delegates that consume remote content;
   the existing fail-closed permission gates + path jail on everything a remote task
   triggers; per-town grants (§5) so exposure is a deliberate, revocable choice;
   per-chat egress firewall governing what leaves toward cloud LLM backends.
   "Never push without approval" stays enforced locally, not trusted remotely.
2. **Delegation exfiltration.** The task text IS the leak to the remote town — the
   existing distinct delegation-consent card already makes this per-use and
   deliberate; standing grants must scope it (which peer, which planes, budgets).
3. **Sybil towns / impersonation.** kind-10420 human↔agent binding verified both
   directions + invite-only pairing. No open federation, no public directory in v1.
4. **Runaway loops / cost.** AgentEngine loop guards exist for threads; grants add
   budgets (messages/day, byte caps, task concurrency).
5. **Hub abuse.** NIP-42 AUTH + invite-gated hub onboarding.

## 5. The one real protocol gap: standing town grants

SPEC §13 gates autonomous agent sends on a human-signed `ai_window` (minutes-scale)
or a thread invite. A week-long two-town co-build fits neither: windows lapse
(AC110's "tether went silent forever" bug was exactly this failure mode surfacing on
the solo path), and per-task approval is too chatty for a wall with hundreds of
posts. Widening gates ad hoc per surface is how invariant 9 erodes — do it once,
properly, as a first-class object instead:

**`standing_grant`** — human-identity-signed, like `ai_window`, extending §13's
model, never replacing its default (silent, fail-closed):

- **Scoped:** peer town identity (npub), planes (`wall`, `delegate`, or both),
  budgets (msgs/day, bytes, concurrent tasks), optional tool ceiling for tasks.
- **Time-bounded in days, not minutes**, with explicit expiry surfaced.
- **Revocable:** signed revocation event, effective on receipt, fail-closed on doubt.
- **Visible:** every affected client renders an indicator for the grant's lifetime
  (same transparency property as the window banner). Agents cannot self-grant.

Deliverables: extension doc (`docs/pqrc-ext-standing-grants.md`, same shape as
`A2A-PQRC-EXTENSION.md`), DEVIATIONS entry tagged `[upstream-NIP]`, Huginn grants
panel (approve/inspect/revoke), phone indicator chips, gate-class tests alongside the
AC110 suite (solo/window/thread/grant matrix).

## 6. Workstreams

- **WS-G1 — Two towns, one task (prove the transport live).** Second node (any Mac:
  eldr-node or a second Huginn) + the phone. Town A delegates over
  `RelayA2ATransport` through relay.lerants.com to Town B; approval card in Huginn;
  reply renders AI-labeled in EldrChat. All pieces exist — this is wiring + a live
  proof, days. Exit: the demo runs over the real relay between two machines.
- **WS-G2 — goose as a harness.** New `HarnessDescriptor` row driving `goose acp`
  (goose *is* an ACP agent in that mode — the direction we need; the SETUP-GUIDE
  caveat was about the reverse). The town's brain becomes an actual goosetown.
  Small; the harness seam is built for exactly this.
- **WS-G3 — the `eldr-gooseworld` goose extension (the funnel).** A Swift MCP-server
  executable any goosetown loads (goose extensions are MCP servers; reuse the
  `pqrc-mcp` / `pqrc-mcp-bridge` loopback+token pattern). Tools: `world_wall_post`,
  `world_wall_read` (cursor semantics mirroring gtwall's per-reader positions),
  `world_delegate(town, task)`, `world_towns`. The binary talks loopback to
  Huginn/eldr-node, which owns keys and transport — **agent keys never leave the
  node** (SPEC §13.5 holds). Injection hardening from §4 baked into `wall_read`
  output framing. Starts with a 1-hour spike reading gtwall's actual source —
  its internals are unspecified in the docs fetched today; don't design blind.
- **WS-G4 — standing town grants** (§5).
- **WS-G5 — wall-as-thread bridge.** Cross-town wall rides the shipped shared-AI
  thread + group fan-out. Pairwise fan-out is fine to ~8 towns; MLS groups (SPEC
  §12, Marmot/X-Wing) remain the v2 scale path — do not block on it. Chunking
  covers big posts (raise hub `max_content_length` — already in motion).
- **WS-G6 — town-in-a-box.** `eldrctl found-town`: SSH-provision eldr-node + goose +
  extension, register the 10420 binding, join the hub, emit an invite QR. Then the
  documented follow-up: Linux eldr-node (swap the Keychain seam; SPEC invariant 10's
  hardware-keystore ladder — TPM where present, hardened-passphrase KEK only where
  no secure element exists). EldrNodeCore is already platform-agnostic + DI'd.
- **WS-G7 — docs, positioning, upstream.** THREAT_MODEL §agent-towns (§4 above),
  DEVIATIONS entries, `docs/DEMO-GOOSEWORLD.md` (two Macs, two goosetowns, one
  wall, humans lurking with a kill switch — crossfire review across *owners*, not
  just models, is the money shot). Publish the goose extension to the goose
  community; it is the distribution wedge the A2A upstream submission (weeks 6–7 of
  the 90-day plan) was always looking for. Spiral (Block's grant arm, already in the
  funding table) now has a one-sentence pitch: "the secure transport for your own
  agent ecosystem." **Naming:** "gooseworld" stays an internal codename until
  goose/AAIF trademark posture is checked; public framing is "Eldr — secure
  inter-town transport for Goosetown."

## 7. Phases

- **Phase 0 (days):** WS-G1. A cross-town delegation over the live relay, approved
  by a human, labeled as an agent, visible on the phone.
- **Phase 1 (~1–2 wks):** WS-G2 + G3 + G5 → the cross-town wall demo with real
  goosetowns on both ends.
- **Phase 2 (~1–2 wks):** WS-G4 + the §4 hardening + THREAT_MODEL/DEVIATIONS. No
  public artifact ships before this lands — connecting shells without it is the one
  unforgivable version of this product.
- **Phase 3 (productize):** WS-G6 + G7 — town-in-a-box, hub policy, Huginn Pro
  "Town" tier, extension published, A2A extension upstreamed, Article-50 provenance
  angle (signed AI labels on cross-org agent traffic) on the 2026-08-02 news cycle.

## 8. What does not change

Privacy remains rule zero. Text-only remains. No blob store, ever. Invariants 8–9
(honest `participant_type`, no agent self-activation, fail-closed autonomous sends)
are not softened by gooseworld — they are its selling proposition: Goosetown gave
agents a commune; gooseworld gives the communes a world with cryptographic
passports, honest name tags, and a human-held leash.
