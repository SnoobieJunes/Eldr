# WS-N10 — Huginn for Linux (Phase B)

**Owner:** Grok Bot (agent), for Auston.
**Exit condition:** this plan leaves `docs/plan/` when every row below is **done** or
**n/a** (with its DEVIATIONS row), and the WS-N10b leftovers are closed or declined.
Backlog: `BACKLOG.md` WS-N10 / WS-N10b. Written 2026-10-13.

Package: `Apps/HuginnLinux` (**AGPL-3.0-only**, like `Apps/Huginn`; AC203).
- `HuginnCore`: UI-free services, tested on Linux.
- `huginn-cli`: headless front end and the launcher's secret helper.
- `huginn-gtk`: GTK 4 app on EldrLinux's `GtkKit`, now a library product.

Launcher: `Apps/HuginnLinux/scripts/huginn` builds what is missing (release) and starts
the app. `--cli …` runs the CLI instead. `scripts/install-desktop.sh` adds
`~/.local/bin/huginn` and a `.desktop` entry.

Labels: *proven* means a test or live run showed it. *compile-checked* means it builds
on Linux but nothing exercised it. *unverified* means design or inference only.

## Audit: Apps/Huginn feature by feature

| Mac feature (source) | Linux status | Evidence / note |
|---|---|---|
| Configuration (`ConfigurationStore`, `ConfigurationView`): endpoint, model, token, agent limits, tools, skills, preamble, system prompt, learning, ungated, vision, cloud delegation | **done**: GTK Configuration tab and `huginn-cli config` | *proven*. A unit test does save → `AgentConfig.fromEnvironment` round-trip. bash `source` round-trip with hostile values (nothing executed). Live: the GTK tab shows the keystore token. |
| Context-graph settings (`ContextGraphSection`) | **partial**: persisted (env keys round-trip), no GTK fields | WS-N10b |
| Keychain secrets (`KeychainBox`), Secure-Enclave metadata key (`MacSecureEnclaveKeyWrapper`) | **done, Linux form**: EldrKeystore `huginn` profile (TPM/systemd-creds, else scrypt passphrase). The B2 key is minted at random and kept in the keystore. | *proven*: unit tests cover the ladder (refuses with no source) and key stability. Live: the launcher's eldr-acp sealed `events.jsonl`. SE wrapping is **n/a** (AC204). |
| Installer + launcher (`InstallerService`) | **done**: copies eldr-acp, huginn-cli, eldr-node and eldr-buzz-agent to `~/.local/bin` (0755) and writes `eldr-acp-launch` | *proven*: a unit test covers env, secrets, exec and the stderr log. Live: a real ACP session through the launcher against a mock LLM, token from the keystore (`Bearer live-toke…` at the server). |
| LLM health (`LLMHealthChecker`) | **done**: Check endpoint, `huginn-cli health` | *proven* live: 2 models listed. A missing token gives 401 by mock design. |
| Test Chat (`TestChatSession`, `TestChatView`) with approvals, timeout deny, auto-approve, reset fail-closed | **done**: GTK tab and `huginn-cli chat` | *proven*: 6 tests on the real ACPAgent. Live GTK: typed a prompt, clicked Approve, file written. Live CLI: auto-approve writes; unanswered request times out and is denied. |
| Inspector (`AgentInspectorView`, `InspectingLLMClient`) | **partial**: raw-stream capture of the last turn plus project memory | Live GTK screenshot. Per-request LLM inspector not ported (WS-N10b). |
| Project memory (`ContextLearner`, `ProjectMemorySection`) | **done**: polling learner (AC206) with a persisted offset | *proven*: 4 tests (failed command, session end, user edit after write_file, sealed at rest, expiry, no re-learn across processes). Live: correction learned from a real eldr-acp `run_shell` failure. |
| Logs (`LogTailer`, `LogConsoleView`, `DiagnosticsLog`) | **done**: Logs tab with filters and copy, `huginn-cli logs` | *proven*: a tailer test (partial lines, truncation, classification). A GTK first-render bug was found live and fixed. |
| Bridge (`ACPBridgeService` / `ACPRelayHost` / `ACPNodeHost`) | **done, Linux form**: supervises `eldr-node` (AC207) | *proven* live: GTK Start → node published keys on relay.lerants.com with owner = test identity n5. Quitting the app stopped it; nothing left running. Phone-driven turn *unverified* in this run. |
| Buzz (`BuzzConnectionStore`, `BuzzGatewayService`, wizard) | **done**: GTK Buzz tab and `huginn-cli buzz` | *proven*: unit tests (attestation, keys only in the keystore, child-env rules, tolerant decode) and the gateway loopback E2E now on Linux. Live: eldr-buzz-agent runs on Linux, dials over NIO, status lines parsed. A real Buzz workspace is *unverified*. |
| Relay provisioner (`RelayProvisioner`, `RelayWizardView`) | **done**: Relay tab and `huginn-cli relay-script` (Mac code, verbatim) | *proven* by unit test |
| World (`WorldStatusClient`, `WorldView`, `WorldMapView`) | **done**: World tab cairo map and `huginn-cli world` | *proven*: unix-socket test (token-first, wrong token → noResponse). Live: GTK map with 3 towns from a test socket. |
| Town grants editor (`TownGrantsView`) | **missing** | WS-N10b |
| Harness registration (`HarnessRegistration`): acpx / OpenClaw | **done** | *proven* by test (idempotent, backup, deferred while gateway running) |
| Xcode registration | **n/a**: Zed `agent_servers` instead (AC208) | *proven* by test. A JSONC settings file is never rewritten; the snippet is copied instead. |
| Setup wizard, enterprise tour | **partial**: Setup tab (install + register + n/a notes), no step-by-step wizard or tour | WS-N10b |
| A2A server host, MCP client launcher | **missing** on Linux hosts (SwiftA2A/PQRCMCP build, AC172) | WS-N10b |
| Pending-approval notifications | **missing**: approvals show inline only | WS-N10b |
| MLX + fine-tune guide | **n/a**: Apple silicon only. Point the endpoint at llama.cpp, Ollama or vLLM. | AC210 |
| Nearby scanner (Multipeer) | **n/a** | AC210 |
| Menu-bar / status-bar extra | **n/a**: no portable tray on GTK 4. Status line in the window. | AC210 |

## WS-N10b leftovers

Owner: Grok Bot. Exit condition: each item below has a test and its row above is done, or is declined in DEVIATIONS.

- Context-graph fields in GTK.
- Per-request LLM inspector.
- Town-grants editor.
- Setup wizard and tour.
- A2A / MCP host wiring.
- Approval notifications.
- Live Buzz-workspace check.
- Phone-driven bridge turn.
- macOS compile check of the BuzzGateway transport change (AC205).
