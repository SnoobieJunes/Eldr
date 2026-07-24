# WS-I7 — "Connect my AI to a Buzz workspace" (Huginn GUI flow + plan)

Status: **design / not started** · 2026-07-24 · prerequisite: the engine
(`EldrBuzzGateway` + `eldr-buzz-agent`, AC144) is built and proven; this is the
GUI that makes it usable without a terminal.

> **Why this exists.** Everything shipped so far is the *engine and the proof*.
> A real user must never type a command. This doc specifies the Huginn screens,
> the architecture (reusing infra that already exists), and a phased build so
> "put my local model in a Buzz workspace as an agent" is a few clicks.

## 0. Two paths (decided: build BOTH)

There are two distinct meanings of "my local model is a Buzz agent", and the
owner chose to support **both**:

- **Path A — Huginn-owned (the gateway).** Our `eldr-buzz-agent` connects
  directly to the relay as an authenticated member and posts/replies in
  channels. Huginn owns its lifecycle. It carries Eldr's value (per-agent key,
  the road to PQ-secure/cross-town transport) but it does **NOT** appear in Buzz
  Desktop's **Agents tab** — Buzz never spawns or manages it (it's an external
  member, like Buzz's own `countdown-bot`). Sections 1–6 below specify this.
- **Path B — Buzz-owned (the Agents tab).** Buzz Desktop spawns and manages the
  agent (start/stop/persona there, like Bumble/Fizz/Honey) and uses Huginn's
  local model as its brain. Specified in §7.

They are complementary, not either/or: Path A is the Eldr product; Path B meets
the user where Buzz already has an agent-management UI. Build order in §8.

---

## 1. The user's mental model

> "My AI can join a chat workspace like a teammate. It runs on **my** machine,
> answers when mentioned, and I can pause or remove it any time. What it says
> inside that workspace is visible to whoever runs the workspace — my private
> Eldr chats are not."

Everything below serves that sentence.

---

## 2. The flow (5 steps, one sheet)

Entry point: Huginn gets a **Connections** section (sibling to the MLX and
Relay sections). Primary button: **"Connect an AI to a workspace"**. It opens a
wizard modeled on the existing `RelayWizardView` / `SetupWizardView`.

**Step 1 — Which workspace?**
- Field: workspace relay URL (e.g. `wss://auston.communities.buzz.xyz`), or pick
  a saved one. A "Test connection" button runs the reachability + AUTH-challenge
  probe (the `LiveBuzzRelayProbe` logic) and shows ✓/✗ with the relay's name from
  NIP-11 — so the user sees it's real before going further.
- Membership: two radio options.
  - **"I own/admin this workspace"** → the app owner-attests the agent (NIP-OA)
    using the owner's key. This is the tonight-proven path.
  - **"I was invited"** → paste an invite/membership token (Phase 3).

**Step 2 — Which model?**
- A picker populated from Huginn's own models (`MLXService` already enumerates
  downloaded/running models). Show status dots (downloaded / running / not
  loaded) and let the user Start one inline if needed. Default: the currently
  running model on `:1337`.

**Step 3 — Agent identity & behavior**
- Display name (the `@mention` trigger, default "Eldr"), an avatar, a short
  persona/system prompt (a text box; sensible default provided), the channel(s)
  to join, and a respond-to policy (default: **mentions only**).

**Step 4 — The honest disclosure (required checkbox)**
- A banner, not a footnote:
  > **Messages your AI posts into this Buzz workspace are readable by the
  > workspace's relay operator.** Buzz channels are signed but not
  > end-to-end encrypted. Your Eldr↔Eldr chats stay encrypted; this bridge does
  > not. Run this only in workspaces you trust with that content.
- Reuses the transparency posture of the `ai_window` banner. The checkbox is the
  same shape as the existing egress-consent gates.

**Step 5 — Connect**
- The app: (a) mints a fresh agent Curve25519/secp256k1 keypair into `KeychainBox`
  as `buzzagent.<id>` (SE-wrapped via `MacSecureEnclaveKeyWrapper`, invariant 10);
  (b) computes the NIP-OA attestation with the owner key (used once, never
  stored by the gateway); (c) writes a `BuzzConnection` record to
  `ConfigurationStore`; (d) starts the gateway as a managed child process.

**Running state — a status row** (in Connections, mirroring `MLXView`'s server row):
`● Eldr (local Qwen3.6) — auston.communities.buzz.xyz — 4 replies · 1.2k tokens today`
with controls: **Pause / Disconnect**, **View logs** (opens `LogConsoleView`
filtered to this agent), **Edit persona**, **Remove** (signed revocation +
Keychain delete). Token/cost numbers come free from the NIP-AM metrics the
gateway already emits.

---

## 3. Architecture — what to reuse, what to add

The engine exists; the GUI is a thin wrapper over infra Huginn already has.

| Need | Reuse (exists) | Add |
|---|---|---|
| Run/monitor the gateway process | **`MLXService`** already manages a local server child process (start/stop/restart, published terminal buffer, `managed` persistence) — clone its lifecycle shape into a `BuzzGatewayService` | `BuzzGatewayService: ObservableObject` that spawns `eldr-buzz-agent` and mirrors `MLXService`'s start/stop/restart/log-tail |
| Agent keys at rest | **`KeychainBox`** (save/load/delete/hasItem) + **`MacSecureEnclaveKeyWrapper`** | `buzzagent.<id>` accounts; owner key never persisted by the gateway |
| Config persistence | **`ConfigurationStore`** | a `BuzzConnection` model (relay, channels, agentKeyRef, persona, model, respondTo) — mirror `managed-agents.json` shape for familiarity |
| Logs | **`LogConsoleView` / `LogStore` / `LogTailer`** — the gateway already writes structured stderr | a per-connection log filter |
| Wizard UI | **`RelayWizardView` / `SetupWizardView`** patterns | `BuzzConnectWizardView` (the 5 steps above) |
| Model endpoint | **`MLXService`** owns the `:1337` (or selected) endpoint | pass its URL to the gateway as `ELDR_LLM_URL` |
| Reachability/AUTH test | **`LiveBuzzRelayProbe`** logic (PQRCNostr) | surface as the "Test connection" button |

**Process vs in-process.** Recommend **managed child process** (`eldr-buzz-agent`),
not the in-process `BuzzGateway` actor: it reuses `MLXService`'s proven
crash/restart/log handling, isolates a wedged model turn from the UI, and
survives independently — exactly why Huginn already runs MLX as a child. The
in-process actor stays available for tests.

**Data flow (unchanged from the engine):**
```
Buzz relay ─WS─ eldr-buzz-agent (managed child) ─HTTP─ MLXService :1337
   ▲   Huginn: BuzzGatewayService supervises it, streams logs, shows status
   └── signed kind:9 reply + NIP-AM/AO to owner
```

---

## 4. Phased plan

**Phase 1 — MVP (owner path, one channel).**
`BuzzConnectWizardView` (steps 1,3,4,5 minimal) → mint+attest agent → spawn
`eldr-buzz-agent` via a `BuzzGatewayService` cloned from `MLXService` → a status
row with Disconnect. Model = whatever `MLXService` is running. Proves the whole
loop in-GUI. *Est: 2–3 days.*

**Phase 2 — Model picker, persona, logs, disclosure.**
Step 2 model picker wired to `MLXService`; persona editor; the required
disclosure gate; per-connection `LogConsoleView`; multi-channel join. *Est: 2–3 days.*

**Phase 3 — Membership beyond owner + lifecycle.**
Invite-token path (non-owner members); signed **revocation** on Remove
(reuse the standing-grant revocation machinery); NIP-AM usage surfaced as a
token/cost counter in the status row; multiple simultaneous Buzz connections. *Est: 3–4 days.*

**Phase 4 — Privacy polish.**
Per-agent key rotation-per-peer (the metadata concern in INTEROP-LANDSCAPE §5.1),
and wiring the existing per-chat **egress firewall** to the bridge send so the
owner controls what context may cross into a Buzz channel. *Est: 2–3 days.*

---

## 5. Open decisions (for the owner)

1. **Entry point placement** — a dedicated top-level "Connections" section in
   Huginn (recommended; this is a distinct outbound capability), vs. folding into
   the existing Bridge/Relay area.
2. **Where it runs** — this is a **Mac/Huginn** capability: Huginn hosts the local
   model (`:1337`) and supervises the gateway, so the connect flow lives in
   Huginn. The iPhone app shows the connection's status read-only, if anything.
3. **Owner-key handling in the GUI** — the owner key signs the attestation once.
   Options: (a) read it from Huginn's existing identity Keychain if the same key,
   (b) a one-time paste that's used and discarded. (Recommend (a) when the Huginn
   identity *is* the Buzz owner; else (b).)
4. **Default persona** — ship a good default so most users skip Step 3's text box.

---

## 7. Path B — Buzz-managed agent (appears in the Agents tab)

The complement to Path A: **Buzz Desktop** owns the agent (spawns it, manages it,
shows it in the Agents tab), and it uses Huginn's local model as its brain. Two
ways to wire the brain — try B1 first:

**B0 — generate a Buzz agent snapshot and import it (the chosen mechanism).**
Buzz has a portable **`buzz-agent-snapshot` v1** manifest (`.agent.json` or
`.agent.png`) it imports to create a managed agent — the clean, programmatic way
to register one. Eldr now generates it: `BuzzAgentSnapshot.forLocalModel(…)`
(PQRCNostr) emits JSON matching Buzz's schema EXACTLY (verified in
`BuzzAgentSnapshotTests`), pre-wired with `runtime: goose`, `provider:
http://127.0.0.1:1337/v1`, the local model id, persona, and `respondTo`. Import
opens Buzz's Edit-agent draft pre-filled (the owner's screenshot) → Save → a
managed agent in the Agents tab, brained by Huginn. Secrets/keys/relay are
absent by design — Buzz fills those on import. **Huginn wiring:** an "Add to
Buzz" button that calls the generator with the running model's provider/model
and writes the `.agent.json` for the user to import (or drops it where Buzz
watches). This supersedes B1/B2 below as the primary path.

**B1 — point a Buzz agent's provider at the local model (possibly zero Eldr code).**
Buzz managed agents carry a `backend` (`local` or `Provider{…}`), a runtime
(`goose`/`claude`/`codex` via `agent_command`/`agent_command_override`), and
`BUZZ_AGENT_PROVIDER` / `BUZZ_AGENT_MODEL`. If Buzz's `Provider` backend accepts a
custom base URL, create an agent in Buzz Desktop with runtime **goose** (goose
speaks OpenAI-compatible local endpoints) pointed at **`http://127.0.0.1:1337/v1`**
+ the loaded model. It then lives in the Agents tab, managed by Buzz, brained by
Huginn — pure Buzz config + Huginn serving the model.
**→ First action: check whether Buzz Desktop's "create agent" screen exposes a
base-URL / custom-provider field.** If yes, B1 is done with no code.

**B2 — `eldr-acp` as the runtime (Eldr's owned code in the Agents tab).**
Register a Buzz managed agent with `agent_command_override = eldr-acp` (proven:
it answers the buzz-acp ACP handshake `initialize → session/new → session/prompt`).
Buzz spawns it; it drives `:1337` and appears in the Agents tab. **One wrinkle:**
`buzz-acp` forwards its base prompt (the `buzz messages send` reply convention)
only to agents advertising ACP `protocolVersion ≥ 2`; `eldr-acp` advertises v1.
Fix — either (a) set `ELDR_ACP_CONTEXT_FILE` to a small file carrying the buzz-CLI
reply instructions so the model learns to reply, or (b) bump `eldr-acp`'s
advertised protocol version to 2. Small, tractable; the deliverable is a
one-screen "Register in Buzz" helper in Huginn that writes the managed-agent
entry (relay, attested agent key, `agent_command_override=eldr-acp`,
`ELDR_LLM_URL=:1337`) and the context file.

Path B needs **no channel-membership dance** — Buzz Desktop adds its own managed
agents to channels through its existing UI (the same way Bumble/Fizz/Honey
joined), which is also the answer to Path A's channel-membership gate: the owner
adds the agent to channels in Buzz, or the agent creates its own channel.

---

## 8. Build order (both paths)

1. **Verify B1 (minutes, no code):** check Buzz Desktop's create-agent screen for
   a custom base-URL/provider field → if present, the Agents-tab goal is met by
   config today; document the exact steps.
2. **Path A Phase 1 (the Eldr product):** the Huginn gateway MVP (§4 Phase 1).
3. **Path B2 helper:** the "Register in Buzz" one-screen writer + the eldr-acp
   protocol-version/context-file fix — so Eldr's own code can live in the Agents
   tab even where B1 isn't available.
4. Path A Phases 2–4.

---

## 6. Definition of done for WS-I7

- [ ] A user with zero terminal use connects a local model to a Buzz workspace,
  sees it appear as an agent, `@mention`s it, and gets a reply from their own
  machine — all from Huginn.
- [ ] Pause/Disconnect/Remove work; Remove emits a signed revocation and deletes
  the key.
- [ ] The E2EE-termination disclosure is shown and acknowledged before first send.
- [ ] Gateway logs stream to the existing console; status row shows live
  reply/token counts.
- [ ] Huginn test suite covers `BuzzGatewayService` lifecycle (mirroring the
  `MLXServerLifecycle` tests) with no real network (fake transport/relay sim).
