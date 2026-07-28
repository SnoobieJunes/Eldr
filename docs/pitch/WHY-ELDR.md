# Why Eldr — and how it differs from Block's Buzz

Eldr is a **post-quantum, end-to-end-encrypted personal messenger where your AI is a
first-class, cryptographically-labeled participant** — "iMessage for the AI age." This
doc starts from the project most people will reach for as a reference point — Block's
**Buzz** — states fairly what it is, and then shows precisely where Eldr is different
and why that difference matters.

Every claim about Eldr below is backed by code in this repository (file paths given).
Every claim about Buzz is from its public repo and engineering blog. Where Eldr is
unproven, this doc says so — a privacy tool that oversells is a privacy tool you
shouldn't trust.

---

## The moment: "Nostr + humans + agents" went mainstream

In 2026, Block (Jack Dorsey) launched **[Buzz](https://github.com/block/buzz)** — an
open-source workspace where "humans and agents build together, on a relay you own."
It's built on **Nostr**, gives every agent its own key, and lets AI agents participate
as members rather than bots. It is a serious, well-built, well-funded product, and its
launch made one thing loud and clear: a decentralized substrate where people and their
AI agents collaborate is not a fringe idea anymore.

Eldr was built on the same instincts — Nostr, cryptographic agent identity, the same
[Agent Client Protocol](https://agentclientprotocol.com) that wires in Goose, Codex,
and Claude Code. So the natural question is: *if Buzz exists, why Eldr?*

The answer is that **they are not the same product, and they are not even trying to
protect the same thing.**

## What Buzz is — stated fairly

Buzz is a **team workspace**: a Slack + GitHub replacement for organizations of humans
and agents. Channels, threads, DMs, voice, media, code repositories (git-over-Nostr,
NIP-34), CI/CD, and automated workflows — all as **signed events in one shared log**,
backed by Postgres/Redis/S3, on a relay a team self-hosts. Its security model is an
**auditable, tamper-evident, searchable record**: who did what, which agent acted under
whose authorization, all cryptographically signed and replayable.

By Block's own engineering write-up, Buzz is **"signed, not end-to-end encrypted"** by
default, and the server **"sees routing metadata"**; only narrow traffic (model
inference, telemetry, cost records) is encrypted
([engineering.block.xyz/blog/buzz](https://engineering.block.xyz/blog/buzz)). That is
not an oversight — it is the *design*. A shared audit log that the server can read,
search, and prove the integrity of is the entire value proposition for a team. You
cannot have a searchable team-wide record and hide the contents from the server at the
same time.

For its job — coordinating a team of people and agents with a durable, trustworthy
record — that is exactly the right trade.

## The gap Buzz leaves open

That same trade means Buzz deliberately does **not** provide:

- **Confidentiality from the server / relay** (it's signed, not E2E-encrypted).
- **Metadata privacy** (the relay sees who talks to whom, and when).
- **Forward secrecy / post-compromise security** (a stolen key opens history).
- **Post-quantum protection** (nothing guards against "harvest now, decrypt later").

Plain Nostr shares these gaps: its encrypted-DM standard has no forward secrecy, no
post-compromise security, no post-quantum layer, and leaks DM metadata publicly
([Nostr security & privacy](https://ron.stoner.com/nostr_Security_and_Privacy/)).

So the space that is **empty** is: *private, metadata-minimal, post-quantum personal
messaging — where your AI is a participant, not a surveillance vector.* That is the
space Eldr is built for.

## What Eldr is

Eldr is a **1:1 and small-group messenger** whose cardinal rule is that **user privacy
comes first, without exception** (SPEC §0). On top of that rule, it makes your AI a
genuine, honest participant in the conversation — able to draft, join a thread, or hold
a bounded autonomous window — while every message stays end-to-end encrypted and every
agent is cryptographically bound to a human owner and labeled as an agent.

It is text-only on purpose, and it **transports messages, it does not store them**:
there is no blob server, relays are transient, and the project deliberately declines to
become a warehouse of other people's data.

## How Eldr differs — the substance

| | **Eldr / PQRC** | **Buzz** (Block) |
|---|---|---|
| **Category** | Private *personal* messenger (1:1, small group) | *Team* workspace (Slack + GitHub for humans + agents) |
| **Security goal** | **Confidentiality** — the server learns as little as possible | **Transparency** — a signed, auditable, searchable shared log |
| **Encryption** | Full E2EE; PQ-hybrid **X25519 + ML-KEM-768** handshake (`PQXDH.swift`), **Double Ratchet** (`DoubleRatchet.swift`), PQ rekey every 50 msgs | **Signed, not E2E-encrypted** by default; server sees routing metadata ([blog](https://engineering.block.xyz/blog/buzz)) |
| **Forward secrecy / PCS** | Yes — message keys used once and deleted; ratchet heals a key compromise | Not from the server (the log is readable) |
| **Metadata privacy** | Gift-wrapped (unsigned rumor → sealed → **fresh one-time key per message**), timestamps fuzzed up to 2 days into the past, size-bucket padding (`GiftWrap.swift`) | Relay sees routing metadata by design |
| **Post-quantum** | Yes — hybrid KEM; breaking a session needs breaking *both* classical and PQ legs | None mentioned |
| **Data at rest** | **Transports, doesn't store** — text-only, no blob server; master key wrapped by the **Secure Enclave** (`SecureEnclaveKeyWrapper.swift`) | Durable Postgres/Redis/S3 — the full history *is* the product |
| **AI / agents** | Agent gets its own key; `participant_type:"agent"` is bound into the AEAD and a human label over agent evidence is a **rejected protocol violation**; autonomy needs a **human-signed, time-bounded, visible** window and **fails closed** otherwise | Each agent its own key; owner signs a scoped authorization; "authorization does not erase authorship" ([blog](https://engineering.block.xyz/blog/buzz)) — *the same core idea* |
| **Agent wiring** | ACP harness (Goose / Codex / Claude Code) via `PQRCACP` | ACP harness (Goose / Codex / Claude Code) via `buzz-acp` — **same standard** |
| **Platforms** | Native SwiftUI on iPhone / iPad / Mac + a macOS companion (Huginn); deep Apple integration (Secure Enclave, Private Cloud Compute) | Tauri desktop + Flutter mobile + CLI — broader reach, less per-OS depth |
| **Org** | Solo + AI pair; ~$0 infra stance | Block — funded team, distribution, brand |

Two honest notes so this table isn't propaganda: Buzz is **broader and more polished**
(chat + git + CI + workflows + voice + media, cross-platform, shipping, funded), and it
solves a real problem Eldr doesn't touch (team coordination with a durable record).
Eldr's edge is **narrow and deep** — the cryptography and the privacy posture — and
every crypto claim above is enforced by a test in this repo (all twelve of the SPEC's
"hard invariants" trace to passing tests; ~676 tests across the eight packages).

## Why people care

The AI era has a quiet cost: to get help from an AI, you increasingly hand it your most
sensitive context — health, money, relationships, source code, plans. Today you get to
pick **one** of two bad options:

- **Private but AI-blind** (Signal, iMessage): nobody sees your messages, but your AI
  can't be in them.
- **AI-native but surveilled** (most everything else, including team logs like Buzz):
  your AI is in the loop, but a server can read, retain, and mine the record.

Eldr is the third option: **your AI in the conversation, and the transcript is yours
alone — provably.** Concretely, that means:

- **You always know who you're talking to.** A message from an agent is
  cryptographically forced to *say so*; a human label forged over an agent signature is
  rejected. No silent AI ghost-writing.
- **The AI can't act on its own.** Autonomy only happens inside a window *you* signed,
  that everyone can see, that expires on its own, and that fails closed the instant it
  lapses.
- **There is no data hoard to breach.** Eldr transports; it doesn't store. A relay is a
  transient postbox, not an archive of your life.
- **It's built for the long game.** Post-quantum hybrid means a copy of your traffic
  captured today can't be quietly decrypted a decade from now.

Who this is for: people who won't paste their life into someone else's server;
developers whose coding agents touch real secrets; anyone who wants AI help *without*
signing up for surveillance to get it.

## What Eldr could contribute to Buzz — and the wider Nostr + agent ecosystem

Buzz's existence is not a reason to shelve this work — it's a reason to place the best
parts of it where they're differentiated and *needed*. Eldr's most durable, most
finishable assets are exactly the things Nostr and Buzz lack:

1. **A confidentiality layer for Nostr (the PQRC gift-wrap + a NIP).** Nostr's encrypted
   DMs have no forward secrecy, no post-compromise security, and no post-quantum layer.
   Eldr already has a written wire spec intended for upstream submission
   (`docs/NIP-XX-pqrc.md`) with frozen interop test vectors. Submitting it as a **NIP**
   is the single highest-leverage move: it plants the idea where it's missing, as an
   open standard anyone — including Buzz's *private* side-channel — could adopt. The
   packages are Apache-2.0 and embeddable.

2. **The `UntrustedDataEnvelope` prompt-injection containment pattern.** Any workspace
   where agents read each other's output and then run shells has the same dominant risk:
   untrusted content flowing into an agent that executes code. Eldr's answer is a
   four-layer structural containment wall (per-read nonce markers generated *after*
   fetch, quote-armoring after splitting on every Unicode line break, control/bidi
   escaping, struct-only headers) that was adversarially tested with a real breakout
   found and fixed. This is a **high-value, low-crypto-dependency** contribution that
   Buzz's threat surface would directly benefit from — the two projects share the
   exposure and the ACP substrate.

3. **ACP / cross-agent interop.** Buzz and Eldr wire the *same* agents through the
   *same* protocol (ACP; both integrate Goose). An adapter that lets an Eldr private
   channel and a Buzz workspace exchange agent traffic is a concrete, plausible bridge.

4. **Eldr as the private layer beside Buzz.** The clean division of labor: Buzz is the
   public, auditable team workspace; Eldr is the confidential 1:1 / side-channel on the
   relay you already run. Complementary, not competing.

None of these is a concession. They're how a small project's best ideas get adopted at
ecosystem scale instead of shouting past a louder launch.

## Honest limits (read these before trusting it)

- **It's early and solo-built.** One person plus an AI pair, not a funded team with an
  ops org.
- **The cross-machine agent layer is not live-proven.** The two-town "gooseworld" flow
  (see [GOOSEWORLD.md](GOOSEWORLD.md)) is tested only *in-process* over a simulator;
  real two-machine delegation over a live relay has not been run, and the threat model
  flags shipping that unhardened as the one unforgivable version of this product.
- **It has not had an independent security audit.** The threat model itself names that
  as a precondition for any non-demo deployment. Do not treat this as audited.
- **The threat model is deliberately honest about what it does *not* hide** — relay-
  visible IP, the recipient tag against a global passive observer, no message
  deniability, single-device with no account recovery. See `docs/THREAT_MODEL.md`.
- **v1 ships the explicit concatenation hybrid, not X-Wing HPKE** (which the SPEC lists
  as preferred) — cryptographically sound and still breaks-both-legs, but a recorded
  spec-vs-code delta (`docs/DEVIATIONS.md`, D2).

The cryptography is real and tested; the *product* is a reference implementation and a
differentiated niche, not a finished, audited, at-scale service. Both of those things
are true at once, and saying so plainly is the point.
