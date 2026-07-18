# A2A integration — architecture, runbook, threat notes

Eldr speaks **A2A v1.0** (Agent2Agent, Linux Foundation) for *agent↔agent* task
delegation. **ACP stays the phone↔agent protocol** — A2A is complementary
(A2A = delegating a task to an opaque peer agent; ACP = a client driving a coding
agent with permission cards/terminals). Deviations: `DEVIATIONS.md` AC95–AC101.

## The pieces

| Piece | Where | What |
|---|---|---|
| SwiftA2A SDK | `Packages/SwiftA2A` | Clean-room A2A v1.0: `A2ACore` (wire model, fixture-pinned to `a2a.proto` + spec JSON), `A2AClient` (JSON-RPC + SSE over URLSession, card resolver), `A2AServer` (transport-agnostic core, task state machine), `A2AHTTPServer` (loopback-only NWListener, bearer on every route). Zero non-Apple deps — built for extraction + proposal to a2aproject as the official Swift SDK. |
| Outbound delegation | `Packages/PQRCACP` | `HarnessKind.a2aRemote` + `HarnessTransportFactory` seam; `A2AHarness` target's `A2AACPBridge` presents a remote A2A agent as an ACP harness, so `delegate_to_cloud_agent` (both WS3e gates + WS3f consent, unchanged) and the Bridge harness picker can target A2A agents. Text-only part bounds enforced in the bridge (urls never fetched, raw >32 KB skipped). |
| Inbound serving | `Apps/Huginn` | `A2AServerHost`: OFF by default, Keychain bearer token, card built from the selected harness, **per-task human approval** (deny/timeout → `REJECTED`), nested tool permissions default-deny. |
| E2EE binding | `Packages/PQRCNostr` + `docs/A2A-PQRC-EXTENSION.md` | `RelayA2ATransport` tunnels A2A JSON-RPC over the gift-wrapped Double-Ratchet relay stream (`A2A1\|…` frames, never cross-routing with `ACP1`/`MCP1`). The extension profile (URI `https://eldr.app/ext/a2a-pqrc-e2ee/v1`) replaces well-known discovery with in-band card exchange and OAuth with the kind-10420 binding. The publishable artifact for upstream. |

## Wire facts that will bite you

- v1.0 JSON-RPC method names are the **proto RPC names** (`SendMessage`, `GetTask`,
  `SubscribeToTask`, …) — NOT 0.3's `message/send`. Empty `A2A-Version` header means
  0.3 and is rejected (AC98).
- Enums serialize as full proto names (`TASK_STATE_WORKING`, `ROLE_AGENT`); fields are
  lowerCamelCase proto3-JSON; `Part` is a strict oneof (`text`/`raw`/`url`/`data`).
- Fixtures frozen from the spec live in `Packages/SwiftA2A/Tests/A2ACoreTests/Fixtures/`;
  round-trip tests pin every spelling. Change nothing by memory — re-freeze from
  `github.com/a2aproject/A2A` if the spec moves.

## Interop runbook (manual gate, not CI)

```bash
# 1. Official sample agent (Python ≥3.10):
git clone https://github.com/a2aproject/a2a-samples && cd a2a-samples/samples/python/agents/helloworld
uv run .        # serves on http://localhost:9999

# 2. Outbound: Huginn → Bridge → harness "A2A Agent (local sample)" (registry id
#    a2a-local-sample, card http://127.0.0.1:9999/.well-known/agent-card.json),
#    then delegate from the phone — expect the delegation consent card, then the reply.

# 3. Inbound: Bridge → "A2A serving" toggle ON, copy the bearer token, then:
curl -s http://127.0.0.1:<port>/.well-known/agent-card.json \
  -H "Authorization: Bearer <token>" -H "A2A-Version: 1.0"    # → card JSON (401 without token)
# POST a SendMessage the same way; approve the task in Huginn's pending list.
```

## Threat notes (summary — THREAT_MODEL.md still governs)

- **Serving is a new inbound surface**: mitigations are loopback-only bind (socket-level
  pin), bearer-on-every-route incl. the card, off-by-default, per-task approval,
  default-deny nested tool permissions. Softening any of these is a DEVIATIONS decision.
- **Webhook push is refused permanently** (client address leak — AC95).
- **Remote A2A agents see whatever you delegate**: the task text is the leak; the
  distinct delegation consent exists exactly so this is a deliberate per-use choice.
- **Card signatures are not yet verified** (AC99): card trust currently equals transport
  trust. HTTPS/bearer locally; kind-10420 peer verification over PQRC.

## CLI quickstart — talking to the served agent from a terminal (verified 2026-07-18)

Any local process (Claude Code, a script, another agent) can drive the served
agent once **Bridge ▸ Serve A2A** is on. The bearer token mirrors once into the
login keychain for exactly this use (first `security` read prompts once —
Always Allow):

```bash
TOKEN=$(security find-generic-password -s chat.eldr.huginn -a a2a-server-bearer-token -w)
H=(-H "Authorization: Bearer $TOKEN" -H "A2A-Version: 1.0" -H "Content-Type: application/json")

# Send (non-blocking). WITHOUT returnImmediately the JSON-RPC response blocks
# until the task is terminal (spec behavior) — always pass it from a CLI.
curl -s "${H[@]}" http://127.0.0.1:41252/a2a -d '{
  "jsonrpc":"2.0","id":1,"method":"SendMessage",
  "params":{"configuration":{"returnImmediately":true},
            "message":{"role":"ROLE_USER","parts":[{"text":"…"}]}}}'
# → result.task.id; then poll (result IS the task object):
curl -s "${H[@]}" http://127.0.0.1:41252/a2a -d '{
  "jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"<task-id>"}}'
# → result.status.state == TASK_STATE_COMPLETED, reply in result.artifacts[].parts[].text
```

Per-task approval applies unless **Auto-approve inbound tasks** is on
(are-you-sure-confirmed; tool use inside tasks still follows Security ▸
ungated-tools). The reverse direction — the LOCAL model tasking a cloud agent —
is `delegate_to_cloud_agent` (harness `claude-code` → `claude-agent-acp`,
using the `claude` CLI's own login); it requires an LLM server whose tool-call
output mlx-lm can parse (see LOOP-STATE 2026-07-18: Qwen3-Coder-Next's XML
grammar does not parse; Qwen3.6-27B's classic format does).
