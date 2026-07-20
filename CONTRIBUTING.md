# Contributing to Eldr

Thanks for wanting to help. This project holds one rule above everything:
**user privacy is the number-one priority, without exception** (SPEC §0). Every
tie — convenience, features, performance — resolves toward privacy. Reviews
enforce that before anything else.

The most valuable contributions right now, in order: **on-device testing**
(pairing, tethered AI, the coding-agent conduit), **security review** (read the
[SPEC](docs/pqrc-SPEC-v1_1.md) and [THREAT_MODEL](docs/THREAT_MODEL.md), then
try to break the implementation), **UX confusion reports** (as valuable as
crashes), **relay operation**, and code.

Vulnerabilities: **never a public issue** — see [SECURITY.md](SECURITY.md).

## Toolchain

- macOS 26 + **stable Xcode 26.5** — this builds everything; CI uses exactly
  this. Install the iOS 26.5 simulator runtime (Xcode → Settings → Components).
- The **Xcode 27 beta** is needed *only* if you enable the experimental Private
  Cloud Compute tier (`ELDR_PCC_SDK`, off by default). For that:
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Building and testing

Core logic lives in eight SPM packages that build and test headlessly — no
simulator needed. This is the fast inner loop; use it:

```bash
for p in PQRCCore PQRCNostr PQRCAgent PQRCACP PQRCMCP EldrNode Eldrctl SwiftA2A; do
  swift test --package-path "Packages/$p" || break
done
```

The apps:

```bash
# iOS app (simulator) — unit + UI + accessibility suites.
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation

# macOS companion (Huginn) — its own project + suite, not covered by the iOS scheme.
# Tests need real signing (team-scoped keychain group) — pass YOUR team id; a free
# personal team works. Building only? Use CODE_SIGNING_ALLOWED=NO instead.
xcodebuild test -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn \
  -destination 'platform=macOS' -skipPackagePluginValidation \
  DEVELOPMENT_TEAM=<your-team-id>
```

### The four build traps (each has cost real hours)

1. **`-skipPackagePluginValidation` is required.** swift-secp256k1 ships a build
   plugin; without the flag the build fails.
2. **Pin `OS=26.5` and use a simulator that exists.** There is no plain
   "iPhone 17" simulator; run `xcodebuild -showdestinations` and pick a real one
   (`iPhone 17 Pro Max` works). An ambiguous name silently flips between
   installed runtimes.
3. **Never pass `CODE_SIGNING_ALLOWED=NO` to `xcodebuild test`.** It strips
   entitlements, so every Keychain call fails with `errSecMissingEntitlement`
   (-34018) and the keychain/Secure-Enclave tests fail in a way that looks like
   a code bug. Simulator test builds sign ad-hoc and keep entitlements — just
   drop the flag. (Plain `build` with it is fine; CI does that.)
4. **`DEVELOPMENT_TEAM` is intentionally blank** in the checked-in projects.
   - EldrChat, simulator: works as-is — ad-hoc signing covers build *and* test.
   - EldrChat, physical device: set your own team in Signing & Capabilities;
     don't commit it.
   - Huginn (native macOS): `build` works teamlessly with
     `CODE_SIGNING_ALLOWED=NO`; `test` needs real signing because the
     data-protection keychain group is team-scoped — pass
     `DEVELOPMENT_TEAM=<your-team-id>` on the command line (free personal
     team is fine).

## Test culture

The test suite is a first-class deliverable ([TEST-PLAN](docs/TEST-PLAN.md)),
not an afterthought. House rules:

- **No unit test touches the network or the real clock.** Dependency seams are
  injected protocols (`RelayTransport`, `MessageStore`, `RandomSource`, `Clock`,
  …); tests use seeded/deterministic implementations.
- **`TestVectors/` is frozen byte-for-byte.** Never regenerate vectors as a side
  effect. A vector change is a protocol change: it needs a SPEC/NIP citation and
  its own justification in the PR.
- Swift Testing (`@Test`, `#expect`) for logic; XCTest only where required
  (XCUITest, performance metrics).
- Actors own all mutable state — no locks. Typed errors; no `try!`, no force
  unwraps, no `fatalError` outside truly unreachable code.
- Strict concurrency (`-strict-concurrency=complete`) everywhere. No
  `@unchecked Sendable` without a written justification comment.

## The hard invariants — the review bar

These come from the [SPEC](docs/pqrc-SPEC-v1_1.md) and
[NIP](docs/NIP-XX-pqrc.md); the tests enforce them. A PR that violates one is
rejected regardless of how nice the feature is.

1. Key rotation is **message-driven, never wall-clock-driven** — no timers
   anywhere in key-schedule code (SPEC §5.2).
2. Message keys are used once and **deleted immediately**; the skipped-key cache
   is bounded by `MAX_SKIP = 1000` and purged after use (§5.3).
3. `PQ_REKEY_INTERVAL = 50` messages, exactly (§6).
4. Plaintext is padded to buckets `{256, 1024, 4096, 16384, 65536}` before AEAD;
   content > 64 KB is **never inlined** — relay chunking only. **There is no
   blob server and never will be**; Eldr is text-only, permanently (§7, §11,
   DEVIATIONS T5).
5. AEAD associated data = `pqrc_version ‖ participant_type ‖ n ‖
   created_at_fuzzed`; **timestamps are never inputs to key derivation** (§8.3).
6. Gift wrap: the rumor is unsigned and never published unwrapped; the seal is
   signed by the sender's key; the outer wrap by a fresh one-time key per
   message; `created_at` fuzzed up to 2 days **into the past** (§8).
7. The kind-10420 binding is verified **in both directions** before any key from
   it is trusted (§3.3).
8. `participant_type` is honest: agent-signed messages MUST carry `"agent"` and
   MUST render as AI-authored; a human label under an agent signature is a
   protocol violation (§8.2, §13.4).
9. `ai_window` announcements are valid only when signed by the **human** identity
   key, are time-bounded, and show a visible indicator for their whole duration;
   agents cannot self-activate, and autonomous sends outside a window/thread
   invite **fail closed** (§13).
10. Long-term secrets live in the Keychain
    (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`), never exported, synced, or
    logged; the at-rest master key is wrapped by the device's secure element
    (§2, §3.1, §3.4).
11. Consumed one-time prekey private halves are deleted; exhaustion falls back
    to the last-resort key with the documented caveat — never a confidentiality
    downgrade (§4.1).
12. Every payload-adjacent value in logs uses OSLog `privacy: .private`; a
    canary-scan test enforces no plaintext in logs or at rest.

## What not to submit

- **New or modified crypto primitives.** PQRC composes vetted building blocks
  (CryptoKit / swift-crypto / swift-secp256k1); it never invents them (SPEC §2).
- **Blob or media storage of any kind.** Blossom is permanently rejected; the
  vestigial `BlobStore`/`LocalBlossomSimulator` seams must not be built on.
- **Wall-clock-driven key rotation** or timers in the key schedule.
- **Images/video/attachments** — out of scope ("use iMessage for that").
- Features that trade privacy for convenience. The tie always breaks the other
  way.

## Pull requests

1. Fork → feature branch → PR against `main`.
2. **CI must pass** — the package matrix (all eight), the iOS + Mac Catalyst
   build gate, and the app test job. The performance job is non-blocking.
3. **Spec-affecting changes must add a [DEVIATIONS.md](docs/DEVIATIONS.md)
   entry** — every judgment call gets a row, tagged `[upstream-NIP]`,
   `[app-only]`, or `[tech-debt]`.
4. **Crypto/protocol changes need a SPEC/NIP citation** in the PR description.
5. State your **test evidence**: which suites you ran and their results. "It
   compiles" is not evidence; nothing merges red.

### Licensing of contributions

This repo is split-licensed (see [LICENSING.md](LICENSING.md)):

- **`Packages/`** (Apache-2.0): contributions are accepted under the
  [Developer Certificate of Origin](https://developercertificate.org). Sign off
  every commit (`git commit -s`); inbound = outbound Apache-2.0.
- **`App/` and `Apps/`** (AGPL-3.0-only + store exception): contributions
  additionally require agreeing to the [Contributor License
  Agreement](CLA.md) — you keep your copyright, and grant the maintainers the
  rights needed to keep shipping the apps (including through Apple's store and
  in commercially licensed builds). You'll be asked to confirm agreement on
  your first app-target PR.

DCO sign-off is expected on all commits either way.
