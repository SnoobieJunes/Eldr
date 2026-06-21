# Eldr ACP Configurator

A SwiftUI **macOS** app that wraps the `eldr-acp` coding-agent CLI in a friendly
setup wizard, a live configuration panel, a log viewer, an in-app test chat, a
self-learning per-project memory, and an EldrChat bridge — then ships as a DMG.

It is the **GUI alternative** to the manual command-line setup documented in
[`docs/SETUP-GUIDE.md §9`](../../docs/SETUP-GUIDE.md). Everything the wizard does
(build/install the binary, write the env file, register the launcher) you can do by
hand; the Configurator just does it for you and adds live monitoring on top.

`eldr-acp` itself is the on-device coding agent: an **Agent Client Protocol (ACP)**
agent that lets a self-hosted, OpenAI-compatible LLM (LM Studio, Ollama, vLLM, …)
pilot **Xcode 27** — write code, build, and run on simulators — entirely on your
own machine, with no cloud and no API key. The Configurator wraps that CLI; the CLI
is unchanged and still runs headless (DEVIATIONS AC1).

- App target / scheme: **`EldrACPConfigurator`** (`chat.eldr.acp.configurator`)
- Deployment target: **macOS 26.0** (forced by the linked `PQRCNostr`/`PQRCCore`
  packages, and matching the rest of the repo — DEVIATIONS AC2)
- Version: **0.1.0**
- Ships **unsandboxed** (it installs a CLI, writes `~/.config`, spawns local tools,
  and pairs over the local network — all of which the App Sandbox forbids;
  Developer ID + notarization + hardened runtime is the Gatekeeper story instead,
  DEVIATIONS AC6)

For the design decisions behind every piece below, see the
**"Eldr ACP Configurator (macOS GUI app + DMG)"** section of
[`docs/DEVIATIONS.md`](../../docs/DEVIATIONS.md) (entries AC1–AC13). This README does
not duplicate that rationale; it tells you how to build, run, and use the app.

---

## Build & run

The app builds and runs straight from Xcode with **no certificates** — only
*distribution* (the DMG) needs signing (see
[Signing & distribution](#signing--distribution)).

```bash
# From the repo root:
cd Apps/EldrACPConfigurator

# Build from the command line:
xcodebuild -scheme EldrACPConfigurator -destination 'platform=macOS' build

# Or just open it in Xcode and press Run:
open EldrACPConfigurator.xcodeproj
```

> The Run Script build phase compiles the bundled `eldr-acp` binary from
> `Packages/PQRCACP` and copies it into the app bundle, so the Configurator can
> install a binary that matches the app it shipped with. If you ever see
> *"The bundled eldr-acp binary is missing from the app"* in the installer, do a
> clean build so that phase runs.

There is no headless test for the full app (the bridge runtime needs a second peer
and the app's identity stack — DEVIATIONS AC9). The CLI it wraps, however, has its
own network-free suite:

```bash
swift test --package-path Packages/PQRCACP   # eldr-acp ACP conformance + ProjectMemory/events
```

---

## First run: the 5-step setup wizard

The first launch opens a wizard (it sets a `setupCompleted` flag and won't reappear;
everything it does is also reachable later from the **Configuration** tab).

1. **Connect your local LLM.** Point the agent at any OpenAI-compatible server.
   Quick-fill buttons preset **LM Studio** (`http://127.0.0.1:1234/v1`) and
   **Ollama** (`http://127.0.0.1:11434/v1`); or type your own URL, an API token
   (usually blank for local servers), and the model id.
2. **Test the connection.** Hit *Test connection* — a green check lists the models
   the server reports; a red result tells you what failed but lets you continue and
   fix it later in Configuration.
3. **Install the agent.** Copies the bundled `eldr-acp` into `~/.local/bin` (mode
   0755) and writes the `eldr-acp-xcode` launcher next to it. Shows the resulting
   binary + launcher paths with copy buttons.
4. **Register in Xcode 27.** Shows the launcher path to paste into Xcode's agent
   settings, with an *Open Xcode* button. (See
   [Registering the launcher in Xcode 27](#registering-the-launcher-in-xcode-27) —
   and read the Xcode-beta caveat there before using the button.)
5. **You're ready.** Hands off to the main window — try the agent in **Test Chat**,
   watch it work in **Logs**, and fine-tune anything in **Configuration**.

---

## Features

The main window is a tabbed view (**Configuration**, **Test Chat**, **Logs**,
**EldrChat Bridge**) plus a menu-bar item.

### Configuration

A live form. Every control is bound to the on-disk files the CLI actually reads, and
edits are **debounced** to disk ~0.5 s after you stop typing — there is no Save
button. It round-trips config through the binary's *own* parsers
(`LLMConfig.fromEnvironment` / `AgentConfig.fromEnvironment`), so what the GUI shows
is exactly what the agent will load (DEVIATIONS AC5). Sections:

- **Local LLM** — server URL, API token (secure field), model id, plus an inline
  health dot + *Test* button.
- **Context budget** — `Max tool-result bytes`, `Max history turns`,
  `Max context chars` (0 = unbounded). These cap what a chatty tool result or a big
  file read can push into the model's window; smaller models need tighter budgets.
- **Tools** — per-tool toggles for the four built-ins: `read_file`, `write_file`,
  `list_dir`, `run_shell`. (All four on writes an empty allowlist = "all", so a
  future tool isn't silently excluded.)
- **Skills** — advertise the built-in slash-commands (`/spec`, `/snippet`, `/html`).
- **Prompt tuning** — a *preamble* appended to the built-in system prompt, and a
  full *system-prompt override* (`{cwd}` is substituted) for when the built-in
  prompt fights your model.
- **Project Memory** — see below.

### Test Chat

Runs a real `ACPAgent` **in-process** so you can exercise your LLM + tools without
Xcode. It drives the same `initialize → session/new → session/prompt` flow Xcode
would, captures the agent's `session/update` notifications, and renders user turns,
tool calls (with arguments), tool results, and assistant replies. Tools run in a
throwaway scratch directory, so the test chat never touches a real project, and
permission requests are auto-granted (there's no editor to prompt). If the health
check is red, it falls back to a built-in echo "LLM" so you can still watch the tool
loop. Editing config and re-sending rebuilds the session with the new settings.

### Logs

Follows `~/.config/eldr-acp/eldr-acp.log` (which the launcher tees the agent's
stderr into) and streams newly-appended lines, color-coded into LLM / tool / error /
info. It handles log rotation (reopens on rename/delete), caps retained lines so a
long session can't grow memory unbounded, and offers Clear. This is the live window
into what the agent is doing inside Xcode.

### Project Memory (self-learning `eldr.md`)

The self-learning loop. When **Self-learning** is on, the agent appends a
`events.jsonl` line after each significant turn (`write_file`, `shell_result`,
`session_end`); the Configurator tails that file and distills it into a durable,
**per-project** `eldr.md` that the agent prepends to its system prompt on its *next*
session. It turns:

- a failed shell command → a `## LLM Corrections` note,
- a file the agent wrote that you then edit within 15 minutes → a "prefer your
  version of that file" correction (a best-effort `DispatchSource` vnode watch, not a
  precise diff — DEVIATIONS AC8),
- a finished session → a `## Session History` entry (most-recent 10 kept).

Each project's memory lives at `~/.config/eldr-acp/projects/<sha256(cwd)>/eldr.md`
and is capped to 4 KB after every update so it always fits the system-prompt budget.
The project identity is the **SHA-256 of the absolute working-directory path** — a
one-way hash, so the shared `projects/` namespace never exposes your real paths; a
local sidecar `cwd` marker lets the UI show a friendly project name (DEVIATIONS AC3).
The agent (`ProjectContext`) and the Configurator (`ContextLearner`) share the exact
same path math, so they always agree on where a project's file lives. The section
lists each project with a one-line preview, a **View** sheet (the full `eldr.md`),
and a **Clear** button. Turn Self-learning off and the agent emits no events and the
learner goes idle.

### EldrChat Bridge

Pairs the coding agent into an **EldrChat** conversation so a group (your phone,
teammates) can see the agent's activity over EldrChat's existing post-quantum, E2EE
PQRC channel. The agent's reports always carry `participant_type: .agent` and render
as AI-authored (invariant 8). The flow: *Enable bridge* generates/loads a Nostr
identity (stored in the Keychain with SPEC §3.1 access flags) and advertises over the
local network; EldrChat scans the shown QR (New conversation ▸ Scan) to add the agent
as a contact; you then pick which conversations to report into and which message
types to share (**Tool calls**, **Build results**, **File diffs**, **Session
summary**).

**Privacy:** every share toggle and conversation is **OFF by default** — nothing is
shared until you pair, pick a conversation, *and* enable a type. The agent never
self-activates (it's your own tool reporting your work, so no `ai_window` gate applies
to it — DEVIATIONS AC9), and *Unpair* deletes the identity and forgets everything.

> **Status:** the bridge UI, identity/Keychain storage, QR pairing codec, Multipeer
> advertising, and the agent-labeled send path are implemented and tested behind a
> `BridgeMessaging` seam, but the full PQRC pairing handshake at runtime needs a
> second peer and the app's session stack and is not yet wired in this app — until
> paired, sends throw (DEVIATIONS AC9). The bridge advertises the Bonjour service
> type `eldr-acp` while EldrChat's nearby link defaults to `pqrc-local`; reconciling
> those is part of that runtime wiring (DEVIATIONS AC10).

### Menu-bar item

A `MenuBarExtra` (DEVIATIONS AC7) gives an always-available status dot (LLM
reachable / unreachable / checking), the current install state, and quick actions:
**Open Configurator**, **Re-check now**, **Quit**.

---

## Where it writes config

The Configurator and the CLI share one set of locations (resolved from
`$ELDR_ACP_CONFIG_DIR` → `$XDG_CONFIG_HOME/eldr-acp` → `~/.config/eldr-acp` for
config, and `~/.local/bin` for the binaries). Everything is plain text you can read
or edit by hand.

| Path | What it is |
|---|---|
| `~/.config/eldr-acp/env` | `export KEY='value'` lines the launcher `source`s (LLM URL/token/model, the context-budget caps, and `ELDR_ACP_EVENTS_FILE`). Single-quote-escaped so any URL/token is safe to source. |
| `~/.config/eldr-acp/tools` | Tool allowlist (empty = all four). |
| `~/.config/eldr-acp/skills` | Skills on/off (`1`/`0`). |
| `~/.config/eldr-acp/prompt-preamble` | Text appended to the system prompt. |
| `~/.config/eldr-acp/system-prompt` | Full system-prompt override. |
| `~/.config/eldr-acp/eldr-acp.log` | The agent's stderr (the launcher tees here; the **Logs** tab follows it). |
| `~/.config/eldr-acp/events.jsonl` | Per-turn events the agent appends (drives Project Memory). |
| `~/.config/eldr-acp/projects/<sha256(cwd)>/eldr.md` | Per-project learned memory (+ a sidecar `cwd` marker). |
| `~/.local/bin/eldr-acp` | The installed CLI binary (0755). |
| `~/.local/bin/eldr-acp-xcode` | The launcher Xcode is pointed at (0755). |

The launcher is a tiny zsh wrapper: it `source`s the env file (so the GUI's settings
reach the agent) and appends the agent's stderr to the log the Logs tab follows:

```zsh
#!/bin/zsh
# Written by EldrACPConfigurator. Xcode 27 is pointed at this launcher.
source "$HOME/.config/eldr-acp/env" 2>/dev/null || true
exec "$HOME/.local/bin/eldr-acp" "$@" 2>> "$HOME/.config/eldr-acp/eldr-acp.log"
```

Because the launcher sources the env file at every spawn, anything you change in the
Configurator takes effect on the agent's next session with no need to touch Xcode.

---

## Registering the launcher in Xcode 27

After the wizard's *Install* step, point Xcode at the launcher:

1. **Xcode ▸ Settings ▸ Intelligence** (model providers).
2. **Add an Agent** (type *Agent (ACP)*).
3. Set its **Executable / command** to the launcher's full path:
   `/Users/<you>/.local/bin/eldr-acp-xcode`. Leave **Interpreter** and **Arguments**
   blank — the launcher has a shebang and is executable, and it picks up the working
   directory Xcode hands it per session (your open project).
4. **Add.**

> **Xcode-beta caveat.** Open Xcode by launching the **app** (Dock/Finder/Spotlight),
> **not** via the `xcode://` URL scheme. On a system with both stable Xcode and
> Xcode-beta installed, the URL scheme can resolve to the *stable* Xcode (which lacks
> the Xcode 27 agent settings), so the wizard's *Open Xcode* button is a convenience
> only — if it opens the wrong Xcode, just open the beta app directly. The launcher
> additionally exports `DEVELOPER_DIR` toward the beta toolchain so the agent's
> `run_shell` (`xcodebuild`/`xcrun simctl`) targets Xcode 27 even when your default
> `xcode-select` is the stable release.

The full manual equivalent — including the per-model tuning knobs, the skills, and
using other ACP clients (Zed, OpenClaw, Goose-style) — is in
[`docs/SETUP-GUIDE.md §9`](../../docs/SETUP-GUIDE.md).

---

## Signing & distribution

See [`docs/SIGNING-AND-DISTRIBUTION.md`](../../docs/SIGNING-AND-DISTRIBUTION.md) for
the full walkthrough (the difference between an Apple Development cert and a Developer
ID Application cert, how to obtain the latter, how to make an app-specific password
and find your Team ID, and how to run `build-dmg.sh`). In short:

- **To run it on your own Mac:** build from Xcode. An **Apple Development** signature
  is enough; Gatekeeper will reject it on *other* Macs.
- **To hand the DMG to anyone else:** you need a **Developer ID Application**
  certificate + notarization, produced by `build-dmg.sh` with `APPLE_ID`,
  `APP_PASSWORD`, and `TEAM_ID` set (DEVIATIONS AC12).

> The DMG currently in `dist/EldrACP-0.1.0.dmg` is **signed but not notarized**, so it
> runs only on the machine that built it. `dist/` is git-ignored — built DMGs are not
> committed.
