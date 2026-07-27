# Eldr ↔ Buzz Interop — what shipped, how to run it

Status: **built + tested 2026-07-24** on branch `gooseworld-on-main`. This
implements the WS-I / WS-A / WS-B / WS-C workstreams from
[`INTEROP-LANDSCAPE.md`](../done/2026-07-24/INTEROP-LANDSCAPE.md) and
[`BUZZ-NIP-INTEROP-PLAN.md`](../done/2026-07-24/BUZZ-NIP-INTEROP-PLAN.md).
> Both were archived on 2026-07-24 once their workstreams shipped; they are kept
> verbatim for the reasoning, not as current instructions.

> **Truthful-reporting note (CLAUDE.md).** Every claim below is labelled
> *proven* (a test ran and passed), *source-grounded* (verified against Buzz's
> Rust source, not run live), or *needs-owner* (requires a credential/host only
> the owner has). Nothing here was run against Block's hosted relay, because
> that needs a member key held in Buzz's keychain.

---

## TL;DR

Our local model (Qwen3.6-35B on Huginn's `:1337` MLX backend) **replies to a
Buzz-channel `@mention` end-to-end, over a real Nostr WebSocket relay, as a
first-class signed agent member** — *proven* by an automated E2E test
(`endToEnd_realLocalModelReplies`, 27 s, green). Zero changes to Buzz were
required. Two things made it work:

1. **A byte-exact NIP-44 / NIP-OA / NIP-01 / BIP-340 codec** in `PQRCNostr`,
   verified against **Buzz's own published test vectors** (`NIP-AE.md`,
   `nip_oa.rs`). Eldr now speaks Buzz's agent-plane crypto exactly.
2. **`eldr-buzz-agent`** — a gateway daemon that joins a Buzz workspace channel,
   listens for mentions, runs each turn against the local model, posts the reply
   as a signed `kind:9`, and emits NIP-AM turn metrics + NIP-AO observer frames
   encrypted to the owner.

---

## The two integration paths

### Path A — `eldr-buzz-agent` gateway (recommended; proven)

One process holds an agent Nostr identity, connects to a Buzz relay, and bridges
to/from the local model. To Buzz it is an ordinary NIP-42-authenticated (and
optionally NIP-OA-attested) **bot member**. To Eldr it is the local model.

```
Buzz relay ──WS(NIP-01/42)──> eldr-buzz-agent ──HTTP(OpenAI)──> Huginn :1337 (MLX)
     ▲                              │
     └────── signed kind:9 reply ───┘   + NIP-AM (44200) + NIP-AO (24200) to owner
```

- **Proven:** `endToEnd_localModelRepliesAndEmitsMetric` (mock model, full socket
  path) and `endToEnd_realLocalModelReplies` (the real MLX model). Both green.
- Reuses `PQRCACP`'s `OpenAICompatibleLLMClient` (reasoning-trace stripping,
  timeout, real token usage) and `PQRCNostr`'s `NostrWebSocketTransport`.
- Files: `Packages/EldrNode/Sources/EldrBuzzGateway/*`,
  `Packages/EldrNode/Sources/eldr-buzz-agent/main.swift`.

### Path B — register `eldr-acp` as a Buzz managed agent (alternative; needs-owner)

Buzz Desktop's `buzz-acp` harness spawns an ACP agent per turn. Point it at
`eldr-acp` (which drives the same local model) via `agent_command_override`.

- **Proven:** `eldr-acp` answers the exact `buzz-acp` handshake —
  `initialize` → `session/new` → `session/prompt` → `stopReason:end_turn`
  (smoke-tested with `ELDR_ACP_FAKE_LLM=1`).
- **Friction (needs-owner verification):** `buzz-acp` only forwards its
  base-prompt (the `buzz messages send` reply convention) to agents reporting
  ACP `protocolVersion >= 2` or named `goose`; `eldr-acp` reports **v1**. So the
  local model won't learn the Buzz CLI reply convention from `buzz-acp`'s system
  prompt. **Bridge:** set `ELDR_ACP_CONTEXT_FILE=<buzz-cli-notes.md>` when
  registering — `eldr-acp` prepends that file to its system prompt on every
  turn, so the model learns to reply via `buzz messages send`. This path is
  wire-able but was **not run against a live Buzz relay** (no member key); verify
  on-device in the morning. **Prefer Path A for the demo.**

### The GUI over both paths — Huginn ▸ **Connections** (WS-I7 / AC146)

Neither path needs a terminal any more. Huginn's **Connections** tab is the
product surface over everything above; the full design is
[`archive/2026-07-24/ELDR-BUZZ-GUI-PLAN.md`](../done/2026-07-24/ELDR-BUZZ-GUI-PLAN.md).

**Path A, in five clicks** — *Connect an AI to a workspace…*

1. **Which workspace?** Paste the relay URL and press **Test connection**: Eldr's
   own transport opens the socket and reports whether the relay answers and
   whether it asks members to authenticate (NIP-42), with the relay's NIP-11 name.
   Then choose *I own/admin this workspace* (paste the owner key once — it signs
   the NIP-OA attestation in memory and is never stored) or *I was invited* (paste
   an auth tag an admin gave you).
2. **Which model?** Leave it empty and the agent follows whatever model Huginn is
   serving (swap the brain in the MLX tab and the workspace agent follows), or pin
   one model/endpoint to this workspace.
3. **Identity & behavior.** Display name (the `@mention` trigger), about, channel
   ids, mentions-only, the egress filter, and the persona prompt.
4. **The disclosure.** The E2EE-termination banner with a required checkbox — the
   gateway refuses to start without it.
5. **Connect.** Huginn mints a fresh agent key into the Keychain
   (`buzzagent.<id>`), attests it, writes the connection record, and starts the
   supervised `eldr-buzz-agent` child.

The running row shows `● Eldr · <relay> — 4 replies · 1.2k tokens`, with
**Pause/Resume**, **View logs** (the existing console, one log per connection),
**Rotate key** (new identity + re-attestation), and **Remove** — which publishes
an agent-signed retirement (kind:0 tombstone + NIP-09 kind:5) and then destroys
the key.

**Path B, in one click** — *Add this model to Buzz's own Agents tab*. Huginn
writes a `buzz-agent-snapshot` v1 `.agent.json` wired to `runtime: goose`,
`provider: lmstudio`, and the loaded model id; import it in Buzz Desktop and
Save. Because Buzz deliberately strips env vars out of snapshots, the panel also
shows the one line you paste into the agent's Advanced ▸ env vars (or already
have in goose's config):

```
LMSTUDIO_HOST=http://127.0.0.1:1337
```

> Note the correction here: `provider` is a goose **provider ID**, not a base URL.
> Buzz projects it into `GOOSE_PROVIDER` at spawn, so a URL in that field imports
> cleanly and then never answers (AC146).

---

## The crypto that makes it interoperable (proven byte-exact)

`Packages/PQRCNostr/Sources/PQRCNostr/`:

| File | What | Conformance |
|---|---|---|
| `NIP44.swift` | NIP-44 v2 (ECDH raw-x → HKDF → ChaCha20 + HMAC) | reproduces **all 4** Buzz NIP-AE event `content` fields byte-for-byte; `K_c` matches the published vector |
| `ChaCha20.swift` | RFC 8439 ChaCha20 (swift-crypto has no bare stream cipher) | RFC 8439 §2.4.2 vector |
| `NIPOA.swift` | NIP-OA owner-attestation auth tags | verifies Buzz's `nip_oa.rs` spec signature; SHA-256 preimage matches |
| `BuzzEvents.swift` | kind 0 / 9 / 9000 / 10100 / 44200 / 24200 builders + NIP-AM/AO payloads | tag layout mirrors `buzz-sdk/builders.rs`; AM/AO round-trip decrypt |

Test: `swift test --package-path Packages/PQRCNostr --filter BuzzInteropCryptoTests`
(12 tests, green). This is the strongest possible interop evidence: **an Eldr
node produces bytes a Buzz relay/verifier accepts, and reads bytes they emit**,
checked against Block's own vectors.

The three re-derivation gotchas Buzz's `NIP-AE.md` flags — raw unhashed
`shared_x`, aux=0 folded through BIP-340 (not omitted), `ensure_ascii=False`
id serialization — are all pinned as conformance assertions.

---

## Relay swap — "can I just point Eldr at a Buzz relay?" (source-grounded)

Grounded in `buzz-relay/src/handlers/ingest.rs::required_scope_for_kind` — read,
not run against a live buzz-relay (needs a member key).

| Eldr event | Buzz-relay verdict | Consequence |
|---|---|---|
| `kind:1059` gift wrap | **accepted** (`MessagesWrite`) and **`#p`-gated read** | Eldr's E2EE messages transit a Buzz relay fine; the relay sees only ciphertext — exactly Eldr's hostile-relay model. Buzz even enforces the same recipient-only 1059 read gate Eldr's anchor relay does. |
| `kind:10420` identity binding | **rejected** (`restricted: unknown event kind`) | key discovery can't ride a Buzz relay |
| `kind:10421/10422` prekeys, `10050` DM relay list | **rejected** | prekey bootstrap can't ride a Buzz relay |

**Honest answer:** *message transport* is relay-agnostic — swap in a Buzz relay
(or any relay) for `kind:1059` traffic and E2EE holds. *Identity/prekey
bootstrap* needs an Eldr-compatible relay (`relay.lerants.com` or a Hunnin
relay). This is fine and expected: Eldr already supports multiple relays with
different roles, and INTEROP §8's rule is "don't ask Buzz to change." So the
setting story is: **keep an Eldr relay for identity, add a Buzz relay for
transport** — not a single wholesale swap.

---

## E2EE termination — the one honest cost (INTEROP §8.1)

A Buzz channel is **signed-not-E2EE plaintext**. The gateway is an *edge bridge*:
content it posts to a Buzz relay is readable by that relay's operator. Therefore:

- The gateway **MUST** be run by the workspace owner, never a third party.
- It prints a disclosure banner at startup (`BuzzGatewayConfig.disclosureBanner`)
  and this is recorded in `THREAT_MODEL.md §7`.
- It is the natural enforcement point for the existing per-chat egress firewall.

This is inherent to bridging two crypto regimes, not a defect. Eldr↔Eldr traffic
stays PQ-ratcheted E2EE; only the Buzz boundary is plaintext, by Buzz's design.

---

## DEMO RUNBOOK

Everything below runs on this Mac. `DEVELOPER_DIR` must point at Xcode 27 beta.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
```

### 0. Prove the crypto interop (5 s, no network)

```bash
swift test --package-path Packages/PQRCNostr --filter BuzzInteropCryptoTests
```

Expect: 12 green — NIP-44/NIP-OA/NIP-01/BIP-340 reproduce Buzz's own vectors.

### 1. Prove the gateway end-to-end with the REAL local model (~30 s)

Requires the MLX server up on `:1337` (it is — `mlx_lm.server … --port 1337`).

```bash
ELDR_BUZZ_E2E_LIVE_MODEL=1 \
  swift test --package-path Packages/EldrNode \
  --filter endToEnd_realLocalModelReplies
```

Expect the log to show the local model authenticating, receiving the mention,
and replying — e.g.:

```
GATEWAY: authenticated to ws://127.0.0.1:PORT as 466d7fca…
GATEWAY: mention … @Eldr in one sentence, what is post-quantum cryptography?
GATEWAY: replied … (246 chars)
LIVE MODEL REPLY: Post-quantum cryptography refers to cryptographic algorithms …
```

The deterministic-model variant (adds a NIP-AM metric decrypt assertion):

```bash
ELDR_BUZZ_E2E=1 swift test --package-path Packages/EldrNode \
  --filter endToEnd_localModelRepliesAndEmitsMetric
```

### 2. Run the gateway as the shipped daemon against a live Buzz relay (needs-owner)

The binary is real; connecting to Block's hosted relay needs an **agent key** and
(for a closed relay) an **owner-signed NIP-OA auth tag** or relay membership —
both held by the owner. Once you have them:

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build --package-path Packages/EldrNode --product eldr-buzz-agent
BIN=$(swift build --package-path Packages/EldrNode --product eldr-buzz-agent --show-bin-path)/eldr-buzz-agent

export BUZZ_RELAY_URL="wss://auston.communities.buzz.xyz"
export BUZZ_PRIVATE_KEY="nsec1…"            # the agent key you mint for Eldr
export BUZZ_AUTH_TAG='["auth", …]'          # owner-attested; optional if the agent key is a member
export ELDR_BUZZ_CHANNELS="<channel-uuid>"  # the workspace channel to join
export ELDR_BUZZ_DISPLAY_NAME="Eldr"
export ELDR_BUZZ_OWNER_PUBKEY="<owner-hex>" # enables NIP-AM/AO to the owner
export ELDR_LLM_URL="http://127.0.0.1:1337/v1"
export ELDR_LLM_MODEL="dawncr0w/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-OptiQ-5bpw-MLX"

"$BIN"
```

Then in Buzz Desktop, `@Eldr <question>` in that channel. The gateway replies as
a signed agent member and (if `ELDR_BUZZ_OWNER_PUBKEY` is set) files a NIP-AM
usage metric you can read back with a `{"kinds":[44200],"#p":["<owner>"]}` query.

**Local-relay alternative (fully self-contained, no Buzz account):** run Eldr's
own `pqrc-relay` and point the gateway at `ws://127.0.0.1:<port>` — this is what
the automated E2E does in-process.

To mint an agent key + owner auth tag for the demo without Buzz Desktop, use the
owner key you control:

```bash
export ELDR_BUZZ_OWNER_PRIVATE_KEY="nsec1…"   # derives owner pubkey + computes the NIP-OA tag
# (BUZZ_AUTH_TAG and ELDR_BUZZ_OWNER_PUBKEY are then auto-filled)
```

---

## What we contribute back (the pitch)

Three specs only Eldr has, written PR-ready for `block/buzz/docs/nips`
(`docs/nips-contrib/`):

- **NIP-AD Untrusted Data Admission** — closes the memory-poisoning hole
  `NIP-AE.md §Security` names and punts on. Reference impl ships in Eldr
  (`UntrustedDataEnvelope`, `TownWall`).
- **NIP-AC Agent Consent Windows** — the revocable, wall-clock-honest authorization
  NIP-OA/NIP-AA can't express under an untrusted relay.
- **A NIP-OA amendment (unsigned carriers)** — NIP-OA provenance *without* the
  permanent public owner↔agent linkage, carried inside a NIP-59 seal. This began
  as a third draft ("NIP-AS Sealed Attestation") and was withdrawn on 2026-07-24
  once it turned out to be one verification rule NIP-OA already almost permits,
  not a NIP of its own.

> **Codes renamed 2026-07-24.** These were `NIP-C1/C2/C3`; Buzz uses two-letter
> codes and `NIP-CW` was already taken by Channel Window. See
> [`nips-contrib/README.md`](../README.md) for the mapping and the
> upstream-namespace caveat.

The reusable asset flowing the other way — NIP-OA/NIP-AM/NIP-AO — is now spoken
natively by Eldr, byte-exact against Block's vectors. That is the adoption path:
a client that gets Buzz's agent-plane crypto right is immediately useful *inside*
Block's ecosystem.
