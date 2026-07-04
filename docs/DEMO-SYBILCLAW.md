# DEMO-SYBILCLAW.md — running the Eldr × sybilclaw demo

How to wire EldrChat/Eldr to a **sybilclaw** install for the funder demo, with every
step marked for *who* (or *what*) performs it. The goal: drive an AI agent on a Mac
running sybilclaw, securely, eventually from a phone over Eldr's post-quantum E2EE relay.

This is **staged** so there is always a working fallback:
- **Stage 0 — install + register** (✅ works today): get `eldr-acp` registered into
  sybilclaw, crash-safely, and drive it locally.
- **Stage 1 — phone → `eldr-acp` over the relay** (🚧 in development): the reliable
  remote path.
- **Stage 2 — phone → sybilclaw's *own* assistant via a Gateway bridge** (🚧 in
  development): the headline.

> **Honesty:** Stage 0 is implemented and build-verified. Stages 1–2 describe the target
> and are in active development — do not present them as working until this doc says so.

---

## Legend — who runs each step

| Tag | Who | Safe to do while the gateway is busy? |
|---|---|---|
| **[human]** | You, physically — Gatekeeper approval, plugging in / QR-pairing a phone, GUI clicks | n/a |
| **[agent]** | sybilclaw's own agent, via its shell/file tools | ✅ yes — these never touch the watched gateway config |
| **[controlled]** | A deliberate gateway-config change that **reloads/restarts the gateway** | ❌ **no** — do it only when you're not mid-task |

> **The cardinal rule of this integration:** *never hot-edit a running gateway's config.*
> sybilclaw's gateway watches `~/.sybilclaw/sybilclaw.json` and, by default, **restarts**
> on a change it can't hot-apply — which kills the live session (the crash you saw).
> Huginn enforces this for you; if you do it by hand, follow the **[controlled]** rule.

---

## What you need

- A Mac (Apple Silicon) already running **sybilclaw** (its gateway daemon, default
  `:18789`).
- **Huginn.app** — the Eldr agent cockpit (build the notarized DMG with
  `Apps/Huginn/build-dmg.sh`; see `docs/SIGNING-AND-DISTRIBUTION.md`).
- A local, OpenAI-compatible LLM (LM Studio / Ollama / vLLM) for `eldr-acp`.
- *(Stages 1–2 only)* an iPhone running EldrChat.

---

## Stage 0 — install + register (works today)

1. **[human]** Install Huginn — open the DMG, drag to Applications, approve Gatekeeper on
   first launch.
2. **[human / agent]** Connect the LLM — in the wizard's first step, or **[agent]** by
   writing `~/.config/eldr-acp/env` (`ELDR_LLM_URL`, `ELDR_LLM_MODEL`; token goes in the
   Keychain via the GUI).
3. **[human / agent]** Install the binary + launcher — the wizard's *Install* step copies
   `eldr-acp` and the `eldr-acp-openclaw` launcher into `~/.local/bin`. An **[agent]** can
   run the equivalent copy itself.
4. **Register — crash-safely** (the wizard's *Register* step, harness = **sybilclaw**):
   - **[agent]** The agent **command** is written to acpx's own
     `~/.acpx/config.json` (`agents.eldr = { command: <launcher>, args: [] }`). This file
     is **not** watched by the gateway, so it's safe anytime — no restart.
   - **[controlled]** For the *gateway* to use `eldr`, it also needs the acpx plugin
     enabled + `eldr` in `acp.allowedAgents` inside `~/.sybilclaw/sybilclaw.json`. Huginn
     writes this **automatically only if the gateway is down**. If the gateway is **up**,
     Huginn does **not** touch it — it shows you the exact JSON to paste, which you apply
     when idle (then the gateway reloads).
5. **[agent]** Verify — `sybilclaw /acp doctor` (or its list-agents command): `eldr` should
   appear and be allowed.

### The exact register moves (if doing it by hand / via the agent)

**Safe anytime** — `~/.acpx/config.json`:
```json
{ "agents": { "eldr": { "command": "/Users/<you>/.local/bin/eldr-acp-openclaw", "args": [] } } }
```

**[controlled] — only when the gateway is idle** — merge into `~/.sybilclaw/sybilclaw.json`
(preserve existing keys), then restart the gateway:
```json
{
  "acp": { "allowedAgents": ["eldr"] },
  "plugins": { "entries": { "acpx": { "enabled": true,
    "config": { "agents": { "eldr": {
      "command": "/Users/<you>/.local/bin/eldr-acp-openclaw", "args": [] } } } } } }
}
```
Back up first; the gateway reloads on the change. Restart it via your service manager
(e.g. `launchctl kickstart -k gui/$(id -u)/<sybilclaw-service>`) **when not mid-task**.

### Verify locally (works today): sybilclaw drives `eldr-acp`

**[human]** Start an ACP session with the `eldr` agent through sybilclaw / acpx. Ask it to
read or write a file or run a shell command — you should see `eldr-acp` execute the tool
and reply. That's the local half of the demo already working end-to-end.

---

## Stage 1 — phone (EldrChat) → `eldr-acp` over the relay  🚧 wired + headless-tested; not yet run on two devices

**What it is:** EldrChat on your phone drives the Mac's `eldr-acp` over Eldr's post-quantum,
end-to-end-encrypted relay — the reliable path. Phone = ACP client; Huginn on the Mac hosts
the agent (`ACPRelayHost`), admitting only the owner's frames (the C-3 gate).

**Status — honest:** the bridge LOGIC is wired on both sides and proven headlessly
(`RelayCarriedACPE2ETests`, `RelayACPHostTests`), and the production messaging seam exists
(`PQRCMessengerMessaging` over the live `PQRCMessenger`, DEVIATIONS **AC25**). At runtime it
stays **fail-closed**: the bridge's default `BridgeMessaging` is `UnpairedMessaging`, which
**throws on send until the live two-device PQXDH pairing handshake completes**
(`startMessagingNode`) — and that live pairing has **not yet been run on two physical
devices** (it can't be exercised headlessly). Do not present this as "working" until you've
done a real 2-device run (below).

**Run it (2 devices, all [human]):**
1. **Mac / Huginn:** open the **EldrChat Bridge** tab → **Enable bridge** → set the
   **owner** to your phone's identity and pick the **project folder**. It shows a QR /
   "Copy pairing link" (`pqrc:add?npub=…&type=coding_agent`). Make sure the LLM is
   reachable (Connections panel) — the relay-ACP host stays off (fail-closed) without a
   pinned owner and a usable model.
2. **Phone / EldrChat:** New conversation ▸ paste the npub, or **open the pairing link**
   from the QR — scan it with the **system Camera app** (EldrChat has no built-in scanner
   yet) or AirDrop/paste the `pqrc:add?npub=…&type=coding_agent` link. The contact is
   tagged `coding_agent`.
3. **Phone:** open that conversation ▸ **Details** ▸ **Mac agent control** ▸ toggle
   **"Drive this agent from here"** — this sets `remoteDevControlConsent` and binds the
   live relay-ACP provider. (Optionally allow autonomous file/shell changes.)
4. **Phone:** in the conversation, open an AI window and type a coding task ("list the
   files in the project"). **Success:** the Mac's `eldr-acp` runs the tool and the result
   streams back to the phone — over the relay, which only ever carries kind-1059
   ciphertext.

---

## Stage 2 — phone → sybilclaw's own assistant via the Gateway bridge  🚧 handshake corrected + unit-locked; live 2-device round-trip still unrun

**What it is:** your phone's chat reaches **sybilclaw's own assistant** (its model, persona,
memory, tools) — *not* eldr-acp, and **no eldr-acp LLM is used**. The phone's message rides
the E2EE relay to Huginn; Huginn forwards it to sybilclaw's local **OpenClaw Gateway** (a
typed-frame WebSocket protocol — `req`/`res`/`event`, **not** JSON-RPC — default :18789); the
reply comes back over the relay. The cockpit is sybilclaw's; Eldr is the private network the
phone reaches it over.

**How it's wired (corrected 2026-06-28, commit `c64386c`):** `SybilclawGatewayClient` +
`SybilclawAgentRunner` (a `BridgeAgentRunner`) swapped in when **Mac-side responder =
"sybilclaw assistant"**. The owner's chat hits `handleInboundPrompt` (C-3 owner gate +
redaction + timeout — all reused from Stage 1) → the runner drives the gateway → the reply is
sent back. The gateway turn is: (1) a mandatory **`connect`** handshake declaring
`client.id="openclaw-macos"`, `client.mode="backend"`, `role="operator"`, scopes, protocol
range `[3,4]` (values ON the gateway's allowlists — the earlier off-allowlist ids were
schema-rejected on every connect); (2) **`chat.send`** `{sessionKey, message, idempotencyKey}`,
which acks immediately with `{runId, status:"in_flight"}`; (3) the reply **streams as `event`
frames correlated by `runId`** — assistant text on `event:"agent"` (stream "assistant",
cumulative `payload.data.text`), terminating on an `event:"chat"` whose `payload.state` is
`final`/`error`/`aborted`. An agent is targeted by encoding it into the key as
`agent:<id>:<sessionKey>` (there is no `agentId` field). Switching the responder re-wires the
live runner with no restart. Two client copies exist (Huginn app + headless `eldr-node`) —
their protocol framing is pinned by `GatewayHandshakeTests` and `SybilclawGatewayFramingTests`
so they can't silently drift (DEVIATIONS AC73).

**Run it (builds on the Stage 1 pairing):**
1. **[human] Mac / Huginn:** pair the phone (Stage 1 steps 1–2). In the **EldrChat Bridge**
   tab, set **Mac-side responder → "sybilclaw assistant"**. Confirm sybilclaw's gateway is
   running (the Connections panel shows it green on the configured port).
2. **[human] Phone:** in the paired conversation, with your AI window on, just chat — your
   messages are forwarded to sybilclaw's assistant and its replies come back over the relay.

**⚠️ Still unverified (the one thing not testable headlessly):** the **live round-trip against
a running gateway on two physical devices**. The handshake, `chat.send` params, and the
event-stream reply parser were corrected against the fork's own reference clients
(rdevaul/sybilclaw apps/ios + android) and are now locked by unit tests
(`GatewayHandshakeTests`, `GatewayReplyTests`, `SybilclawGatewayFramingTests`) — so the earlier
"confirm the method/params on his gateway" caveat is retired; the framing is grounded, not
guessed. What remains is exercising it end-to-end on real hardware. A "didn't reply in time" on
a chat is the signal to turn on opt-in gateway **diagnostics** (Bridge ▸ diagnostics; logs the
token-redacted `connect` handshake + the gateway's raw reply, never the prompt/reply text) and
compare against the gateway's own logs.

---

## Troubleshooting

- **"Registering crashed my sybil agent."** Something hot-edited the **running** gateway's
  config, forcing a restart. Use Huginn's deferred-JSON flow: apply gateway-config changes
  only when the gateway is **down/idle** (the **[controlled]** rule).
- **"sybilclaw doesn't see `eldr`."** Confirm `acp.allowedAgents` contains `"eldr"` and the
  gateway reloaded; confirm the launcher path is executable (`chmod +x`).
- **"Which config file?"** Stock sybilclaw reads `~/.sybilclaw/sybilclaw.json`; standalone
  `acpx` reads `~/.acpx/config.json`. Huginn writes **both** as needed, so either entry
  point finds the agent.
