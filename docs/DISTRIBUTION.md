# DISTRIBUTION.md — how Eldr ships

Eldr is **two apps with two distribution channels**. The split is deliberate and,
for the Mac node, not changeable — it's dictated by what each app is allowed to do
under Apple's App Sandbox rules. This page is the one-screen overview; the step-by-step
lives in `TESTFLIGHT-GUIDE.md` (iOS) and `SIGNING-AND-DISTRIBUTION.md` (the Mac node).

## At a glance

| Component | What it is | Channel | Sandbox | Status |
|---|---|---|---|---|
| **EldrChat (iOS / iPadOS)** | The messenger — E2EE chat plus on-device **and** cloud AI *inside* conversations | **App Store / TestFlight** | Sandboxed (required) | Primary consumer product |
| **EldrChat (Mac, Catalyst)** | The same chat client on macOS | **Mac App Store** (eligible) or Developer ID | Sandbox-able | Builds today; ship when wanted |
| **Huginn (macOS node)** | The optional power-user node: hosts a local coding agent (ACP / OpenClaw / local LLMs), pilots your dev environment, bridges to the phone | **Developer ID + notarized DMG** | **Unsandboxed (required)** | Ships as a DMG |

## What works without the Mac node

EldrChat on iOS is a complete app on its own: end-to-end-encrypted human messaging,
**on-device AI** (Apple FoundationModels), and **cloud LLM providers configured in the
app** (Claude, OpenAI, Gemini, OpenRouter, Groq, and a custom endpoint — see
`BackendRegistry`). Huginn is the **self-hosted / agentic upgrade tier**: when you want
the AI to run on *your* hardware (OpenClaw, LM Studio/Ollama) and *do work* on your Mac,
the node is what makes that productive. Core app = App Store; power tier = DMG.

## Why Huginn is a DMG, not the App Store (DEVIATIONS AC6)

The Mac App Store **requires** the App Sandbox. Huginn's core job is fundamentally
incompatible with it: it spawns arbitrary processes (the `eldr-acp` agent, `/bin/zsh`,
an interactive PTY, `xcodebuild`, external harnesses like OpenClaw / Claude Code),
writes launchers and config under `~/.local/bin` and `~/.config/eldr-acp`, and makes
outbound connections to a local LLM and a Nostr relay. The sandbox blocks all of it —
**there is no entitlement for "spawn arbitrary executables,"** and any child process
inherits the sandbox and breaks. This was verified empirically: a `sandbox = true`
attempt failed every LLM connection with *"Operation not permitted"* and was reverted
(DEVIATIONS AC36/AC37). It is a function-vs-sandbox incompatibility, not a preference.

So Huginn ships the way its peers do — **Developer ID-signed + notarized** — the same
channel as **Ollama, LM Studio, OpenClaw, Docker Desktop, Cursor, and VS Code**, all
non-App-Store for the identical reason. Notarized means a **clean Gatekeeper**
experience (double-click to open on any Mac) plus Sparkle-style auto-update. For a tool
that hosts a local agent, this is the native and expected channel, not a workaround.

## What the split costs (and how it's mitigated)

- **No App Store search for the node.** Discovery happens *in-product* instead — EldrChat
  links users to the Huginn DMG ("set up your Mac node"), so the store isn't the funnel.
- **Two-part onboarding** (App Store app + DMG node) is the one real friction; an in-app
  handoff to the DMG download keeps it to a ~60-second flow.
- It does **not** block shipping, trust, or updates — all solved without the App Store.

## How to ship each

- **EldrChat → TestFlight / App Store:** `TESTFLIGHT-GUIDE.md`. Sandbox-compatible,
  standard iOS submission (`ITSAppUsesNonExemptEncryption = YES` + ENC export
  self-classification — §C there). App names are globally unique on App Store Connect, so
  confirm "EldrChat" is available when creating the record.
- **Huginn → notarized DMG:** `SIGNING-AND-DISTRIBUTION.md`. Requires a **Developer ID
  Application** certificate (paid Apple Developer Program) + an app-specific password;
  `Apps/Huginn/build-dmg.sh` runs the whole pipeline (archive → notarize → staple → DMG)
  and outputs `Apps/Huginn/dist/Huginn-<version>.dmg`.
