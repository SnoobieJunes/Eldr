# Plan — EldrChat as a secure, universal ACP router

## Context

The earlier confusion: you connected LM Studio to EldrChat's chat and expected the chat AI to drive Xcode, but the chat path has no tools and the ACP coding agent (`eldr-acp`) is driven by Xcode, not the chat — two unrelated paths to the same model.

The real product is bigger and cleaner than "give the chat a brain." **EldrChat is a secure, universal ACP _router_** — the user's primary interface and communication layer — while the actual coding is delegated to interchangeable, swappable ACP harnesses (Xcode ACP Agent, OpenClaw, Claude Code, Codex, Gemini CLI, OpenCode, Cursor, future ACP tools). OpenClaw is **one backend, not the foundation**. ACP is to agents what HTTP is to the web; EldrChat speaks it to everything.

**EldrChat owns:** identity, end-to-end encryption, the secure transport, session history, notifications, device-to-device connectivity, the chat UX, permission/consent, and the **router** that targets a backend.
**The harness owns:** the model, the tools, and the actual development work.

**Why a router, not an OpenClaw competitor:** (1) no vendor lock-in — any new agent that speaks ACP (or can be adapted) becomes a selectable backend with no redesign; (2) best tool per job — Claude Code for big refactors, Codex for generation, Gemini CLI for multimodal, OpenClaw for orchestrated sessions, Xcode ACP for native Apple dev, all behind one interface; (3) industry alignment — ACP is becoming the standard for agent comms much as HTTP did for the web. OpenClaw remains a strong early backend (session management, multi-agent orchestration, mature workflows, memory) — it's a first integration target, not the base.

### Architecture (with prompts in / results out)

```
   ░ USER PROMPT IN ░                                       ░ RESULTS / STREAM OUT ░
        │                                                            ▲
        ▼                                                            │
  ┌──────────────────────── iPhone / Android ──────────────────────────────┐
  │ EldrChat — identity · E2EE · session history · notifications ·          │
  │            device connectivity · ROUTER (pick a backend)                │
  │   prompt ─▶ ACP client: session/prompt      session/update ─▶ bubbles   │
  └──────────────────────────────┬────────────────────────────▲────────────┘
                                  │  SECURE TRANSPORT           │  E2EE, peer-authenticated
                                  │  Multipeer (no-WiFi) / LAN  │
                                  │  peer = VERIFIED PQRC id    │
                                  ▼                             │
  ┌────────────────── Eldr Node (Mac / server / Pi) ───────────────────────┐
  │ Node host: authenticate peer → decrypt → forward ACP                    │
  │            surface permission prompts to the node owner                 │
  │      │  ACP over stdio (spawns / connects the chosen harness)  ▲        │
  │      ▼                                                         │        │
  │  ┌──── selectable ACP backend = execution engine ─────────────────────┐│
  │  │ Xcode ACP · OpenClaw · Claude Code · Codex · Gemini CLI · OpenCode  ││
  │  │ · built-in eldr-acp (bring-your-own-model)                          ││
  │  │   runs model + tools: edit files · xcodebuild · xcrun simctl        ││
  │  └─────────────────────────────────────────────────────────────────────┘│
  └─────────────────────────────────────────────────────────────────────────┘
```

- **Prompt in:** user types in EldrChat → ACP `session/prompt` → secure transport → node → harness.
- **Results out:** harness streams `session/update` (assistant text, tool_call lifecycle, build output) → node → secure transport → EldrChat chat bubbles. Permission asks surface to the **node owner** (the machine being acted on consents).

### Key design decisions
- **EldrChat phone = ACP client; the Eldr node = a secure ACP bridge/proxy.** The node authenticates the phone's PQRC identity, terminates the encrypted transport, and forwards ACP JSON-RPC to a locally **spawned harness over stdio** (and surfaces permission prompts). The node interprets little ACP itself — it pipes the verified, decrypted stream both ways. This is the embryonic "Eldr node."
- **The built-in `eldr-acp` is just one backend** (the bring-your-own-model reference harness); external harnesses bring their own models, so per-provider model wiring is now **optional**, not headline.
- **Remove MCP** — ACP supersedes it.

## Reusable pieces already in the repo (reuse, don't rebuild)
- ACP agent + tool loop + JSON-RPC: `Packages/PQRCACP/Sources/PQRCACP/{ACPAgent,ToolExecutor,ClientConnection,LLMClient}.swift`; binary `Sources/eldr-acp/main.swift`. The agent has **no hard stdio dependency** — `OutputSink` abstracts outbound; inbound is `handle(line:)`.
- Multipeer + zero-trust handshake: `Packages/PQRCNostr/Sources/PQRCNostr/{MultipeerLinkTransport,MultipeerNearbyLink,NearbyRelayHub}.swift` + `NearbyLink`/`LocalLinkSimulator` seam — challenge-response identity proof binds a peer to a verified PQRC identity (this is the router's authn for free).
- Multipeer-AI precedent: `App/PQRC/Engine/NearbyHubAIProvider.swift`, `ConfiguredAI.kind == "hub"` ("Nearby host's AI (Multipeer)").
- Config/consent/firewall: `App/PQRC/Engine/ConfiguredAI.swift`, `AISettingsView.swift`.
- Test seams: `LocalLinkSimulator`, `MockLLMClient`, `EchoLLMClient`, `FixedClock`, `SeededRandomSource`, `ChaosMatrixTests` approach.

## Engineering work (mapped to your product roadmap)

### Build now = Phase 1 (EldrChat + Xcode ACP + OpenClaw) + the routing scaffold

**Phase 1 definition of done** (prove the architecture, not every agent): secure remote access phone→Mac · end-to-end encrypted comms · ACP session creation · streaming responses · basic task execution · **Xcode ACP Agent** backend · **OpenClaw** backend. Workflow: Phone → EldrChat → Mac → (Xcode ACP | OpenClaw); user sends instructions, monitors progress, approves actions, and receives results from anywhere.

1. **Decouple ACP from stdio (transport seam).** `ACPTransport` abstraction: outbound via `OutputSink`, inbound via `AsyncStream<String>` of JSON-RPC lines; a transport-agnostic `runACPAgent`/`runACPProxy` driver. Keep `eldr-acp` working as the stdio transport. Files: new `Packages/PQRCACP/Sources/PQRCACP/ACPTransport.swift`; refactor `eldr-acp/main.swift`.

2. **ACP client (phone).** `ACPClient` actor: `initialize`/`session/new`/`session/prompt`, parse `session/update` into a UI stream, answer `session/request_permission`. Files: `Packages/PQRCACP/Sources/PQRCACP/ACPClient.swift`.

3. **Eldr node host + secure bridge (Mac).** A small host that: accepts a verified-identity connection from EldrChat over the secure transport, decrypts, and **spawns/forwards** to a chosen local ACP harness over stdio; surfaces permission prompts to the node owner; keeps the harness registry. Backends for Phase 1: **Xcode ACP Agent** and **OpenClaw** (both already speak ACP), plus built-in `eldr-acp`. Files: new `Packages/PQRCACP/Sources/eldr-node/` (host) + a backend descriptor type (`how to launch/connect each harness`).

4. **Secure transports for ACP.** Carry the ACP line stream over (a) **LAN/TCP** (dev/wired) and (b) **Multipeer** (no-WiFi) by riding the verified `NearbyLink` peer (extend `LinkPayload` with an `acp` channel), reusing `MultipeerLinkTransport`'s identity proof so the peer is a verified PQRC identity. Files: new `MultipeerACPTransport.swift` (+ LAN variant); small extension to `MultipeerLinkTransport.swift`.

5. **Router UI + backend model.** Evolve `ConfiguredAI` into a selectable **ACP backend** ("Current agent: Xcode / OpenClaw / …") with per-backend node + transport + identity. Wire the chosen backend into the chat so a chat message becomes a `session/prompt` and updates render as bubbles. Files: `App/PQRC/Engine/ConfiguredAI.swift`, new `App/PQRC/Engine/ACPRouter.swift` + `ACPBackendProvider.swift`, `App/PQRC/Engine/PersonaRuntime.swift`, `App/PQRC/Views/Settings/AISettingsView.swift`.

6. **Remove MCP.** Delete `Packages/PQRCMCP/` (pqrc-mcp, pqrc-mcp-bridge, MCPServer, tests), `App/PQRC/Engine/{LocalMCPServer,RuntimeSecureChatBridge}.swift`, MCP settings, Xcode/package refs; salvage redaction/byte-bound logic into the ACP egress firewall if useful. Update `SETUP-GUIDE.md`, `USER-GUIDE.md`, `APP-SPEC.md` §24, `TEST-PLAN.md`.

7. **Zero-trust / permission / privacy.** Gate sessions to verified, paired identities (self-devices or accepted contacts); reject unproven peers. Permission policy for mutating tools (`write_file`/`run_shell`) surfaced to the node owner with allow/deny + remember. Off-device consent + optional egress firewall for any cloud-backed harness. Document the new trust boundary in `docs/THREAT_MODEL.md` and `docs/DEVIATIONS.md` (supersede A35/A36; note §13 scoping now that ACP rides Multipeer/identity).

### Scaffolds that make Phases 2–4 drop-in (build the seams now, not the integrations)
- Backend registry is data-driven, so **Phase 2** harnesses (Claude Code, Codex, Gemini CLI, OpenCode, Cursor) register as descriptors with no architecture change.
- A `Router` indirection so **Phase 3** intelligent routing (task-type → engine) is a policy swap.
- The node host is a standalone process so **Phase 4** (Eldr nodes on Macs/servers/Pis) is "run the host on another machine."

## Diagnostic tooling (your explicit asks)
- **Agent Inspector** (DEBUG + opt-in): live ACP session view — prompt sent, full `session/update` stream, each tool call + result + permission decision, and (for the built-in agent) the raw brain request/response incl. `finish_reason`/`stop_reason`, token counts, errors. Files: extend `App/PQRC/Support/Log.swift`; new `App/PQRC/Views/Settings/AgentInspectorView.swift`; structured events from `ACPClient`/node.
- **Nearby Multipeer scanner** (NEW): a diagnostic that browses for nearby MultipeerConnectivity advertisers — lists discovered peers/service types, connection state, and whether *this* device is advertising — so you can answer "is my Mac node broadcasting and does the phone see it?" Reuse `MCNearbyServiceBrowser`/the `NearbyLink` seam; testable headlessly via `LocalLinkSimulator`. Files: new `App/PQRC/Views/Settings/NearbyScannerView.swift` + a browse helper in PQRCNostr.
- **Ring-buffer event log**: bounded, privacy-safe (metadata/phases only, no payloads at rest — CLAUDE.md invariant 12).

## Intermittent-failure hardening
- Stop swallowing provider errors: `AgentEngine.runThreadTurn`/`runWindowReply` (`AgentEngine.swift:233`,`:271`) `try?` the provider — surface typed errors to UI/inspector instead of the AI going silent.
- Retry/backoff for 429/5xx in `OpenAICompatibleLLMClient` and the phone chat providers; inspect `stop_reason`/`finish_reason` for `max_tokens` truncation and empty-after-reasoning-strip; make `max_tokens` configurable.

## Test plan (headless-first)
- **ACP round-trip (no radios):** `ACPClient ↔ node ↔ agent` over an in-memory transport (reuse `LocalLinkSimulator`): initialize → session/new → prompt → streamed updates → end_turn; tool calls; permission grant/deny; cancel.
- **Backend swap:** same task against built-in `eldr-acp` and a stub external harness; identical client behavior.
- **Transport chaos:** ACP session through `LocalLinkSimulator` chaos (drop/dup/reorder/jitter) + mid-turn disconnect; no deadlock, clean failure + recovery.
- **Zero-trust:** unproven/unverified peer cannot open a session; mutating tool blocked without permission.
- **Nearby scanner:** simulated advertisers are discovered/listed; no payload leakage (extend `SecuritySuiteTests`).
- **Provider robustness:** 429/5xx retried; truncation/empty surfaced not swallowed.
- **MCP removal regression:** all packages/targets build green with PQRCMCP gone.
- Frameworks: Swift Testing for logic (`swift test` headless on PQRCACP/PQRCAgent/PQRCNostr); `xcodebuild test` for app + UI smoke of the inspector, scanner, and coding-agent chat.

## Verification (end-to-end)
1. `swift test --package-path Packages/PQRCACP` (+ PQRCAgent, PQRCNostr) green incl. new ACP round-trip + chaos + scanner tests.
2. Manual: phone EldrChat → pick **Xcode ACP** backend → ask it to list files, read one, then `xcodebuild`/`xcrun simctl` a project on the Mac; confirm streamed tool calls, a permission prompt on the Mac, and real build output in the chat — first over LAN, then over Multipeer with WiFi off.
3. Switch the backend to **OpenClaw**; re-run the same task; confirm identical EldrChat UX.
4. Open the **Agent Inspector** and the **Nearby Multipeer scanner**; confirm the session events and that the phone sees the Mac node advertising.
5. `xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat` green with PQRCMCP removed.
