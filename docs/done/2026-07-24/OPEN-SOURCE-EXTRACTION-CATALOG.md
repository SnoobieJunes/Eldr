> **ARCHIVED 2026-07-24 — historical. Do not build from this.**
> The static-analysis survey that preceded the extraction. Superseded by
> [`../../OSS-EXTRACTION-AUDIT.md`](../../guide/OSS-EXTRACTION-AUDIT.md), which records what
> happened when the extraction was actually attempted — **four claims in this file are
> wrong** (audit §2) and **one structural recommendation is reversed** (audit §3: do
> *not* factor a shared `swift-pqrc-types`). To publish, see
> [`../../OSS-RELEASE-RUNBOOK.md`](../../guide/OSS-RELEASE-RUNBOOK.md).
> Kept because its packaging philosophy — many small single-purpose repos, one
> primitive each — survived contact with the code and still governs.

# Eldr Open-Source Extraction & Contribution Catalog

Status: **survey / plan** · Last updated: 2026-07-24

A whole-codebase review of every distinct capability in Eldr, sorted by where it should go:
**contribute** to an existing OSS project, **extract** into our own small standalone repo, or
**keep internal**. Derived from a full file-by-file inventory of all 8 packages + the app + Huginn,
plus a full read of Block's Buzz NIP suite (see `BUZZ-NIP-INTEROP-PLAN.md` for the NIP-specific detail).

Two companion docs already cover slices of this: `BUZZ-NIP-INTEROP-PLAN.md` (protocol/NIP
contributions) and `componentization-seams` (the verified dependency graph). This doc is the
superset — everything, one place.

Effort labels: **S** = days · **M** = 1–2 weeks · **L** = 3+ weeks. All effort is estimate, not measured.

## Packaging philosophy: smallest independently-usable unit

**The audience is other protocol/tool builders — there will be more projects like Buzz — who want to
pick ONE primitive, not adopt a framework.** So favor MANY SMALL single-purpose repos over a few big
ones. Each repo = one primitive, minimal dependencies, usable without dragging in the rest. Concretely:

- **Do NOT ship a monolithic `pqrc-swift`.** Split it into standalone units a builder can take à la carte:
  `swift-pqxdh` (handshake), `swift-double-ratchet` (ratchet + PQ rekey), `swift-nostr-giftwrap`,
  `swift-message-padding`, `swift-relay-chunking`, `swift-ephemeral-prekeys`, `swift-encrypted-store`.
  Someone building a Buzz-like might want only the gift-wrap codec, or only the padding, and should
  get exactly that with no PQ-crypto dependency they don't need.
- Dependencies flow one way and stay thin. If two primitives share types, factor a tiny `swift-pqrc-types`
  rather than merging them.
- A meta-repo / SwiftPM umbrella (`pqrc`) MAY re-export the set for people who DO want the whole messenger,
  but it depends on the small repos — never the reverse.
- Same rule everywhere below: prefer `untrusted-data-envelope` alone over "an MCP toolkit"; prefer
  `swift-credential-redactor` alone over "a logging library."

The tables below name the smallest sensible unit in the **Destination** column.

---

## Legend of destinations

- **CONTRIBUTE →** upstream project exists and wants it; send a PR / SDK there.
- **EXTRACT →** no good upstream home; publish our own small repo (mirror from the monorepo, graduate on adoption).
- **KEEP** — SPEC-bound, E2EE-welded, or app-specific; not meaningfully reusable.

---

## 1. Cryptographic protocol core (`PQRCCore`)

The PQRC protocol itself. Already CC0 (protocol docs) + Apache (code). No PQ-messaging equivalent
exists as a clean Swift library — libsignal is C++/Rust and heavier. **Split into small à-la-carte
repos (see Packaging philosophy), NOT one `pqrc-swift`.**

| Capability | Files (LOC) | Destination (smallest unit) | Notes |
|---|---|---|---|
| **PQXDH handshake** (post-quantum X3DH: X25519 + ML-KEM-768 via swift-crypto X-Wing) | `Handshake/PQXDH.swift` (206) | **EXTRACT → `swift-pqxdh`** | No maintained Swift PQ-handshake lib exists. Depends only on swift-crypto. |
| **Double Ratchet + PQ rekey** (message-driven, `PQ_REKEY_INTERVAL=50`, `MAX_SKIP=1000`) | `Ratchet/*` (443+142+41) | **EXTRACT → `swift-double-ratchet`** | Usable standalone (any X3DH/PQXDH input). Vector-backed (`ratchet_chain.json`, `pq_rekey.json`). |
| **Human-AI tether** (kind-10420 bidirectional binding + HKDF agent-key derivation) | `Identity/IdentityBinding.swift` (128), `Identity/PQRCIdentity.swift:44` | **CONTRIBUTE → nostr NIPs / block-buzz** + **EXTRACT → `swift-agent-binding` (+ Python `agent-binding`)** | Overlaps Buzz NIP-OA. See `BUZZ-NIP-INTEROP-PLAN.md` §A1/§C. Issuer-free; already parameterized (`outerSignatureValid: Bool`). |
| **Standing grants** (bounded, signed, revocable town/context grants) | `Envelope/StandingGrant.swift` (411) | **CONTRIBUTE → block-buzz (Consent Windows NIP)** + **EXTRACT → `swift-consent-grants`** | The revocable/wall-clock-honest answer NIP-OA lacks. §C3 of the NIP plan. |
| **Bucket padding** ({256,1024,4096,16384,65536}) | `Envelope/Padding.swift` (51) | **EXTRACT → `swift-message-padding`** | 51 LOC, zero deps — the ideal small repo. Metadata-length defense any messenger can grab. |
| **Ephemeral key manager** (Secure-Enclave one-time prekeys, consume-and-delete) | `Identity/EphemeralKeyManager.swift` (308), `Prekeys/*` (221+86) | **EXTRACT → `swift-ephemeral-prekeys`** | SE-backed; non-SE fallback generalizes. |
| **CredentialRedactor** (secret-shape scrubber: PEM, sk-, AKIA, Bearer, conn-strings, high-entropy) | `Support/CredentialRedactor.swift` (106) | **EXTRACT → `swift-credential-redactor`** | Commodity but reusable by ANY tool logging agent/LLM output. Zero deps, pure, tested. **Easiest win.** |
| **EncryptedStore + MessageStore protocol** (envelope encryption seam) | `Store/*` (125+207) | **EXTRACT → `swift-encrypted-store`** | The persistence seam; usable without the rest of the protocol. |

---

## 2. Nostr wire + transport (`PQRCNostr`)

Mixed: some pieces duplicate existing Nostr libs (don't bother), others are genuinely novel.

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **NIP-59 gift-wrap codec** (rumor/seal/wrap, fresh one-time wrap key, past-fuzzed timestamps) | `GiftWrap.swift` (176), `SealCipher.swift` (70) | **CONTRIBUTE → a Swift Nostr lib** (nostr-sdk-swift) or **EXTRACT** | Correct, invariant-tested gift wrap is rare and error-prone. High reuse value. |
| **Relay chunking** (>64 KB text split into ordered ratcheted events, NIP-11-sized) | `RelayFraming.swift` (215) + chunk paths in `PQRCMessenger.swift` | **EXTRACT → `pqrc-swift`** | The text-only, no-blob-server answer. Distinctive design choice. |
| **Nearby mesh link** (offline P2P over MultipeerConnectivity, sealed per-link) | `MultipeerNearbyLink.swift` (240), `MultipeerLinkTransport.swift` (368), `NearbyRelayHub.swift` (576) | **EXTRACT → `swift-nearby-mesh`** | Offline sealed messaging with no relay at all. Novel; nobody ships this for Nostr. |
| **Agent-frame tunnels** (ACP/MCP/A2A over Nostr relay events) | `RelayACPTransport.swift` (303), `RelayMCPTransport.swift` (217), `RelayA2ATransport.swift` (305) | **EXTRACT → `agent-frames-over-nostr`** | The one layering-violation cluster (Nostr→ACP). Extract as a small adapter package. Genuinely novel: agent protocols over an untrusted relay. |
| **Local relay + simulators** (NIP-01/42 loopback relay, chaos test doubles) | `NostrRelayServer.swift` (212), `pqrc-relay`, `LocalRelaySimulator.swift` (302) | **KEEP / test-support** | Useful internally; low external demand. |
| Bech32, NostrEvent, NostrWire, BIP-340 signing | `Bech32.swift` (87), `NostrEvent.swift`, `NostrWire.swift`, `NostrKeypair.swift` | **KEEP** — duplicates existing Nostr libs; not worth extracting. | |
| `LocalBlossomSimulator` | (102) | **DELETE-eligible** — vestigial (blob path permanently rejected). | |

---

## 3. Agent engine + AI provenance (`PQRCAgent`)

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **ai_window / thread-invite / grant gating + loop guard** (autonomous sends fail closed; SPEC §13, invariant 9) | `AgentEngine.swift` (1006) | **CONTRIBUTE → block-buzz (Consent Windows / Sealed Attestation NIPs)** | The human-consent enforcement layer. Wall-clock-honest, revocable — the gap NIP-OA/AA document in their own text. |
| **AISelectionPolicy** (which of N AIs answers a turn) | `AISelectionPolicy.swift` (351) | **KEEP** — product logic, not a primitive. | |
| **AgentProvider protocol + 8 providers** (Anthropic/OpenAI/Gemini/Groq/OpenRouter/CustomOpenAI/FoundationModels/PCC) | `AgentProvider.swift` (158) + 8 files | **EXTRACT → `swift-agent-provider`** (small) | A clean multi-vendor inference seam. `CustomOpenAIProvider` already covers Ollama/LM Studio/vLLM. Modest but useful. |
| **PCC (Private Cloud Compute) provider + self-gating** | `PCCFoundationModelsProvider.swift` (271) | **KEEP / reference** — Apple-SDK-specific; the version-gate pattern is worth a blog post, not a lib. | |
| **Reasoning-trace stripper** | `ReasoningTrace.swift` (77) | **EXTRACT → `swift-reasoning-trace`** (tiny) | Vendored in two places already; strips `<think>` blocks. Trivial, reusable. |

---

## 4. ACP coding agent (`PQRCACP`) — the hardened Swift ACP agent

Upstream: Zed's [agent-client-protocol](https://github.com/agentclientprotocol/agent-client-protocol)
(official TS impl; JetBrains/Google/GitHub adopting). A community `wiedymi/swift-acp` SDK exists. So
"Swift ACP SDK" is partly taken — **our lane is the hardened AGENT**, not the SDK.

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **Full ACP agent** (JSON-RPC over stdio, bidirectional, session/fs/terminal/permission) | `ACPAgent.swift` (1395), `ACPClient.swift`, `ACPTransport.swift`, `ACPMessages.swift` | **EXTRACT → `eldr-acp`** (own repo) + **CONTRIBUTE** interop tests to Zed ACP | Biggest single reusable asset (9k LOC). Zero-dep by contract. |
| **ToolExecutor + path jail** (sandboxed file/shell, path confinement) | `ToolExecutor.swift` (1037) | **EXTRACT → `eldr-acp`** | The security hardening nobody else ships. |
| **PTY terminal** | `PTYProcess.swift` (302) | **EXTRACT** | |
| **Permission flow** (`PERMISSION_TIMEOUT`, wait-forever, gated) | `ACPPermissionChannel.swift` (156) | **EXTRACT** | |
| **Encrypted at-rest event log + redaction** | `ACPEvents.swift` (348), `ACPMetadataCrypto.swift` (61) | **EXTRACT** | Encrypted agent audit log — distinctive. |
| **ProjectMemory** (`eldr.md`, byte-capped, ENCRYPTED sink) | `ProjectMemory.swift` (97) | **KEEP / grow** — the privacy-conforming alternative to beads (see beads analysis). | |
| **SybilClaw gateway client** | `SybilclawGatewayClient.swift` (523) | **KEEP** — specific to our Mac-tether backend. | |
| **ContextGraphClient** (:8302 semantic retrieval seam) | `ContextGraphClient.swift` (148) | **KEEP** — thin HTTP seam to external `rdevaul/contextgraph`; opt-in, default OFF. | |

**Xcode angle specifically:** Xcode 27 spawns ACP agents over stdio (`--acp`). `eldr-acp` *is* an
Xcode-compatible agent today. The `pqrc-mcp-bridge` (below) is the MCP-side Xcode shim. Neither is a
plugin; both are standard-protocol binaries → the contribution is "a privacy-hardened agent + MCP
server that any ACP/MCP client (Xcode, Zed, Goose) can spawn," documented as such.

---

## 5. MCP server + injection containment (`PQRCMCP`)

Upstream: [modelcontextprotocol](https://github.com/modelcontextprotocol). Our novel parts have no
MCP-ecosystem equivalent.

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **UntrustedDataEnvelope** (prompt-injection containment; terminal-escape forgery defense) | `UntrustedDataEnvelope.swift` (295) | **CONTRIBUTE → block-buzz (Untrusted Data Admission NIP)** + **EXTRACT → `untrusted-data-envelope`** | STRONGEST contribution. Buzz NIP-AE names this as their unsolved problem. Uncontested across all 14 NIPs and the MCP ecosystem. |
| **Codename wall / SecureChatBridge** (chat exposed to MCP client as codenames only, window-gated writes) | `MCPServer.swift` (293), `SecureChatBridge.swift` (104) | **EXTRACT → `mcp-codename-wall`** | Privacy-preserving MCP exposure. Product-ready; the seam is already clean. |
| **TownWall + GooseworldMCPServer** (cross-town delegated agent access, deny-all default) | `TownWall.swift` (472), `GooseworldMCPServer.swift` (362), `WallChunking.swift` (125) | **EXTRACT → gooseworld tooling** | Cross-org agent boundary. Ties to the Goose ecosystem. |
| **eldr-gooseworld / pqrc-mcp-bridge** (stdio↔loopback shims, zero protocol knowledge) | `eldr-gooseworld/main.swift` (142), `pqrc-mcp-bridge/main.swift` (121) | **CONTRIBUTE → Goose extensions** | `eldr-gooseworld` is already a working Goose extension binary. |

---

## 6. A2A SDK (`SwiftA2A`)

**Upstream landscape (verified 2026-07-24):** the [a2aproject](https://github.com/orgs/a2aproject/repositories)
org ships SDKs for **Python, Java, Rust, JS, .NET, Go — but NO Swift SDK.** (This contradicts the older
AC112 note that a community Swift SDK was already listed; the org currently has none. **Re-verify before
acting** — a community lib may exist outside the org.)

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **A2A v1.0 core + client + server** (JSON-RPC, SSE streaming, AgentCard, TaskStateMachine, security schemes) | `A2ACore/*` (~2k), `A2AClient/*` (~600), `A2AServer/*` (~700) | **CONTRIBUTE → a2aproject as `a2a-swift`** (or **EXTRACT** if they decline) | 3 of 4 products are Foundation-only (Linux-clean). Clean-room, 1,637 test LOC vs frozen `a2a.proto` fixtures. If the org truly has no Swift SDK, this is a **fill-the-official-gap** opportunity, not the also-ran the AC112 note assumed. |
| **A2A HTTP transport** (Network.framework binding) | `A2AHTTPServer/*` (~350) | **CONTRIBUTE** (macOS-gated; note portability) | Only non-portable piece; per-file `#if os(macOS)`. |

**Action:** this reopens the dropped-ambition question. Recommend re-checking the a2aproject org + docs;
if no maintained Swift SDK exists, propose `a2a-swift` upstream rather than keeping it internal.

---

## 7. Headless node + Linux port (`EldrNode`, `Eldrctl`)

The "run on your own Linux server / AWS / GCP, reach over Tailscale" story.

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **Headless serve loop** (dependency-injected, relay + messenger + owner-gated ACP) | `EldrNodeCore.swift` (559) | **EXTRACT → `pqrc-swift` example / `eldr-node`** | The reusable daemon. |
| **Linux keystore ladder** (TPM-sealed via systemd-creds → scrypt-passphrase KEK, fail-closed, loud posture) | `FileIdentityStore.swift` (305) | **EXTRACT → `swift-hardware-keystore`** | Genuinely useful beyond Eldr: a Swift-on-Linux hardware-keystore abstraction. **BUT: never compiled on Linux** — CI is macOS-only. Verify before extracting (add a `ubuntu-latest` job first). |
| **Town authorizer** (deny-all gate + standing-grant unlock) | `TownAuthorizer.swift` (168), `StandingGrantTownAuthorizer.swift` (119) | **EXTRACT** with the standing-grant piece. | |
| **ConduitProvisioner** (SSH installer generator, idempotent `install-huginn.sh`) | `ConduitProvisioner.swift` (315), `EldrctlMain.swift` (425) | **KEEP** — Eldr-specific provisioning. | |

**Cheapest high-value action in this whole doc:** add one `runs-on: ubuntu-latest` CI job for
PQRCCore+PQRCNostr+PQRCMCP. Converts "we think it's portable" into fact and unblocks the Linux/AWS/GCP
story *and* the Python ports (cross-platform vector validation). ~1 afternoon.

---

## 8. App + Huginn key-management & infra

Mostly app-specific, but a few reusable security primitives are buried here.

| Capability | Files (LOC) | Destination | Notes |
|---|---|---|---|
| **Secure-Enclave key wrapper** (P-256 SE wrap of the at-rest master key; iOS + macOS variants) | `App/.../SecureEnclaveKeyWrapper.swift` (90), `Huginn/.../MacSecureEnclaveKeyWrapper.swift` (106) | **EXTRACT → `swift-secure-enclave-vault`** | The invariant-10 hardware-wrap pattern. Reusable by any privacy-first Swift app. |
| **Silo / account vault** (per-account key isolation, crypto-shred by Keychain deletion) | `SiloKey.swift` (93), `AccountVault.swift` (87), `KeychainStore.swift` (234) | **EXTRACT** with the SE vault. | |
| **Envelope-encrypted SwiftData store** (MessageStore over SwiftData, sensitive fields encrypted) | `App/.../SwiftDataStore.swift` (489), `Huginn/.../EncryptedFileMessageStore.swift` (322) | **EXTRACT → reference impl in `pqrc-swift`** | Shows how to back the MessageStore protocol privately. |
| **MLX local model serving** (on-device model host, load/serve, log console) | `Huginn/.../MLXService.swift` (1705), `MLXSupport.swift` (1545) | **KEEP / maybe contribute snippets to mlx-swift-examples** | Large, tied to Apple MLX; upstream `ml-explore/mlx-swift` exists. Contribute fixes, don't extract wholesale. |
| **RelayProvisioner** (Hunnin: spawn-your-own-relay) | `Huginn/.../RelayProvisioner.swift` (427) | **KEEP** — the Hunnin differentiator; product, not primitive. | |
| **ContextLearner** (teachable fine-tune) | `Huginn/.../ContextLearner.swift` (272) | **KEEP** — product feature. | |
| **BackendRegistry** (declarative one-entry-per-backend table) | `App/.../BackendRegistry.swift` (188) | **KEEP** — pairs with the provider extraction if ever wanted; app-layer today. | |

---

## Priority summary (what to do, in order)

Ordered to front-load the smallest, most-independently-useful units (the pick-and-choose primitives a
future Buzz-builder grabs first), before the larger multi-file extractions:

1. **Linux CI job** (S) — unblocks Linux keystore, AWS/GCP story, and Python vector validation. Cheapest, highest leverage.
2. **`swift-credential-redactor`** (S) — easiest standalone win; zero deps, immediately useful to any agent tool.
3. **`swift-message-padding`** (S) — 51 LOC, zero deps; the model small repo. Do it to set the template.
4. **`untrusted-data-envelope`** repo + Untrusted-Data-Admission NIP to block-buzz (S–M). Strongest contribution, code already ships.
5. **`swift-nostr-giftwrap`** (S–M) — high-reuse, error-prone-to-reimplement; also contributable to a swift Nostr lib.
6. **`swift-pqxdh`** + **`swift-double-ratchet`** (M each) — the two crypto primitives, as SEPARATE small repos, not one bundle.
7. **`eldr-acp`** hardened-ACP-agent repo (M) — biggest single reusable asset; diff against `wiedymi/swift-acp` first.
8. **`a2a-swift`** (M) — re-verify the a2aproject org has no Swift SDK; if so, propose upstream. Genuinely open lane.
9. **Tether / Consent-Window / Sealed-Attestation NIPs** to block-buzz + Python verifier (M) — per `BUZZ-NIP-INTEROP-PLAN.md`.
10. **Remaining small units** as bandwidth allows: `swift-message-padding` done above, then `swift-ephemeral-prekeys`,
    `swift-encrypted-store`, `mcp-codename-wall`, `swift-nearby-mesh`, `agent-frames-over-nostr`,
    `swift-secure-enclave-vault`, `swift-reasoning-trace`, `swift-hardware-keystore` (after Linux CI proves it compiles).
11. **`pqrc` umbrella** (S, LAST) — SwiftPM meta-package re-exporting the small repos for anyone who wants the whole messenger. Depends on them; never the reverse.

## Standing caveats
- Everything above is **static analysis** — no extraction attempted, nothing built on Linux this session.
- Extraction = mirror from the monorepo (source of truth), graduate a mirror to a real repo only on external adoption (per `componentization-seams`).
- Repo is **private** as of last check — "go public" is a prerequisite decision, separate from "split."
- License direction: protocol CC0, packages Apache-2.0, apps AGPL — verify each extraction's license and any target-repo CLA before pushing.
