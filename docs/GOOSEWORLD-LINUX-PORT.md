<!-- SPDX-License-Identifier: Apache-2.0 -->
# Linux eldr-node — a town on Linux (GOOSEWORLD §6 WS-G6 follow-up)

**Status: PLAN, not implementation.** This is the honest engineering path for running an
eldr-node *town* (the `eldrctl found-town` deliverable) on a Linux host — a server, a VPS,
a Raspberry Pi — instead of a Mac. Every claim below is grounded in a real file:line read
on 2026-07-21. Where a claim needs a Linux toolchain to prove, it is labelled
**`[unverified]`** — this repo's `swift test` runs on macOS today, so nothing here has been
compiled on Linux.

The house rule (SPEC §0 / CLAUDE.md invariant 10) does not bend for a server: long-term
secrets must still be wrapped by a hardware keystore where one exists, and the
passphrase-only fallback carries the deniability/brute-force cost DEVIATIONS AC31 already
documents. Porting to Linux is exactly the ladder invariant 10 anticipates: **Secure
Enclave on Apple → TPM 2.0 on Linux where present → hardened-passphrase KEK only where no
secure element exists.**

---

## 1. What already ports for free

Verified by reading the source, not from memory.

| Component | File(s) | Portability |
|---|---|---|
| **swift-crypto core** | `Packages/PQRCCore/Package.swift:13` (`swift-crypto ≥ 4.3.1`) | swift-crypto is Apple's cross-platform CryptoKit-shaped library and builds on Linux. PQRCCore uses `import Crypto` (NOT `import CryptoKit`) everywhere — grep shows ~10 files (`PQRXDH.swift`, `DoubleRatchet.swift`, `PrekeyManager.swift`, …) all on `import Crypto`. **Clean.** `[unverified: Linux compile]` |
| **BIP-340 Schnorr** | `Packages/PQRCNostr/Package.swift:24` (`swift-secp256k1 0.23.0`) | 21-DOT-DEV/swift-secp256k1 vendors libsecp256k1 (C) and advertises Linux support. **Expected clean**, but the build plugin + C interop want a real Linux run. `[unverified]` |
| **At-rest envelope encryption** | `Packages/PQRCCore/Sources/PQRCCore/Store/EncryptedStore.swift:10` | `MasterKeyWrapper` is **already a protocol seam**, with `SoftwareKeyWrapper` (AES-256-GCM, `import Crypto`) for "platforms without a Secure Enclave" (its own doc comment, line 15). The store logic is portable; only the *production wrapper* is Apple-specific (see §3). |
| **EldrNodeCore serve-loop LOGIC** | `Packages/EldrNode/Sources/EldrNodeCore/EldrNodeCore.swift` | The C-3 owner gate (`routeInbound`, `:339`), the town A2A gate (`routeInboundA2A`, `:418`), `bootstrapOwnerFromRequest` (`:526`), the `NodeMessenger` protocol seam (`:38`) — all pure Swift, `import Crypto`-free, no `import Security`, DI'd. **The reasoning is platform-agnostic.** BUT see the blocker in §2: `serve` *calls into* `runHarness`, which is macOS-gated, so the file as written compiles only where that does. |
| **LAN Multipeer link** | `MultipeerNearbyLink.swift:2`, `NostrRelayServer.swift` | `#if canImport(MultipeerConnectivity)` — Apple-only, but **already self-excluding**. On Linux it compiles to nothing; the town simply has no Bonjour/AWDL nearby link and relies on the relay/hub. Non-blocking. |
| **The goose extension** | `Packages/PQRCMCP/Sources/eldr-gooseworld/main.swift:2` | Already `#if canImport(Glibc)` / else `Darwin`. Pure Swift + a loopback socket pump. **Ports today** (see §5). |

**Net:** the crypto core and the messenger's *logic* are portable; the friction is entirely
in the node's macOS **identity store**, the **agent tool-host** gates, and two stray
`import CryptoKit` lines — all enumerated next.

---

## 2. The hard blockers (each with the file:line that gates it)

### Blocker A — the node identity store is concrete macOS Keychain
`Packages/EldrNode/Sources/eldr-node/NodeKeychain.swift`
- `:3` `import Security`
- `:37` `SecItemCopyMatching`, `:55` `SecItemAdd`, `:68` `SecItemDelete`
- `:53` `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

This is the node's whole long-term-secret store (Nostr identity, PQRC identity seed,
identity-DH seed, prekey state, the LLM token, cloud-CLI vendor keys). It is `import
Security` top to bottom and has **no protocol seam** — `EldrNodeMain.swift` news up a
concrete `NodeKeychain()` in ~8 places (`:98`, `:115`, `:156`, `:160`, `:331`, `:355`,
`:364`, `:374`, `:386`). **This is the #1 blocker.** The file's own header comment (`:12–15`)
already flags it: "a Linux server / Raspberry Pi has NO macOS Keychain … a hardened
file-keystore for keychain-less hosts is a separate deliverable." The fix is §4's
`IdentityStore` seam.

### Blocker B — the agent tool-host is `#if os(macOS)`, and `EldrNodeCore.serve` calls into it
- `Packages/PQRCACP/Sources/PQRCACP/ACPProxy.swift:74` `#if os(macOS)` around `runHarness`
- `Packages/PQRCACP/Sources/PQRCACP/ACPTransport.swift:59` `#if os(macOS)` around `runACPAgent`
- `Packages/PQRCACP/Sources/PQRCACP/ACPAgent.swift:11` `#if os(macOS)` around `ACPAgent`
- `Packages/PQRCACP/Sources/PQRCACP/ToolExecutor.swift:122` `#if os(macOS)` around `ToolExecutor`
- `Packages/PQRCACP/Sources/PQRCACP/PTYProcess.swift:23` `#if os(macOS)` + `import Darwin`

`EldrNodeCore.serve` calls `runHarness(...)` **unconditionally** (`EldrNodeCore.swift:226`).
Because `runHarness` is `#if os(macOS)`, the serve loop as written **compiles only on
macOS**. So the memory/spec line "EldrNodeCore is already platform-agnostic + DI'd" is true
of its *logic* but optimistic about its *compilation*: it is agnostic down to the agent
host, then hard-binds to a macOS-only symbol.

Two of these are shallow, one is real:
- `ToolExecutor` spawns `Foundation.Process` (`:122` comment). **`Process` exists on Linux**
  (swift-corelibs-foundation) — this gate is a scoping choice ("the phone never runs the
  agent"), not a hard platform limit. Widening it to `os(macOS) || os(Linux)` is plausible.
  `[unverified: Process/env parity on Linux]`
- `runHarness`/`runACPAgent`/`ACPAgent` are the same story — node-side, gated off the iOS
  build, not intrinsically macOS.
- **`PTYProcess` is the real one:** `import Darwin` + `openpty`/`ttyname` (`:23`). The Phase-D4
  persistent interactive terminal needs a Linux PTY re-seam (`Glibc` + `<pty.h>`/`posix_openpt`).
  This is genuine new code, though small and self-contained.

### Blocker C — two `import CryptoKit` lines in the PQRCACP library (transitively pulled by EldrNodeCore)
- `Packages/PQRCACP/Sources/PQRCACP/ACPMetadataCrypto.swift:2` `import CryptoKit`
- `Packages/PQRCACP/Sources/PQRCACP/ACPEvents.swift:2` `import CryptoKit`

`CryptoKit` is Apple-only; on Linux these do not resolve. Both files use only
`AES.GCM.SealedBox` / `SymmetricKey` (`ACPMetadataCrypto.swift:25,35`), which **exist
identically in swift-crypto** — so the fix is a one-line swap to `import Crypto` (plus a
`swift-crypto` dependency on the PQRCACP target, which today has *zero* external deps by
design — `Package.swift:14–19`; that trade-off must be made deliberately). Small, but it is
a true compile blocker for EldrNodeCore on Linux because EldrNodeCore depends on the PQRCACP
library (`EldrNode/Package.swift:44`).

### Blocker D — the Secure Enclave master-key wrap (invariant 10)
`EncryptedStore.swift:5–8` documents the production wrapper as "Secure Enclave P-256 key
agreement (app layer, where CryptoKit.SecureEnclave exists)". There is no SE on Linux.
The *seam* exists (`MasterKeyWrapper`, Blocker-free), but a **Linux production conformance
does not** — that is §3's ladder, and it is where invariant 10 actually has to be satisfied,
not waved at.

### Blocker E — package platform declaration
`Packages/EldrNode/Package.swift:22` `platforms: [.macOS(.v26)]`. SwiftPM `platforms` only
bounds *Apple* OS minimums, so this does not itself forbid a Linux build — but the executable
target compiles `NodeKeychain.swift`, so today a Linux build fails at Blocker A, not here.
PQRCCore/PQRCNostr/PQRCAgent declare `[.iOS(.v26), .macOS(.v26)]` (no Linux entry needed;
Linux is implied when the sources compile). No `Package.swift` edit is strictly required
beyond making the sources compile — but a Linux CI job should be added (§6).

### Network transport — a caveat, not a blocker
`NostrWebSocketTransport.swift:16` is NIP-01 over `URLSessionWebSocketTask`. On Linux that
lives in `FoundationNetworking` (a separate `import`), and swift-corelibs-foundation's
WebSocket support has historically lagged Apple's. **`[unverified]` — this is the most
likely place a "it compiles but won't connect" surprise hides.** Fallback options: keep the
existing `RelayTransport` protocol seam and drop in a small third-party Linux WebSocket
client behind it, or run the relay over the LAN. The seam (`RelayTransport.swift`) makes
this a swap, not a rewrite.

---

## 3. The hardware-keystore ladder (invariant 10)

Invariant 10 requires the at-rest master key be wrapped by the device's secure element:
Secure Enclave P-256 on Apple, "the platform-equivalent hardware keystore (StrongBox/TPM)
elsewhere, and a hardened-passphrase KEK **only** where no secure element exists."

**Apple → Linux mapping:**

| Rung | Apple | Linux | Notes |
|---|---|---|---|
| Hardware keystore (preferred) | Secure Enclave P-256, non-extractable, `WhenUnlockedThisDeviceOnly` | **TPM 2.0** via `tpm2-tss` (C) behind a thin Swift shim | Wrap the 256-bit master key under a TPM-resident key (a persistent handle, or a policy-sealed object). Most servers/NUCs and the Pi 4/5 (with a TPM HAT or fTPM) have one. `[unverified: needs a Swift↔tpm2-tss shim; none exists in-repo]` |
| Hardware keystore (mobile) | — | StrongBox is **Android**, not Linux — **do not claim it** | Called out explicitly so nobody wires an Android API into a Linux node. |
| Passphrase KEK (last resort only) | passphrase layered *under* the SE wrap | **Argon2id** KEK (memory-hard) wrapping the master key, no hardware binding | This is the rung DEVIATIONS AC31 is about: passphrase-only means a stolen disk image is **offline-brute-forceable**, and CLAUDE.md invariant 10 records that the passphrase-*only* silo was reverted precisely because it made accounts brute-forceable. On Linux with no TPM this is the honest floor, and it must surface the same deniability/brute-force caveat AC31 documents — never silently. |

**What a Linux `SecureElementSeam`/`MasterKeyWrapper` conformance needs:**
- `wrap(masterKey:) -> Data` / `unwrap(wrapped:) -> Data` (the existing protocol,
  `EncryptedStore.swift:10`).
- A TPM conformance: seal the master key to a TPM object; the wrapped blob touches disk, the
  unwrapped key lives only in memory after first unlock (mirrors the SE contract).
- A `HardenedPassphraseKeyWrapper` conformance: `Argon2id(passphrase, salt) → KEK`, then
  `SoftwareKeyWrapper`-style AES-256-GCM under the KEK. `swift-crypto` has HKDF/AEAD but
  **not** Argon2 — so this rung needs an Argon2 dependency or a vetted C binding (do NOT
  hand-roll a KDF; SPEC §2 "no invented primitives"). `[dependency decision required]`
- Honest posture reporting: the node must be able to say which rung it is on, so a town
  owner knows whether their server is TPM-backed or passphrase-only.

**No secure element on Linux → the node must degrade LOUDLY, never silently** — the same
fail-closed philosophy as the PCC build gate's opposite (a silent downgrade is the failure
mode CLAUDE.md keeps warning about).

---

## 4. The seams to add (and which already exist)

**Already abstracted (reuse verbatim — this is why the port is feasible):**
- `NodeMessenger` — `EldrNodeCore.swift:38`. The messenger is injected; tests already run it
  over a `LocalRelaySimulator` with no network/Keychain.
- `MasterKeyWrapper` — `EncryptedStore.swift:10`. The keystore seam already exists; Linux
  just needs new conformances (§3).
- `LLMClient`, `ToolEnvironment`, `HarnessDescriptor`, `RelayTransport`, `TownAuthorizer`
  (`TownAuthorizer.swift`), `TownA2AService` — all injected into `serve(...)`
  (`EldrNodeCore.swift:186`). The C-2 jail, the model, the town gate: all DI'd.

**Still concrete macOS — must be seamed:**
- **`IdentityStore`** (NEW protocol). Extract the `load`/`save`/`delete` surface of
  `NodeKeychain` (`NodeKeychain.swift:28–69`) into a protocol; `NodeKeychain` becomes the
  macOS conformance, a `FileIdentityStore` (0600 files under `$XDG_DATA_HOME`, contents
  wrapped by the §3 `MasterKeyWrapper`) becomes the Linux conformance. Then change
  `EldrNodeMain.swift`'s ~8 `NodeKeychain()` call sites to take the injected store. This is
  the single highest-leverage change.
- **Biometric/passphrase unlock** — Apple uses `LocalAuthentication` (not currently imported
  in the node graph; it is an app-layer concern today). On Linux there is no system
  biometric prompt for a daemon; the "unlock" is presenting the passphrase/TPM auth at
  daemon start. Model it as an `UnlockProvider` seam so the node's start-up unlock is
  explicit and testable.
- **PTY** — `PTYProcess` (`PTYProcess.swift`) needs a Linux backend behind its existing
  `terminate()`/`output` surface (the *interface* is already the seam; only the `import
  Darwin` body is macOS).

---

## 5. goose + the extension on Linux

- **goose** ships Linux binaries (Block distributes Linux releases). `found-town`'s bootstrap
  already does the right, honest thing here: it **does not auto-install goose** — it verifies
  `command -v goose` and fails closed pointing at the official installer
  (`FoundTownProvisioner.townScript`). That logic is OS-neutral; the only macOS-ism in the
  town script is `$HOME/.config/goose` (correct on Linux too) — **no change needed.**
- **`eldr-gooseworld`** (`Packages/PQRCMCP/Sources/eldr-gooseworld/main.swift`) is already
  Linux-ready: `#if canImport(Glibc)` at line 2, pure POSIX `socket`/`connect`/`read`/`write`,
  a loopback Unix-domain or `127.0.0.1` socket, no Apple frameworks. It is a byte pump that
  holds no key and no state (its own header, `:16–23`). **This binary ports today** — the
  blocker is not the extension, it is the node it connects to (§2).
- Consequence: on a Linux town, goose + `eldr-gooseworld` are the *easy* half. The work is
  making the **node** (identity store + agent host) run so the loopback socket has something
  to talk to.

---

## 6. Staged plan, and an honest risk/effort table

**Do first (unblocks everything, low risk):**
1. **Blocker C** — swap `import CryptoKit` → `import Crypto` in the 2 PQRCACP files; add the
   `swift-crypto` dep to the PQRCACP target (a deliberate break from its zero-dep stance —
   document it). Verify macOS `swift test` still green. *This is the smallest real change and
   it un-breaks EldrNodeCore's dependency for Linux.*
2. **`IdentityStore` seam (Blocker A)** — extract the protocol, keep `NodeKeychain` as the
   macOS conformance, inject it. No behavior change on macOS; adds the injection point.

**Do next (the substance):**
3. **`FileIdentityStore` + the §3 `MasterKeyWrapper` ladder** — the passphrase (Argon2id) rung
   first (works on any Linux box, no hardware), TPM rung second. Surface the posture loudly.
4. **Widen Blocker B** — `runHarness`/`runACPAgent`/`ToolExecutor` to `os(macOS) || os(Linux)`;
   re-seam `PTYProcess` on `<pty.h>`. Prove a shell tool round-trip on Linux.
   **(DONE 2026-07-24 — WS-L4, DEVIATIONS AC141: gates widened, PTY re-seamed via the
   `CEldrPTYShim` header shim + a /proc session sweep, and the FULL 270-test PQRCACP
   suite — PTY kill-the-orphan proofs, bash `run_shell` round-trips, the RunnerE2E
   real-binary handshake — is green in the swift:6.2 container VM.)**
5. **Add a Linux `swift test` CI job** (the fast inner-loop matrix in CLAUDE.md, run on Linux).
   Until this exists, every "ports free" claim here stays `[unverified]`.

**Optional / later:**
6. TPM 2.0 hardware rung (needs a `tpm2-tss` Swift shim — real work, hardware-dependent).
7. A Linux WebSocket client behind `RelayTransport` if `FoundationNetworking`'s
   `URLSessionWebSocketTask` proves inadequate (§2 caveat).
8. Nearby/Multipeer link — **skip**; it is Apple-only and already self-excludes. A Linux town
   uses the hub/relay, which is the default anyway (GOOSEWORLD §3).

**Risk / effort:**

| Item | Effort | Risk | Why |
|---|---|---|---|
| CryptoKit → Crypto swap (Blocker C) | XS | Low | Same API in swift-crypto; only the zero-dep policy of PQRCACP is touched |
| `IdentityStore` seam (Blocker A) | S | Low | Mechanical extraction; macOS path unchanged |
| Passphrase (Argon2id) KEK rung | M | **Med** | Needs a vetted Argon2 dep (no hand-rolling); carries the AC31 deniability caveat — a *security* posture, not just code |
| Widen agent-host gates + PTY re-seam (Blocker B) | M | Med | `Process` likely ports; `PTYProcess` is genuine new Linux code `[unverified]` |
| swift-secp256k1 / swift-crypto on Linux | S | **Med** | Expected clean but `[unverified]` — C interop + build plugin want a real Linux run |
| WebSocket on Linux (`FoundationNetworking`) | S–M | **Med–High** | Most likely "compiles, won't connect" surprise; seam makes it swappable |
| TPM 2.0 hardware rung | L | High | New Swift↔tpm2-tss shim; hardware-dependent; the honest fulfilment of invariant 10 on server hardware |
| goose + `eldr-gooseworld` on Linux | XS | Low | Extension already Glibc-gated; goose ships Linux |

**Bottom line:** the *messenger and crypto* port with small changes; the *node identity +
keystore* is the real work and is exactly where invariant 10 has teeth; the *agent tool
host* is a gate-widen plus one genuine PTY re-seam; and the *goose side* is already done.
None of it has been compiled on Linux yet — treat every unlabeled "clean" as "clean by
reading, `[unverified]` until a Linux `swift test` says so."
