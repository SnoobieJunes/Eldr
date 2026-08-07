# BACKLOG — everything planned and not built

**This is the only list.** Before this file existed the answer to "what's left?" was
spread across 13 documents, `DEVIATIONS.md`, and two gitignored files in `private/`.
If you add work, add it here — a plan document is *how*, this is *what and whether*.

Last swept: **2026-07-24**, against every doc in `docs/`, `DEVIATIONS.md` (AC1–AC154),
and `private/`. Re-swept **2026-07-27** against the live tree, which picked up
`PQXDH-CONFORMANCE-2026-07.md` (§B5).

---

## The shape of it

| | Items | Blocked on |
|---|---|---|
| **A. Waiting on you** | 14 | A machine, a credential, a decision, or an eyeball. No amount of coding clears these. |
| **B. Designed, not built** | 18 | Engineering. Each has a written plan and an estimate. |
| **C. Known gaps, no plan** | 21 | Nothing. They are recorded so they aren't rediscovered as surprises. |

**If you do one thing:** §A1. Six separate workstreams are parked behind "needs a
second machine," and it is the only blocker that unblocks more than one of them.

---

# A. Waiting on you

Nothing here is an engineering problem. Ordered by how much else they unblock.

### A1 · A second machine — blocks 6 things ⭐

The single highest-leverage item in this file.

| Blocked | Where | What it would prove |
|---|---|---|
| The two-town gooseworld ritual | [`guide/DEMO-GOOSEWORLD.md`](guide/DEMO-GOOSEWORLD.md) | Cross-town delegation over a real relay, with real latency, NIP-42 AUTH, and two independent keystores. Today: proven only in-process (`GooseworldTwoTownE2ETests`). |
| `eldrctl` end-to-end | [`guide/CONDUIT-SETUP.md`](guide/CONDUIT-SETUP.md) | `eldrctl install` against a real second Mac, then driving it from the phone. |
| DEMO-SYBILCLAW Stages 1 + 2 | [`guide/DEMO-SYBILCLAW.md`](guide/DEMO-SYBILCLAW.md) | Phone → `eldr-acp` over the relay, and the sybilclaw gateway round-trip. Both wired and headless-tested, never run on two devices. |
| Publishing the goose extension | [`guide/UPSTREAM-GOOSE-EXTENSION.md`](guide/UPSTREAM-GOOSE-EXTENSION.md) | Its own checklist makes the ritual a precondition — and `THREAT_MODEL.md` §4a calls shipping before it "the one unforgivable version of this product." |
| The WS-G1 Phase-0 exit | [`pitch/GOOSEWORLD.md`](pitch/GOOSEWORLD.md) §7 | The last unclosed gooseworld phase gate. |
| Live `wss://` from a Linux node | DEVIATIONS AC139 | The SwiftNIO transport works in a container with no network. |

### A2 · Credentials and accounts

| Item | Needs | Where |
|---|---|---|
| Live Buzz workspace run (Path A + the GUI flow) | Owner's nsec + a real workspace | [`guide/ELDR-BUZZ-INTEROP.md`](guide/ELDR-BUZZ-INTEROP.md) §2, [`plan/ELDR-BUZZ-MOBILE-RELAY.md`](plan/ELDR-BUZZ-MOBILE-RELAY.md) §7 |
| Claim a Buzz invite and post (`live_joinAndRead`) | An invite generated from Buzz Desktop | `plan/ELDR-BUZZ-MOBILE-RELAY.md` §7 — the test is written and gated on `BUZZ_LIVE_INVITE` |
| Notarize the Huginn DMG | Apple Developer Program + app-specific password | [`guide/SIGNING-AND-DISTRIBUTION.md`](guide/SIGNING-AND-DISTRIBUTION.md) |
| BIS annual self-classification | Filed by Feb 1, and again when a new crypto item ships | [`guide/EXPORT-COMPLIANCE.md`](guide/EXPORT-COMPLIANCE.md) |
| ANSSI declaration | Only if shipping to France | `guide/EXPORT-COMPLIANCE.md`, `guide/TESTFLIGHT-GUIDE.md` §C |

### A3 · Decisions only you can make

| Decision | Why it's blocking | Where |
|---|---|---|
| ~~Go public with the Eldr repo~~ — **DONE.** Verified `PUBLIC` on 2026-07-26. The 8 extracted repos' provenance links to `github.com/SnoobieJunes/Eldr` now resolve. **Consequence: every push is publication** — scan before pushing. | — | `guide/OSS-RELEASE-RUNBOOK.md` §1 is now moot |
| **Maintain 8 repos, or narrow the promise** | Each ships a `SECURITY.md` promising 72-hour acknowledgement and 90-day disclosure. On eight surfaces. Edit them *before* pushing — a promise quietly dropped is worse than a narrower one made honestly. | `guide/OSS-RELEASE-RUNBOOK.md` §3 |
| **goose / AAIF trademark posture** | Gates whether "gooseworld" can ever be public. Everything currently says internal-codename-only. | `guide/UPSTREAM-GOOSE-EXTENSION.md` |
| **The image-pipeline consulting line** | `private/IMAGE-PIPELINE-PLAN.md` is pre-Phase-0 and says outright that it **contradicts** `private/BUSINESS-CASE.md`'s "no consulting anywhere in the plan." A real conflict, still unresolved. | `private/IMAGE-PIPELINE-PLAN.md` |
| **Fate of the standalone MCP-server path** | Once ACP MCP-passthrough landed, the standalone server for external clients became a separate product decision. | `private/meatsuittasks.md` |

### A4 · On-device verification (nothing is broken; nothing is confirmed)

These are eyeball passes. The code is written and the tests are green; no one has looked at it on hardware.

- **iPad / Mac landscape pass** on every primary screen — conversation list, ConversationView, ThreadView, Settings, Onboarding. Built iPhone-portrait-first. (`CLAUDE.md` § Platform expansion — *"a verification pass, not new layout work"*.)
- **The Huginn MLX overhaul**, WS-M3/M4/M5 — download progress, detail popover, loss chart, dataset assistant, the Advanced disclosure. Six separate `NEEDS OWNER` entries in `private/LOOP-STATE.md`.
- **The Buzz Connections tab** — banner, section, tab look, paste flow (DEVIATIONS AC146).
- ~~**The World dashboard maps**~~ — rendered and accepted by the owner 2026-07-28. Still worth a second look when a real second town exists: the radial layout has only ever been seen at one town, never at the 8-town fan-out cap, and a live (pulsing) edge has never been observed because no peer has yet sent traffic. Also unconfirmed: that the consolidated Huginn tab lost nothing — Town Grants and Buzz Connections now live one level down.
- **Per-chat egress firewall with a real cloud AI** — confirm ON redacts and bounds, OFF sends raw.
- **Encrypted Mac-AI memory + unpair shred**, **interactive terminal kill**, **MCP codename passthrough**, **node-side image input** — the remaining `private/meatsuittasks.md` device checks.

---

# B. Designed, not built

Each has a written plan. Estimates are the plans' own, solo-developer days.

### B1 · Ready to execute — just not done yet

| Item | Effort | Where |
|---|---|---|
| **Push the 8 OSS repos.** Built, tested, committed, **zero remotes**. Publication order matters for exactly one pair (`swift-a2a` before `eldr-acp`). | ~1 day | [`guide/OSS-RELEASE-RUNBOOK.md`](guide/OSS-RELEASE-RUNBOOK.md) |
| **Submit the 3 NIP PRs** to `block/buzz`. Bodies pre-written, every command given. | ~20 min | [`nips-contrib/PR-SUBMISSION-RUNBOOK.md`](nips-contrib/PR-SUBMISSION-RUNBOOK.md) |
| **Relay-side work for ephemeral receiving keys** (kind 10422). The app toggle **must not** be flipped until the relay passes the §6 gate — today it breaks inbound delivery. | — | [`guide/RELAY-EPHEMERAL-KEYS-SETUP.md`](guide/RELAY-EPHEMERAL-KEYS-SETUP.md) |
| **The node-served web dashboard (WS-D2/D3-web).** Deliberately deferred when AC155 shipped native-first, so a **Linux town has no dashboard at all** — `world/status` exists and is transport-agnostic, but only the two Apple apps can read it. Needs the specced loopback HTTP+SSE server: token-gated, `Origin`/`Host`-validated against DNS rebinding, no write path, no-CDN vendored frontend. | ~2–3 days | DEVIATIONS AC155; original spec in the retired gooseworld-v2 plan |
| **Streaming dashboard updates.** AC155 refreshes on demand and labels every row with when it was confirmed. Live updates need WS-D1n's observer hooked *after* the authorizer in `routeInboundA2A` and delivered **non-blocking** to a bounded `AsyncStream` — an awaited observer would head-of-line-block all three planes (an availability DoS). Would also let the Mac map pulse per actual message instead of per live-state. | ~1 day | DEVIATIONS AC155 |
| **A deterministic "universe seeded" signal for `--uitest`.** `EldrChatUITests` fails intermittently and *a different test loses the race each run* — observed 2026-08-06: `PerformanceUITests.test_scroll10kMessages` ("no matches for ScrollView"), then `UXVerificationTests.test_rec1_aiControlsOverlap`, then `test_rec4_largePasteChip` (both "conversation Bob missing"). Each passes in isolation; `simctl shutdown all` does not help, so it is not accumulated simulator state. The mitigations in place — a 150 s wait and `UXVerificationTests.launchUniverse`'s single relaunch — treat the symptom. The fix is for `bootUniverse` to publish a **seeded** state the tests can await (accessibility element, or a springboard-visible marker) instead of every test polling for its own row. `PQRCApp.swift:1304` already carries the `TODO(AC111)`. **The failure message always names a missing UI element, so it reads like a layout regression when it is a boot race** — that mis-read costs a debugging session each time. | ~0.5 day | `App/PQRC/PQRCApp.swift:1304`; DEVIATIONS AC111 |

### B1a · Both apps, one machine, actually talking ⭐

Every "phone ↔ Mac" proof today has a **simulated** phone. `RelayACPHostTests`
(Huginn) runs the shipping `ACPRelayHost` against an in-process `ACPClient` over a
`LocalRelaySimulator`; `LocalUniverse` is one process pretending to be several
people. Neither has ever had the real EldrChat binary on one end. So the app pair
this product *is* has never been exercised as two processes.

It does not need a second machine. Two facts make it work today:

- **EldrChat already builds for the Mac** — `SUPPORTS_MACCATALYST = YES` on the app
  target, so it runs natively beside Huginn.
- **`pqrc-relay` is a real relay**, not a simulator: `NostrRelayServer` over a real
  WebSocket at `ws://127.0.0.1:7777`. Huginn's `RelayWizardView` already has a
  button pointing at it, and `BuzzGatewayTests` already drives it over a real
  socket. (The iOS Simulator also shares the host network stack, so `127.0.0.1`
  inside the sim is the Mac's loopback — the same relay serves either shape.)

Three tiers, cheapest first. They stack; none invalidates the one below.

| Tier | What it proves | Effort |
|---|---|---|
| **1 — real wire, one process.** Swap `LocalRelaySimulator` → `NostrRelayServer` in the existing `RelayACPHostTests`. Same assertions, real sockets, real framing, real backpressure. Catches everything the simulator's in-memory shortcut hides. | The wire, not the app | ~0.5 day |
| **2 — two real processes.** Boot `pqrc-relay`, launch Huginn.app and Catalyst EldrChat, drive **both** from one macOS XCUITest via `XCUIApplication(bundleIdentifier:)`. This is the "two apps talking" test. Needs a launch-arg seam so EldrChat can take a relay URL + peer npub without a human pasting a pairing link (today that arrives via `onOpenURL`, `PQRCApp.swift:81`). | The product | ~1–2 days |
| **3 — iOS runtime.** EldrChat in the Simulator, Huginn native, same loopback relay. Closest to the shipping shape. **One XCUITest bundle cannot drive a simulator app and a Mac app**, so this is a script plus assertions on both sides' logs, not one test. | The real target | ~1 day |

Do Tier 1 first regardless: it is small, it is CI-able, and it is the only one that
runs unattended. Tier 2 is the one worth having before any demo.

Worth stating plainly: this replaces the **solo** test written before the Mac app
existed. That test is not wrong, it just cannot fail for the reasons that matter
now — a serialization mismatch, a pairing regression, or a gate that only fires
across a process boundary all pass a single-process simulation.

### B2 · The Buzz mobile plan — Phase 1 done, 2 and 3 not started

Phase 1 (WS-BM1–BM3) landed 2026-07-24 as AC147–AC153 and is green — but has never run against a live Buzz relay and no screen has been looked at.

| | What | Effort |
|---|---|---|
| **WS-BM4** | The secure plane — PQ-ratcheted kind:1059 over a Buzz relay. *This is the moat.* Must land with a `THREAT_MODEL.md` entry for the §3.3 metadata regression. | 4–6 d |
| **WS-BM5** | Agent control from the phone — mention your agent, see NIP-AM/AO, approve tool calls. | 3–4 d |
| **WS-BM6** | **Push notifications — the biggest product risk.** Either Block provisions an Eldr app profile, or you run your own APNs executor. Confirmed live: the relay advertises only `buzz-ios-production`/`buzz-ios-sandbox`. Plan for your own; ask for theirs. | 5–10 d |
| **WS-BM7** | Bridge mode (Mode 2) — mirror + disclosure + egress firewall. Must never default on. | 3–4 d |
| **WS-BM8** | Read state, presence, typing, search. | 3–4 d |

Full detail: [`plan/ELDR-BUZZ-MOBILE-RELAY.md`](plan/ELDR-BUZZ-MOBILE-RELAY.md).

### B3 · Four protocol findings the extraction surfaced — upstream action still open

Found by giving the extracted packages adversarial tests the upstream suite lacks. **All four are present in this tree too.** Each is asserted by a test in the extracted repo; none has been mirrored back.

| Finding | What to do |
|---|---|
| **A lost rekey-bearing message kills the session permanently.** Not "one chain" — the root fold diverges and every later message fails. Effective out-of-order tolerance is *not* `MAX_SKIP=1000`. | Check whether the relay path can drop a message permanently. If it can: retain and redeliver rekey-bearers until acked, or make the root fold recoverable. |
| **The PQ rekey counter is shared across directions**, so one side does all the rekeying (measured: `alice=0, bob=4` over 120 round trips). Intended, undocumented. | Mirror the test upstream; note the behaviour in the SPEC. |
| **The non-rekeying side never rotates its KEM key** — so PQ post-compromise healing is one-directional. | Rotate the receiver's KEM key periodically, or document the asymmetry in the SPEC. |
| **Skipped keys are a forward-secrecy exception.** 4 of 4 undelivered messages readable from a stolen state, still readable 80 messages later — no clock ages them out. Inherent to any ratchet tolerating reordering (Signal's included), but not what "keys are used once and deleted" implies. | Documented and mitigable via `purgeSkippedKeys()` in the extracted repo. Bring the doc and the method upstream. |

Source: [`guide/OSS-EXTRACTION-AUDIT.md`](guide/OSS-EXTRACTION-AUDIT.md) §4.

### B4 · Eleven more extraction candidates

The pattern is established; each is a repeat of it. Highest strategic value first — `swift-consent-grants` pairs directly with the NIP-AC PR.

`swift-consent-grants` (S–M) · `swift-nostr-giftwrap` (S–M) · `swift-agent-binding` (S) ·
`mcp-codename-wall` (M) · `swift-encrypted-store` (S) · `swift-secure-enclave-vault` (M) ·
`swift-nearby-mesh` (M) · `agent-frames-over-nostr` (M–L) · `swift-hardware-keystore` (M) ·
`swift-ephemeral-receiving-key` (S) · the `pqrc` umbrella (S, last)

Detail: `guide/OSS-EXTRACTION-AUDIT.md` §6.

### B5 · Owed by the PQXDH conformance fix (2026-07-25)

Both named in [`PQXDH-CONFORMANCE-2026-07.md`](PQXDH-CONFORMANCE-2026-07.md) § Still outstanding.

| Item | Detail |
|---|---|
| **Bind the KEM public key into the derivation** | PQXDH §4.12 requires it, or one compromised PQ prekey can be re-encapsulated onto every initiator. ML-KEM binds it internally (FIPS 203 hashes the encapsulation key into the shared secret), so this is **defence in depth, not a live hole** — which is why it was deliberately left out. Natural fourth item for a future `hybrid-v3`; the `"suite"` field already exists to negotiate it. |
| **A `DEVIATIONS.md` entry is owed** | For the `hybrid-v2` bump and the new `ik_dh_sig` field. **`D2` still records `hybrid-v1`** and is now wrong (`DEVIATIONS.md:12`). The fixing agent left it out on purpose — that file had unrelated uncommitted work and adding it would have dragged it in. |

### B6 · One plan that was written and never executed

**SSE streaming resilience for the A2A client (C1).** `HTTPJSONRPCTransport.stream(_:)` opens once and never reconnects — no backoff, no `Last-Event-ID` resume, no connection state, even though `SSEParser` already parses the `id:` field. Still a real gap. The plan's §1 constraint table is still the right one.

Its premise has since flipped — it was written under AC112 ("keep SwiftA2A internal"), and the SDK was subsequently extracted and published as `swift-a2a`. Read it with that in mind: [`done/2026-07-24/A2A-SDK-IMPROVEMENTS.md`](done/2026-07-24/A2A-SDK-IMPROVEMENTS.md).

---

# C. Known gaps, no plan yet

Recorded so they aren't rediscovered as surprises. None is scheduled.

### C1 · Security follow-ups that have a named fix

| Gap | Where |
|---|---|
| AI instructions + custom skills persist in **cleartext UserDefaults**, bypassing `EncryptedStore` | DEVIATIONS (deferred, MED) |
| Unbounded discovery/subscription caches — `nearbyBundles`, the transport's `.unbounded` inbound stream, `NearbyRelayHub.subTasks` | DEVIATIONS (deferred, LOW) |
| MCP UDS has no peer-credential check (`SO_PEERCRED`/`LOCAL_PEERPID`) | `THREAT_MODEL.md` §6 |
| MCP conversation-title fallback could emit a key prefix in a contrived state | `THREAT_MODEL.md` §6 |
| A2A **agent card signatures are not verified** — card trust == transport trust | `guide/A2A-INTEGRATION.md`, AC99 |
| The delegation path injects **no vendor key**; `withVendorKey` is only on top-level responders | DEVIATIONS (deferred) |
| The nested permission proxy is not e2e-tested against a real permission-issuing harness | DEVIATIONS (deferred) |
| `ConduitProvisioner`'s env heredoc is unquoted — an embedded `'` breaks it. Not currently reachable. | DEVIATIONS (deferred, LOW) |

### C2 · Accepted limits

| Limit | Where |
|---|---|
| Per-day wall budgets are engine-side (phone); the headless node meters nothing | AC143 |
| `world_delegate` is fire-and-forget — the reply lands on the delegation channel, not as the tool's return value | AC143 |
| Pairwise fan-out caps at ~8 towns; MLS is the v2 scale path | `pitch/GOOSEWORLD.md` §6 |
| `.a2aRemote` delegation is refused on Linux (fails loudly as `unsupportedKind`) | AC141 |
| The Linux TPM rung is systemd-creds sealing, not an in-process `tpm2-tss` shim | AC139 |
| Phone → Huginn grant hand-off is copy/paste; an automatic paired-channel push is future work | AC145 |
| Headless `eldr-node` gateway continuity is per-process, not per-conversation | AC69 |
| The in-app **Agent Inspector** and **Nearby scanner** are not built — use OS logs | `TEST-PLAN.md` §14 |

### C3 · v2 / research

Formal verification (Verifpal/Tamarin) of the rekey fold positions · **third-party audit (OTF Security Lab) — a stated precondition for any non-demo deployment** · silo count-hiding via a pooled opaque-record store (Phase 2) · ephemeral receiving keys on by default · Tor / mixnet transport · cryptographic *message* deniability · MLS groups · multi-device.

Source: `THREAT_MODEL.md` §6.

---

## Keeping this true

Sweep it when you close a workstream — the same moment you write the `DEVIATIONS.md`
entry and move the plan to `done/`. Three steps, one sitting:

1. Write the DEVIATIONS entry (the durable record).
2. Move the plan to `done/<YYYY-MM-DD>/` with a header, and re-point inbound links —
   **including Swift source comments**.
3. Strike the line here, or move it down a section if only part of it landed.

If an item can't be written as a line in this file, it isn't a backlog item yet —
it's a thought, and thoughts go in `private/`.
