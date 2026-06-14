# CLAUDE.md — PQRC iOS Client ("iMessage for the AI age")

This repository contains the v1 iOS client and test suite for **PQRC (Post-Quantum Ratcheted Conversations)** — a post-quantum, decentralized, AI-native E2EE messenger over Nostr.

## Read these, in this order, before writing code

1. `docs/pqrc-SPEC-v1_1.md` — the protocol. **This is law.**
2. `docs/NIP-XX-pqrc.md` — the wire format. Law for anything on the wire.
3. `docs/APP-SPEC.md` — what to build (product + architecture + UI).
4. `docs/TEST-PLAN.md` — how to prove it works (the test suite is a first-class deliverable, not an afterthought).

**Conflict resolution order:** SPEC > NIP > APP-SPEC > this file. If a gap exists in all of them, choose the privacy-maximizing option, implement it, and record the decision in `docs/DEVIATIONS.md`. Do not stop to ask; leave a clearly-marked TODO and keep going.

**The cardinal rule (SPEC §0): user privacy is the number one priority, without exception.** Every tie resolves in favor of privacy, even at the cost of convenience, features, or performance.

## Stack

- **Language:** Swift 6.x, strict concurrency enabled everywhere (`-strict-concurrency=complete`). No `@unchecked Sendable` without a written justification comment.
- **UI:** SwiftUI only. iOS 26.0 minimum deployment target. Adopt the iOS 26 design language (Liquid Glass) via standard system components; custom chrome only where APP-SPEC says so.
- **Crypto:** Apple CryptoKit on-device; `swift-crypto` **pinned ≥ 4.3.1** for the platform-agnostic core package (SPEC §2 — the pin is a CVE fix, do not lower it). **No other crypto dependencies. No libsignal. No custom primitives.** PQRC composes vetted building blocks; it never invents them.
- **Nostr event signing:** secp256k1 BIP-340 Schnorr via a maintained Swift package (suggest `21-DOT-DEV/swift-secp256k1`; any equivalent maintained BIP-340 implementation is acceptable). CryptoKit does not provide secp256k1.
- **Persistence:** SwiftData in the app layer behind a `MessageStore` protocol defined in core; sensitive fields envelope-encrypted at the application layer per SPEC §3.4 (see APP-SPEC §3).
- **Testing:** Swift Testing (`@Test`, `#expect`) for all logic; XCTest only where required (XCUITest UI tests, `measure`/XCTMetric performance tests).

## Repository layout (target)

```
Packages/
  PQRCCore/        # identity, agent derivation, PQXDH, Double Ratchet, PQ rekey,
                   # padding, AEAD, gift-wrap codec. NO UIKit/SwiftUI imports.
                   # Must build and `swift test` on macOS (uses swift-crypto).
  PQRCNostr/       # Nostr event model, BIP-340 signing, NIP-01 codec,
                   # RelayTransport protocol, LocalRelaySimulator, LocalBlossomSimulator.
  PQRCAgent/       # AgentProvider protocol + Mock / FoundationModels / Anthropic providers.
App/               # Thin SwiftUI app target (PQRC.xcodeproj), UI tests, perf tests.
TestVectors/       # Frozen JSON vectors (see TEST-PLAN §2).
docs/              # The four documents above + generated THREAT_MODEL.md, DEMO.md, DEVIATIONS.md.
```

Core logic lives in SPM packages so `swift test` runs headlessly and fast; the app target stays thin. This is deliberate — iterate in packages, verify in the simulator.

## Commands

```bash
# Fast inner loop (no simulator needed)
swift test --package-path Packages/PQRCCore
swift test --package-path Packages/PQRCNostr
swift test --package-path Packages/PQRCAgent

# Full app build + tests (discover available simulators first if the name fails).
# The app project/target/scheme is EldrChat (renamed from PQRC; the old PQRC
# scheme is stale and won't resolve a destination).
xcodebuild -project App/EldrChat.xcodeproj -scheme EldrChat -showdestinations
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Hard invariants — MUSTs the tests enforce

These come straight from the SPEC/NIP. Violating any of them is a failed build, not a style issue.

1. Key rotation is **message-driven, never wall-clock-driven**. No timers anywhere in key schedule code (SPEC §5.2).
2. Message keys are used once and **deleted immediately**; skipped-key cache bounded by `MAX_SKIP = 1000` and purged after use (SPEC §5.3).
3. `PQ_REKEY_INTERVAL = 50` messages, exactly (SPEC §6).
4. Plaintext padded to buckets `{256, 1024, 4096, 16384, 65536}` before AEAD; **content > 64 KB is never inlined** — Blossom pointer or chunking only (SPEC §7, §11).
5. AEAD AD = `pqrc_version || participant_type || n || created_at_fuzzed`. **Timestamps are never inputs to key derivation** (SPEC §8.3, NIP).
6. Gift wrap: rumor is unsigned and never published unwrapped; seal signed by sender's Nostr key; outer wrap signed by a fresh random one-time key per message; `created_at` on seal and wrap fuzzed up to 2 days **into the past** (SPEC §8).
7. The kind-10420 binding is verified **in both directions** before any key from it is trusted (SPEC §3.3).
8. `participant_type` is honest: agent-signed messages MUST carry `"agent"` and MUST render as AI-authored. A human label under an agent signature is rejected as a protocol violation (SPEC §8.2, §13.4).
9. `ai_window` announcements are valid only when signed by the **human identity key**, are time-bounded, and produce a visible indicator in every client for the duration. Agents cannot self-activate, and autonomous sends outside an active window/thread-invite MUST fail closed (SPEC §13).
10. All long-term secrets: Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, wrapped via Secure Enclave P-256, never exported, never synced, never logged (SPEC §3.1, §3.4).
11. Consumed one-time prekey private halves are deleted; exhaustion falls back to the last-resort key with the documented unlinkability caveat surfaced in DEVIATIONS/THREAT_MODEL, never a confidentiality downgrade (SPEC §4.1).
12. Every payload-adjacent value in logs uses OSLog `privacy: .private`. A canary-scan test enforces no plaintext in logs or at rest.

## Engineering conventions

- Actors own all mutable session/ratchet state. No locks.
- Dependency seams are protocols, injected: `RelayTransport`, `BlobStore`, `AgentProvider`, `MessageStore`, `RandomSource`, `NonceSource`, `Clock`. Production uses system implementations; tests use seeded/deterministic ones. **No unit test touches the network or the real clock.**
- Typed errors (`enum ... : Error`); no `try!`, no force unwraps, no `fatalError` outside truly unreachable code.
- Wire structs round-trip through Codable with stable field names matching the NIP exactly (`spk`, `pqpk`, `otp`, `otp_pq`, `lrp`, `dh`, `pn`, `n`, `pq`, `ptr`, …).
- Unknown JSON fields are preserved-or-ignored, never fatal (forward compatibility, SPEC §12).

## Definition of done (one-shot)

- [ ] All three packages compile; `swift test` green on every package.
- [ ] App target builds; `xcodebuild test` green including UI smoke tests and the accessibility audit.
- [ ] TEST-PLAN coverage implemented: crypto vectors frozen in `TestVectors/`, ratchet/FS/PCS proofs, envelope/padding/fuzz checks, agent-integrity suite, simulator chaos matrix, group fan-out, performance budgets wired (baseline-relative).
- [ ] Demo "Local Universe" runs: scripted Alice/Bob conversation incl. one AI-drafted message, one `ai_window`, one shared AI thread, one >64 KB paste, one group of 4. Script documented in `docs/DEMO.md`.
- [ ] `docs/THREAT_MODEL.md` generated per SPEC §15.3 (honest about IP visibility, recipient `p`-tag, no deniability, single-device).
- [ ] `docs/DEVIATIONS.md` lists every judgment call made, each tagged `[upstream-NIP]`, `[app-only]`, or `[tech-debt]`.
- [ ] No TODO blocks a green test run.
