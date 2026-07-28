# Extraction catalog — soundness audit and execution report

Status: **executed, adversarially reviewed, 8 repos green on macOS + Linux** · 2026-07-24
Companion to [`OPEN-SOURCE-EXTRACTION-CATALOG.md`](../done/2026-07-24/OPEN-SOURCE-EXTRACTION-CATALOG.md)
(archived 2026-07-24 — this document supersedes it)

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

Practically: for `eldr-acp` it barely matters, because the catalog's own framing
is right — the lane is the *hardened agent*, not the SDK, and that holds whether
or not a Swift SDK exists. For `a2a-swift` it matters a lot.

**Both READMEs now hedge rather than assert.** `a2a-swift` carries a visible
callout telling the reader to verify the gap before relying on it; `eldr-acp` says
a community Swift SDK "may exist (unverified at the time of writing)". Neither
states an unchecked fact about someone else's repo.

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

## 4. Findings about the protocol code

These surfaced only because the extracted packages got adversarial tests the
upstream suite does not have. **§4.1–4.3 are present upstream too** — the code is
the same. None is necessarily a bug; all were undocumented behaviours.

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

### 4.2 Losing a rekey-bearing message desynchronizes the session PERMANENTLY

**Corrected 2026-07-24 after an adversarial review — my first description of this
was wrong in the direction that matters.**

I originally wrote that a skip across a rekey boundary breaks "later messages on
that chain", and that "any reply from the peer starts a fresh chain and recovers."
The second half is false, and I verified it with a probe rather than reasoning
about it:

```
PROBE-A: failures on the fresh chain after the peer's reply = 5/5
PROBE-B: late redelivery of the rekey message succeeded = true
PROBE-B: failures after late redelivery                 = 0/5
```

The mechanism I missed: an outbound rekey refreshes the sender's chain
immediately **and** queues its ML-KEM secret in `pendingOutboundRootFolds`, which
is folded into the shared **root** at the next DH ratchet boundary. A receiver
reproduces both only by processing the header that carried the rekey. So the
damage is not confined to one chain — the peer's reply is precisely what triggers
the diverging root fold, and every subsequent message fails thereafter.

The only recovery is delivering the rekey-bearing message eventually (late is
fine — a failed decrypt costs nothing, thanks to value semantics), or a new
handshake.

**Impact is larger than I first stated.** The effective out-of-order tolerance is
not `maxSkip = 1000`; a single permanently-lost rekey-bearing message ends the
session. On an ordered, reliable relay this is rare. On lossy delivery it is a
liveness bug that looks like a crypto bug.

**Recommend:** check whether `PQRCSession`/the relay path can drop a message
permanently. If it can, either retain and redeliver rekey-bearing messages until
acknowledged, or make the root fold recoverable. Both behaviours are now asserted
by tests in `swift-double-ratchet`
(`losingARekeyBearingMessageIsPermanent`, `lateRedeliveryOfARekeyRecovers`).

### 4.3 The side that never rekeys never rotates its KEM key

Follows from §4.1 and was surfaced by the same review. `myKEMs` only grows in
`performOutboundRekey`, and the shared counter guarantees that in symmetric
traffic one side never performs one. So that side keeps the single KEM key it
started with for the life of the session, and every rekey the peer sends targets
that one long-lived key.

This does not weaken the harvest-now-decrypt-later defence. It does mean
KEM-based **post-compromise** healing is one-directional: an adversary who once
extracts that static private key can decapsulate every future rekey secret in
that direction. Asserted by `nonRekeyingSideNeverRotatesItsKEMKey`.

**Recommend:** consider rotating the receiver's KEM key periodically in ordinary
headers, or document the asymmetry in the SPEC.

### 4.4 Unknown-key-share: a layer that does not travel with the ratchet

`PQXDH.respond` never verifies that a handshake's `ik_dh` belongs to its `ik`,
and `HandshakeMessage` carries no signature of its own. Upstream that is fine —
the kind-10420 bidirectional binding check (invariant 7) and the gift-wrap seal
both sit above it. It is worth recording explicitly *because* it is invisible
until you extract the handshake on its own, which is exactly what happened here:
the extracted README carried a "not open to unknown-key-share" claim that was
true of Eldr and false of the package.

No upstream change needed. The lesson is for future extractions: a security
property provided by a *different layer* does not survive the split, and the
prose usually does.

---

## 5. What shipped

Eight repos. **Green on macOS (Xcode 27 / Swift 6.4) AND on Linux (aarch64,
Swift 6.2.4, `swift:6.2` container).** **489 tests on macOS, 472 on Linux** — the difference is entirely platform-gated
suites, itemised below.

| Repo | Deps | macOS | Linux | Notes |
|---|---|---|---|---|
| `swift-message-padding` | none | 10 | 10 | catalog priority 3. Generalised: caller-supplied bucket ladders |
| `swift-credential-redactor` | none | 13 | 13 | catalog priority 2 ("easiest win" — correct) |
| `swift-reasoning-trace` | none | 19 | 19 | had **no upstream tests**; written from scratch |
| `untrusted-data-envelope` | none | 32 | 32 | catalog priority 4, the flagship. Ships NIP-AD (CC0) |
| `swift-pqxdh` | swift-crypto | 18 | 18 | catalog priority 6 |
| `swift-double-ratchet` | swift-crypto | 30 | 30 | catalog priority 6; decoupled per §2.1 |
| `swift-a2a` | none | 89 | 80 | catalog priority 8; renamed — `a2a-swift` was taken |
| `eldr-acp` | a2a-swift¹ | 278 | 270 | catalog priority 7, biggest asset; 8 gated (`A2AHarness` is `#if os(macOS)`) |

¹ `A2AHarness` target only; the core library links nothing on Apple platforms.
Publication order is a hard gate: `swift-a2a` must be pushed and tagged first.

### 5.1 Linux verification — done, and it found a real bug

The catalog called a Linux CI job "the cheapest high-value action in this whole
doc." It was right, and it did not merely confirm a hope — **`a2a-swift` did not
compile on Linux at all.**

`A2AClient`'s HTTP transport is built on `URLSession`, and swift-corelibs-foundation's
URLSession (a) lives in a separate `FoundationNetworking` module, (b) is not
`Sendable`, and (c) **has no `AsyncBytes`**, which the SSE streaming path requires.
The first two are import-and-annotation problems; the third is not fixable without
a different HTTP stack.

**Fix applied:** the three URLSession-backed pieces — `HTTPJSONRPCTransport`,
`AgentCardResolver`, and the `A2AClient.connecting(cardURL:)` convenience — are now
gated behind `#if canImport(Darwin)`, matching the per-file gating `A2AHTTPServer`
already used. Everything transport-agnostic still builds on Linux: a Linux user
implements `A2AClientTransport` over AsyncHTTPClient/NIO and injects it, reusing the
pure-Foundation `SSEParser`. The README no longer claims "three of four build clean
on Linux" — that claim was false and is now replaced with the measured result.

Two non-findings worth recording so nobody re-chases them:

- **ML-KEM-768 works fine on Linux.** swift-crypto supplies it directly, so the
  macOS-26 platform floor is an Apple-availability artefact only. Both crypto
  repos pass unchanged.
- **`eldr-acp`'s one Linux "failure" was my test harness.** `versionFlagPrintsNameAndVersion`
  spawns a hardcoded `.build/debug/eldr-acp`, so running with `--scratch-path` left it
  executing the *macOS* binary ("Exec format error"). With a default build directory
  it is 270/270. Worth noting upstream that the test hardcodes `.build/debug/`, which
  also breaks under `-c release`.

Reproduce with:

```bash
colima start --cpu 4 --memory 8
cd ~/Development\ Projects/eldr-oss
docker run --rm -v "$PWD":/src swift:6.2 bash -lc '
  mkdir -p /tmp/w/REPO
  tar -C /src/REPO --exclude=.build --exclude=.swiftpm -cf - . | tar -C /tmp/w/REPO -xf -
  cd /tmp/w/REPO && swift test'
```

The `--exclude=.build` copy matters: mounting the host tree directly lets a macOS
`.build` leak into the container.

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
- **Every repo has a Linux CI job (`swift:6.2` container), and Linux is now
  verified locally** — see §5.1. This was the catalog's priority-1 item and it
  paid for itself immediately by catching a genuine `a2a-swift` build failure.

---

## 5.2 The adversarial review pass

After the extraction was done, three independent hostile reviews were run over
the repos with instructions to verify every claim against the code. They were
worth more than the extraction itself. Highlights of what they caught:

**Provably false claims.** The lost-rekey "recovers" sentence (§4.2) was
disproven by an executed probe, not an argument. The `a2a-swift` README's usage
examples were **fabricated against an API that does not exist** — wrong
initialisers, wrong type names, a non-exhaustive switch, an `AgentExecutor`
shape with the wrong signature. Every snippet is now compiled before publication.

**Security claims that oversold the code.** `eldr-acp`'s hardening table said the
audit log "is AES-GCM encrypted on disk" (it is opt-in, off by default, with a
plaintext fallback on seal failure), named the wrong environment variable for the
permission timeout, and described credential redaction as protecting the live
channel when the code is explicit that it is at-rest log hygiene only. The
`swift-pqxdh` README claimed unknown-key-share resistance the package does not
have (§4.4). `untrusted-data-envelope` claimed breakout required defeating all
four layers when it requires two.

**A real vulnerability in code I wrote.** The envelope's header fields are
separated by `|`, and field *values* were only single-line sanitized — so a value
of `mallory | origin: LOCAL-OPERATOR` forged a field and let remote text claim a
locally-computed property. The README's own example fed a remote display name
into a field. Fixed, with tests.

**Things that would have embarrassed on day one.** A shipped system prompt
telling every user's model it was "EldrChat's coding agent"; two comments leaking
the existence and section numbers of a private planning document; a third-party
fork attributed to a named individual; a committed `.DS_Store`; CI jobs that
would have been red on first push (a `macos-15` runner cannot build a macOS 26
platform floor, and `eldr-acp`'s path dependency breaks resolution).

**Tone.** A recurring pattern of aphorisms, sneers at unnamed competitors,
self-declared honesty ("honestly labelled", "solo-maintainer honesty"), and
catchphrases repeated across repos until they read as a tic. Cut throughout.

The pattern worth generalising: **claims about code age badly when the code moves
and the prose doesn't, and a security property provided by a different layer does
not survive an extraction** — but the sentence asserting it usually does.

## 5.3 A second review pass, and what it found

Four more reviews were run over the finished repos. They found three defects in
code, not documentation, each verified by execution before anything was changed:

- **`swift-reasoning-trace` leaked the entire scratchpad on uppercase markers.**
  The fast-path guard was case-sensitive, so it short-circuited before four
  `.caseInsensitive` searches could run — those options were dead code. That is
  precisely the failure the library exists to prevent.
- **`swift-credential-redactor` was not idempotent**, though the README asserted
  it provably was. A token in git-remote userinfo double-wrapped into
  `‹redacted:‹redacted:token›` because both value classes admitted the marker
  delimiters.
- **The forward-secrecy claim in `swift-double-ratchet` was false** for
  undelivered messages — see §4.5.

Plus two publication blockers: `eldr-acp` did not build for anyone (a path
dependency that silently worked only when a sibling checkout happened to sit
beside it), and **the name `a2a-swift` was already taken** by a package on the
Swift Package Index.

### 4.5 Skipped keys are a forward-secrecy exception

Measured: after five sends of which only the last arrived, **4 of 4 undelivered
messages were readable from a stolen state**, and still readable 80 messages
later — there is no clock in the ratchet to age them out. This is inherent to any
ratchet tolerating out-of-order delivery, Signal's included, and applies upstream
too. It is not a defect; it was simply not what "message keys are used once and
deleted" implies. Now documented, pinned by two tests, and mitigable via a new
`purgeSkippedKeys()`.

Also worth recording for upstream: `PQXDH.respond` never binds `ik_dh` to `ik`,
so the extracted handshake has no authentication at all — fine in Eldr, where the
kind-10420 check sits above it, and a reminder that **a property provided by
another layer does not survive extraction even though the prose does**.

---

## 6. Not yet extracted

Nothing below is blocked; the pattern is established and each is a repeat of it.
Ordered by value.

| Candidate | Source | Why it's worth doing | Effort |
|---|---|---|---|
| `swift-consent-grants` | `Envelope/StandingGrant.swift` (411) | **Reference impl for NIP-AC.** Pairs directly with the NIP PR — highest strategic value left | S–M |
| `swift-nostr-giftwrap` | `GiftWrap.swift`, `SealCipher.swift` | Catalog priority 5. Error-prone to reimplement; high reuse | S–M |
| `swift-agent-binding` | `IdentityBinding.swift` + `AgentKeyDeriver` | Reference impl for the NIP-OA unsigned-carriers amendment (the NIP-AS draft it was written against was withdrawn 2026-07-24). `AgentKeyDeriver` was deliberately **removed** from `swift-pqxdh` to leave this repo a clean home | S |
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

- **Verified:** macOS build + test (**489** tests) **and Linux build + test (**472**
  tests)**, all 8 repos. Linux via colima + `swift:6.2` on aarch64. (These are §5's
  figures. An earlier revision of this section said 477/460 — the pre-§5.2/§5.3
  counts, before the adversarial passes added tests. Re-counted 2026-07-24 from the
  repos themselves: 10, 13, 19, 32, 18, 30, 89, 278 = 489.)
- **Unverified:** the a2aproject and `wiedymi/swift-acp` claims in §2.4 (both
  README files now hedge rather than assert); any interop against another A2A
  implementation; x86-64 Linux (only aarch64 was tested).
- **The Eldr repo is still private.** "Go public" remains a prerequisite decision
  separate from "split" — but note these eight repos are *already* separable and
  could go public independently of Eldr, since each carries its own Apache-2.0
  grant and none imports app code.
- **Licensing verified:** Apache-2.0 for all package code (matching
  `LICENSING.md`); CC0 for `NIP-AD.md` shipped inside `untrusted-data-envelope`.
  Buzz's repo needs **no CLA and no DCO**, though every commit here is signed off
  anyway.
