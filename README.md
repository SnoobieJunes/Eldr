# Eldr — private messaging for you *and* your AI

**EldrChat** is a text messenger built on one bet: the next era of messaging has to be private not just between people, but between people **and their AIs**.

Right now you get to pick one. Private messengers (Signal, iMessage) are adding AI that the *platform* runs and controls. AI-everywhere apps let a company's model read your conversations as the price of admission. Eldr refuses the trade: your conversations are end-to-end encrypted against today's adversaries *and* tomorrow's quantum ones, they travel over open relays instead of anyone's server farm, and the AI in your chats is one **you own** — it speaks only when you visibly allow it, and it can never pretend to be you.

> 📱 **Text only, on purpose.** Eldr transports your words; it never stores them. No photos, no videos, no cloud archive of your life ("use iMessage for that"). Messages even expire off the relays within days.

**Status: alpha, pre-release, not yet security-audited.** The eight core packages run their 670-test headless suite green (frozen byte-for-byte crypto vectors and a networked chaos matrix included), and the app targets carry further UI + security-regression suites — but no independent audit has happened yet. Don't stake your safety on it. Details in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

---

## What you can do with it

### Message people, properly privately
- **No phone number, no email, no account.** Your identity is a key that never leaves your device. There's no directory to search and no account database to breach — you're reachable only by people you've shared your key with.
- **Encryption built for the long game.** Every conversation starts with a hybrid post-quantum handshake (X25519 + ML-KEM-768) and runs a double ratchet that re-keys continuously — keys are used once and destroyed, with a fresh post-quantum re-key every 50 messages. A device compromised today can't read yesterday; a quantum computer tomorrow can't read today.
- **The envelope lies for you.** Messages travel gift-wrapped: signed by single-use throwaway keys, timestamps fuzzed up to two days into the past, sizes padded to fixed buckets so length reveals nothing — and every envelope carries an expiry so relays auto-delete it after roughly 5–7 days.
- **Paste a whole novel.** Text over 64 KB splits into ordered encrypted chunks, and a full-screen reader (landscape, pinch-zoom, markdown) makes long content actually readable on a phone.
- **Small groups** with per-person colors, and loud warnings whenever someone's safety code changes.

### Bring your AI into the conversation — on your terms
- **Draft with AI, send as you.** Your AI reads the conversation and proposes a reply; you edit and send it as yourself, or send it openly as your AI.
- **Let it reply on its own — inside a window.** An *AI window* is time-boxed, cryptographically signed by *you*, and visible to everyone in the chat for its whole duration. Outside a window (or an explicit thread invite), the protocol refuses autonomous AI sends. Fail closed, always.
- **AI can never impersonate a human.** Agent-signed messages must be labeled as AI and render unmistakably as AI. A message claiming to be human under an AI signature is rejected as a protocol violation — honesty enforced by signatures, not by policy.
- **Shared AI threads.** Invite your AI and your collaborator's AI into one thread and let them work in front of everyone, with per-person invite status.

### Choose which AI — and firewall what it sees
- Run the **on-device Apple model**, tether **your own self-hosted model**, or connect cloud providers (Anthropic, OpenAI, Gemini, Groq, OpenRouter, or any OpenAI-compatible endpoint) — per persona, your pick.
- Anything cloud-bound passes a per-chat **egress firewall**: real names are replaced with codenames and the context is size-bounded before it leaves the device. Your own private tethered AI can be allowed to see raw — that's your call, per chat.
- When an agent reads your chat context over MCP, it sees **codenames only**, and it cannot post as you outside a live window.

### Turn your Mac into your AI (Huginn)
- Pair your phone with your Mac once, over the same encrypted transport — and the model running on your Mac (LM Studio, or anything with an OpenAI-style endpoint) becomes the AI in your pocket. Your prompts and its memory never touch a third party.
- The Mac AI's long-term memory is **encrypted at rest** with a Secure-Enclave-wrapped key. **Unpair the phone and the key is shredded** — the memory becomes unreadable, by anyone. (This covers the built-in agent's memory; a third-party backend like sybilclaw keeps its own history outside Eldr's reach.)

### Drive a real coding agent from your phone
- The built-in `eldr-acp` agent (or Xcode's agent, or OpenClaw) runs on **your** Mac and you pilot it from your phone over the same post-quantum encryption — through whatever relay you choose, including your own, never a vendor's cloud. And it lives inside your messenger, next to the conversations it's working for.
- Every risky action (writes, shell) prompts you: **Allow once / Allow always / Deny** — and if you ignore the prompt, the Mac denies on its own after ~2 minutes. File access is jailed to the project folder. There's a red kill switch, a live plan/TODO checklist above the chat, and an interactive terminal that is refused entirely unless you've granted autonomous-changes consent.
- A CLI (`eldrctl`) can provision a second Mac over SSH and hand you a pairing link.

### Keep separate lives separate
- Multiple accounts ("silos") on one device, each behind its own passphrase and/or Face ID. The lock screen **never shows a list of accounts** — nobody holding your phone can prove a second silo exists.

### Use it with zero infrastructure
- **Nearby mode:** chat with someone in the same room over local networking with no internet at all, with automatic relay fallback.
- **Local Universe:** a complete five-persona demo world runs inside the app — try every feature without creating anything or sending a byte off-device.
- The default bootstrap relay (`relay.lerants.com`) is free to use, and you can self-host your own instead.

### Let agents talk to agents — encrypted
- Eldr speaks **A2A v1.0** (the Linux Foundation's Agent2Agent protocol) and defines a draft **"A2A over PQRC"** extension — post-quantum, end-to-end-encrypted, serverless transport for agent↔agent delegation, intended for submission upstream. If agents are about to do business with each other, their channel shouldn't be readable by a middleman.

---

## What it deliberately is not

- **Not a media platform.** No images, no video, no file lockers. Transporting text is a promise we can keep; storing your data is a liability we refuse.
- **Not audited.** The test suite proves the implementation against the spec; it is not an independent security review.
- **Not metadata-invisible.** Relays can see your IP and the recipient tag on envelopes, and there's no deniability of authorship. We wrote down exactly what leaks: [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).
- **Not multi-device (yet).** One device per account today.

## Why care

1. **AI is coming to your private chats whether you like it or not.** The mainstream version will be platform-owned models with platform-decided visibility. Eldr is the counter-model: user-owned AI, cryptographically leashed, honestly labeled — built into the protocol, not the terms of service.
2. **"Harvest now, decrypt later" is a today problem.** Anything encrypted classically can be recorded now and broken when quantum hardware matures. Post-quantum ratcheting is table stakes for conversations meant to stay private for decades.
3. **The agent economy needs a private wire.** Agents delegating work to other agents over HTTP-through-somebody's-cloud repeats every mistake messaging just spent a decade fixing. A serverless, post-quantum E2EE agent transport is infrastructure that doesn't exist yet.

## How you can help

- **Build it and beat on it.** Quickstart below. File issues for anything that confuses you — UX confusion reports are as valuable as crashes.
- **Device testing.** The highest-value work right now is proving flows on real hardware (pairing, tethered AI, the coding-agent conduit). File what you find as issues.
- **Security review.** Read [docs/pqrc-SPEC-v1_1.md](docs/pqrc-SPEC-v1_1.md) and [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), then try to break the implementation. Report privately (below). We treat findings as first-class commits — the repo's audit-fix history is public.
- **Run a relay.** Deployment runbook: [docs/RELAY-DEPLOY-CROSTINI.md](docs/RELAY-DEPLOY-CROSTINI.md).
- **Protocol feedback.** The wire format ([docs/NIP-XX-pqrc.md](docs/NIP-XX-pqrc.md)) and the A2A extension ([docs/A2A-PQRC-EXTENSION.md](docs/A2A-PQRC-EXTENSION.md)) both want adversarial readers before they're submitted upstream.
- **Contribute code.** Ground rules: read `CLAUDE.md` (the hard invariants are non-negotiable — the tests enforce them), every judgment call gets a [docs/DEVIATIONS.md](docs/DEVIATIONS.md) entry, and nothing merges red.

## Quickstart

**Toolchain:** stable Xcode 26.5 builds everything (CI does exactly that). The Xcode 27 beta is needed **only** if you enable the experimental Private Cloud Compute tier (`ELDR_PCC_SDK`); for that, `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` first.

```bash
# All eight packages, headless — no simulator needed.
for p in PQRCCore PQRCNostr PQRCAgent PQRCACP PQRCMCP EldrNode Eldrctl SwiftA2A; do
  swift test --package-path "Packages/$p" || break
done

# The iOS app (simulator).
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation

# The macOS companion.
xcodebuild test -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn \
  -destination 'platform=macOS' -skipPackagePluginValidation
```

> `-skipPackagePluginValidation` is required (swift-secp256k1 ships a build plugin).
> Don't pass `CODE_SIGNING_ALLOWED=NO` to `xcodebuild test` — Keychain tests need entitlements.

## Architecture

```
Packages/
├── PQRCCore/   # identity, PQXDH, double ratchet, PQ rekey, padding, AEAD, gift-wrap
├── PQRCNostr/  # Nostr events, BIP-340 signing, relays, chunking, nearby link
├── PQRCAgent/  # AgentProvider + engine: AI windows, thread invites, loop guard
├── PQRCACP/    # the coding agent: tool executor, path jail, permissions, PTY
├── PQRCMCP/    # MCP server — chat context as codenames only
├── EldrNode/   # headless Mac/server node + gateway client
├── Eldrctl/    # SSH installer / conduit provisioner CLI
└── SwiftA2A/   # A2A v1.0 types, JSON-RPC, client/server
App/            # SwiftUI iOS app (EldrChat) — iPhone/iPad/Mac Catalyst
Apps/Huginn/    # macOS companion — tethered AI + coding agent
TestVectors/    # frozen byte-for-byte crypto vectors
```

Core logic lives in the packages (no UI imports) so `swift test` runs headlessly; the app targets stay thin. Swift 6, strict concurrency, actors own all mutable state, CryptoKit/swift-crypto only — no libsignal, no custom primitives.

## Documentation

All docs live in [`docs/`](docs/) — retired material is quarantined in [`docs/deprecated/`](docs/deprecated/).

| Start here | |
|---|---|
| [docs/USER-GUIDE.md](docs/USER-GUIDE.md) | Plain-language walkthrough of everything the app does |
| [docs/pqrc-SPEC-v1_1.md](docs/pqrc-SPEC-v1_1.md) | The PQRC protocol — law |
| [docs/NIP-XX-pqrc.md](docs/NIP-XX-pqrc.md) | The Nostr wire format — law on the wire |
| [docs/APP-SPEC.md](docs/APP-SPEC.md) | Product + architecture spec |
| [docs/TEST-PLAN.md](docs/TEST-PLAN.md) | The test suite as a deliverable |
| [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) | What leaks and what doesn't — honestly |
| [docs/DEVIATIONS.md](docs/DEVIATIONS.md) | Every judgment call, tagged and dated |
| [docs/SETUP-GUIDE.md](docs/SETUP-GUIDE.md) | Building, running, transports |
| [docs/DEMO.md](docs/DEMO.md) / [docs/DEMO-SYBILCLAW.md](docs/DEMO-SYBILCLAW.md) | Scripted demos |

## Relay

The bootstrap relay is **relay.lerants.com** — [khatru](https://github.com/fiatjaf/khatru) behind Cloudflare, NIP-42 AUTH read-gating on encrypted envelopes by recipient tag. Self-hosting is supported and documented ([docs/RELAY-DEPLOY-CROSTINI.md](docs/RELAY-DEPLOY-CROSTINI.md)).

## Security reporting

**Please don't open public issues for vulnerabilities.** Email **security@lerants.com** with a description and reproduction steps; expect a response within 72 hours and coordinated disclosure.

## License

Split licensing, on purpose ([LICENSING.md](LICENSING.md) has the full map):

- **`Packages/`** — all eight SPM packages (crypto core, Nostr transport, agent stack, MCP, A2A, node, CLI): **Apache-2.0**. Embed them in anything, including proprietary products.
- **The apps** (`App/` EldrChat, `Apps/Huginn/`) and everything else: **AGPL-3.0-only**, with a Signal-style [App Store exception](LICENSE-EXCEPTIONS.md) so builds can ship through Apple's store. Forks stay open.

---

*Built in the open, human + AI pair-engineering: ~82k lines of Swift 6 across eight packages and two apps, ~900 tests, frozen crypto vectors, and a public decision ledger — in weeks, not years. User privacy is the number-one priority, without exception.*
