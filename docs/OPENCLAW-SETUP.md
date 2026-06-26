# OPENCLAW-SETUP.md — running EldrChat's ACP agent inside OpenClaw

A start-to-finish guide for wiring **EldrChat's ACP agent (`eldr-acp`)** into
**OpenClaw** so a self-hosted LLM can write code, build, and run shell commands
from inside OpenClaw.

This is the OpenClaw-focused walkthrough. The canonical reference (Xcode-framed,
plus the full env/tuning tables) is [`SETUP-GUIDE.md §9`](SETUP-GUIDE.md); the
design decisions are DEVIATIONS **A42** (OpenClaw first-class) and **A43**
(contextgraph route).

---

## What this is

- **OpenClaw is the ACP _client_.** It spawns an agent over stdio and drives it
  with JSON-RPC (`initialize → session/new → session/prompt`).
- **`eldr-acp` is the ACP _agent_.** It loops tool calls (`read_file`,
  `write_file`, `run_shell`, …) against **your own** OpenAI-compatible LLM and
  streams the result back to OpenClaw.

The agent is **client-agnostic** — the exact binary Xcode 27 spawns is what
OpenClaw spawns. The only OpenClaw-specific piece is *where* its command is
registered: OpenClaw loads ACP agents through its **`acpx` plugin**.

`eldr-acp` requires **no authentication** (`authMethods` is empty), so acpx's
credential plumbing is a no-op.

## Prerequisites

| Requirement | Notes |
|---|---|
| macOS with the Swift 6.2 toolchain | Needed to build `eldr-acp` (Xcode 26.x). See [`SETUP-GUIDE.md §1`](SETUP-GUIDE.md). |
| OpenClaw installed | With its `acpx` plugin available. |
| A local OpenAI-compatible LLM endpoint | LM Studio or Ollama on e.g. `http://127.0.0.1:1337/v1`. The model **must support tool/function calling**; prefer an **instruct** model over a reasoning model for snappy, low-confusion tool use. |

There are **two ways** to set this up. **Path A** (the Configurator GUI) is
recommended — it does every step below for you. **Path B** is the manual
equivalent for anyone not using the GUI.

---

## Path A — GUI (recommended): the Eldr ACP Configurator

The `EldrACPConfigurator` macOS app wraps the whole setup in a wizard and
registers OpenClaw first-class, exactly like Xcode (A42).

1. **Build / open the Configurator.**
   ```bash
   xcodebuild -scheme EldrACPConfigurator -destination 'platform=macOS' build
   ```
   Or open `Apps/EldrACPConfigurator/EldrACPConfigurator.xcodeproj` and Run.

2. **Walk the wizard:** connect your LLM → test it → install the binary +
   launcher. These steps write `~/.config/eldr-acp/env`, `~/.local/bin/eldr-acp`,
   and the dedicated `~/.local/bin/eldr-acp-openclaw` launcher.

3. **Step 4 — "Register in OpenClaw".**
   - The **Launcher** shown is `~/.local/bin/eldr-acp-openclaw`.
   - The **OpenClaw config file** defaults to `~/.config/openclaw/config.json`
     and is editable if yours lives elsewhere.
   - Click **Register with OpenClaw**.

   This merges the agent into OpenClaw's `acpx` plugin config **without
   clobbering** your existing settings — only the agent entry is added. If
   contextgraph is enabled in the Configurator, its OpenClaw plugin entry is
   written at the same time (A43).

That's it — skip to [Verify it works](#verify-it-works).

---

## Path B — Manual

For setups not using the Configurator. This produces the identical result.

1. **Build + install the agent** ([`SETUP-GUIDE.md §9`](SETUP-GUIDE.md) step 1):
   ```bash
   swift build -c release --package-path Packages/PQRCACP
   cp "$(swift build -c release --package-path Packages/PQRCACP --show-bin-path)/eldr-acp" \
      ~/.local/bin/eldr-acp
   ```

2. **Create the launcher** `~/.local/bin/eldr-acp-openclaw`. OpenClaw's agent
   registration has no environment-variable field, so a one-line wrapper supplies
   the LLM config (same script body as the Xcode launcher in §9):
   ```zsh
   #!/bin/zsh
   [ -f "$HOME/.config/eldr-acp/env" ] && source "$HOME/.config/eldr-acp/env"
   export ELDR_LLM_URL="${ELDR_LLM_URL:-http://127.0.0.1:1337/v1}"   # LM Studio / Ollama
   export ELDR_LLM_TOKEN="${ELDR_LLM_TOKEN:-<your LM Studio token>}"
   export ELDR_LLM_MODEL="${ELDR_LLM_MODEL:-<your model id, e.g. an instruct model>}"
   exec "$HOME/.local/bin/eldr-acp"
   ```
   ```bash
   chmod +x ~/.local/bin/eldr-acp-openclaw
   ```
   Put the token in `~/.config/eldr-acp/env` (`ELDR_LLM_TOKEN=…`) so it survives
   token rotation without editing the script.

3. **Register the agent in OpenClaw's config** (default
   `~/.config/openclaw/config.json`). Merge this `acpx` block in, preserving your
   other keys:
   ```json
   { "plugins": { "entries": { "acpx": { "enabled": true,
       "config": { "agents": { "eldr": {
         "command": "/Users/<you>/.local/bin/eldr-acp-openclaw", "args": [] } } } } } } }
   ```

---

## Verify it works

1. **Network-free smoke test** (no model server needed). The agent must reply to
   an `initialize` line immediately:
   ```bash
   ELDR_ACP_FAKE_LLM=1 ~/.local/bin/eldr-acp-openclaw
   # then type an `initialize` JSON-RPC line — it must respond at once
   ```

2. **In OpenClaw:** select the `eldr` agent and run a turn against your real
   local model. Confirm the three **skills** show up in the command menu (A38):

   | Command | Does |
   |---|---|
   | `/spec <what>` | A structured Markdown specification (Goals/Non-Goals, MUST/SHOULD requirements). |
   | `/snippet <what>` | One minimal, runnable code snippet (infers language; defaults to Swift). |
   | `/html <what>` | A self-contained single-file HTML visualization (renders offline). |

3. **Protocol conformance** — the same handshake OpenClaw drives, network-free
   and in-process:
   ```bash
   swift test --package-path Packages/PQRCACP
   ```

---

## Tuning, skills, and contextgraph

The agent loops tool calls against *your* model, so two things break weak setups:
**context flooding** (a huge `read_file`/`xcodebuild` dump) and **tool
confusion**. The env knobs that cap and shape what the model sees
(`ELDR_ACP_MAX_TOOL_RESULT_BYTES`, `ELDR_ACP_MAX_HISTORY_TURNS`,
`ELDR_ACP_MAX_CONTEXT_CHARS`, `ELDR_ACP_TOOLS`, `ELDR_ACP_PROMPT_PREAMBLE`,
`ELDR_ACP_SYSTEM_PROMPT`) and the skill toggle (`ELDR_ACP_SKILLS`) are documented
with defaults and per-model recipes in [`SETUP-GUIDE.md §9`](SETUP-GUIDE.md)
("Tuning for your model" — A37 — and "Skills" — A38). **All defaults are safe**;
tune only if your model struggles. Set them in `~/.config/eldr-acp/env`.

**contextgraph (optional, A43).** For smarter context assembly, contextgraph
ships its own OpenClaw plugin. The Configurator writes that plugin entry pointed
at the same local service when contextgraph is enabled before the "Register in
OpenClaw" step; the agent-level route (`ELDR_ACP_CONTEXTGRAPH=1`) works under any
ACP client. See [`SETUP-GUIDE.md §9.4`](SETUP-GUIDE.md) "contextgraph".

## Troubleshooting

- **Registration says the config "isn't a JSON object."** Your OpenClaw config
  is invalid JSON or you pointed at the wrong file — open it, fix it, or set the
  correct path in the wizard / your hand-edit.
- **The model mis-calls or over-calls tools.** Use an **instruct** model, and
  narrow the menu with `ELDR_ACP_TOOLS=read_file,write_file,run_shell`.
- **A JSON-RPC error on reconnect** (`session/load` / `session/resume`). Expected:
  the agent advertises `loadSession:false`, so a client that tries to resume gets
  a clean error and simply opens a fresh session — not a crash. Optional methods
  the agent doesn't implement (`session/set_mode`, `session/list`, `authenticate`,
  …) return `-32601` without affecting the live session.
