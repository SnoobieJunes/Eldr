> **ARCHIVED 2026-07-24 — historical. Do not build from this.**
> Self-declared IMPLEMENTED at the top of its own body. The adopt/align/contribute
> work landed as DEVIATIONS **AC144**. Live successors:
> [`../../ELDR-BUZZ-INTEROP.md`](../../guide/ELDR-BUZZ-INTEROP.md) and
> [`../../nips-contrib/`](../../nips-contrib/).
> **Its C1/C2/C3 NIP codes are obsolete** — C1 → NIP-AD, C3 → NIP-AC, C2 withdrawn
> in favour of a NIP-OA amendment. See `../../nips-contrib/README.md`.

# Buzz NIP Interop & Contribution Plan

Status: **IMPLEMENTED (2026-07-24)** — the adopt/align/contribute work below
shipped. Codecs (NIP-OA, NIP-44 v2, NIP-AM, NIP-AO) are proven byte-exact
against Buzz's own vectors; the `eldr-buzz-agent` gateway runs the local model
as a Buzz member (proven E2E with the real MLX model); the three contribution
NIPs are drafted PR-ready. See **`ELDR-BUZZ-INTEROP.md`** (runbook + status) and
**`nips-contrib/`** (the three NIPs). DEVIATIONS AC144. Original plan preserved
below for provenance.

Status (original): **plan / not started** · Last updated: 2026-07-24

This is the implementation plan for interoperating with Block's **Buzz** NIP suite
(`/Users/auston/Development Projects/buzz/docs/nips/`, 14 letter-code drafts) and for
contributing the pieces only Eldr has. It is derived from a full read of all 14 drafts.

## The governing fact: the relay-trust axiom split

Every **agent-plane** Buzz NIP assumes the relay is **trusted and authoritative** (it holds
the agent↔owner graph, gates reads, and/or signs authoritative state). Eldr's cardinal axiom
(SPEC §0) is that the **relay is untrusted transport**. This is not a feature gap in either
direction — it is why the two products don't compete (Buzz = desktop / team / trusted relay;
Eldr = mobile + local-tether AI / solo & small-group / untrusted relay, with Hunnin.app letting
a person spawn their own relay).

**Consequence for every line below:** "adopt a NIP" means *speak its wire format for interop*,
NOT *replace the Eldr engine*. Net rip-out across this whole plan is ~zero. We add wire codecs
and align two boundaries; the crypto core, ratchet, `AgentEngine`, and Huginn memory engine are
untouched.

---

## Part A — ADOPT (relay-independent subset; additive)

### A1. NIP-OA (Owner Attestation) codec — *adopt, additive*
- **What:** emit/verify their `["auth", owner_pubkey_hex, conditions, sig_hex]` tag. Owner
  BIP-340-signs `SHA256("nostr:agent-auth:" || agent_pubkey || ":" || conditions)`; conditions
  are `kind=<n>` / `created_at<t` / `created_at>t` joined by `&`.
- **Eldr today:** `PQRCCore/Identity/IdentityBinding.swift` (3-key, bidirectional, kind-10420) +
  `AgentKeyDeriver` (`Identity/PQRCIdentity.swift:44`). These STAY. OA is a *second, simpler*
  provenance format we can also speak for interop with Buzz-ecosystem verifiers.
- **Work:** one new file in `PQRCNostr` (needs secp256k1, which lives there, not Core). ~1 file +
  vectors. Freeze Buzz's published vectors (owner_secret 0x01 / agent_secret 0x02).
- **Rip-out:** none.

### A2. NIP-AM (Agent Turn Metrics) — *adopt, pure gap*
- **What:** one `kind:44200` event per completed agent turn, NIP-44-encrypted to owner, carrying
  token counts + estimated cost + `(sessionId, turnSeq)` for delta recompute.
- **Eldr today:** NOTHING. No per-turn accounting exists. Pure addition.
- **Where it fits:** `AgentEngine` turn completion path; Huginn already sees turn boundaries via
  the SybilClaw gateway (`event:agent` by runId).
- **Privacy check:** payload is NIP-44 to owner; only `p`/`agent`/`created_at` cleartext. Compatible.
- **Work:** emit-side in `AgentEngine`/Huginn; read-side accounting view later. Medium.

### A3. NIP-PL (Push Leases) — *adopt when push is wanted*
- **What:** signed, expiring, revocable filter authorizing a push executor to wake an installation;
  the push body is ONE fixed byte constant — no event content transits Apple/Google.
- **Eldr today:** no push at all.
- **Why adopt vs build:** its first design goal (no shadow feed; fixed wake payload) matches Eldr's
  posture and is better than anything we'd write. The executor = the user's own relay (Hunnin), which
  fits "spawn your own relay" exactly.
- **Work:** large, but deferred until push is on the roadmap. Flag: NIP-PL's public gateway profile is
  Buzz-specific (App Attest, push.buzz.xyz) — Eldr would run its OWN executor on Hunnin, using the base
  protocol only.

---

## Part B — ALIGN (existing Eldr thing → their wire shape; refactor a boundary, don't rip)

### B1. NIP-AO (Agent Observability) — *align one serialization boundary*
- **What:** ephemeral `kind:24200` frames, NIP-44 encrypted, streaming `acp_read`/`acp_write`/
  `turn_started`/`session_resolved` telemetry agent→owner, plus `cancel_turn` control owner→agent.
- **Eldr today:** ACP-over-relay already moves ACP frames (`PQRCACP/MCPOverRelayClient.swift`,
  `PQRCNostr/RelayACPTransport.swift`). AO literally names our frame kinds.
- **Work:** align our frame JSON to their `ObserverEvent` shape at the transport boundary. NOT an
  engine change. **Caveat:** AO's *authorization* rules require a trusted relay
  (`is_agent_owner` lookup) — adopt the PAYLOAD shape, NOT the relay-authz model.
- **Rip-out:** none; boundary reshaping only.

### B2. NIP-AE (Agent Engrams) — *align optionally + steal the blinded d-tag*
- **What:** agent memory `kind:30174`, NIP-44 to the agent↔owner conversation key, **HMAC-blinded
  `d` tags** so the relay never learns the memory slug. Wiki-link `[[slug]]` references, reachability
  graph, tombstones.
- **Eldr today:** Huginn has encrypted at-rest AI memory (`Apps/Huginn/**` memory/ContextGraph);
  `PQRCACP/ContextGraphClient.swift` is the :8302 context graph. These STAY.
- **Adopt:** (a) the blinded-`d`-tag technique regardless — same instinct as our codename wall;
  (b) OPTIONALLY expose/store Huginn memory in AE's envelope shape for portability.
- **Do NOT adopt:** AE's trust model. Note AE self-admits agent-key compromise decrypts ALL memory
  and NIP-44 has no forward secrecy — Eldr's PQ + ratchet posture is strictly stronger; don't regress to it.
- **Beads cross-check (RESOLVED 2026-07-24):** analysis says beads does NOT replace anything here.
  Beads (`bd`, Steve Yegge, Go/MIT, Dolt-backed) is a dependency-aware issue tracker = task memory, a
  different category from AE's conversation memory or ContextGraph's semantic turn retrieval. Its
  storage is **plaintext Dolt on disk + sync = push to a git remote** — a hard violation of invariants
  10/12 (encrypted-at-rest) and 4 (transport-not-store). Only real overlap is `ProjectMemory.swift`
  (~100 ln, tested, ENCRYPTED sink via ACPMetadataCrypto); replacing it with an unencrypted Go/Dolt
  daemon is a privacy regression for negative value. **Do not adopt beads as a replacement.** Correct
  use = interoperate at the gooseworld seam: Eldr *transports* bead-shaped task text (bead ID + title +
  acceptance criteria) inside `world_delegate` payloads over the PQ-E2EE channel; the `.beads/` store
  stays on the goosetown machine (see `docs/GOOSEWORLD.md:20,59`). That's a payload-convention doc note,
  no beads dependency in Eldr. So B2 alignment work is UNBLOCKED and unchanged by beads.

### B3. NIP-AP (Agent Personas) — *low priority, opposite posture*
- **Eldr today:** `App/PQRC/Engine/ConfiguredAI.swift`, `BackendRegistry.swift`, `AgentSkills.swift`.
- Theirs is deliberately PLAINTEXT (public discovery). Eldr's personas carry user instructions we keep
  private. Adopt only a read-codec if we ever want to consume public Buzz personas. Probably skip.

---

## Part C — CONTRIBUTE (the specs only Eldr has; write as NIPs)

Target repo: **`block/buzz/docs/nips`** (their staging ground — every draft is unnumbered; several
normatively say "don't advertise in supported_nips until numbered"). Low friction, lands next to the
specs it cites. Upstream `nostr-protocol/nips` is a later, joint step. Their repo is Apache-2.0; Eldr
protocol docs are CC0 (clean direction) — check for a CLA. Disclose in the PR that we ship a
privacy-first personal client on the same protocol.

### C1. Untrusted Data Admission — *STRONGEST; write first*
- **Cites:** NIP-AE §Security "Memory poisoning … admission control is the implementer's problem" and
  "No owner write authority … out of band." Their own durable-memory spec names this hole and punts.
- **Eldr has it, shipping:** `PQRCMCP/UntrustedDataEnvelope.swift` (295 ln), `TownWall.swift` (472),
  `eldr-gooseworld` binary. Defends against terminal-escape forgery (`\e[2J\e[H`), wraps hostile content.
- **Scope of NIP:** a wire convention + verification rules for marking agent-facing untrusted content so
  a harness can refuse to act on injected directives. Relay-independent.

### C2. Sealed Attestation — *provenance without public linkage*
- **Cites:** NIP-OA §Privacy "the `auth` tag intentionally links the owner key and the agent key; verifiers
  MAY correlate." Permanent public linkage by design.
- **Eldr has it:** provenance proven to the recipient only, inside NIP-59 gift wrap. NIP-PL already treats
  gift wrap as opaque, so the ecosystem understands the primitive; nobody has specced provenance *within* it.
- **Scope:** carry an OA-equivalent attestation inside the NIP-59 seal; verify post-unwrap.
B
### C3. Consent Windows — *revocable, wall-clock-honest authorization*
- **Cites:** NIP-AA §Revocation — owner cannot unilaterally revoke an issued `auth` tag; all 3 paths are
  relay-side. Under an untrusted relay, NIP-OA has no revocation.
- **Eldr has it:** `AgentEngine.receiveWindow` gates on `clock.now()` + `maxWindowDuration`;
  `AIWindowAnnouncement` is human-key-signed + time-bounded; `endMyAIWindow` emits a SIGNED revocation
  (`Envelope/Rumor.swift`, `PQRCAgent/AgentEngine.swift`).
- **Scope:** a bounded, human-signed, revocable authorization window layered over OA-style provenance.

---

## Part D — DO NOT ADOPT (the axiom blocks them)

NIP-AA (agent relay auth), NIP-IA (identity archival), NIP-DV (DM visibility), NIP-CW (channel window):
all require the relay to hold the member graph or sign authoritative state. No counterpart is possible
under Eldr's untrusted-relay model. Leave Eldr's own mechanisms as they are. Workspace-plane NIP-ER
(reminders), NIP-RS (read state), NIP-WP (workspace icon) are Slack plumbing with no Eldr overlap.

---

## Python interop library (separate deliverable)

Build a NIP-OA **verifier** + NIP-AE **reader** (not a competing tether primitive). AE has the richest
vectors (conversation key, d-tag HMACs, four full signed events). Pin its three "implementation gotchas"
as conformance tests — they are exactly what a port gets wrong:
1. NIP-44 ECDH IKM is the RAW unhashed `shared_x` (not SHA-256 of it).
2. BIP-340 `aux = 0x00…00` means 32 zero bytes through the tagged hash, NOT "aux omitted".
3. NIP-01 id serialization uses `ensure_ascii=False`.
A library that gets AE + OA right is immediately useful *inside* Block's ecosystem — that's the adoption path.

## Suggested order
1. C1 Untrusted Data Admission NIP (draft the spec; code already exists).
2. A1 NIP-OA codec + frozen vectors (unblocks the Python verifier).
3. C3 Consent Windows + C2 Sealed Attestation NIPs.
4. A2 NIP-AM (cheap gap fill).
5. B1/B2 alignments — AFTER the beads/context analysis lands.
6. A3 NIP-PL and Python library when scheduled.
