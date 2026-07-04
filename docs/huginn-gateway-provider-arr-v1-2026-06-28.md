# Huginn ↔ SybilClaw: Why "Provider" Is the Wrong Abstraction ARR v1-2026-06-28

**Version:** v1 — 2026-06-28 08:30 PDT
**Orchestrator:** Agent: Gaho — deepseek/deepseek-v4-pro (cloud, OpenRouter)
**Sub-agent:** (none — direct investigation)
**Human in the loop:** Garrett Kinsman

---

## 1. Executive Summary

Huginn cannot be added as a config-level "gateway provider" because **provider** and **gateway client** are two different layers in OpenClaw's architecture, with two different extension mechanisms. Provider = channel plugin (Node.js extension, configurable). Gateway client = WS handshake identity (hardcoded allowlist, NOT configurable). Huginn needs the right client-side identity values — no gateway config changes are required.

The fix is **0 lines of gateway config** and **2 string constants** in `SybilclawGatewayClient.swift`.

---

## 2. The Two Layers

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 1: Message Channels (CONFIGURABLE)                    │
│  Discord, Signal, Telegram, iMessage, WebChat...              │
│  → Registered via plugins.entries in openclaw.json            │
│  → Each has a channel id: "discord", "signal", "telegram"    │
│  → This is what "provider" means                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  LAYER 2: Gateway WebSocket Clients (HARDCODED)              │
│  webchat-ui, cli, openclaw-macos, probe, test...             │
│  → Validated at WS handshake by a JSON Schema constant       │
│  → NOT configurable — baked into protocol-ZUWop5o6.js        │
│  → This is what Huginn connects as                           │
└─────────────────────────────────────────────────────────────┘
```

**"Provider" = Layer 1.** Gateways don't have providers. Gateways have **clients** that connect via WebSocket, and those clients send messages through **channels**. The channel is the routable thing. The client is just the transport.

Huginn is a **Layer 2 client** that routes messages through a **Layer 1 channel**. It doesn't need a new provider — it needs to use the right client identity in its WS handshake.

---

## 3. What Huginn Is vs. What Provider Means

### Provider (Layer 1)

A provider is a channel plugin — a Node.js module loaded by the gateway at startup:

```json
// openclaw.json
{
  "plugins": {
    "entries": {
      "discord": { "enabled": true },
      "signal": { "enabled": true }
    }
  }
}
```

Providers handle:
- Connecting to external messaging APIs (Discord REST/WS, Signal Protocol, etc.)
- Receiving inbound messages from users on those platforms
- Sending outbound agent replies back through those platforms
- Session lifecycle per-platform

**OpenClaw ships with ~15 provider plugins** (Discord, Signal, Telegram, WhatsApp, iMessage, Slack, etc.). They're all battle-tested, configurable, and route through the gateway's message channel system.

### Gateway Client (Layer 2)

A gateway client is **any process that opens a WebSocket to the gateway and sends the `connect` handshake**. This is what Huginn does. The client must identify itself with:

```json
{
  "type": "req",
  "id": "c1",
  "method": "connect",
  "params": {
    "minProtocol": 1,
    "maxProtocol": 1,
    "client": {
      "id": "<one of 13 hardcoded values>",
      "mode": "<one of 7 hardcoded values>",
      "version": "0.1.0",
      "platform": "darwin",
      "deviceFamily": "macos_desktop"
    },
    "device": {
      "id": "<ed25519 public key fingerprint>",
      "publicKey": "<base64>",
      "signature": "<ed25519 signature of challenge nonce>",
      "signedAt": 1782410000000,
      "nonce": "<challenge nonce>"
    }
  }
}
```

---

## 4. Why Not Both? Could Huginn ALSO Register a New Channel?

Yes — but it doesn't help. Huginn already routes through Discord's channel. Adding a new channel called `"eldrchat"` would require:

1. A **Node.js channel plugin** registered in `openclaw.json`
2. That plugin implementing inbound/outbound message delivery
3. Huginn connecting to the gateway as a WebSocket client AND consuming events from that new channel

This is a full plugin development effort (hundreds of lines of Node.js) when the actual goal — "send messages from EldrChat → gateway → agent → reply" — already works with the existing channel system.

The `channel` parameter in Huginn's `chat.send` RPC call determines which channel the message routes through. The channel MUST be one the gateway already has loaded (like `"discord"`). Adding a new channel just for EldrChat means maintaining a parallel delivery system that does the same thing.

---

## 5. The Gateway Client ID Allowlist (EXACT)

Found at `/opt/homebrew/lib/node_modules/sybilclaw/dist/message-channel-D9VoYxIv.js`:

### Valid Client IDs (GATEWAY_CLIENT_IDS)

| Value | Meaning |
|-------|---------|
| `webchat-ui` | WebChat UI (browser) |
| `openclaw-control-ui` | Control UI |
| `openclaw-tui` | Terminal UI |
| `webchat` | WebChat client |
| `cli` | CLI client |
| `gateway-client` | Peer gateway |
| `openclaw-macos` | macOS app |
| `openclaw-ios` | iOS app |
| `openclaw-android` | Android app |
| `node-host` | Node host |
| `test` | Test client |
| `fingerprint` | Fingerprint client |
| `openclaw-probe` | Probe client |

### Valid Client Modes (GATEWAY_CLIENT_MODES)

| Value |
|-------|
| `webchat` |
| `cli` |
| `ui` |
| `backend` |
| `node` |
| `probe` |
| `test` |

### Validation Code

```javascript
// These are TypeBox → AJV compiled schemas — JSON Schema validation, NOT a config lookup
const GatewayClientIdSchema = Type.Union(
  Object.values(GATEWAY_CLIENT_IDS).map((value) => Type.Literal(value))
);
const GatewayClientModeSchema = Type.Union(
  Object.values(GATEWAY_CLIENT_MODES).map((value) => Type.Literal(value))
);
```

The error `"must be equal to constant; must match a schema in anyOf"` occurs when Huginn sends a `client.id` or `client.mode` that isn't in these hardcoded sets.

### How Client Identity Affects Routing

The client ID/mode combination controls how the gateway treats the connection:

```javascript
// isGatewayCliClient checks: normalizeGatewayClientMode(client?.mode) === "cli"
// Used to enable CLI-specific routing (mainKey inheritance, session scope)
function isGatewayCliClient(client) {
  return normalizeGatewayClientMode(client?.mode) === GATEWAY_CLIENT_MODES.CLI;
}

// isWebchatClient checks: mode === "webchat" OR id === "webchat-ui"
// Used for webchat-specific session handling
function isWebchatClient(client) {
  if (normalizeGatewayClientMode(client?.mode) === GATEWAY_CLIENT_MODES.WEBCHAT) return true;
  return normalizeGatewayClientName(client?.id) === GATEWAY_CLIENT_NAMES.WEBCHAT_UI;
}
```

---

## 6. Recommended Client Configuration for Huginn

```
client.id:    "openclaw-macos"    (macOS app identity — closest match to Huginn's nature)
client.mode:  "backend"           (backend service, not interactive CLI)
client.platform: "darwin"
client.version: "0.1.0"
```

Alternatively, for simplicity:
```
client.id:    "cli"
client.mode:  "probe"
```

Either combination passes validation. The `"backend"` mode specifically identifies Huginn as a bridge/relay, not an interactive terminal.

---

## 7. Summary: "Provider" vs. "Client" — Final Answer

| Question | Answer |
|----------|--------|
| Can Huginn be a config-level "provider"? | **No.** "Provider" = channel plugin. Huginn is not a messaging channel — it's a transport bridge. |
| Could we build Huginn as a channel plugin? | Yes, but it's the wrong abstraction — hundreds of JS lines for what already works via WS RPC. |
| Does Huginn need a gateway config change? | **No.** The fix is Swift-side: pick a valid `client.id` + `client.mode` from the allowlist. |
| Does it replace Discord? | It can route through Discord's channel (current path) OR create a separate `"eldrchat"` channel via channel param. Neither requires erasing Discord. |
| What breaks if we try to add `"eldr"` to GATEWAY_CLIENT_IDS? | It's a compiled constant — requires forking SybilClaw itself, rebuilding, and maintaining a fork. |

---

## 8. Artifacts

| File | Location |
|------|----------|
| Client ID/Mode registry | `/opt/homebrew/lib/node_modules/sybilclaw/dist/message-channel-D9VoYxIv.js` |
| Connect params JSON Schema | `/opt/homebrew/lib/node_modules/sybilclaw/dist/protocol-ZUWop5o6.js` (line ~1206) |
| WS handshake validator | `/opt/homebrew/lib/node_modules/sybilclaw/dist/server.impl-BJOssgVm.js` (line ~10913) |
| Gateway config (channels) | `sybilclaw.json` → `plugins.entries` |
| Huginn client code | `SybilclawGatewayClient.swift` (in Huginn source repo) |

---

## References

All files examined on this machine during investigation:
- `/opt/homebrew/lib/node_modules/sybilclaw/dist/message-channel-D9VoYxIv.js` — Client ID/Mode constants and validation
- `/opt/homebrew/lib/node_modules/sybilclaw/dist/protocol-ZUWop5o6.js` — ConnectParamsSchema (line 1206), AgentParamsSchema (line 175)
- `/opt/homebrew/lib/node_modules/sybilclaw/dist/server.impl-BJOssgVm.js` — WS handshake handler (line 10913)
- `/opt/homebrew/lib/node_modules/sybilclaw/dist/chat-7UmP5OOj.js` — Session routing (isWebchatClient/isGatewayCliClient)