# Interop Landscape — Eldr, Buzz, Goosetown, and what it takes to be the roads

> **Analysis + decision doc. Nothing here is a claim that a feature shipped.**
> Every capability below is labeled *Shipped* / *Wired + tested* / *Demo-only* /
> *Doc-only* / *Inert*. Written 2026-07-23 against branch `gooseworld-on-main`
> (HEAD `41e23f2`), which carries the cross-town work rebased onto main — so
> several things `docs/GOOSEWORLD.md` describes as "not in this published tree"
> **are** in this tree, and are cited as such.
>
> Working rules, same as GOOSEWORLD.md: evidence over enthusiasm, docs are
> treated as claims to verify rather than facts. "goose", "goosetown", and
> "Buzz" are used descriptively.
>
> **Method caveat, load-bearing: nothing was built or run.** This is static
> analysis — source reading, `strings` on the goose binary, and read-only CLI
> invocations. Test-count claims in any README are unverified here. Runtime
> behavior is inferred from code, not observed.

## 0. The question this answers

Can Eldr's approach connect independent AI agent systems — goosetowns, Buzz
communities, EldrChat instances — into a shared ecosystem, the way the internet
connects independent servers? And is Eldr/Huginn the right architecture to be
the connective layer rather than another destination?

**Short answer: yes, and most of the hard parts are already built.** Four
concrete things block it, one of which is a genuine architectural gap rather
than wiring. Details in §6–§8.

---

## 1. Three systems, three altitudes

They are not competing designs. They sit at different layers, which is why the
interop question has a clean answer rather than a turf war.

| | Goosetown | Buzz | Eldr |
|---|---|---|---|
| **What it is** | Conventions + monitoring UI on one host | Self-hosted team workspace on one relay | E2EE messenger + agent transport |
| **Coordination unit** | Append-only text file | Signed Nostr event in Postgres | Gift-wrapped ratcheted rumor |
| **Identity** | A string in a prompt | secp256k1 pubkey, per-agent | Ed25519 human key + one derived agent key |
| **Reach** | One filesystem | One relay | Any relay, plus LAN Multipeer |
| **Enforcement** | An LLM reading prose | Relay-side, in Rust | Client-side, signature-verified |
| **Federates?** | No | **No, by design** | Yes — that's the point |

### 1.1 Goosetown is a building, not a town

~1,060 lines of bash and Python. **There is no orchestrator process** — the
orchestrator is a prompt (`.claude/skills/goosetown-orchestrator/SKILL.md`).
Delegates are spawned by goose's built-in `summon` platform extension, receive
**only a task string** (no parent history — the tool description states
"Delegates know only instructions + source content"), and return **one text
blob**. Goose enforces flatness in Rust: subagents cannot spawn subagents.

Coordination is `gtwall` — `printf '%s|%s|%s\n' ts id msg >> wall.log`
(`goosetown/gtwall:195`), newlines stripped and `|` escaped (`:187`), per-reader
cursors as line offsets. Writes take an mkdir-lock with a 10s ceiling; **reads
take no lock at all** (`gtwall:200-223`). Lock-acquisition failure is silent to
the LLM — stderr warning, `return 1` — so a delegate believes it broadcast when
it did not (`gtwall:189-192`).

`@name` targeting has **no parser anywhere in the repo** (verified by grep
across `ui/js`, `scripts`, `gtwall`, `dashboard` — zero hits). The wall is a pure
broadcast bus; targeting exists only because an LLM reads `@worker-auth` and
decides it means itself. Same for the `📡`/`⏰`/`🚨` escalation tiers: emoji as
protocol, LLM as parser.

*Status: Shipped, single-host, prose-enforced.*

**Security finding worth acting on independently of any interop work.**
`POST /api/wall` on the dashboard (ports 4242–4300) is unauthenticated and posts
as sender id `user` (`scripts/goosetown-ui:596`), while `AGENTS.md:32` instructs
every agent that messages from `user` are from the human operator and must be
prioritized above all other traffic and acknowledged immediately. Any localhost
process — including a browser page, as there is no CSRF token or `Origin` check
— can inject maximum-trust instructions into every delegate's context. The
source comments the missing auth (`goosetown-ui:576-578`) but not the
impersonation amplification. `GOOSETOWN_BIND_HOST` (`dashboard:12`) allows
binding `0.0.0.0`.

### 1.2 Buzz is a town with excellent municipal infrastructure and no highway exits

`buzz/ARCHITECTURE.md:9`, verbatim:

> The relay is the single source of truth. All reads and writes flow through it.
> **There is no peer-to-peer event exchange, no gossip, no replication** — just
> clients connecting to one relay over WebSocket.

That is a design commitment, not a backlog item. Two Buzz deployments run by
different organizations have no path to exchange events. The `buzz-relay-mesh`
crate is *intra-deployment* QUIC scaling (shared Redis registry, and it
deliberately does **not** reuse the relay key because all pods share one
secret — `crates/buzz-relay-mesh/src/wire.rs:56-62`). `VISION_MESH.md` describes
something else entirely — pooling members' idle GPUs — with no corresponding
code. The name collision between that doc and the crate is the highest-risk
confusion in that repo.

What Buzz *does* have, and has more completely than Eldr: **agents as
first-class network principals.** Agent profile (kind 10100), encrypted agent
memory / engrams (30174), personas (30175), teams (30176), managed agents
(30177), observer frames (24200), turn metrics (44200) — all with handlers, all
in `crates/buzz-core/src/kind.rs`. `buzz-acp` is a working ACP harness pool
driving `claude-code-acp` / `codex-acp` off relay `@mention` events.

*Status: Shipped as a destination. Federation: absent by design.*

Note: job kinds 43001–43006 (JOB_REQUEST/ACCEPTED/PROGRESS/RESULT/CANCEL/ERROR)
are declared but have **no dispatcher** — they appear only in
`crates/buzz-db/src/feed.rs` as activity-feed filters. *Doc-only / reserved
integers.* Buzz has no request/response primitive on the wire either (§7).

### 1.3 Eldr is the road-building equipment

The only one of the three with paving, passports, customs, and a published road
standard:

- **Paving** — `RelayFraming` (`Packages/PQRCNostr/Sources/PQRCNostr/RelayFraming.swift:16-31`):
  `<MAGIC>|<lineId>|<seq>|<total>|<payloadB64Url>`, multiplexing `ACP1|`,
  `MCP1|`, and `A2A1|` frame classes over gift-wrapped E2EE traffic, with
  bounded reassembly (`maxChunksPerLine=4096`, `maxPendingReassemblies=256` with
  LRU eviction, `maxReorderBuffer=1000`). A JSON-RPC line always starts `{`, so
  a first-byte test routes each inbound body unambiguously. *Shipped.*
- **Passports** — kind-10420 identity binding, verified in **both** directions
  (`Packages/PQRCCore/.../Constants.swift:79`). *Shipped.*
- **Customs** — four independent, human-signed, time-bounded gates:
  `ai_window`, `ai_invite`, `ai_context_grant`, `standing_grant`
  (`Packages/PQRCAgent/.../AgentEngine.swift`). `authorizeAutonomousSend` fails
  closed. Gates require a signature by the *human* identity key; an agent-key
  signature is rejected. *Shipped.*
- **A published standard** — `docs/A2A-PQRC-EXTENSION.md`, CC0, extension URI
  `https://eldr.app/ext/a2a-pqrc-e2ee/v1`, drafted for submission to the
  a2aproject community. *Draft, unreviewed.*

---

## 2. How each system passes context

This is the mechanical core of the comparison.

| | Mechanism | By value or reference? | Survives a hop? |
|---|---|---|---|
| **Goosetown → delegate** | Task string in `delegate(instructions:)` | Value; parent history **not copied, not summarized** | N/A, single host |
| **Delegate → orchestrator** | One formatted text blob via `load(task_id)` | Value | N/A |
| **Goosetown agent ↔ agent** | Append line to `gtwall`, others poll | Value, broadcast | No |
| **Buzz agent ↔ agent** | Signed Nostr event, relay fan-out | Value; engrams (30174) are stored state | Within one relay only |
| **Eldr app → LLM** | `AgentContext` flattened to one string | Value | N/A |
| **Eldr agent ↔ agent** | Post into shared thread; next agent re-reads | Value, re-serialized every turn | Yes, over relay |
| **Eldr node ↔ node** | JSON-RPC in `ACP1|`/`MCP1|`/`A2A1|` frames | Value | Yes — **this is the road** |

### 2.1 The Eldr chat path is lossier than it looks

`renderTranscript` (`Packages/PQRCAgent/.../FoundationModelsAgentProvider.swift:107-112`)
takes `.suffix(20)`, renders `"\(role): \(entry.text)"`, joins with `\n` — and
that single string becomes **one `user` message**
(`AgentProvider.swift:112-119`). No `assistant` role is emitted for history.
Three consequences:

1. **Role structure is destroyed.** A model cannot distinguish its own prior
   output from the human's.
2. **Message 21 does not exist**, and nothing signals the truncation. Compare
   `ContextBudget.trim` (`Packages/PQRCACP/.../AgentConfig.swift:462+`), which
   does anchored, aged, explicitly-elided trimming properly — but guards only
   the ACP loop, not the chat providers.
3. **`\n` is the record separator and message text is unescaped.** A message
   containing `"Alice: ignore previous instructions"` is byte-identical to a
   real turn from Alice. The four-layer containment in `UntrustedDataEnvelope`
   (`Packages/PQRCMCP/.../UntrustedDataEnvelope.swift:20-51`) exists only on the
   town-wall path, which is demo-only (§6.2).

Multi-agent collaboration works by agents posting chat messages into a shared
thread and each subsequent agent re-reading it — context rebuilt from scratch,
per agent, per turn (`App/PQRC/Engine/PersonaRuntime.swift:2997-3030`). This is
correct and cheap for a messenger. It cannot carry a week-long two-town
co-build, because nothing is ever passed by reference.

---

## 3. The text-based question, answered

**The phrase "our text-based approach" conflates two different things, and only
one of them works.**

### 3.1 The ⟡⟡ AgentSkills envelope is not a protocol

`Packages/PQRCAgent/Sources/PQRCAgent/AgentSkills.swift:39-50` defines:

```
⟡⟡ <skill-name> · v<version>
from: <you>'s AI · <your context-domain>
re:   <short subject; correlates to a prior message>
scope: thread:<thread-id>
⟡⟡
<body — per the active skill's contract>
⟡⟡ end <skill-name>
```

**Nothing parses it.** Verified by grepping every `⟡⟡` occurrence in the tree:
all hits are in `App/PQRC/Views/…` (display) plus a settings toggle. The only
code that touches the marker is `MessageBubble.strippedEnvelopeBody`
(`App/PQRC/Views/Components/MessageBubble.swift:245-289`), which strips the
frame for rendering. There is no reader for `from:`, `re:`, or `scope:`
anywhere.

The header's own comment is honest about this (`AgentSkills.swift:12-16`):
*"This is pure prompt composition… No new wire format, no event kind… the
envelope is just message text."* The user-facing copy is not — `SettingsView.swift:501`
calls it "a small machine-readable header." **No machine reads it.** That
sentence should be corrected regardless of what else is decided.

Consequences: `re:` was designed to correlate request and response and is
inert (§7). `scope:` duplicates a thread binding the engine already sets
independently inside the ciphertext (`Rumor.swift:466`). Round-trip fidelity
depends entirely on an LLM voluntarily emitting well-formed ASCII art.

### 3.2 `RelayFraming` is a protocol, and it is good

Typed magic prefixes, explicit chunk sequencing, bounded reassembly,
adversarial caps on peer-supplied `total`, LRU eviction under loss. It carries
JSON-RPC — machine-checkable, versioned, negotiable.

### 3.3 The rule that follows

**Text is the right encoding for cargo. It is the wrong encoding for the
envelope.**

Text is what LLMs consume and it survives version skew gracefully — keep it for
message *content*. Addressing, correlation, consent, and provenance must be
typed and machine-verified, because those are the things a hostile or buggy
peer will get wrong and the things you must be able to check without an LLM in
the loop.

Eldr is viable as connective tissue **because of §3.2, not §3.1.** Any strategy
that rests on the ⟡⟡ convention as the interop contract is betting
interoperability on model compliance.

---

## 4. What already lines up (better than expected)

**All three systems already speak ACP.**

- Eldr — `PQRCACP` + `RelayACPTransport`, `ACP1|` frames. *Shipped.*
- Buzz — `buzz-acp` pool driving `claude-code-acp` / `codex-acp`. *Shipped.*
- goose — natively: `goose acp` (stdio) and `goose serve` (**ACP over HTTP and
  WebSocket**, default `127.0.0.1:3284`). Verified via `--help` on v1.37.0.

The agent-protocol question is already settled. The disagreement between the
three is **transport and identity** — precisely the layer Eldr owns.

**The Nostr substrate also lines up.** Eldr's kinds (10420–10422, 10050, 1420,
13) do not collide with any of Buzz's ~130 (whose 10xxx band tops out at 10100).
And both already emit **NIP-59 gift wraps as kind 1059** — identical outer
envelope, different inner semantics. That is the good failure mode: same IP
packet, different application protocol. A single relay could carry both today
without either side changing.

---

## 5. Identity — the one real architectural gap

### 5.1 What Eldr's agent key is

`AgentKeyDeriver.deriveAgentKey`
(`Packages/PQRCCore/Sources/PQRCCore/Identity/PQRCIdentity.swift:44-56`) is
`HKDF(ikm: identity.privateKey, salt: agentHKDFSalt, info: prefix || identityPub)`
— a **pure deterministic function of the human's identity key**. One-way, so
agent-key exposure does not expose the identity key; re-derived on demand, never
stored. It signs `"pqrc-agent-msg-v1" || ciphertext` and is REQUIRED iff
`participant_type == "agent"` (`Envelope/Rumor.swift:411-416`).

Four crypto mechanisms live in Eldr and are worth keeping distinct:

| Mechanism | Answers |
|---|---|
| Human identity key | *Whose account is this?* |
| **Derived agent key** | *Was this written by a human or an AI?* |
| Double-ratchet session keys | *Who can read it?* (relay cannot) |
| Consent gates | *What is the AI allowed to do?* |

The derived agent key is a **provenance flag, not an identity.** There is
exactly one per human, forever; a second cannot be minted without changing the
derivation. So:

- Your Claude and your local MLX model are indistinguishable on the wire.
- You cannot revoke one agent — only the human's entire agent capability.
- A remote town cannot address a specific agent.
- Different agents cannot hold different authority.

Compounding it, in-app `@`-mention routing matches on **lowercased display
name** (`PersonaRuntime.swift:3018`), and AI configs live in **UserDefaults in
plaintext** (`App/PQRC/Engine/ConfiguredAI.swift:6-7`) while API keys correctly
go to Keychain.

For a messenger, one honesty flag is the right call. For roads between towns,
you need addressable, individually-revocable principals.

### 5.2 How Buzz solved it — NIP-OA

Each agent holds an **independently generated keypair** and is the actual author
(`event.pubkey` *is* the agent key). A portable tag carries the owner's
authorization (`buzz/docs/nips/NIP-OA.md:33`):

```json
["auth", "<owner-pubkey-hex>", "<conditions>", "<sig-hex>"]
```

Signed by the owner over `SHA256("nostr:agent-auth:" || event.pubkey || ":" || conditions)`.

The decisive design choice, stated explicitly in the spec: **this is not
delegation-as-impersonation.** *"An event that includes a valid `auth` tag
remains authored by `event.pubkey`."* NIP-26 is cited as prior art for the
credential format and then explicitly rejected for its semantics, because
assigning the event to the delegator "MUST NOT be reused for agent provenance."

Provenance and authority stay orthogonal — which is exactly the property Eldr's
invariants 8–9 (honest `participant_type`, no agent self-activation) exist to
protect. The two designs want the same thing; Buzz's just has a key to hang it
on.

Conditions are a small, strictly-validated grammar
(`crates/buzz-sdk/src/nip_oa.rs:62-75`): `kind=<n>`, `created_at<n>`,
`created_at>n`, `&`-joined, canonical decimals, no whitespace. It is a
**reusable capability** — one tag, many events. Revocation cascades via NIP-AA:
drop the owner's membership and the agent's next connect fails.

### 5.3 The transplant into PQRC

The governance half is already built — standing grants are scoped,
time-bounded (≤30 days), budgeted, revocable, visible, and human-signed
(`AgentEngine.swift:427-717`). What is missing is that the *subject* of a grant
is a role flag rather than a key. Four steps:

1. **Per-agent keypairs.** Each `ConfiguredAI` gets its own Curve25519 signing
   key in Keychain — same pattern as the existing `apikey.<id>` slots, so
   `agentkey.<id>`. Replaces the HKDF derivation for new agents.
2. **Bind them.** kind-10420 is *already* a bidirectional human↔agent binding,
   so the concept exists. Extend it (or add a sibling kind) to bind
   human → agent-pubkey with conditions and expiry, signed by the human
   identity key. NIP-OA's shape inside PQRC's envelope.
3. **Carry the pubkey.** `agent_sig` signs with the per-agent key; the rumor
   gains `agent_pubkey` so a receiver can verify against the binding.
4. **Revoke.** Signed revocation event — reuse the standing-grant revocation
   machinery unchanged.

Migration is compatible: the derived key remains valid as a legacy "some agent
on this device" principal, so old peers keep verifying while new peers get
specificity.

**Tradeoff to decide deliberately, not discover later:** per-agent keys reveal
*which* agent is speaking. Today's single derived key hides that. Given privacy
is rule zero, this is a real regression and not a footnote. Options: rotate
per-agent keys per peer, or reveal agent identity only inside an
already-paired town. This belongs in THREAT_MODEL before any of it ships.

---

## 6. What is blocking, concretely

### 6.1 The on-ramp is barricaded — *Inert*

`EldrNodeCore.serve` accepts `townAuthorizer` and `townService`
(`Packages/EldrNode/Sources/EldrNodeCore/EldrNodeCore.swift:186-196`), defaulting
to `DenyAllTownAuthorizer()` and `nil`. The shipped daemon calls it passing
**neither** (`Packages/EldrNode/Sources/eldr-node/EldrNodeMain.swift:209-217`).

So the cross-town A2A plane — built, frame-routed, and unit-tested — drops every
frame in production. `RelayA2ATransport`, `TownAuthorizer`,
`StandingGrantTownAuthorizer`, and the two-town E2E harness are exercised only
by tests. **Highest leverage item in the portfolio, and it is wiring, not
design.** This is GOOSEWORLD.md's own WS-G1.

### 6.2 There is no production Gooseworld host — *Demo-only*

`eldr-gooseworld` (the MCP-server binary a goosetown loads) exists
(`Packages/PQRCMCP/Sources/eldr-gooseworld/main.swift`). Its server counterpart
does not: `GooseworldMCPServer` appears only in its own file, its tests, and
`DemoGooseworldBridge`. The road ends at a demo.

The trust boundary is already reasoned about correctly
(`Packages/PQRCMCP/Sources/PQRCMCP/GooseworldBridge.swift:12-21`): the spawned
binary is a dumb pipe to a loopback socket; the node holds the key and stamps
authorship, so `post` takes no author and an agent cannot post as another town.
That analysis is sound and worth preserving verbatim into the real
implementation.

### 6.3 No per-agent identity — *Architectural* (§5)

### 6.4 No correlation above the transport — *Architectural* (§7)

---

## 7. Correlation

Town A delegates a task to Town B. Twenty minutes later a message arrives.
**Which request does it answer?** Is the task running, done, failed, or never
received?

Today there is no answer:

- `RelayFraming`'s `lineId` orders chunks within one sender's byte stream. It is
  reassembly plumbing and does not surface to the application.
- The ⟡⟡ `re:` field was designed for exactly this and is read by nothing (§3.1).

Without correlation you are limited to one blocking request at a time — no
concurrency, no timeouts, no retries, no partial progress. That is not a
network.

**The fix is already in the tree.** A2A defines task IDs and a lifecycle state
machine (submitted → working → completed / failed / rejected), and `SwiftA2A`
implements it — `Tests/A2AServerTests/TaskStateMachineTests.swift` exists. Route
cross-town work through A2A task objects instead of chat messages carrying prose
envelopes. Mostly wiring.

Worth noting Buzz has the same gap from the other direction: its job kinds
43001–43006 would provide correlate-and-await and are unimplemented. Whoever
ships this first defines it for both.

---

## 8. Integrating with Buzz without asking Buzz to change anything

The concern that integration requires Buzz to adopt PQRC is **unfounded**, and
this is the most actionable finding in the document.

Buzz's entire join requirement is: a secp256k1 keypair, BIP-340 Schnorr
signing, NIP-01 JSON canonicalization, a WebSocket, NIP-42 AUTH, a membership
row **or** a NIP-OA `auth` tag from a member, and an `h` tag equal to the
channel UUID on kind-9. There is a working reference implementation in their own
repo — `examples/countdown-bot`, ~600 lines over raw `tokio-tungstenite`, which
explicitly supports **both** the standalone and the owner-attested auth paths
(`examples/countdown-bot/src/main.rs:9-13`).

So the integration is an **Eldr↔Buzz town gateway**: one process holding two
identities — a Buzz member (or NIP-OA-attested agent) keypair, and an Eldr node
identity. It subscribes to a Buzz channel and bridges to and from Eldr's A2A /
wall plane. To Buzz it is an ordinary bot member. To Eldr it is a paired town.

**Zero changes to Buzz. Zero changes to the Buzz protocol.** This is how
internetworking has always worked: you do not modify the endpoints, you build a
gateway at the edge. Roads do not require towns to rebuild themselves; they
require an on-ramp.

### 8.1 The cost, stated plainly

**A gateway terminates E2EE.** Eldr's value proposition is that the relay is
hostile and sees only ciphertext (THREAT_MODEL §2.1–2.2). Bridging two crypto
regimes necessarily means decrypting at the boundary and re-encrypting or
posting plaintext-to-relay on the far side. Therefore:

- The gateway MUST be run by the town owner, never a third party.
- It MUST be visible in-product — "messages crossing this boundary are readable
  by the Buzz relay operator" — with the same transparency property the
  `ai_window` banner already has.
- It is the natural enforcement point for the existing per-chat egress firewall.

This is inherent to bridging, not a defect in either design. But it must be a
surfaced, deliberate decision rather than something a user discovers.

### 8.2 Do not ask Block to adopt PQRC

Bilateral protocol asks between projects rarely land. If
`docs/A2A-PQRC-EXTENSION.md` is accepted as a registered A2A extension,
adoption follows from the standard rather than from negotiation. The standards
path is the distribution strategy.

---

## 9. Portfolio risk

**ACP-over-Nostr is being implemented twice**, in two languages, with
incompatible cryptography and disjoint kind spaces:

| | `buzz-acp` | `PQRCACP` + `RelayACPTransport` |
|---|---|---|
| Language | Rust | Swift |
| Encryption | NIP-44 v2 | Gift wrap + Double Ratchet + ML-KEM-768 |
| Identity | Per-agent keypair + NIP-OA | One derived key per human |
| Kinds | 10100, 30174–30177, 24200, 44200 | 10420–10422, 10050, 1420 |
| Reach | One relay | Any relay + Multipeer |

Both are real and both work. Roads require picking one envelope. The reading
this document supports: **Eldr should be the transport standard** — it has the
security properties, the offline/nearby fallback, and a published spec — and
**Buzz should become a town on those roads** rather than growing its own
federation, which `ARCHITECTURE.md:9` says it deliberately will not do.

The reusable asset flowing the other way is NIP-OA/NIP-AA (§5.2), which is
protocol-level and transplants cleanly.

---

## 10. Workstreams

Ordered by leverage per unit of effort.

- **WS-I1 — Connect the on-ramp.** Wire `townAuthorizer` + `townService` into
  `eldr-node`'s `serve` call behind config, defaulting to deny-all. Unblocks
  everything downstream. *Days. §6.1.*
- **WS-I2 — Ship the Gooseworld host.** Replace `DemoGooseworldBridge` with a
  real `GooseworldMCPServer` over the loopback + token pattern, preserving the
  trust-boundary reasoning already written. *§6.2.*
- **WS-I3 — Correlation via A2A tasks.** Route cross-town work through A2A task
  objects and lifecycle states. Retire `re:` as a correlation mechanism.
  *§7.*
- **WS-I4 — Per-agent identity.** The four-step transplant in §5.3, plus a
  THREAT_MODEL entry for the metadata regression and a DEVIATIONS entry tagged
  `[upstream-NIP]`. *Largest item; do it once, properly.*
- **WS-I5 — Eldr↔Buzz gateway.** Build against `examples/countdown-bot` as the
  reference. Ship the E2EE-termination disclosure UI with it, not after. *§8.*
- **WS-I6 — Correct the envelope story.** Fix `SettingsView.swift:501`
  ("machine-readable header" — it is not). Decide whether ⟡⟡ stays a
  human-legible display convention (fine) or gets a real parser (only if
  something actually needs to route on it — A2A task IDs likely make it
  unnecessary). *§3.*

Independent of interop: **fix the goosetown dashboard's unauthenticated
`user`-impersonation write path** (§1.1). It is a live prompt-injection channel
into every delegate, and it is not Eldr's bug to fix but is worth reporting
upstream.

---

## 11. What was not verified

Honesty ledger for anything built on top of this document.

- **Nothing was built or run.** No `swift test`, no `xcodebuild`, no `cargo
  build`, no goosetown execution. All behavioral claims are code-reading.
- **`docs/DEVIATIONS.md` is ~303 KB and was sampled, not read.** It is the
  authoritative ledger of proven-vs-inferred and would sharpen several
  shipped/inert calls above.
- **`PersonaRuntime.swift` is 3,815 lines; roughly 500 were read.** Additional
  context paths may exist.
- **`PQRCMessenger.swift` (1,203 lines)** — callers and transport seams read,
  the send/receive pipeline itself not; gift-wrap ordering/retry claims are
  inherited from doc comments.
- **Goosetown has never run on this host.** `~/.goosetown/walls/` is empty and
  `summon`, `tom`, and `skills` are all `enabled: false` in
  `~/.config/goose/config.yaml`. Wall contention, telepathy delivery, and
  skill-source resolution are inferred from source and binary strings, not
  observed.
- **Buzz throughput/latency unmeasured.** `benchmarks/` and `perf/` exist and
  were not opened.
- Whether any real LLM reliably complies with the ⟡⟡ envelope in practice.
  `strippedEnvelopeBody` degrades gracefully when it does not, which suggests
  non-compliance is expected.

### Documentation drift found along the way

- `buzz/ARCHITECTURE.md` — frame size stated 64 KiB, actual 512 KiB
  (`crates/buzz-relay/src/config.rs:14`); historical REQ cap stated 500, actual
  2,000 (`handlers/req.rs:25`); "81 kinds", actual ~130; "no rate limiting
  implementation", actually implemented (`buzz-pubsub/src/rate_limiter.rs:99`).
- `goosetown/README.md:52-54` claims delegates broadcast on gtwall; the worker
  and reviewer skills contain zero gtwall references and the worker skill says
  the opposite ("Isolated — No communication with other workers").
- `goosetown/AGENTS.md:57-65` documents `bd`/beads as core; `bd` is not
  installed and no `.beads/` exists.
- `Eldr/CLAUDE.md:1` still titles the repo "PQRC iOS Client"; `CLAUDE.md:91-103`
  and `README.md:79` disagree on required Xcode version.
- `Eldr/SettingsView.swift:501` describes the ⟡⟡ envelope as machine-readable
  (§3.1).
