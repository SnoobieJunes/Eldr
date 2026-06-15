# SETUP-GUIDE.md — building, running, and testing PQRC

End-to-end instructions for getting the project running and exercising the
two transports added by the S1/S2 stretch goals:

- **Local-first transport (S1)** — MultipeerConnectivity delivery between
  co-present devices (SPEC §10), with automatic relay fallback.
- **The PQRC relay server (S2)** — `pqrc-relay`, a localhost NIP-01 + NIP-42
  WebSocket relay, plus `NostrWebSocketTransport`, the real-network client.

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| macOS with Xcode 26.x | Swift 6.2 toolchain; the packages build with `swift test` on macOS directly |
| iOS 26.5 simulator runtime | Pin `OS=26.5` in destinations — machines with a beta runtime installed can silently resolve an ambiguous name to the beta |
| Two iPhones or iPhone+iPad (optional) | Only needed for real-radio Multipeer testing (§6) |
| An Apple Development team | The project uses automatic signing (`DEVELOPMENT_TEAM` is set in the pbxproj; change it to yours if needed) |

No third-party services are required for anything in this guide.

## 2. First build + the fast test loop (no simulator)

```bash
git clone <repo> && cd Eldr

# All protocol logic lives in SPM packages and tests headlessly:
swift test --package-path Packages/PQRCCore     # crypto, ratchet, PQXDH, vectors, SiloKey
swift test --package-path Packages/PQRCNostr    # envelope, transports, S1 local link, NearbyRelayHub, chaos matrix
swift test --package-path Packages/PQRCAgent    # agent integrity + AgentSkills + reasoning-trace stripping
swift test --package-path Packages/PQRCMCP      # MCP server protocol suite (A35)
swift test --package-path Packages/PQRCACP      # ACP agent suite (A36)
```

The last two packages are **standalone agent-interop tools** with no app/crypto
deps (DEVIATIONS A35/A36): `PQRCMCP` builds `pqrc-mcp` (EldrChat as a read-only
MCP secure-chat source); `PQRCACP` builds `eldr-acp` (the on-device LLM as an ACP
coding agent for Xcode 27). Both run their tests network-free.

All three must be green. `PQRCNostr` includes the SPEC §10 local-link suite
(`LocalLinkTests`) running against the deterministic `LocalLinkSimulator` —
co-present delivery, relay fallback, partition/rejoin, replay/tamper/forged-
hello adversarial cases. No network, no radios, no real clock.

## 3. The full app build

```bash
# Discover simulators if the destination below fails:
xcodebuild -showdestinations -project App/EldrChat.xcodeproj -scheme EldrChat

xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation
```

> The project/target/scheme is **EldrChat** (renamed from PQRC). The old `PQRC`
> scheme is stale and won't resolve a destination — use `EldrChat`.

`-skipPackagePluginValidation` is required (swift-secp256k1 ships a build
plugin). If a simulator wedges with "Application failed preflight checks":
`xcrun simctl shutdown all && xcrun simctl erase <UDID>`.

To just *use* the app with zero infrastructure: run the scheme with launch
argument `--local-universe` (or `--local-universe --demo-script` for the
scripted Alice/Bob demo per docs/DEMO.md). The Local Universe is fully
in-process — five personas over a simulated relay.

## 4. Building and running the PQRC relay server (`pqrc-relay`)

The relay server is an executable target inside `Packages/PQRCNostr`. It
speaks the NIP-01 subset (EVENT/REQ/EOSE/OK/CLOSE) plus NIP-42 AUTH, enforces
the anchor-relay rule (kind-1059 gift wraps are served ONLY to the
authenticated, p-tagged recipient — SPEC §9.1), and can inject deterministic
chaos for resilience demos.

```bash
# Build + run (default port 7777):
swift run --package-path Packages/PQRCNostr pqrc-relay

# Custom port and chaos injection:
swift run --package-path Packages/PQRCNostr pqrc-relay \
  --port 7777 --drop 0.2 --jitter 150 --duplicate 0.1 --reorder 8 --seed 42

# Release binary, if you want to keep one around:
swift build --package-path Packages/PQRCNostr -c release --product pqrc-relay
ls Packages/PQRCNostr/.build/release/pqrc-relay
```

Expected startup output:

```
pqrc-relay listening on ws://127.0.0.1:7777
  NIP-01 subset: EVENT / REQ / EOSE / OK / CLOSE
  NIP-42 AUTH: kind-1059 envelopes served only to the AUTHed recipient
Stop with Ctrl-C.
```

Smoke-test it with any WebSocket tool:

```bash
# e.g. websocat (brew install websocat). The relay greets with its AUTH challenge:
websocat ws://127.0.0.1:7777
# < ["AUTH","<challenge-hex>"]
# > ["REQ","s1",{"kinds":[1]}]
# < ["EOSE","s1"]
```

Notes:
- Events are **in-memory only** — restarting the relay forgets everything.
  It is dev/demo tooling; production guidance is §7.
- The exact same `LocalRelaySimulator` code serves the in-process test matrix,
  so the wire behavior you demo is the behavior the tests prove.

## 5. Testing against the Nostr relay (WebSocket transport)

### 5.1 Automated: the conformance gate

The TEST-PLAN §7 transport conformance suite is the acceptance gate for any
relay. Three variants exist in `ConformanceSuite.swift`:

```bash
# Always on (in-process simulator, network-free):
swift test --package-path Packages/PQRCNostr --filter swapPoint_transportConformanceSuite

# Real NostrWebSocketTransport ⇄ in-process pqrc-relay over 127.0.0.1
# (opt-in: opens a loopback socket):
PQRC_LOOPBACK_TESTS=1 swift test --package-path Packages/PQRCNostr \
  --filter swapPoint_webSocketLoopbackConformance

# Against a deployed relay:
PQRC_RELAY_URL=wss://relay.lerants.com swift test --package-path Packages/PQRCNostr \
  --filter swapPoint_deployedRelayConformance
```

The deployed-relay run **fails on a vanilla public relay** that serves
kind-1059 to unauthenticated readers — that failure is the point: do not route
PQRC traffic through a relay that flunks the gate.

### 5.2 Interactive: the app against `pqrc-relay`

The single-persona app resolves its relays in this order
(`PQRC_RELAY_URL` env → the `relayURLs` list managed in **Settings →
Servers** (add/remove any `ws://`/`wss://` URL in-app, then "Apply &
reconnect") → default `wss://relay.lerants.com`; the literal value `local`
is the in-process simulator). For ad-hoc testing you can skip the env var
entirely and just add `ws://127.0.0.1:7777` in Settings:

1. Start the relay: `swift run --package-path Packages/PQRCNostr pqrc-relay`.
2. In Xcode: Product → Scheme → Edit Scheme… → Run → Arguments → Environment
   Variables, add `PQRC_RELAY_URL = ws://127.0.0.1:7777`.
3. Run the app on an iOS simulator (simulators share the Mac's loopback, so
   `127.0.0.1` reaches the relay directly). Complete onboarding.
4. **Two-simulator conversation**: run the app on a second simulator (same
   scheme, second destination — or `xcrun simctl launch` with
   `SIMCTL_CHILD_PQRC_RELAY_URL=ws://127.0.0.1:7777`). Exchange npubs via the
   QR/new-chat flow. Messages now travel app → WS → pqrc-relay → WS → app as
   real gift wraps.
5. Watch the privacy property hold: the relay's stored events are kind-1059
   wraps with random pubkeys, a fuzzed `created_at`, and the recipient `p`
   tag — never sender, never content.

On a physical device, replace `127.0.0.1` with your Mac's LAN IP and allow
port 7777 through the macOS firewall (`ws://` to a LAN IP is fine in Debug;
TestFlight/Release builds expect `wss://`).

## 6. Testing the MultipeerConnectivity local link (S1)

### 6.1 What ships where

- `MultipeerLinkTransport` (routing, signed hellos, seal frames, fallback) —
  fully unit-tested against `LocalLinkSimulator`; nothing to set up.
- `MultipeerNearbyLink` (the thin MC radio adapter) — needs real devices.
- App wiring is **user-toggleable**: Settings → Nearby (default ON in Debug,
  OFF in Release). The shared `App/Info.plist` carries
  `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_pqrc-local._tcp/_udp`); the radios — and the Local Network permission
  prompt — only start when the toggle is on (DEVIATIONS A9).
- Pairing is automatic for verified contacts: discovery is anonymous Bonjour,
  identities are proven per-connection by a signed challenge, and only
  contacts whose 10420 binding you've verified ever receive traffic.

### 6.2 Automated proof (runs in every `swift test`)

```bash
swift test --package-path Packages/PQRCNostr --filter LocalLinkTests
```

Covers, end to end over the simulated radio: zero relay envelopes while
co-present; wire frames are kind-13 seals (never bare rumors, never wraps);
agent-message integrity on the local path; automatic relay fallback on
partition and silent return to local on rejoin; replayed seals processed
exactly once; tampered seals dropped without poisoning the session; forged
hello proofs unable to attract another identity's traffic; unknown local
senders gated into message requests.

### 6.3 Two physical devices

Simulators do not get real AWDL/Bluetooth; Multipeer between two simulators on
one Mac sometimes works over loopback Bonjour but is not dependable. Use
hardware:

1. Build the **Debug** configuration to both devices (Xcode ▸ Run, or
   `xcodebuild -configuration Debug … install`).
2. First launch: complete onboarding on both; approve the **Local Network**
   permission prompt when it appears.
3. Pair the contacts once via the normal flow (QR / npub exchange). This needs
   a shared relay one time — co-present discovery never replaces contact
   verification (the 10420 binding must verify in both directions first).
4. Put both devices on the same Wi-Fi or just near each other with Bluetooth
   on, then **enable Airplane Mode Wi-Fi/cellular off if you want the full
   offline demo** — AWDL/Bluetooth keeps working.
5. Send messages. Delivery is now point-to-point: with the relay unreachable
   (airplane mode / pqrc-relay stopped), messages still arrive.
6. Verify the fallback: separate the devices (out of radio range), send —
   the message arrives via the relay once connectivity returns; bring them
   back together and traffic returns to the radio.

What you should observe on a relay you control (`pqrc-relay` console or stored
event count): **no kind-1059 events at all** for messages sent while
co-present.

### 6.4 Troubleshooting Multipeer

- No discovery → check both builds are Debug, Local Network permission was
  granted (Settings ▸ Privacy ▸ Local Network), Bluetooth/Wi-Fi toggles on.
- Discovery but no delivery → both apps must be foregrounded (iOS suspends MC
  in background; SPEC §10.1 documents the background constraint honestly).
- Stale peers after force-quit → relaunch both; the hello exchange re-runs on
  every connection and reconnects map the newest proof.

### 6.5 Device-hosted relay hub — `host` / `nearby` (A31)

For a small group with no trusted network, one device can be a **pocket relay**
(`NearbyRelayHub`, a distinct `_pqrc-relay` Bonjour service — not the direct-Nearby
`_pqrc-local` of §6.1):

1. On the host: **Settings ▸ Servers** → add the literal keyword **`host`** →
   Apply. That device now runs the `LocalRelaySimulator` engine over Multipeer.
2. On each companion: **Settings ▸ Servers** → add **`nearby`** → Apply. They
   connect to the host over the radio (no router, no public relay).
3. Send messages. The kind-1059 anchor-relay rule holds over the hub: the host
   forwards **sealed ciphertext + p-tags only** and cannot read message content.
4. Optionally enable the host's **shared AI** (a tethered AI with the **`hub`**
   backend on a companion): the companion's (firewall-redacted) message text goes
   to the host's on-device model behind the off-device-AI consent alert. This is
   the one path where the host sees content — by the companion's explicit consent.

The whole protocol is unit-tested against `LocalLinkSimulator`
(`NearbyRelayHubTests`); the MC radio adapter itself needs two physical devices.

## 7. Deploying a production anchor relay (beyond `pqrc-relay`)

`pqrc-relay` is for development. For a deployed relay (e.g.
`wss://relay.lerants.com`), SPEC §9.1/§15 prescribe an AUTH-gated
strfry or khatru:

1. Stand up [strfry](https://github.com/hoytech/strfry) (C++) or
   [khatru](https://github.com/fiatjaf/khatru) (Go) behind TLS (`wss://`).
2. Enforce, via config/plugin:
   - NIP-42 AUTH required before serving kind-1059 (`p` tag must equal the
     authenticated pubkey);
   - writes restricted to the kinds PQRC uses (1059, 10420, 10421, 10050);
   - `max_content_length` ≥ 1 MB (SPEC §11.2).
3. Run the acceptance gate: `PQRC_RELAY_URL=wss://… swift test …
   --filter swapPoint_deployedRelayConformance` (§5.1). Do not point clients
   at the relay until it passes.
4. Decide and publish the operator IP/retention policy (THREAT_MODEL §2.1,
   §2.7; TESTFLIGHT-GUIDE §D).

## 8. Command crib sheet

```bash
# Everything headless, fast:
swift test --package-path Packages/PQRCCore
swift test --package-path Packages/PQRCNostr
swift test --package-path Packages/PQRCAgent
swift test --package-path Packages/PQRCMCP     # MCP server (A35)
swift test --package-path Packages/PQRCACP     # ACP agent (A36)

# Opt-in socket suites:
PQRC_LOOPBACK_TESTS=1 swift test --package-path Packages/PQRCNostr --filter Loopback
PQRC_RELAY_URL=wss://relay.lerants.com swift test --package-path Packages/PQRCNostr --filter deployedRelay

# Relay server / agent-interop executables:
swift run --package-path Packages/PQRCNostr pqrc-relay --port 7777
swift run --package-path Packages/PQRCMCP pqrc-mcp          # MCP stdio server (DemoSecureChatBridge)
ELDR_ACP_FAKE_LLM=1 swift run --package-path Packages/PQRCACP eldr-acp   # ACP agent, no model server

# Full app suite:
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation
```

## 9. Driving Xcode 27 with the ACP agent (`eldr-acp`)

EldrChat ships an **Agent Client Protocol** agent so a self-hosted LLM can pilot
Xcode 27 (write code, build, run on simulators). Xcode 27 is the ACP *client*;
`eldr-acp` is the *agent* it spawns over stdio (A36).

**1. Build + install the agent**
```bash
swift build -c release --package-path Packages/PQRCACP
cp "$(swift build -c release --package-path Packages/PQRCACP --show-bin-path)/eldr-acp" ~/.local/bin/eldr-acp
```

**2. Create a launcher.** Xcode 27's "Add an Agent" dialog has **no
environment-variable field**, so a one-line wrapper supplies the LLM config and
selects the beta toolchain. `~/.local/bin/eldr-acp-xcode`:
```zsh
#!/bin/zsh
[ -f "$HOME/.config/eldr-acp/env" ] && source "$HOME/.config/eldr-acp/env"
export ELDR_LLM_URL="${ELDR_LLM_URL:-http://127.0.0.1:1337/v1}"   # LM Studio / Ollama
export ELDR_LLM_TOKEN="${ELDR_LLM_TOKEN:-<your LM Studio token>}"
export ELDR_LLM_MODEL="${ELDR_LLM_MODEL:-<your model id, e.g. an instruct model>}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
exec "$HOME/.local/bin/eldr-acp"
```
`chmod +x ~/.local/bin/eldr-acp-xcode`. Put the token in `~/.config/eldr-acp/env`
(`ELDR_LLM_TOKEN=…`) so it survives token rotation without editing the script.

**3. Register in Xcode 27** → Settings ▸ Intelligence ▸ **Add an Agent**:

| Field | Value |
|---|---|
| **Name** | `Eldr` |
| **Executable** | `/Users/<you>/.local/bin/eldr-acp-xcode` (full path) |
| **Interpreter** | *(blank — the launcher has a shebang and is executable)* |
| **Arguments** | *(none)* |

Click **Add**. The agent uses the working directory Xcode hands it per session
(your open project), so `ELDR_WORKDIR` is only a fallback.

**Notes**
- The LLM must support OpenAI **tool/function calling** (LM Studio does). Prefer an
  **instruct** model over a reasoning model for snappy, low-confusion tool use.
- Smoke-test with no model server: `ELDR_ACP_FAKE_LLM=1 ~/.local/bin/eldr-acp-xcode`
  then type an `initialize` line — it must reply immediately.
- `run_shell` honors `DEVELOPER_DIR`, so `xcodebuild`/`xcrun simctl` target the
  Xcode 27 beta toolchain even though your default `xcode-select` may be stable.

### Tuning for your model (context budget, tools, prompt) — A37

The agent loops tool calls against *your* local model. The two things that break a
self-hosted setup are **context flooding** (a big `read_file` or chatty
`xcodebuild` dumps tens of thousands of tokens into the next prompt and the model
loses the system instructions) and **tool confusion** (weaker models mis-call or
over-call vague tools). These knobs cap and shape what the model sees. **All
defaults are safe** — an un-tuned install just works; tune only if your model
struggles. Set them in `~/.config/eldr-acp/env` (sourced by the launcher) or as env.

| Env var | Default | Effect |
|---|---|---|
| `ELDR_ACP_MAX_TOOL_RESULT_BYTES` | `8192` | Max bytes of **one tool result** fed back to the model. Larger → head+tail truncated with a `… N bytes elided …` marker (so a 200 KB file read can't flood the window). `0` → unbounded. |
| `ELDR_ACP_MAX_HISTORY_TURNS` | `12` | Most-recent user/assistant/tool **turns** kept each call. The system prompt + the original task are *always* kept; older turns drop. `0` → no turn cap. |
| `ELDR_ACP_MAX_CONTEXT_CHARS` | `49152` | Soft ceiling on **total** characters sent. Over budget → oldest non-anchor message *content* is elided (oldest-first) until it fits. `0` → no cap. |
| `ELDR_ACP_TOOLS` | *(all)* | Comma/space tool **allowlist**, e.g. `read_file,write_file,run_shell`. Only listed tools are advertised + accepted; trims the menu for models that get confused by choice. |
| `ELDR_ACP_PROMPT_PREAMBLE` | *(none)* | Extra text **appended** to the system prompt — model-specific tool-calling rules you want to experiment with. Also a `prompt-preamble` file in `~/.config/eldr-acp/`. |
| `ELDR_ACP_SYSTEM_PROMPT` | *(built-in)* | **Replaces** the system prompt entirely (`{cwd}` is substituted). Also a `system-prompt` file in the config dir. Use only if the built-in prompt fights your model. |

Config-dir lookups honor `ELDR_ACP_CONFIG_DIR`, else `$XDG_CONFIG_HOME/eldr-acp`,
else `~/.config/eldr-acp`. **Env always wins over a file.** On startup the agent logs
the active budget to stderr (`context budget: …`) so you can confirm what's in force.

- **Small / 7-8B / heavily-quantized model** (tight window, weaker tool use): shrink
  the budgets and trim the toolset, e.g.
  `ELDR_ACP_MAX_TOOL_RESULT_BYTES=4096 ELDR_ACP_MAX_HISTORY_TURNS=6 ELDR_ACP_MAX_CONTEXT_CHARS=16384 ELDR_ACP_TOOLS=read_file,write_file,run_shell`,
  and add a terse `ELDR_ACP_PROMPT_PREAMBLE` like *"Call exactly one tool per step.
  Keep replies short."*
- **Large / long-context model** (e.g. 128k window): raise the ceilings to let it
  hold more of the codebase, e.g.
  `ELDR_ACP_MAX_TOOL_RESULT_BYTES=32768 ELDR_ACP_MAX_HISTORY_TURNS=40 ELDR_ACP_MAX_CONTEXT_CHARS=262144`
  (leave tools at the default full set).
