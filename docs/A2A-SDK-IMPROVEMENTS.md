# A2A SDK Improvements — cherry-picks from the Victory-Apps comparison (plan)

**Status:** proposed, not yet implemented · **Date:** 2026-07-18 · **Owner:** —
**Provenance:** derived from the head-to-head review of `Victory-Apps/a2a-swift`
(MIT, v0.5.0) against our `Packages/SwiftA2A`, and the decision in **DEVIATIONS AC112**
to keep our SDK internal rather than adopt or extract-upstream.
**Related:** `docs/A2A-INTEGRATION.md`, `docs/A2A-PQRC-EXTENSION.md`, DEVIATIONS AC95–AC101, AC112.

---

## 0. Why this document

The comparison settled two things:

1. **We are not adopting `Victory-Apps/a2a-swift` as a dependency.** Their client is
   welded to `URLSession` — there is **no transport-abstraction protocol anywhere in
   their SDK** (`A2AClient` holds a `private let session: URLSession` and builds
   `URLRequest`s directly). Our A2A traffic runs over the **E2EE Nostr tunnel**
   (`RelayA2ATransport`, injected through our `A2AClientTransport` seam), which their
   client structurally cannot carry without forking and rewriting its core class.
   Taking a pre-1.0, single-maintainer package onto our message path — and still
   maintaining a fork — is strictly worse than what we have.

2. **Their SDK is genuinely ahead on two things worth importing into ours.** This plan
   scopes exactly those, the design constraints they must respect, and — for discipline —
   what we deliberately skip.

We **reimplement the designs**; we do not vendor the package. Victory-Apps is MIT, so any
verbatim snippet is permissible with attribution (see §7).

---

## 1. What we keep (this frames every change below)

These are non-negotiable and constrain the ports. The comparison confirmed each:

| Property | Ours | Theirs |
|---|---|---|
| Transport seam (`A2AClientTransport`) — enables A2A-over-Nostr | **yes** | no (URLSession-welded) |
| Forward-compat on unions (unknown security scheme / OAuth flow / role) | preserved as `.unknown` | **throws** `dataCorrupted` |
| `SecurityRequirement` wire shape | decodes proto **and** OpenAPI/doc shape | proto-only — **throws `keyNotFound("schemes")`** on the spec's own canonical example (proven by execution 2026-07-18) |
| Concurrency | pure-actor, 0 locks, 0 `@unchecked Sendable` | 3 `@unchecked` + 2 `NSLock` (justified, but manual) |
| Dependencies | zero non-Apple | zero core (+ optional Vapor/Hummingbird) |
| Push notifications | refused by design (AC95, privacy) | shipped |

Any change here must preserve all of the above.

---

## 2. Changes to incorporate

### C1 — SSE streaming resilience: reconnection + connection-state  · **Priority: P1**

**Gap today.** `HTTPJSONRPCTransport.stream(_:)` opens the stream once
(`session.bytes(for:)`) and iterates a single pass; if the connection drops mid-stream,
the `AsyncThrowingStream` simply finishes or throws. There is **no reconnection, no
backoff, and no way for a caller to observe connection state.** We already parse the SSE
`id:` field (`SSEParser.swift` → `SSEEvent.id`), so the substrate for resume exists and
is currently unused.

**What we port** (from VA's `SSEConfiguration` / `SSELineParser` / `StreamingSession` /
`ConnectionState`, reimplemented):

- **`SSERetryPolicy`** — `maxRetries` (default 3), `initialInterval` (1s), `maxInterval`
  (30s), `backoffMultiplier` (2.0), `jitterFraction`; presets `.default` and `.disabled`
  (`maxRetries: 0` → throw immediately, i.e. today's behavior).
- **`Last-Event-ID` resume** — on reconnect, send the last seen `SSEEvent.id` as the
  `Last-Event-ID` header (standard WHATWG SSE semantics; matches VA).
- **`ConnectionState`** — `.connecting`, `.connected`, `.reconnecting(attempt:max:)`,
  `.disconnected(any Error)`.
- **Optional connection-state channel** — expose an `AsyncStream<ConnectionState>`
  alongside the existing events stream (a `StreamingSession`-style pair) so the app/UI can
  show "reconnecting…". Opt-in; the plain `stream(_:)` signature stays for callers that
  don't care.

**Placement (our structural advantage over VA).** Implement the reconnection loop **inside
`HTTPJSONRPCTransport`**, *not* in `A2AClient`. VA had to bake it into their client because
their client is the HTTP layer; ours doesn't. Consequences:

- `A2AClient` stays transport-agnostic — no HTTP retry logic leaks into it.
- `RelayA2ATransport` (E2EE Nostr) is **untouched** — the relay already store-and-forwards,
  and its resume story is the Nostr subscription layer, not HTTP SSE. Reconnection is an
  HTTP concern and stays in the HTTP transport.
- Connection-state observability is surfaced via an optional capability, not forced onto
  every `A2AClientTransport` conformer.

**Spec nuance (do it right, not just VA-parity).** `Last-Event-ID` reconnection is
*best-effort transport recovery* — not every agent honors it for `SendStreamingMessage`.
The A2A-idiomatic resume for a task stream is **`SubscribeToTask(taskId)`**. Baseline C1 =
transport-level backoff reconnect with `Last-Event-ID` (covers connection blips, matches
VA + WHATWG). **Follow-up (C1.1, optional):** when the stream is for a known task id,
prefer re-issuing `SubscribeToTask` over a raw reconnect. Not required for the first cut.

**Better-than-VA requirement — deterministic backoff.** VA sleeps with a raw `Task.sleep`,
which is untestable without real waiting. Drive our backoff delay through an **injectable
clock/sleeper seam** (our existing `Clock` dependency-seam convention) so unit tests assert
the retry schedule without touching the real clock (CLAUDE.md: *no unit test touches the
network or the real clock*).

**Invariants preserved:** SSE parser still never logs payloads (privacy); retry state
(`attempt`, `lastEventId`) stays **task-local** inside the streaming `Task` — no new actor,
**no lock, no `@unchecked Sendable`**; typed errors only.

---

### C2 — Internal test-support target `A2ATestKit`  · **Priority: P2**

**Motivation.** Our two consumers each hand-roll their own doubles — `A2AServerTests/
ScriptedExecutor.swift`, and an ad-hoc mock `A2AClientTransport` in the A2AHarness /
Huginn `A2AServerHost` tests. VA ships a reusable `A2ATesting` module (mocks, fixtures,
stream assertions) instead. We should DRY ours the same way — **and C1 needs exactly this
anyway** (a transport that can drop a stream mid-flight is how you test reconnection).

**Contents** (start minimal, grow on demand):

- `MockA2AClientTransport` — scripted responses + **drop-mid-stream / inject-error** modes
  (the C1 test fixture) + `Last-Event-ID` capture for assertions.
- `MockAgentExecutor` — scriptable server-side executor (supersedes `ScriptedExecutor`).
- Fixtures — `AgentCard` / `Message` / `Task` builders.
- `StreamCollector` + stream assertions — collect an `AsyncThrowingStream` and assert its
  event/`ConnectionState` sequence.

**Scope note.** Internal only — the public-SDK/extraction ambition is dropped (AC112), so
this is a test-scoped target consumed by our test targets, not a shipped product. Build the
`MockA2AClientTransport` drop-mid-stream piece **with C1** (it's the C1 test dependency);
the rest of the kit can follow.

---

## 3. Explicitly NOT doing (and why)

| Candidate from VA | Decision | Reason |
|---|---|---|
| Push notifications (webhooks) | **No** | AC95 — publishing a callback URL to a remote agent is a privacy leak; SSE + `GetTask` polling + the bidirectional PQRC tunnel cover the async case. |
| Linux / Vapor / Hummingbird server | **No** | Product is Apple-only; Huginn is macOS, the node is a Mac. Our `A2AHTTPServer` (loopback Network.framework) is sufficient; adding Vapor would add a heavy dependency for zero product benefit. |
| `ClientInterceptor` middleware | **Defer** | Our `A2AClientTransport` seam + `A2AAuthProvider` already cover header injection and per-transport logging; a transport-agnostic interceptor would look different from VA's HTTP-specific one. Revisit only if a concrete need appears. |
| Adopt VA as a dependency | **No** | Transport lock-in blocks A2A-over-Nostr (proven); pre-1.0 single-maintainer supply-chain risk on the message path. AC112. |
| Their `SecurityRequirement`/`StringList` model | **No** | That is their interop bug (proto-only decode); ours already handles both shapes. |
| `JSONValue` `ExpressibleBy*` literals / subscripts | **Already have** | Present in our `A2AJSONValue`. No gap. |

---

## 4. Design constraints (must not break)

- The `A2AClientTransport` seam stays clean — **no transport-specific (HTTP) code in
  `A2AClient`**; C1 lives in `HTTPJSONRPCTransport`.
- **Zero non-Apple dependencies** in SwiftA2A (extraction is off, but the clean-layering
  reason stands).
- Swift 6 strict concurrency, **pure-actor**: no locks, no `@unchecked Sendable` — C1's
  retry state is task-local; C2 mocks isolate via actor or value semantics.
- Privacy: SSE parser never logs payloads; the injected clock keeps any timing out of the
  key schedule (N/A to A2A, but the seam convention is uniform).
- Forward-compat (`.unknown` unions) and the dual `SecurityRequirement` decode are retained.

---

## 5. Test plan (all deterministic — no real clock, no network)

- **Backoff schedule:** injected sleeper records requested delays; assert the sequence
  matches `initialInterval · multiplier^n` clamped to `maxInterval`, within jitter bounds.
- **Reconnect + resume:** `MockA2AClientTransport` drops the stream after *k* events →
  assert (a) reconnect issued with `Last-Event-ID` = last emitted `SSEEvent.id`, (b) events
  resume without loss/dup, (c) `ConnectionState` sequence = `[.connecting, .connected,
  .reconnecting(1,N), .connected, …]`.
- **Exhaustion:** drops exceed `maxRetries` → events stream finishes *throwing*; terminal
  state `.disconnected(error)`.
- **`.disabled` policy:** first drop throws immediately (parity with today's behavior).
- **Client agnosticism:** the same `A2AClient` over a mock (non-HTTP) transport ignores all
  of C1 — proves the retry logic did not leak out of the HTTP transport.

---

## 6. Rollout / definition of done

- [ ] `SSERetryPolicy`, `ConnectionState`, and the optional connection-state stream added;
      reconnection implemented in `HTTPJSONRPCTransport`; `A2AClient` and
      `RelayA2ATransport` unchanged.
- [ ] Backoff delay routed through an injected clock/sleeper seam; deterministic tests green.
- [ ] `A2ATestKit` — at least `MockA2AClientTransport` (drop-mid-stream) — landed; the new
      C1 tests use it; existing A2AHarness / Huginn A2A tests migrated where cheap.
- [ ] `swift test` green for `SwiftA2A`; Huginn (macOS) and EldrChat suites unaffected.
- [ ] No new lock, `@unchecked Sendable`, `try!`, force-unwrap, or `fatalError`.
- [ ] `docs/DEVIATIONS.md` gets an entry (AC113+) recording the port and attribution.

---

## 7. Attribution

`Victory-Apps/a2a-swift` is MIT-licensed. This work reimplements its
`SSEConfiguration` / `SSELineParser` / `StreamingSession` / `ConnectionState` designs rather
than vendoring the package. Credit the project here and in the DEVIATIONS entry; if any code
is lifted verbatim, retain the MIT notice at the use site.
