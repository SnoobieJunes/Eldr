# WS-N — native Linux parity with EldrChat (iOS/Mac) and Huginn (Mac)

**Owner:** Auston (solo; agent-assisted).
**Exit condition:** this plan leaves `docs/plan/` when every row below marked
**missing** or **partial** is either closed by a DEVIATIONS entry or declined in
one (with the reason). Each WS-N item that lands gets its own AC row.

Written 2026-10-13. Backlog entry: `BACKLOG.md` §B1 (EldrLinux row).
Linux surfaces: `eldr-chat` (CLI), `eldr-gtk` (GTK 4 via C, AC164), `eldr-node`
(agent daemon), `eldr-acp`, `eldrctl`. No non-Apple deps; swift-nio is allowed.

> **Labels (CLAUDE.md truthful reporting).** *proven*: a test or live run this
> session shows it. *compile-checked*: it builds on Linux but nothing exercised it.
> *unverified*: design or inference. Apple-side behaviour is read from source. It
> is **not** run here, because xcodebuild can't run on this box.

## Matrix: EldrChat (App/PQRC)

| Feature (iOS/Mac source) | Linux status | Plan |
|---|---|---|
| 1:1 PQ messaging, chunked large text, history | **done**: CLI + GTK (AC156–AC163, *proven* live) | — |
| Message requests (accept/decline) | **done**: CLI + GTK (*proven*) | — |
| Stale-session recovery / explicit reconnect | **done** (AC165–AC167, AC169; *proven* live) | — |
| Markdown rendering + paste of any size | **done**: GTK (AC169, *proven* by unit tests and a screenshot) | — |
| AI-account sponsorship issue/revoke/badge | **done** (AC162, AC168; *proven*) | — |
| **Group chats** (`createGroup`/`reviseRoster`, D1) | **done (WS-N1, AC173)**: CLI `group …`/`groups`, GTK sidebar + group conversations. *proven*: `GroupTests` and a live 3-identity run on relay.lerants.com | rename/leave done (AC176, *proven* by GroupTests) |
| Threads (`ThreadCreate`, D7) | **done (WS-N2, AC174)**: CLI `thread create|send|history`/`threads`, GTK thread rows. *proven*: AITests + live relay run, GTK sidebar screenshot | — |
| AI windows 1/8/24 h, `ai_invite`, loop guard (SPEC §13) | **done (WS-N2, AC174)**: AgentEngine wired into EldrClient; CLI `ai-window`/`ai-invite`/`ai-status`, GTK AI bar. *proven*: AITests; live relay window reply and in-thread invite reply with mock LLM | — |
| Standing grants / context grants / revocation | **done (AC183, AC184)**: town grants plus human/ai context grants, marks, and "what my AI sees". *proven* by unit tests | iOS 1:1 scope asymmetry *unverified* |
| LLM providers: OpenAI-compatible / Anthropic / Gemini / Groq / OpenRouter | **done (AC182)**: native kinds. *proven* mapping; real-API calls *unverified* | — |
| On-device Foundation Models / PCC / MLX | **n/a**: Apple-only (AC189). Linux equivalent: local OpenAI-compatible server via `custom` | — |
| Pairing link / QR | **done (WS-N4, AC175)** *proven* | — |
| Contacts management (rename, safety code, verify, block, pin, delete history) | **done (AC181)** *proven* | — |
| Settings | **done (WS-N5, AC176)** *proven* | — |
| Attachments | **done** for large text (chunking); blob `ContentPointer` **n/a** (blob server rejected, AC189) | — |
| Buzz workspaces / channels | **done (AC186)**: CLI + GTK. *proven* against the simulator; real workspace *unverified* | — |
| World / town view | **done as list (AC187)**; map **partial** | tech-debt |
| ACP approval cards / terminal | **deferred** with WS-N6 | WS-N6 |
| Onboarding tour | **done (AC188)**, generated from iOS | — |
| Coauthored send, per-thread loop guard, pin/verify markers | **done (AC184, AC185)** *proven* | — |
| State forward-compat (AC177) | **done (AC180)** *proven* | — |
| Unread/markRead, retry, mentions, multi-AI roster/critique, context mode, solo AI chat, relay status panel | **partial / missing** | Phase A follow-up (BACKLOG) |
| Multipeer / nearby | **n/a** (AC189) | — |

## Matrix: Huginn (Apps/Huginn, Mac)

| Feature | Linux status | Plan |
|---|---|---|
| Agent host over relay (ACPRelayHost/ACPNodeHost) | **done**: `eldr-node` (WS-L4, *proven* by the suite) | — |
| Configuration / setup / relay wizards | **partial**: `eldr-node` flags | WS-N9: an `eldrctl` subcommand or a GTK panel |
| Log console / diagnostics | **partial**: stderr/journald | — |
| Test chat | **done** in effect: `eldr-chat` against the node | — |
| MLX local models | **n/a**: Apple-only | WS-N3 covers local models via OpenAI-compatible servers (llama.cpp / Ollama) |
| A2A server, MCP client | **partial**: SwiftA2A and PQRCMCP *proven* on Linux (AC172); no Linux host wiring | WS-N9 |
| Buzz connections / gateway | **missing** | WS-N7 |
| Town grants / world view | **missing** | see the BACKLOG dashboard item |
| Nearby scanner | **missing**: no BLE/Bonjour on Linux | declined for now |
| Status bar / menu bar | **missing** | low priority (tray icons are desktop-specific) |

## Order

WS-N1 groups (**done**). Then WS-N2 threads + AI windows/grants/loop guard, WS-N3
providers, WS-N4 pairing/contacts, WS-N5 settings, then the rest.

## WS-N6: ELDR as an AI participant, and ELDR drives Xcode (added 2026-10-13)

Owner: ELDR (Linux agent). Exit: Phase 4 of `docs/guide/OWNER-TEST-PLAN.md` passes on Auston's Mac.

| Item | Status |
|---|---|
| External-agent bridge (AI account + inbox/outbox + `scripts/agent-bridge`, AC178) | **done**. *proven*: `externalAgentBridge_gatesOnSponsorshipOwnerAndLoopGuard`, plus a live relay run with n3 (owner) and the mock LLM covering turn-taking, the loop-guard stop, human resume and revocation. |
| Loop-guard default 50 (AC179) | **done**. *proven* by unit test. |
| Linux ACP-over-relay client (`RelayACPTransport` + `ACPClientDriver` on `EldrClient`, permission prompts surfaced to the bridge) | **missing**: blocks the Xcode phase. |
| A second driver for `eldr-node` (own instance, or a delegated-driver grant) | **missing / unverified** |
