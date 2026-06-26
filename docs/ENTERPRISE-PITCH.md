# Eldr — Enterprise Pitch & Positioning

> The single source of truth for the funder/enterprise narrative. The in-app
> **"Why Eldr for teams"** tour (Huginn ▸ Configuration ▸ "Why Eldr for teams")
> is the distilled, on-device version of this document — keep the two in sync.
>
> **Honesty rule (same as the rest of this repo):** capabilities marked *Shipped*
> run in the app today. Capabilities marked *Rolling out* are in active development
> and must never be pitched as already working. Say which is which.

---

## One-liner

**Eldr is the private network for your team and its AI agents** — post-quantum,
end-to-end encrypted, self-hosted, with zero-trust access controls — so people and AI
can collaborate across trust boundaries **without your data ever leaving your control.**

## The problem

AI agents are powerful, and that power becomes a liability the moment you have to
*reach* one over a network or *share* one with someone you don't fully trust:

- Cloud AI tools send your prompts, code, and context to a third party you don't
  control. You can't prove what was retained, and "delete" is a promise, not a guarantee.
- Giving a vendor, contractor, new hire, or non-technical teammate access to an agent
  (or to the systems it can touch) usually means giving them — and the agent — far more
  reach than the task requires. **Granting access is granting risk.**
- The transport is the soft underbelly. Even a strong model behind a weak channel
  (an exposed port, a SaaS relay, a screen-scraped session) is one interception away
  from a breach — and "harvest now, decrypt later" means today's capture can be read by
  tomorrow's quantum computer.

## The insight

**The model isn't the moat — the network around it is.** Anyone can run a capable
model. What's scarce is a way to put that model to work *with other people* that is
private by right, controllable down to the message, and survives a hostile or absent
network. That's the layer Eldr owns.

---

## What we built vs. what an agent host (e.g. sybilclaw) is

These are complementary, not competitive — and we integrate with them.

| | **The agent host** (sybilclaw / OpenClaw, etc.) | **Eldr / EldrChat** |
|---|---|---|
| Role | The **cockpit + brain + local tools** | The **private network + access control + mobile remote** |
| What it is | A self-hosted, multi-user AI assistant: persona, per-user memory, a skills catalog, tools (shell, browser, cron, chat connectors) | A post-quantum, decentralized, E2EE messenger + agent-routing fabric |
| What it lacks | A secure, sovereign, mobile, zero-trust way to *reach* and *share* the assistant | (We don't try to be the assistant — we carry it) |
| Strength | Rich, customizable agent that does real work on your machines | Confidentiality, honest AI labeling, consent gates, egress control, decentralization |

**How they link (the integration story):** A company runs its sovereign assistant on its
own infrastructure. **Eldr is how its people securely reach and share that assistant** —
from their phones, from anywhere, end-to-end encrypted and post-quantum, with every AI
action labeled and every channel revocable. The cockpit is theirs; **Eldr is the private
network it flies over.** (Concretely: EldrChat on a phone drives a self-hosted agent on a
Mac/server over Eldr's relay — see *Rolling out*.)

---

## The three layers

### Layer 1 — Zero-trust collaboration *(lead)*

Give a contractor, a new hire, or a non-technical teammate a **scoped, observable,
revocable** line to an AI agent — collaboration without handing over the keys:

- **Per-chat egress firewall** caps and obfuscates what can ever leave a conversation;
  private-paired channels pass data straight, everyone else is redacted by default.
- **Fail-closed by construction:** an agent **cannot self-activate** — it acts only
  inside a window a human personally opens, for as long as they allow. Autonomous sends
  outside that window fail closed.
- **Honest AI labeling:** every AI-authored message is cryptographically marked as AI
  and rendered distinctly — it can't be forged or stripped. For a regulated team that is
  an **audit trail by construction**, not a bolt-on.
- **Revocation is instant:** unpair and the identity and its access are gone.

### Layer 2 — Sovereign, self-hosted AI *(support)*

**Own your agents and your comms, end to end.** Run the model yourself — on-device or on
your own server — and run the network yourself too: no API key, no third-party cloud, no
vendor lock-in. Customize the skills, prompts, tools, and memory. "Your code, your AI,
your rules" — extended to the **wire your messages travel on.** The agent-host
integration is the proof point: drive *your* assistant on *your* infrastructure from
*your* phone, with nothing exposed to the open internet.

### Layer 3 — Resilient / interplanetary comms *(vision & moat)*

The properties that make Eldr safe are the same ones that make it survive:

- **Post-quantum encryption** (PQXDH + Double Ratchet + periodic PQ rekey) defeats
  harvest-now-decrypt-later — a message sent today stays private years from now.
- **Decentralized:** rides Nostr — no single company owns the route. No central server
  to fail, be subpoenaed, or be cut off.
- **Disruption-tolerant:** keeps working when the internet doesn't — falls back to local
  radio (Bluetooth/Wi-Fi, no router or carrier) or a phone-hosted "pocket relay."

The same store-and-forward, no-central-authority, partition-tolerant design that survives
an outage is exactly what communication needs at the edge — and, eventually, **off-Earth.**
It's a comms fabric built for environments where you can trust neither the network nor the
timing.

---

## Enterprise use cases

- **Vendor / contractor access** — let an outside party task an AI agent on a sandboxed,
  egress-capped, revocable channel; pull the plug when the engagement ends.
- **Onboarding & non-technical staff** — give someone a safe, observable way to work
  alongside a powerful agent without exposing the systems behind it.
- **Regulated industries** — confidentiality plus an unforgeable AI-vs-human record gives
  you defensible provenance for every agent action.
- **Field / disconnected operations** — keep collaborating when connectivity is hostile
  or absent (local radio, pocket relay).
- **Cross-organization AI collaboration** — let two parties' assistants work a shared
  thread on the record, each side controlling what its agent sees and what may leave.

---

## What ships today vs. what's rolling out

**Shipped (runs in the app today):**
- Post-quantum, end-to-end encrypted messaging over decentralized Nostr.
- On-device AI and bring-your-own / tethered models; honest, signed AI labeling.
- Human-opened AI consent windows; per-chat egress firewall (on by default for
  off-device models).
- Self-hostable relay; local-radio delivery; phone-hosted pocket relay (host only ever
  sees sealed ciphertext).
- Multiple isolated accounts per app, each sealed under its own key.
- An ACP coding agent (`eldr-acp`) and a headless relay node so a phone can drive a
  Mac-side agent over the E2EE relay (proven headlessly).

**Rolling out (in active development — do not pitch as done):**
- One-click Huginn.app install + a crash-safe bridge that registers and drives a
  **self-hosted agent stack (e.g. sybilclaw)** from an EldrChat phone over the relay.
- This enterprise tour and the funder collateral built from it.

---

## The ask / the vision

**Own the network your AI runs on.** Zero-trust collaboration, sovereign self-hosted AI,
and post-quantum encryption in one fabric — so teams can put powerful agents to work with
vendors, contractors, and each other without handing their data to anyone. That's the
company we're building.

---

## Appendix — how this maps to the in-app tour

The **"Why Eldr for teams"** tour (`EnterpriseTourStep`, in
`Apps/Huginn/Sources/Views/EnterpriseTourView.swift`, launched from Huginn's
**Configuration ▸ "Why Eldr for teams"** row) is this doc in **11 cards** with
raven/sailing titles: it opens on (0) *Huginn — the raven of thought* (the framing)
and (1) *Delivered, never rewritten* (tool-agnostic routing), then walks sovereignty,
secret-scrubbing, change-approval, on-the-wire labeling, decentralization, the
phone-pairing bridge, post-quantum encryption, and the close. Edit the cards and this
document together.
