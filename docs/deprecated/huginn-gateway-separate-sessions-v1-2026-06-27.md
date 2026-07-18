# Huginn Gateway — Separate Sessions from Discord

> **⚠️ SUPERSEDED (2026-07-03).** This is a planning/research artifact; its recommended fix
> ("Option B" — add `channel:"eldrchat"` + `dmScope:"per-channel-peer"` to `makeParams` on the
> `agent` RPC) is **NOT** what shipped. The shipped approach is an **opaque per-conversation
> `chat.send` sessionKey** (`eldr:<SHA256(salt‖conversationID)>`, agent targeted via
> `agent:<id>:<key>`) — see **DEVIATIONS AC69** and `ACPBridgeService.gatewaySessionKey`. No
> `dmScope` / `channel` / `per-channel-peer` / `makeParams` exists in the shipped client. Kept
> for history.

**Version:** v1 — 2026-06-27 18:20 PDT
**Orchestrator:** Agent: Gaho — deepseek-v4-pro (cloud)
**Human in the loop:** Garrett Kinsman

## Problem

Huginn/EldrChat and Discord DMs share the **same OpenClaw session**: `agent:gaho:direct:784460676068409394`. Every message from either app lands in the same conversation bucket. Context, history, and state are interleaved.

## Root Cause

The gateway's `buildAgentPeerSessionKey` generates session keys based on `dmScope` and `channel` params passed by the caller:

| Caller | Params Passed | Session Key |
|--------|--------------|-------------|
| Discord provider | `dmScope: "per-peer"`, `peerId: "784460676068409394"` | `agent:gaho:direct:784460676068409394` |
| Huginn `agent` RPC | `dmScope: "per-peer"`, `peerId: "784460676068409394"` | `agent:gaho:direct:784460676068409394` |

With `per-peer` scoping, the `channel` field is stripped — so no matter which path the message takes, it resolves to the same session key.

The global config is:
```json
// sybilclaw.json
"session": { "dmScope": "per-peer" }
```

## Where the Fix Lives

The session key is resolved from **params the caller passes**. Question: who controls those params?

### Option A: Gateway Config Change ❌ (Breaks Things)

Change `session.dmScope` from `"per-peer"` → `"per-channel-peer"`:

- Discord: `agent:gaho:direct:784460676068409394` → `agent:gaho:discord:direct:784460676068409394`
- Huginn: `agent:gaho:direct:784460676068409394` → `agent:gaho:unknown:direct:784460676068409394`

**These ARE separate.** But the Discord session key changes, which means **all existing Discord conversation history becomes orphaned** on the old key. New DMs start fresh.

### Option B: Huginn Changes Its Params ✅ (Clean)

Huginn passes two additional params in its `agent` RPC call:

```
channel: "eldrchat"
dmScope: "per-channel-peer"
```

Result:
- Discord stays: `agent:gaho:direct:784460676068409394`
- Huginn becomes: `agent:gaho:eldrchat:direct:784460676068409394`

**No gateway changes. No Discord history lost.** Just Huginn adding two params.

### Option C: Mixed Approach

Change gateway to `per-channel-peer` AND have Huginn pass `channel: "eldrchat"`:

- Discord: `agent:gaho:discord:direct:784460676068409394` (new key, history orphaned)
- Huginn: `agent:gaho:eldrchat:direct:784460676068409394` (new key)

Separate, but both lose existing session history. Could manually migrate JSONL session files.

## What Huginn Needs to Change

In `SybilclawGatewayClient.swift`, the `makeParams` function for `agent` calls:

```swift
// CURRENT
let params: [String: Wrapped] = [
    "agentId": .string("gaho"),
    "peerId": .string("784460676068409394"),
    "peerKind": .string("direct"),
    "dmScope": .string("per-peer"),
    "prompt": .string(message),
    // ...
]

// FIXED — add these two:
    "channel": .string("eldrchat"),
    "dmScope": .string("per-channel-peer"),
```

That's it. Two lines. No gateway-side changes needed.

## Response Streaming

Separately from session keys: once Huginn calls `agent`, the gateway **streams responses back through the same WebSocket connection**. If Huginn isn't showing responses in EldrChat, that's a Huginn-side issue (not consuming the event stream). The stream format is `{ "type": "event", "event": "agent.delta", "payload": { "text": "..." } }` — Huginn needs to listen for and render these events.

## Summary

| Can gateway config fix it? | Yes, but Option A breaks Discord history |
| Better approach? | Huginn passes `channel` + `dmScope: "per-channel-peer"` |
| Gateway code change needed? | None |
| Files to change? | `SybilclawGatewayClient.swift` in Huginn — 2 params |