# Eldr Conduit Setup — drive your Mac's agent from your iPhone

This is the human-and-AI runbook for putting a Mac into **conduit mode**: your iPhone
EldrChat drives the agent already running on that Mac — **sybilclaw's assistant** (your
"current agent") or **eldr-acp** — end to end, over the post-quantum relay.

`eldrctl` provisions the Mac over SSH and hands you a pairing link. The exact step list the
AI on the Mac follows is also available verbatim from:

```
eldrctl conduit instructions
```

> **Honest status.** This is the *provisioning* layer. The live two-device pairing (Stage 1,
> eldr-acp over the relay) and the sybilclaw-gateway round-trip (Stage 2) are wired and
> tested headlessly but **not yet proven on real hardware** (`docs/DEMO-SYBILCLAW.md`).
> `eldrctl` makes them easy to stand up so they can finally be exercised on two devices; it
> does not by itself make them work. Report what you actually observe.

---

## The one hard requirement

The target Mac must have an **unlocked login session** (auto-login is fine for a dedicated
conduit host). The conduit's long-term keys are `WhenUnlockedThisDeviceOnly` — at the login
window the Keychain is unreadable, so a Mac sitting at loginwindow **cannot be provisioned or
serve**. `install-huginn.sh` preflights for this and aborts loudly if the session is locked.
This is a property of the privacy invariant, not a bug to work around.

## Prerequisites

1. **The phone's owner identity hex** (64 hex chars) — the user reads it from
   EldrChat ▸ Settings. This is the C-3 gate target: only this identity may drive the agent.
2. **The model is reachable** on the Mac:
   - `--responder sybilclaw` (default): the local sybilclaw/OpenClaw Gateway is running
     (default port `18789`). Routes each turn to the user's own assistant.
   - `--responder eldr-acp`: a local OpenAI-compatible LLM is up (e.g. LM Studio at
     `http://127.0.0.1:1234/v1`). The proven fallback path.
3. **The signed `Huginn.app`** is available on the controller machine (default
   `/Applications/Huginn.app`). It bundles the `eldr-node` binary the installer ships. Build
   it with `Apps/Huginn/build-dmg.sh` if needed.

## Provision (one idempotent command)

```bash
eldrctl install \
  --target user@mac-host \
  --owner  <64-hex phone identity> \
  --relay  wss://relay.lerants.com \
  --responder sybilclaw            # or: eldr-acp
  # --app /path/to/Huginn.app      # if not in /Applications
  # --no-app                       # headless node only (skip the GUI bundle)
  # --workdir /path/to/project     # the agent's file-tool jail (default: remote $HOME)
  # --dry-run                      # stage + run with no system changes
```

What it does, in order (see `Apps/Huginn/install-huginn.sh`):

1. Stages `Huginn.app` + `eldr-node` into a fresh temp dir on the target (`scp`).
2. Preflights: macOS, and an **unlocked GUI session**.
3. Copies `Huginn.app` → `/Applications` (verifies codesign), installs `eldr-node` →
   `~/.local/bin`.
4. Writes conduit config under `~/.config/eldr-acp/` (`env` with the model URL/model — **no
   token**, C-8; plus `owner`, `workdir`, `responder`).
5. Writes and loads a **LaunchAgent** (`chat.eldr.node`, `RunAtLoad`/`KeepAlive`,
   `LimitLoadToSessionType=Aqua`) that runs `eldr-node --owner … --relay … --responder …`.
6. Prints the **pairing link**.

Re-running converges (it reloads the LaunchAgent); nothing is duplicated.

## Seed the model token (only if the model needs one)

The token is **never** passed on the command line. Seed it on a hidden prompt; it is piped
over SSH straight into the node's Keychain (stdin only — never argv, disk, or history):

```bash
eldrctl conduit import-token --target user@mac-host
```

Local models (LM Studio, Ollama) usually need no token — skip this.

## Pair the phone

1. Get the link (also printed by `install`):
   ```bash
   eldrctl conduit pairing-link --target user@mac-host
   ```
   It looks like: `pqrc:add?npub=npub1…&type=coding_agent&relay=wss%3A%2F%2F…`
2. In EldrChat: **new conversation ▸ scan the QR or paste the link**. This adds the Mac as a
   `coding_agent` contact.
3. In that conversation's details, turn **ON "Drive this agent from here"**
   (`remoteDevControlConsent`).

   Until you do, the agent will not act, **and the egress firewall stays ON**. Enabling
   consent is what turns the firewall OFF for that chat (a per-conversation override still
   wins). Trust is granted by you, per node — never by the network path. The 64 KB inline
   context cap stays enforced on the relay path regardless.

## Verify

```bash
eldrctl conduit status --target user@mac-host
```

Confirms the LaunchAgent is loaded and tails `~/.config/eldr-acp/eldr-node.log`. Then send a
message from the phone and confirm a reply returns. If `--responder sybilclaw` and the
gateway is down, turns fail with a clear gateway error — start the gateway and retry.

## Keychain prompts (Mac + iPhone)

This work also collapses the repeated Keychain prompts:

- **Mac (Huginn):** its long-term items moved to the **data-protection keychain** under a
  team-scoped access group, so a Huginn rebuild no longer re-prompts and "Always Allow"
  finally sticks — **0 prompts** for the GUI/conduit. (The `eldr-acp` launcher's external
  `security` read keeps a file-keychain token mirror; it prompts at most once and sticks.)
  See DEVIATIONS AC65/AC66.
- **iPhone (EldrChat):** biometric unlock now reuses one `LAContext`, so unlocking is **one**
  Face ID prompt. See DEVIATIONS AC67.
