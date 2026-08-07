# WS-P — both apps, one machine, actually talking

**Owner:** Auston (solo).
**Exit condition:** this plan leaves `docs/plan/` when **WS-P1 and WS-P2 land in
`DEVIATIONS.md`** — a real-socket `RelayACPHost` test running unattended in the
package suite, and a macOS XCUITest that drives the Huginn and EldrChat binaries
against each other over a live `pqrc-relay`. WS-P3 is explicitly optional; if the
owner decides the Simulator shape is not worth a bespoke script, say so in the
DEVIATIONS entry and the plan still exits.

Written 2026-08-06. Backlog entry: `BACKLOG.md` §B1a.

> **Truthful-reporting note (CLAUDE.md).** Every claim below is labelled
> *verified* (read in the source named, this session) or *unverified*
> (design/inference). **Nothing in this plan has been built or run.** The tier
> estimates are estimates.

---

## 1. The problem

Every "phone ↔ Mac" proof in this repo has a **simulated phone**.

- `Apps/Huginn/Tests/RelayACPHostTests.swift` — *verified*. Runs the **shipping**
  `ACPRelayHost` (real code, not an inline `runACPAgent`) and puts every ACP line
  through real gift-wrap + Double Ratchet. But the owner end is an in-process
  `ACPClient`, and the transport is `LocalRelaySimulator` — an in-memory fanout,
  not a socket.
- `App/PQRC/Engine/LocalUniverse.swift` — *verified*. One process pretending to be
  several people. It predates the Mac app entirely.

The real EldrChat binary has never been on either end of anything.

That test is not wrong. It simply **cannot fail for the reasons that now matter**:
a serialization mismatch, a pairing regression, a backpressure stall, or a gate
that only fires across a process boundary all pass a single-process simulation.

## 2. Why no second machine is needed

Two facts, both *verified* this session:

- **EldrChat already builds for the Mac.** `SUPPORTS_MACCATALYST = YES` on the app
  target (`App/EldrChat.xcodeproj/project.pbxproj`), so it runs natively beside
  Huginn.
- **`pqrc-relay` is a real relay, not a simulator.** `NostrRelayServer`
  (`Packages/PQRCNostr/Sources/PQRCNostr/NostrRelayServer.swift`) over a real
  WebSocket; the executable is `Packages/PQRCNostr/Sources/pqrc-relay`. Huginn's
  `RelayWizardView.swift:105` already has a button pointing at
  `ws://127.0.0.1:7777`, and `Packages/EldrNode/Tests/EldrNodeCoreTests/BuzzGatewayTests.swift`
  already drives it over a real socket.

The iOS Simulator shares the host's network stack, so `127.0.0.1` inside the sim
is the Mac's loopback — the same relay serves either shape (*unverified* for this
app specifically; it is standard Simulator behaviour, but it has not been tried
here).

## 3. The one real blocker, and it is shared

Pairing arrives as a deep link: Huginn emits a URL carrying an `npub` (plus
`&type=coding_agent`), and the app consumes it in `PQRCApp.swift:81` via
`onOpenURL`, stashing `pendingNpub` / `pendingContactType` (*verified*,
`PQRCApp.swift:1295-1302`). **A human pastes that link.**

Both WS-P2 and WS-P3 need that automated, so build the seam once, in WS-P2:

- Accept `--pair-relay <ws-url>` and `--pair-npub <npub>` alongside the existing
  launch arguments (`--uitest`, `--local-universe`, `--reset`, … — the parser is
  already there at `PQRCApp.swift:167`).
- Route them through **the same** `pendingNpub` path the deep link uses. Do not
  add a second pairing code path; a test that exercises a bypass proves nothing
  about the shipping one.
- Gate on the existing test-only argument set so the flags cannot be reached in a
  normal launch.

## 4. The tiers

They stack. None invalidates the one below.

### WS-P1 · Real wire, one process (~0.5 day)

Swap `LocalRelaySimulator` → `NostrRelayServer` in `RelayACPHostTests`. Same
assertions, real sockets, real framing, real backpressure.

- Bind the relay on port **0** and read back the assigned port — a fixed 7777 will
  collide with a relay the owner left running, and the failure will look like a
  protocol bug.
- Keep the existing `LocalRelaySimulator` test **as well**, don't replace it. It is
  fast and deterministic; the socket version is the one that catches framing and
  backpressure. Two tests, two jobs.
- Watch for the ordering assumption: the simulator delivers synchronously, a socket
  does not. If the test passes only because delivery was instant, that is a finding
  to record, not a flake to paper over.

**This is the one to do first regardless of everything else** — it is small, it
runs unattended, and it goes in the package suite that already runs on every change.

### WS-P2 · Two real processes (~1–2 days)

The test this whole plan is for.

1. Boot `pqrc-relay` on an ephemeral port as a test fixture; tear it down after.
2. Launch **Huginn.app** and **Catalyst EldrChat**, driving both from one macOS
   XCUITest via `XCUIApplication(bundleIdentifier:)`.
3. Pair using the WS-P2 launch-arg seam (§3), pointed at the fixture relay.
4. Assert a real exchange in **both** directions, and assert on **both** UIs — a
   message sent from EldrChat appearing in Huginn's view, and the agent's reply
   appearing in EldrChat's.

Two things to decide when you get there rather than now:

- **Catalyst is not iOS.** A Catalyst-only pass does not prove the iPhone build;
  that is what WS-P3 is for. Say which one the test covers, in the test.
- **Keychain.** Both apps are signed and both touch the data-protection keychain.
  Two apps on one machine with adjacent bundle ids is exactly the situation
  `KeychainIsolationTests` exists for — expect to need distinct test bundle ids,
  and treat any cross-talk as a **finding**, not test friction.

### WS-P3 · iOS runtime (~1 day, optional)

EldrChat in the Simulator, Huginn native, same loopback relay. Closest to the
shipping shape.

**Constraint, not a limitation to engineer around:** a single XCUITest bundle
cannot drive a Simulator app and a Mac app. So this is a script that launches
both and asserts on both sides' logs — not one test. Decide whether that is worth
maintaining before building it.

## 5. Order, and what would make this not worth doing

1. **WS-P1.** Unconditional.
2. **The launch-arg seam** (§3). Small, and WS-P3 needs it too.
3. **WS-P2.** The one worth having before any demo.
4. **WS-P3** only if the Catalyst/iOS gap turns out to matter in practice.

Honest counter-case: if WS-P1 passes on the first try with no ordering surprises,
that is weak evidence the simulator was not hiding much, and WS-P2's value drops
from "find bugs" to "demo insurance". That is still worth ~1 day before showing
the product to anyone, but it is a different justification — record which one it
is in DEVIATIONS rather than letting the original motive stand unexamined.

## 6. Related

- `BACKLOG.md` §B1a (this work) and §B1's `--uitest` seed-race entry — **fix the
  seed race first if WS-P2 grows any dependency on `--uitest` seeding**, or WS-P2
  inherits a known-flaky foundation.
- `guide/DEMO.md` — the scripted Local Universe demo this eventually complements.
  It is not replaced: it stays the single-process narrative demo.
- DEVIATIONS AC111 (the UI-test seeding race), AC144 (the real-socket
  `NostrRelayServer` precedent in `BuzzGatewayTests`).
