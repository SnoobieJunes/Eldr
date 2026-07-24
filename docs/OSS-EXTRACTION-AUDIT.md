# Extraction catalog — soundness audit and execution report

Status: **executed, 8 repos built and green** · 2026-07-24
Companion to [`OPEN-SOURCE-EXTRACTION-CATALOG.md`](OPEN-SOURCE-EXTRACTION-CATALOG.md)

The catalog was a static-analysis survey; its own closing caveat said so ("no
extraction attempted"). This document is what happened when the extraction was
actually attempted: what held up, what didn't, and what is left.

**Repos live in `/Users/auston/Development Projects/eldr-oss/`.** Nothing is
pushed. Nothing has a GitHub remote. See
[`OSS-RELEASE-RUNBOOK.md`](OSS-RELEASE-RUNBOOK.md) to publish.

---

## 1. Verdict on the plan

**The packaging philosophy is right and survives contact with the code.** "Many
small single-purpose repos, one primitive each, minimal dependencies" is
achievable — four of the eight repos built here have *zero* dependencies and are
genuinely usable à la carte. The instinct to refuse a monolithic `pqrc-swift` was
correct.

**Four specific claims in the catalog were wrong.** All four were discovered by
trying, not by reading. They are detailed in §2.

**One structural recommendation is reversed.** The catalog proposed a shared
`swift-pqrc-types` package that other primitives depend on. Don't. See §3.

---

## 2. Where the catalog was wrong

### 2.1 "`swift-double-ratchet` — usable standalone (any X3DH/PQXDH input)"

**False as written.** `DoubleRatchet`'s two public initialisers took
`PQXDH.InitiationResult` and `PQXDH.ResponseResult` directly. As shipped, the
ratchet could not be used with any other key agreement, and a `swift-double-ratchet`
repo would have had to depend on `swift-pqxdh` — collapsing two "independent
primitives" into one dependency chain.

**Fixed during extraction.** The initialisers now take primitive key material
(`initiatorRootKey`, `peerRatchetPublicKey`, `myKEMPrivateKey`,
`peerKEMPublicKey`). The parameters map one-to-one onto what PQXDH returns, so
composition is unchanged, but the packages are now genuinely independent — neither
depends on the other. This is worth mirroring back upstream.

### 2.2 "`swift-pqxdh` … depends only on swift-crypto"

**Understated.** PQXDH also needs the identity key, the prekey bundle wire type,
and `PrekeyManager.ConsumedPrekeys` — `PQXDH.respond` takes the latter as a
parameter. The handshake and the prekey machinery are one unit and cannot be
separate repos without a circular or backwards dependency.

**Resolved by scope, not by fighting it.** `swift-pqxdh` contains identity +
prekeys + handshake. That is one primitive ("the asynchronous PQ handshake"),
not three.

### 2.3 "Ephemeral key manager … `EphemeralKeyManager.swift` **and** `Prekeys/*`"

**These are two different things and the catalog conflated them.**

- `Prekeys/*` is X3DH prekey machinery — the keys a handshake consumes. It
  belongs with PQXDH (§2.2) and it shipped there.
- `Identity/EphemeralKeyManager.swift` is the **kind-10422 rotating receiving
  key**: an unlinkability measure that keeps the long-term npub off the relay as
  a gift-wrap `p` tag. It has nothing to do with X3DH prekeys.

A `swift-ephemeral-prekeys` repo built from both would have been an incoherent
package. The receiving-key rotation is still worth extracting, under a name that
says what it does.

### 2.4 "A community `wiedymi/swift-acp` SDK exists" / the a2aproject Swift gap

**Unverified, and left unverified.** Both claims are about the state of other
people's repos on a given day. I did not check either — no network verification
was performed for this audit, and the catalog's own instruction ("**Re-verify
before acting**") stands.

Practically: for `eldr-acp` it doesn't matter, because the catalog's own framing
is right — the lane is the *hardened agent*, not the SDK, and that framing holds
whether or not a Swift SDK exists. For `a2a-swift` it matters a lot, and the
README says so in a visible callout rather than asserting the gap as fact.

---

## 3. Reversed recommendation: no shared types package

The catalog says: *"If two primitives share types, factor a tiny
`swift-pqrc-types` rather than merging them."*

**Don't do this.** Three reasons, in increasing order of importance:

1. **It defeats the stated goal.** The audience is someone who wants *one*
   primitive. Making them take two packages to get one is exactly the framework
   tax the philosophy exists to avoid.
2. **The shared surface is tiny.** In practice it is ~150 lines: hex/big-endian
   byte helpers, `zeroize()`, a `RandomSource` seam, and a couple of typed error
   cases. Duplicating that across three repos is cheaper than coupling them.
3. **It creates a publish-order dependency.** A shared package must be pushed and
   tagged *before* anything can depend on it, and every consumer needs a version
   bump when it changes. For 150 lines of byte helpers that is a permanent tax.

**What was done instead:** each crypto repo carries its own small support surface.
The duplication is real and deliberate. Where a constant is *wire-visible* (HKDF
salts, info prefixes), it keeps its original `pqrc-v1-…` spelling in every copy
and a test asserts the exact string — because renaming one would silently break
interop with deployed peers while still compiling and still passing a round-trip
test against itself.

---

## 4. Two genuine findings about the protocol code

Both surfaced only because the extracted packages got adversarial tests that the
upstream suite did not have. **Both are present upstream too** — the code is the
same. Neither is necessarily a bug; both are behaviours that were undocumented.

### 4.1 The PQ rekey counter is shared across directions

`messagesSinceRekey` counts messages in **both** directions and is reset by a
rekey from **either** side. In a symmetric conversation, whichever party reaches
50 first performs the rekey and the other party's counter resets before it ever
gets there — so **one side ends up doing all the rekeying** and the other's
`rekeyCounter` stays at zero indefinitely.

Measured over 120 round trips: `alice=0, bob=4`.

This appears **intended and correct** — the ML-KEM secret folds into the *shared*
root key, so a rekey in either direction heals the session for both, and rekeying
from both ends would double the ~2.2 KB cost to refresh a root that is already
refreshed. It is asserted by a test in `swift-double-ratchet`
(`rekeyCounterIsSharedAcrossDirections`) so a future change to per-direction
counters is caught as the wire-visible behaviour change it would be.

**Recommend:** mirror that test upstream and note the behaviour in the SPEC.

### 4.2 Skipping across a PQ-rekey boundary desynchronizes the chain

An outbound rekey refreshes the sender's send chain immediately. A receiver
reproduces that refresh only by processing the header that carried the rekey.
`skipReceivingChain` derives keys for skipped positions from the **un-refreshed**
chain — so if the message carrying a rekey is never delivered, every later
message on that chain fails to authenticate with `decryptionFailed`.

Reproduced directly: send 51 messages, deliver only #50 (the first after the
rekey at #49) → `decryptionFailed`.

**Impact is probably small in practice** — an ordered relay makes it rare, and any
reply from the peer starts a fresh chain and recovers. But it means the effective
out-of-order window is *the current rekey interval*, not `maxSkip = 1000`, whenever
a skip would cross a rekey. The upstream `maxSkip` bound implies a wider tolerance
than actually exists.

Captured as `skippingAcrossARekeyBoundaryDesynchronizes` in `swift-double-ratchet`.

**Recommend:** confirm against `PQRCSession`'s real delivery path, then either
document the narrower window in the SPEC or reconsider whether skipped-key
derivation should replay pending chain refreshes.

---

## 5. What shipped

Eight repos, all building and testing green on macOS with Xcode 27 / Swift 6.4.
**477 tests total.**

| Repo | Deps | Tests | Notes |
|---|---|---|---|
| `swift-message-padding` | none | 10 | catalog priority 3. Generalised: caller-supplied bucket ladders |
| `swift-credential-redactor` | none | 11 | catalog priority 2 ("easiest win" — correct) |
| `swift-reasoning-trace` | none | 17 | had **no upstream tests**; written from scratch |
| `untrusted-data-envelope` | none | 28 | catalog priority 4, the flagship. Ships NIP-AD (CC0) |
| `swift-pqxdh` | swift-crypto | 18 | catalog priority 6 |
| `swift-double-ratchet` | swift-crypto | 26 | catalog priority 6; decoupled per §2.1 |
| `a2a-swift` | none | 89 | catalog priority 8 |
| `eldr-acp` | a2a-swift¹ | 278 | catalog priority 7, biggest asset |

¹ `A2AHarness` target only; the core library links nothing on Apple platforms.

### Things worth knowing about what shipped

- **`untrusted-data-envelope` was generalised, not just copied.** Upstream it is
  welded to `WallReadResult`/`WallPost`. It now takes generic `UntrustedItem`s
  with caller-supplied metadata fields, and the label is configurable. All four
  containment layers are intact and the adversarial suite runs **against a fixed,
  published nonce** — proving layers 2–4 hold without layer 1.
- **`swift-reasoning-trace` had zero upstream test coverage.** It is vendored in
  two places in Eldr and tested in neither. It now has 17 tests, including the
  Harmony one-pipe quant variant that a naive implementation silently drops real
  answers on.
- **Platform floor is macOS 26 / iOS 26 for the two crypto repos**, because
  ML-KEM-768 arrives in CryptoKit there. Not caution — without it there is no PQ
  leg. Linux is unaffected (swift-crypto supplies ML-KEM itself).
- **Every repo has a Linux CI job.** This is the catalog's "cheapest high-value
  action" (priority 1), applied to the extractions. **It has not been run** —
  there is no Docker on this machine, so Linux compilation remains *unverified*
  and will be proven or disproven the first time CI runs after push. Do not claim
  Linux support until that job is green.

---

## 6. Not yet extracted

Nothing below is blocked; the pattern is established and each is a repeat of it.
Ordered by value.

| Candidate | Source | Why it's worth doing | Effort |
|---|---|---|---|
| `swift-consent-grants` | `Envelope/StandingGrant.swift` (411) | **Reference impl for NIP-AC.** Pairs directly with the NIP PR — highest strategic value left | S–M |
| `swift-nostr-giftwrap` | `GiftWrap.swift`, `SealCipher.swift` | Catalog priority 5. Error-prone to reimplement; high reuse | S–M |
| `swift-agent-binding` | `IdentityBinding.swift` + `AgentKeyDeriver` | Reference impl for NIP-AS. `AgentKeyDeriver` was deliberately **removed** from `swift-pqxdh` to leave this repo a clean home | S |
| `mcp-codename-wall` | `MCPServer.swift`, `SecureChatBridge.swift` | Seam is already clean | M |
| `swift-encrypted-store` | `Store/*` | Small, self-contained | S |
| `swift-secure-enclave-vault` | app + Huginn wrappers | Apple-only; needs signing to test | M |
| `swift-nearby-mesh` | Multipeer trio (1184 LOC) | Genuinely novel; MultipeerConnectivity = Apple-only | M |
| `agent-frames-over-nostr` | Relay{ACP,MCP,A2A}Transport | Novel, but drags in PQRCNostr | M–L |
| `swift-hardware-keystore` | `FileIdentityStore.swift` | **Blocked on the Linux CI job actually running.** Never compiled on Linux | M |
| `swift-ephemeral-receiving-key` | `EphemeralKeyManager.swift` | Renamed per §2.3 | S |
| `pqrc` umbrella | — | Last, per the catalog. Depends on the small repos, never the reverse | S |

---

## 7. Standing caveats, updated

- **Verified:** macOS build + test, all 8 repos, 477 tests.
- **Unverified:** Linux compilation (no Docker here); the a2aproject and
  `wiedymi/swift-acp` claims in §2.4; any interop against another A2A
  implementation.
- **The Eldr repo is still private.** "Go public" remains a prerequisite decision
  separate from "split" — but note these eight repos are *already* separable and
  could go public independently of Eldr, since each carries its own Apache-2.0
  grant and none imports app code.
- **Licensing verified:** Apache-2.0 for all package code (matching
  `LICENSING.md`); CC0 for `NIP-AD.md` shipped inside `untrusted-data-envelope`.
  Buzz's repo needs **no CLA and no DCO**, though every commit here is signed off
  anyway.
