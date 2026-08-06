# CLAUDE.md — PQRC iOS Client ("iMessage for the AI age")

This repository contains the v1 iOS client and test suite for **PQRC (Post-Quantum Ratcheted Conversations)** — a post-quantum, decentralized, AI-native E2EE messenger over Nostr.

## Read these, in this order, before writing code

1. `docs/pqrc-SPEC-v1_1.md` — the protocol. **This is law.**
2. `docs/NIP-XX-pqrc.md` — the wire format. Law for anything on the wire.
3. `docs/APP-SPEC.md` — what to build (product + architecture + UI).
4. `docs/TEST-PLAN.md` — how to prove it works (the test suite is a first-class deliverable, not an afterthought).

**Conflict resolution order:** SPEC > NIP > APP-SPEC > this file. If a gap exists in all of them, choose the privacy-maximizing option, implement it, and record the decision in `docs/DEVIATIONS.md`. Do not stop to ask; leave a clearly-marked TODO and keep going.

**The cardinal rule (SPEC §0): user privacy is the number one priority, without exception.** Every tie resolves in favor of privacy, even at the cost of convenience, features, or performance.

## Truthful reporting

- **Never report a build, test, or feature as working without having run it and
  seen it pass.** Distinguish what is *proven* (ran it, saw the output) from what
  is *inferred* or *compile-checked only*. Label every unverified claim as
  unverified.
- If something is broken, can't be done, or was claimed done but wasn't, say so
  plainly and show the evidence. Nothing merges red.

## Stack

- **Language:** Swift 6.x, strict concurrency enabled everywhere (`-strict-concurrency=complete`). No `@unchecked Sendable` without a written justification comment.
- **UI:** SwiftUI only. iOS 26.0 minimum deployment target. Adopt the iOS 26 design language (Liquid Glass) via standard system components; custom chrome only where APP-SPEC says so.
- **Crypto:** Apple CryptoKit on-device; `swift-crypto` **pinned ≥ 4.3.1** for the platform-agnostic core package (SPEC §2 — the pin is a CVE fix, do not lower it). **No other crypto dependencies. No libsignal. No custom primitives.** PQRC composes vetted building blocks; it never invents them.
- **Nostr event signing:** secp256k1 BIP-340 Schnorr via a maintained Swift package (suggest `21-DOT-DEV/swift-secp256k1`; any equivalent maintained BIP-340 implementation is acceptable). CryptoKit does not provide secp256k1.
- **Persistence:** SwiftData in the app layer behind a `MessageStore` protocol defined in core; sensitive fields envelope-encrypted at the application layer per SPEC §3.4 (see APP-SPEC §3).
- **Testing:** Swift Testing (`@Test`, `#expect`) for all logic; XCTest only where required (XCUITest UI tests, `measure`/XCTMetric performance tests).

## Platform expansion roadmap (iPad / Mac) — responsive pass DONE; verify on-device

The product is text-only and privacy-first (AI/Human context sharing; NOT a media
platform — images/video stay out of scope, "use iMessage for that"). It runs on
iPhone, iPad, and Mac (Mac Catalyst) from one SwiftUI codebase, with the UI
**responsive to screen size and usable in landscape** — do NOT lock to portrait.
The adaptive pass is largely complete (DEVIATIONS AC37/AC40/AC42); when touching UI,
PRESERVE it and verify on-device — don't regress it:
- `MainView` is a **`NavigationSplitView`** (conversation list + detail): wide
  screens (iPad/Mac/landscape) show list-and-detail side by side, compact widths
  (iPhone portrait) collapse to a stack. Mac Catalyst adds a menu bar, keyboard
  shortcuts, and a resizable window. Do NOT regress this back to a `NavigationStack`.
- Reading-width content is constrained (`.frame(maxWidth:)` on the message list /
  forms) so chat bubbles don't sprawl edge-to-edge on a 27" display, while lists/
  detail use the extra width. Keep new chrome within this pattern.
- The full-screen markdown reader (`FullScreenReaderView`) — landscape + pinch-zoom —
  is the reference for responsive behavior.
- Remaining work is **on-device verification**: confirm every primary screen
  (conversation list, ConversationView, ThreadView, Settings, Onboarding) holds up in
  landscape and at iPad/Mac widths (they were built iPhone-portrait-first). Orientations
  are enabled app-wide; this is a verification pass, not new layout work.
- Keep it SwiftUI-only; reuse the existing `AppModel`/`PersonaRuntime` engine (it's
  platform-agnostic). Mac/iPad get the same engine, only the View layer adapts.

## Repository layout (actual)

```
Packages/
  PQRCCore/        # identity, agent derivation, PQXDH, Double Ratchet, PQ rekey,
                   # padding, AEAD, gift-wrap codec, MessageStore protocol, EncryptedStore.
                   # NO UIKit/SwiftUI imports. Builds + `swift test` on macOS (swift-crypto).
  PQRCNostr/       # Nostr event model, BIP-340 signing, NIP-01 codec, RelayTransport,
                   # LocalRelaySimulator, relay chunking, Multipeer link, `pqrc-relay` exe.
  PQRCAgent/       # AgentProvider protocol + Demo / FoundationModels / API providers,
                   # AgentEngine (ai_window, thread invites, loop guard).
  PQRCACP/         # the ACP agent protocol: tool executor, path jail, permission flow,
                   # PTY, context budget, at-rest log redaction. The `eldr-acp` executable.
  PQRCMCP/         # MCP server — the phone's chat context to an agent, as CODENAMES only.
  EldrNode/        # headless `eldr-node` daemon (Mac/server) + sybilclaw gateway client.
  Eldrctl/         # `eldrctl` CLI — SSH installer / conduit provisioner.
  SwiftA2A/        # A2A v1.0 (Agent2Agent) core types, JSON-RPC, client/server, HTTP transport.
App/               # Thin SwiftUI iOS app (EldrChat.xcodeproj; sources still under App/PQRC/).
Apps/Huginn/       # macOS companion app (Huginn.xcodeproj) — pairs with the phone, runs the
                   # tethered AI + coding agent, encrypted at-rest AI memory.
TestVectors/       # Frozen JSON vectors (see TEST-PLAN §2).
docs/              # ALL documentation lives here — one folder, real files (the old root
                   # copies + symlinks are gone). Canon: pqrc-SPEC-v1_1.md, NIP-XX-pqrc.md,
                   # APP-SPEC.md, TEST-PLAN.md. Indexed by docs/README.md.
                   # What's left: docs/BACKLOG.md. Designs: docs/plan/.
                   # How-to: docs/guide/. Finished: docs/done/<date>/.
Eldr.xcworkspace   # ties the two apps + packages together.
```

Core logic lives in SPM packages so `swift test` runs headlessly and fast; the app targets stay thin. This is deliberate — iterate in packages, verify in the simulator.

**Sources still live under `App/PQRC/`** even though the project/scheme is `EldrChat` — the directory was never renamed. Don't "fix" it casually; the pbxproj uses file-system-synchronized groups.

## Commands

**Toolchain rule (hard): build/test against the Xcode 27 beta, NOT the 26.x release —
unless the user EXPLICITLY asks for the stable one.** The `xcode-select` default is
`/Applications/Xcode.app` (a 26.x release — 26.6 as of 2026-07-19; don't assume a
specific point release, run `xcodebuild -version`), whose SDK is missing iOS-27
symbols this app uses — most notably the Private Cloud Compute FoundationModels API
(`PrivateCloudComputeLanguageModel`, `ContextOptions`). Building with 26.x does not
fail — the app compiles and silently drops to the non-PCC path — so a 26.x build is
how you ship a phone that says "compiled against an SDK without the Private Cloud
Compute API". **Always export the beta's `DEVELOPER_DIR` before building:**

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer   # Xcode 27 — the default for this repo
```

### 🚫 THE PCC BUILD GATE — DO NOT TOUCH IT. EVER. (DEVIATIONS AC125)

**There is no PCC build flag, environment variable, `.define`, Xcode build setting,
or flag file. Do not add one. Do not "restore" one. The only correct action here is
no action.**

PCC gates itself on the SDK's own module version, in exactly one place —
`Packages/PQRCAgent/Sources/PQRCAgent/PCCFoundationModelsProvider.swift`:

```swift
#if canImport(FoundationModels, _version: 2.0) && (os(iOS) || os(macOS))
```

Xcode 27's FoundationModels declares `user-module-version 2.0.59` and vends the PCC
symbols; Xcode 26.6 declares `1.5.2` and does not. The compiler reads the installed
SDK and picks the right branch by itself — identically for the Xcode GUI, `xcodebuild`,
`swift test`, and CI, with nothing to configure, inherit, or forget. (The
`os(iOS) || os(macOS)` clause scopes it to the platforms Apple ships PCC on — the 2.0
module also appears on tvOS/watchOS/visionOS, where the symbols are unusable and the
version check alone would wrongly open the gate. Mac Catalyst is `os(iOS)`, so it's
covered.)

**Why this is locked.** Every manual flag has already been tried and each one broke
the product a different way:

| Attempt | Failure |
|---|---|
| `.define("ELDR_PCC_SDK")` unconditional | Broke stable Xcode + 3 of 5 CI jobs; no GitHub runner has Xcode 27 (AC123) |
| `ELDR_PCC_SDK` env-var opt-in | Dock-launched Xcode doesn't inherit shell env → PCC silently OFF in the app the owner actually runs (AC125) |
| `.pcc_enabled` flag file | Same silent-OFF failure; also invisible to SwiftPM's manifest cache |

```bash
# Fast inner loop (no simulator needed) — ALL EIGHT packages, not just the first three.
for p in PQRCCore PQRCNostr PQRCAgent PQRCACP PQRCMCP EldrNode Eldrctl SwiftA2A; do
  swift test --package-path "Packages/$p" || break
done

# Full app build + tests. The app project/target/scheme is EldrChat (renamed from PQRC;
# the old PQRC scheme is stale and won't resolve a destination).
xcodebuild -project App/EldrChat.xcodeproj -scheme EldrChat -showdestinations
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation

# The macOS companion app (Huginn) has its own project + suite — it is NOT covered by
# the iOS scheme and NOT in CI. Run it whenever you touch Apps/Huginn or the gateway.
# Huginn tests need REAL signing (the data-protection keychain group is team-scoped).
# NO team argument is needed — see § Code signing below; run `scripts/setup-signing.sh`
# once per clone and both projects sign themselves from then on.
xcodebuild test -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn \
  -destination 'platform=macOS' -skipPackagePluginValidation
```

**Three xcodebuild rules that have each cost real hours — do not rediscover them:**
- **`-skipPackagePluginValidation` is required.** swift-secp256k1 ships a build plugin; without the flag the build fails.
- **Pin `OS=26.5` and use a device name that exists.** This Mac has both the iOS 26.5 and iOS 27.0 runtimes, and an unpinned/ambiguous name silently flips between them. There is **no plain "iPhone 17" simulator** — run `-showdestinations` and pick a real one (`iPhone 17 Pro Max` works on 26.5).
- **NEVER pass `CODE_SIGNING_ALLOWED=NO` to `xcodebuild test` if any test touches the Keychain.** It strips entitlements, so every `SecItem*` call returns `errSecMissingEntitlement` (-34018) and the keychain/Secure-Enclave tests all fail in a way that looks like a code bug but isn't. Simulator builds sign ad-hoc and keep entitlements — just drop the flag.

### Code signing — one command per clone, zero personal data in git

An Apple Team ID identifies a real person in Apple's developer directory, and this
repo is public, so it must never appear in a tracked file. It leaked three times
anyway, always the same way: you open the project in Xcode with a team selected,
Xcode rewrites the pbxproj, and the line rides along in the next `git commit -a`.

The fix is the standard Xcode one — an **xcconfig with an optional include**:

| File | Tracked? | Holds |
|---|---|---|
| `Signing.xcconfig` | yes | `#include? "Signing.local.xcconfig"` + `DEVELOPMENT_TEAM = $(ELDR_DEV_TEAM)` |
| `Signing.local.xcconfig` | **no** (gitignored) | `ELDR_DEV_TEAM = <your team>` |

Both projects reference `Signing.xcconfig` as the **project-level**
`baseConfigurationReference`. Run this once per clone and never think about it again:

```bash
./scripts/setup-signing.sh          # detects your team, writes the gitignored file
ln -sf ../../scripts/check-no-team-id.sh .git/hooks/pre-commit   # blocks re-leaks
```

After that the Xcode GUI, `xcodebuild`, and every test command here sign with no
flags. **Do not pass `DEVELOPMENT_TEAM=` on the command line** — it is unnecessary
and it is how the wrong team got used for a whole debugging session.

Three things that make this work and are easy to break:

- **`#include?` is the optional form.** A fresh clone or CI runner has no local
  file, the include is skipped, `DEVELOPMENT_TEAM` resolves empty, and simulator
  builds sign ad-hoc exactly as before. Nothing to edit, no placeholder, no error.
- **An empty `DEVELOPMENT_TEAM = ""` in `buildSettings` BEATS the xcconfig.** Those
  were removed from both projects; do not let them come back. That mismatch — app
  target signed, test target pinned empty — is what produced the misleading
  "No signing certificate Mac Development found".
- **Not an environment variable.** Xcode launched from the Dock does not inherit
  your shell. This repo already paid for that lesson (DEVIATIONS AC125, where an
  env-var opt-in silently disabled PCC in the app the owner actually ran).

Detection reads **provisioning profiles**, not certificates. A certificate proves
you hold a key; a profile proves Xcode has an *account* for that team. They come
apart, and on this machine they name **different teams**: every "Apple Development"
cert in the keychain belongs to one team, while all 25 provisioning profiles — and
the only team that actually builds — belong to another. A cert-based guess picks
the team that cannot build, and the failure reads as a missing certificate:

```
error: No Account for Team "…". Add a new account in Accounts settings.
error: No signing certificate "Mac Development" found: … matching team ID "…"
```

The second line is a consequence of the first. Chasing the certificate, or adding
`-allowProvisioningUpdates`, is a dead end.

If a diff on `*.pbxproj` shows only a `DEVELOPMENT_TEAM` line, that is Xcode, not
your work — `git restore` it.

## Hard invariants — MUSTs the tests enforce

These come straight from the SPEC/NIP. Violating any of them is a failed build, not a style issue.

1. Key rotation is **message-driven, never wall-clock-driven**. No timers anywhere in key schedule code (SPEC §5.2).
2. Message keys are used once and **deleted immediately**; skipped-key cache bounded by `MAX_SKIP = 1000` and purged after use (SPEC §5.3).
3. `PQ_REKEY_INTERVAL = 50` messages, exactly (SPEC §6).
4. Plaintext padded to buckets `{256, 1024, 4096, 16384, 65536}` before AEAD; **content > 64 KB is never inlined** — **relay chunking only** (SPEC §7, §11).
   **The product is TEXT-ONLY and there is NO blob server — Blossom is rejected, permanently.** The user will not take on the liability/cost of *storing* people's data, only *transporting* it (relay = transient store-and-forward; a blob store is not). Images/video are out of scope ("use iMessage for that"). Large text splits into ordered, ratcheted relay events (`MessageBody.chunk {id,index,total}` inside the ciphertext), sized from each relay's NIP-11 `max_content_length`. `LocalBlossomSimulator` and the `BlobStore` seam still exist in `PQRCNostr` as **vestigial** code — do not build on them, do not "finish" them, and do not present a blob path as an option.
5. AEAD AD = `pqrc_version || participant_type || n || created_at_fuzzed`. **Timestamps are never inputs to key derivation** (SPEC §8.3, NIP).
6. Gift wrap: rumor is unsigned and never published unwrapped; seal signed by sender's Nostr key; outer wrap signed by a fresh random one-time key per message; `created_at` on seal and wrap fuzzed up to 2 days **into the past** (SPEC §8).
7. The kind-10420 binding is verified **in both directions** before any key from it is trusted (SPEC §3.3).
8. `participant_type` is honest: agent-signed messages MUST carry `"agent"` and MUST render as AI-authored. A human label under an agent signature is rejected as a protocol violation (SPEC §8.2, §13.4).
9. `ai_window` announcements are valid only when signed by the **human identity key**, are time-bounded, and produce a visible indicator in every client for the duration. Agents cannot self-activate, and autonomous sends outside an active window/thread-invite MUST fail closed (SPEC §13).
10. All long-term secrets: Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never exported, never synced, never logged. The at-rest master key MUST be wrapped by the device's **secure element** — Secure Enclave P-256 on Apple platforms (iOS + modern Mac), the platform-equivalent hardware keystore (StrongBox/TPM) elsewhere, and a hardened-passphrase KEK **only** where no secure element exists. The passphrase-only silo KEK that made accounts offline-brute-forceable from a stolen-device image is reverted. Each account chooses, at setup, an optional **passphrase** (layered under the hardware wrap) and/or **biometric** unlock (SPEC §2 — no invented primitives — §3.1, §3.4; full tradeoffs + the deniability cost in DEVIATIONS AC31).
11. Consumed one-time prekey private halves are deleted; exhaustion falls back to the last-resort key with the documented unlinkability caveat surfaced in DEVIATIONS/THREAT_MODEL, never a confidentiality downgrade (SPEC §4.1).
12. Every payload-adjacent value in logs uses OSLog `privacy: .private`. A canary-scan test enforces no plaintext in logs or at rest.

## Engineering conventions

- Actors own all mutable session/ratchet state. No locks.
- Dependency seams are protocols, injected: `RelayTransport`, `BlobStore`, `AgentProvider`, `MessageStore`, `RandomSource`, `NonceSource`, `Clock`. Production uses system implementations; tests use seeded/deterministic ones. **No unit test touches the network or the real clock.**
- Typed errors (`enum ... : Error`); no `try!`, no force unwraps, no `fatalError` outside truly unreachable code.
- Wire structs round-trip through Codable with stable field names matching the NIP exactly (`spk`, `pqpk`, `otp`, `otp_pq`, `lrp`, `dh`, `pn`, `n`, `pq`, `ptr`, …).
- Unknown JSON fields are preserved-or-ignored, never fatal (forward compatibility, SPEC §12).

## Documentation lifecycle — every doc has a type, and two of them expire

`docs/README.md` is the index and **`docs/BACKLOG.md` is the single list of unbuilt
work** — not a plan doc, not DEVIATIONS, not `private/`. Read the index before adding
a document; the odds are high that the right move is editing one that already exists.

**Every document is exactly one of four types.** The type decides where it lives
and how it ends:

| Type | Lives in | How it ends |
|---|---|---|
| **Law** | `docs/` | Never. Edited in place. SPEC, NIP, APP-SPEC, TEST-PLAN, THREAT_MODEL, the CC0 extensions. |
| **Guide** | `docs/` | Never, but it rots — it encodes commands, counts, and version numbers. Fix it when you touch what it describes. |
| **Ledger** | `docs/` | Never. `DEVIATIONS.md` is append-only: a wrong entry is corrected by **appending a bracketed correction**, never by rewriting history. |
| **Plan** | `docs/plan/` | **Expires.** It leaves the moment its work lands in DEVIATIONS. |

**The rule that matters, because breaking it is what caused the sprawl:**

> **A finished plan moves to `docs/done/<YYYY-MM-DD>/`. It is never edited into
> a status report and left in `docs/`.**

A plan that stays put becomes three documents at once — a plan, a status board, and
an archive — and each wants a different shape. That is where the "Status: BUILT"
preambles stacked on top of unchanged plan bodies come from, and it is why the same
fact ended up copied into five documents and then corrected in only one.

When a plan's work lands:

1. Write the DEVIATIONS entry. **That is the durable record** — not the plan doc.
2. `git mv` the plan to `docs/done/<YYYY-MM-DD>/`, dated by retirement.
3. Add a header: what superseded it, and what in it is still worth reading. If a
   specific claim turned out to be *wrong* rather than merely superseded, say so —
   those are different warnings.
4. **Re-point every inbound reference, including Swift source comments.**
   `grep -rn "<filename>" .` — comments in `Packages/` count. When
   `ACPRouterplan.md` was archived, seven files under `Packages/PQRCACP/` were left
   pointing at a path that no longer exists.
5. **Strike the item from `docs/BACKLOG.md`**, or move it down a section if only
   part of it landed. That file is the single answer to "what is left to build?" —
   if it is not swept, it stops being the answer and the sprawl comes back.

**Before writing any new document, in order:**

- Does an existing doc own this subject? Edit it.
- Is this a decision rather than a document? It is a DEVIATIONS entry. Most
  "analysis docs" are one long DEVIATIONS entry that escaped.
- Is it a plan? It goes in `docs/plan/` with an **owner** and an **exit condition**
  in the first ten lines, and a workstream prefix that is not already taken (grep
  DEVIATIONS: `WS-G`, `WS-L`, `WS-M`, `WS-I`, `WS-BM`, `WS-B`/`C`/`D` are in use).
- Is it a fact already stated elsewhere? **Link it, do not copy it.**

**Status honesty is per-claim, not per-document.** A banner at the top of a long
document is how a reader ends up trusting the paragraphs underneath it that are no
longer true. Mark the individual claim.

## Definition of done 

- [ ] All **eight** packages compile; `swift test` green on every package.
- [ ] Both app targets build: `xcodebuild test` green for **EldrChat** (incl. UI smoke tests + the accessibility audit) **and for Huginn** (macOS).
- [ ] TEST-PLAN coverage implemented: crypto vectors frozen in `TestVectors/`, ratchet/FS/PCS proofs, envelope/padding/fuzz checks, agent-integrity suite, simulator chaos matrix, group fan-out, performance budgets wired (baseline-relative).
- [ ] Demo "Local Universe" runs: scripted Alice/Bob conversation incl. one AI-drafted message, one `ai_window`, one shared AI thread, one >64 KB paste (**via relay chunking**), one group of 4. Script documented in `docs/guide/DEMO.md`.
- [ ] `docs/THREAT_MODEL.md` generated per SPEC §15.3 (honest about IP visibility, recipient `p`-tag, no deniability, single-device).
- [ ] `docs/DEVIATIONS.md` lists every judgment call made, each tagged `[upstream-NIP]`, `[app-only]`, or `[tech-debt]`.
- [ ] No TODO blocks a green test run.
