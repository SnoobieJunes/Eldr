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
| **Group chats** (`createGroup`/`reviseRoster`, D1) | **done (WS-N1, AC173)**: CLI `group …`/`groups`, GTK sidebar + group conversations. *proven*: `GroupTests` and a live 3-identity run on relay.lerants.com | Linux has no member-leave and no rename yet → WS-N1b |
| Threads (`ThreadCreate`, D7) | **missing** | WS-N2: thread create/route in EldrClient, then CLI/GTK |
| AI windows 1/8/24 h, `ai_invite`, loop guard (SPEC §13) | **missing** (the AgentEngine library builds on Linux, AC172) | WS-N2: wire `AgentEngine` into EldrClient (sink = `deliver`), with CLI `ai-window` and a GTK "My AI responds" bar |
| Standing grants / context grants / revocation | **missing** | WS-N2 (shares the AgentEngine wiring) |
| LLM providers: OpenAI-compatible / Anthropic / Gemini / Groq / OpenRouter | **partial**: providers *compile-checked* on Linux (AC172); nothing calls them from a Linux UI | WS-N3: keys from env or the encrypted state (never argv), and `eldr-chat ai-config` |
| On-device Foundation Models / PCC | **n/a**: Apple-only | declined: not available on Linux |
| Pairing link / QR | **partial**: link copy + paste (*proven*); no QR | WS-N4: a QR encoder with no deps, rendered in GTK |
| Contacts management (rename, remove, safety code) | **partial**: add/list only | WS-N4 |
| Settings (relay list, display name, loop-guard limit) | **missing**: flags/env only | WS-N5: a GTK settings dialog over `ClientState` |
| Attachments (`ContentPointer`) | **missing**: the receive path only flags them | WS-N6 |
| Buzz workspaces / channels | **missing** | WS-N7: after the WS-BM Phase 2 decision |
| World map / town view | **missing** (AC155: no Linux dashboard) | covered by the existing BACKLOG B1 dashboard item; not duplicated |
| ACP approval cards / terminal | **partial**: `eldr-acp` CLI host (AC WS-L4) | WS-N8: GTK approval card |
| Onboarding tour | **missing** | low priority |

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
