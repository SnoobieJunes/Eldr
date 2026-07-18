# AGENTS.md — Eldr / PQRC

Agent-facing orientation for this repo. The full contract is `CLAUDE.md`; the specs
it points to are law.

## What this is

The v1 iOS client + test suite for **PQRC (Post-Quantum Ratcheted Conversations)**: a
post-quantum, decentralized, AI-native end-to-end-encrypted messenger over Nostr. It is
**text-only and privacy-first** — no media, no blob/storage server ("use iMessage for
that"). **User privacy is the number-one priority, without exception**; every tie
breaks toward privacy.

## Package layout (`Packages/`)

- `PQRCCore` — identity, PQXDH, Double Ratchet, PQ rekey, padding, AEAD, gift-wrap,
  `MessageStore`/`EncryptedStore`. No UIKit/SwiftUI.
- `PQRCNostr` — Nostr event model, BIP-340 signing, NIP-01 codec, relays, chunking.
- `PQRCAgent` — `AgentProvider` + Demo/FoundationModels/API providers, `AgentEngine`.
- `PQRCACP` — the ACP agent: tool executor, path jail, permission flow, PTY, context
  budget, at-rest log redaction. The `eldr-acp` executable.
- `PQRCMCP` — MCP server exposing the phone's chat context as CODENAMES only.
- `EldrNode` / `Eldrctl` — headless `eldr-node` daemon + `eldrctl` CLI.
- `SwiftA2A` — A2A v1.0 (Agent2Agent) core types, JSON-RPC, client/server, HTTP transport.

`App/` is the thin SwiftUI iOS app (`EldrChat.xcodeproj`; sources under `App/PQRC/`).
`Apps/Huginn/` is the macOS companion (`Huginn.xcodeproj`) that runs the tethered AI +
coding agent.

## Build / test

**Toolchain rule (hard): export the Xcode 27 beta first, or app builds fail with
missing iOS-27 symbols:**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

```bash
# Fast headless inner loop — all eight packages.
for p in PQRCCore PQRCNostr PQRCAgent PQRCACP PQRCMCP EldrNode Eldrctl SwiftA2A; do
  swift test --package-path "Packages/$p" || break
done

# iOS app + macOS companion (need -skipPackagePluginValidation; pin OS=26.5).
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation
xcodebuild test -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn \
  -destination 'platform=macOS' -skipPackagePluginValidation
```

- `-skipPackagePluginValidation` is required (swift-secp256k1 ships a build plugin).
- Do NOT pass `CODE_SIGNING_ALLOWED=NO` to tests that touch the Keychain.
- `PQRCACP`'s `swift test` hangs under a sandboxed shell — run it with the sandbox off.

## Hard invariants (violating one is a failed build, not a style nit)

- **Swift 6, strict concurrency complete.** Typed errors; no `try!`, no force unwraps,
  no `fatalError` outside truly-unreachable code. Actors own mutable state; no locks.
- **Crypto:** CryptoKit on-device, `swift-crypto ≥ 4.3.1` in core. No other crypto deps,
  no libsignal, no custom primitives.
- Key rotation is **message-driven, never wall-clock** (no timers in key-schedule code).
  Message keys used once then deleted; `MAX_SKIP = 1000`; `PQ_REKEY_INTERVAL = 50`.
- Plaintext padded to `{256,1024,4096,16384,65536}`; content > 64 KB is **relay-chunked,
  never inlined**. No blob server, ever.
- `participant_type` is honest: agent-signed messages render as AI-authored.
- `ai_window` is valid only when signed by the human identity key, time-bounded, and
  visibly indicated; agents can't self-activate; autonomous sends fail closed.
- Long-term secrets: Keychain `WhenUnlockedThisDeviceOnly`, hardware-wrapped, never
  exported/synced/logged. **Every payload-adjacent log value uses OSLog `privacy:
  .private`** — a canary scan enforces no plaintext in logs or at rest.

## Conventions

Dependency seams are injected protocols (`RelayTransport`, `AgentProvider`,
`MessageStore`, `RandomSource`, `Clock`, …) so tests stay off the network and the real
clock. Wire structs round-trip through Codable with the NIP's exact field names; unknown
JSON fields are preserved-or-ignored, never fatal. Record every judgment call in
`docs/DEVIATIONS.md` tagged `[upstream-NIP]`, `[app-only]`, or `[tech-debt]`.
