# WS-I7 — "Connect my AI to a Buzz workspace" (Huginn GUI flow + plan)

Status: **BUILT — 2026-07-24 (AC146)** · both paths, Phases 1–4 · engine
prerequisite (`EldrBuzzGateway` + `eldr-buzz-agent`, AC144) was already proven.

> **What shipped vs. this plan.** Everything below is implemented, in Huginn's
> new **Connections** tab, plus three things the plan didn't foresee:
>
> 1. **The status row is a contract, not log-scraping.** `BuzzGatewayStatus` /
>    `BuzzGatewayCounters` (in **PQRCNostr**, the one module both the gateway and
>    Huginn link) define the `ELDR-BUZZ-STATUS {json}` lines the gateway emits and
>    the supervisor folds. Both directions are unit-tested, and the loopback E2E
>    asserts the GUI's counters against the real emitter.
> 2. **Path B's snapshot was wrong and is fixed.** Buzz's `definition.provider` is
>    a provider **ID** projected into `GOOSE_PROVIDER`, not a base URL — AC144's
>    generator emitted `http://127.0.0.1:1337/v1`, which would import cleanly and
>    then never answer. It now emits `lmstudio` (a real goose provider) and the UI
>    surfaces the `LMSTUDIO_HOST=…` line to paste, because Buzz deliberately
>    excludes env vars from snapshots.
> 3. **§8 build-order item 1 (verify B1) is answered from source** (Buzz's
>    `discovery.rs` + goose's provider metadata), not from a GUI click — see §8.
>
> **Verified:** all 8 package suites, EldrChat 104/104, and the Huginn suite —
> including the 11 new tests, which caught two real bugs on their first run (an
> asymmetric date strategy that would have emptied the connections file on every
> relaunch, and a missing-binary check that reported a raw spawn error instead of
> the actionable one). The Huginn suite must be run with the Mac **unlocked**:
> these tests write real `WhenUnlockedThisDeviceOnly` Keychain items, so a locked
> screen fails them — and six pre-existing Keychain tests — with
> `errSecInteractionNotAllowed`.
>
> **Not done:** a live run against a hosted Buzz workspace (needs the owner's nsec
> and a real workspace).

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

## 5. Open decisions — resolved when this was built (AC146)

1. **Entry point placement** → a dedicated top-level **Connections** tab, as
   recommended. It is a distinct outbound capability (this Mac joining someone
   else's workspace), not part of the phone tether.
2. **Where it runs** → Mac/Huginn only, as written. The phone shows nothing yet;
   a read-only status mirror there is future work, not a gap in this flow.
3. **Owner-key handling** → **(b), a one-time paste**, unconditionally. Option (a)
   was rejected on inspection rather than preference: Huginn's stored identity is
   the *node's* PQRC/Nostr identity, which is not the Buzz *workspace owner's*
   account key, so "read it from the Keychain if it's the same key" would be true
   approximately never and would invite the user to attest with the wrong key. The
   pasted key signs the NIP-OA attestation in memory and is then dropped —
   verified by a test that asserts it never appears in the connections file.
   What persists is the auth tag (a signature) and the owner's public key.
4. **Default persona** → shipped as `BuzzConnection.defaultSystemPrompt`, which
   states where the agent runs, tells it to answer concisely and admit
   uncertainty, and tells it never to repeat credentials into the channel (the
   prompt-level companion to the egress firewall). Step 3's text box is
   pre-filled with it, so most users can skip past.

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

## 8. Build order (both paths) — done, with B1 answered

1. **B1 verified from source, not a screenshot (2026-07-24).** Buzz's agent
   dialog does expose a **Custom provider…** field
   (`desktop/src/features/agents/ui/AgentConfigFields.tsx`,
   `CUSTOM_PROVIDER_DROPDOWN_VALUE`), and the value is a provider **ID** that Buzz
   projects into `GOOSE_PROVIDER` at spawn
   (`desktop/src-tauri/src/managed_agents/discovery.rs`: the `goose` runtime's
   `provider_env_var`). goose's own `lmstudio` provider resolves
   `base_url = ${LMSTUDIO_HOST}/v1/chat/completions`. So the exact recipe is:
   **runtime `goose`, provider `lmstudio`, model = the loaded model id, and
   `LMSTUDIO_HOST=http://127.0.0.1:1337`** (already present in this machine's
   `~/.config/goose/config.yaml`, so nothing else is needed here). No Eldr code is
   required for B1 — and Huginn's "Add to Buzz" panel now writes exactly this
   snapshot and shows that env line with a Copy button.
2. **Path A Phase 1–4 (the Eldr product):** built — see §4 and the status note at
   the top.
3. **B2 (`eldr-acp` as the Buzz runtime) not built, deliberately.** B0/B1 reach
   the Agents tab with no Eldr code and no ACP-version wrinkle; B2's only added
   value is running Eldr's own harness there, which the ACP `protocolVersion ≥ 2`
   gap makes strictly more fragile. Left as a documented option, not a shipped
   path.

---

## 6. Definition of done for WS-I7

- [x] A user with zero terminal use connects a local model to a Buzz workspace —
  wizard → minted+attested agent key → supervised gateway — all from Huginn.
  *(The end-to-end `@mention`→reply path is the one AC144 proved live against a
  real relay and the real local model; the GUI drives that same binary. A live run
  of the GUI flow against a hosted workspace still needs the owner's nsec.)*
- [x] Pause/Disconnect/Remove work; Remove publishes an agent-signed retirement
  (kind:0 tombstone + NIP-09 kind:5 deletion request) and destroys the key.
- [x] The E2EE-termination disclosure is shown and acknowledged before first
  send — and the gateway refuses to start without it (fail closed).
- [x] Gateway logs stream to the existing console (`LogConsoleSource.buzzGateway`,
  one file per connection); the status row shows live reply/token counts folded
  from the gateway's own status lines.
- [x] Huginn tests cover `BuzzGatewayService` lifecycle with no network — a fake
  `eldr-buzz-agent` script drives start → connected → counters → stop, plus the
  fail-closed gates, the child environment, key mint/rotate/destroy, and the
  attestation. **Green** — and they caught two real bugs doing it (see the status
  note at the top).
- [x] Phase 4: per-connection agent keys + a Rotate action, and the egress
  firewall (`CredentialRedactor`) on every outbound reply.
