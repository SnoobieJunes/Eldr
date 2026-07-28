# Eldr — Features, Setup & Testing Guide

A concise, complete reference to what the app does, how to use every feature, how to set up and configure the system (including the optional Mac coding agent), and how to build/test/demo it. For a warm, plain-language walkthrough aimed at end users, see `USER-GUIDE.md`; this document adds the setup/config and testing detail.

Eldr ("iMessage for the AI age") is a **post-quantum, end-to-end-encrypted, AI-native messenger** over Nostr, on one SwiftUI app (**EldrChat**) for iPhone/iPad/Mac. Everything is device-only; keys never leave the device; any time context could reach a remote AI it's shown loudly. Privacy is the number-one rule.

## The pieces

| Piece | What it is | Where it runs |
|---|---|---|
| **EldrChat** | The messenger app (chats, contacts, AI) | iPhone / iPad / Mac |
| **Relay** | Nostr relay ferrying encrypted envelopes; default `wss://relay.lerants.com` | Server (or `local` in-process sim) |
| **Huginn** | macOS app that turns your Mac into an AI "node" (the coding agent) | Mac only |
| **eldr-acp / eldr-node** | The coding agent + headless node Huginn drives | Mac only |

You need only EldrChat + a relay to message and use AI. Huginn is optional — it's for the Mac coding-agent feature (Part 4).

> **Verification note.** The build/test commands in Part 5 were run and observed **green** in this repo. The in-app step-by-step flows are transcribed from the current SwiftUI source (labels quoted verbatim), not from driving every screen on-device — treat "how to test" as instructions to run. Anything needing Face ID / Secure Enclave, Nearby radios, PCC, or the Mac stack is only fully exercisable on real hardware.

---

# Part 1 — Setup

## 1.1 First run — create or unlock your account
Launch EldrChat. You always land on a **lock screen** (never an account list — hidden accounts stay deniable).

**Create an account:**
1. Tap **"Create a new account"**, enter a **Display name**.
2. Choose the type with **"Protect with a passphrase (hidden account)"**:
   - **Off** = your normal default account (one per device). Keep **"Unlock with Face ID / Touch ID"** on for glance-unlock.
   - **On** = a hidden account: set **Passphrase** + **Confirm passphrase** (the only way in; nothing reveals it exists). No biometrics.
3. Acknowledge **"there is NO recovery…"** and tap **Create account**.

**Unlock later:** Face ID auto-prompts, or **"Open my account"**, or type a **Passphrase** → **Unlock**.

Your at-rest key is wrapped by the **Secure Enclave**; keys can never be exported (Settings ▸ Identity: "Key export → Not possible — by design"). On Simulator, use the passphrase path (biometrics/SE are software-emulated).

## 1.2 Connect a relay
Settings (gear, top-left; ⌘, on Mac) ▸ **Servers**:
- Each relay row shows live status (green = Connected). **"My keys on relay"** shows Publishing / Published / Not published.
- Add one: type `wss://your.relay` and tap **+**. Keywords also work: **`local`** (offline in-process sim), **`host`** (host a nearby relay), **`nearby`** (join a hosted one).
- **Check connection** re-pings; **Apply & reconnect** rebuilds onto the new list; **Reset to default server** restores `wss://relay.lerants.com`.
- Settings ▸ **Prekeys** ▸ **Replenish & republish bundle** after changing relays so peers can start chats with you.

## 1.3 (Optional) Set up the Mac coding agent — Huginn
Only for the Mac-Tethered-AI (Part 4): build/run Huginn on the Mac, point it at a local LLM (LM Studio / Ollama / sybilclaw), **Enable bridge**, and pair the phone by scanning its QR.

---

# Part 2 — Contacts & conversations

## 2.1 Add a contact
- **Paste an npub:** conversation list → compose button ("New conversation", ⌘N) → paste `npub1…` into **Contact** → optional **First message** → **Start encrypted conversation**.
- **QR code:** there's **no in-app scanner** — the other person shows their QR (Settings ▸ Identity ▸ **Share my address**); scan it with the **system Camera**, which deep-links (`pqrc:add?npub=…`) into EldrChat with the npub prefilled.
- **Nearby (no server):** when the Nearby setting is on and you're together, pick the person under **Nearby · no server** (confirm the safety code in person after).

If the contact hasn't joined the relay yet, you get an **"Invite them to EldrChat"** share link.

## 2.2 Verify a contact (safety codes)
Open a 1:1 → **•••** ▸ **Conversation details** → compare the **safety code** out-of-band, then mark **Verified** (D13). A later code change surfaces a warning. (1:1 only — groups have no single identity key.)

## 2.3 Message requests, rename, block
- A first message from an unknown sender lands under **Message Requests** (never a live chat) → **Accept** / **Decline**.
- **Rename** (local-only alias) and **Block / Report** live in **Conversation details ▸ Safety**.

## 2.4 Send a message (1:1)
Type in the **Message** field → send (up-arrow; Mac: Return sends, ⇧Return = newline). Bubble status is honest: **Sent to relay / Queued / Not sent · Tap to retry** (never "delivered"). Type **`@`** to mention your AIs / people / their AIs.

## 2.5 Groups
Compose ▸ group button ("New group", ⇧⌘N) → **Group name** → check members (paired Mac nodes can be added) → **Create group** (or **Create solo AI group** with no members = just you + your AIs). Header shows "N people" or "Just you · your AI"; tap it for the roster. Membership is *asserted*, not cryptographically guaranteed (shown in the footer).

## 2.6 Threads (shared AI sub-conversations)
A focused, recorded sub-chat where each side can invite their AI for a bounded time.
1. **•••** ▸ **Start AI thread** (or long-press a message ▸ **Start a thread from here**) → title → **Create AI thread**.
2. Open from the **thread chips** row (`✳︎ title · count`).
3. Inside: **Invite my AI** (15/30/60/120 min; header shows countdown) → **Withdraw my AI** to stop early. **Share context / Stop sharing context** (30 min) controls what your AI sees. **AI turn limit** caps back-to-back AI replies (0 = unlimited, default 50). **Skills** pins shared hand-off formats. Long-press a thread message ▸ **Copy to main chat** brings an answer back.

An AI can **never** join a thread on its own — a human invites it.

## 2.7 Large pastes & the reader
Eldr is text-only (no media/blob server). Paste a big block → it collapses to a chip: **"Large text · N KB · sends in encrypted chunks"** (>64 KB → split across ratcheted E2EE relay chunks) or **"…sends padded inline"** (smaller). Incoming long content collapses to a preview with **Show more** / **Open full screen**. The reader renders markdown/HTML natively (sanitized — no web view, no remote loads, so a message can't leak your IP or run scripts), with pinch-zoom and a **Source ⇄ Rendered** toggle.

---

# Part 3 — AI

Two homes: **Settings ▸ AI** (global setup) and the per-chat **AI hub** (per-conversation behavior). Everything is **off by default** — nothing gathers context or replies until you opt in, and any remote send is shown loudly.

## 3.1 Configure your AIs — Settings ▸ AI
1. Settings ▸ **AI** ▸ **Add an AI** (defaults to on-device, random name).
2. Open its row → set **Name**, **Enabled**, **Backend**, and the fields that appear (key / URL / model / reasoning).
3. Set **Context & behavior**: **Instructions** (system prompt; empty = pure conduit), **Gathers** (Live / Marked only / Off), **Does** (Participate / Draft only / Summarize), **Context depth** (1–100), **Handles coding tasks**.
4. Tap **Test** to run that AI on a sample and see the real reply or exact error.

**Backends** (key needed? / off-device? / egress-firewall applies?):

| Backend | Key | Off-device | Firewall | Notes |
|---|---|---|---|---|
| **On-device Core AI** (`ondevice`) | – | No | n/a | Runs on the phone; nothing leaves the device. Needs Apple on-device model, else a Demo stub. |
| **Apple Private Cloud Compute** (`pcc`) | – | Yes (attested) | **No** | Consent required; full names/context sent (attested, no retention). Adds a Reasoning-depth picker. Needs PCC-capable hardware. |
| **Claude / OpenAI / Gemini** | ✔ | Yes | ✔ | Cloud vendors. |
| **OpenRouter / Groq** | ✔ | Yes | ✔ | Have a Model field. |
| **Custom / self-hosted** (`custom`) | opt | Yes | ✔ | OpenAI-compatible **Server URL required** (e.g. LAN Ollama / LM Studio). |
| **Nearby host's AI** (`hub`) | – | Yes | ✔ | Needs relay set to `nearby` + staying near the host. |
| **Mac-Tethered-AI** (`acp`) | – | Yes | ✔ | The Mac coding agent — needs a paired + consented Mac (Part 4). |
| **Demo** (`demo`) | – | No | n/a | Simulated echo; no real AI. |

- **API keys** go in a SecureField → device Keychain (never synced/exported).
- Switching an AI to any off-device backend raises a **"Send conversation content off this device?"** consent gate.
- **Egress firewall** (account-level, ON by default): replaces real names with private codenames and size-bounds anything sent to a **remote, firewalled** AI. On-device/PCC unaffected.

## 3.2 "My AI responds" — draft privately vs respond in chat
Open the per-chat **AI hub**: tap the toolbar **AI chip** (sparkles) or the **AI faces bar** above the composer (shown with 2+ AIs). Sheet title: **"AI in this chat"**.
- **Drafts privately** (default): **Draft a reply now** → review in the **AI Draft** sheet → **Send as my AI** or **Edit & send as me**. Nothing posts until you send.
- **Responds in chat**: pick **1 / 8 / 24 hours** → **Turn on for N hours**. Opens a **visible, time-bounded AI window** (announced on-wire, human-signed, with a live countdown every client sees) *and* shares context for that period. **Stop my AI replying here** ends it. An AI can never self-activate.

Also: long-press the empty composer ▸ **Draft with AI**; long-press a guest message ▸ **Have my AI answer this**.

## 3.3 Run multiple AIs — roster, order, critique
In the hub's **"Replies in this chat"**: tap rows to include/exclude AIs; with 2+, tap **Edit** and drag to set reply order (chained AIs each see the previous ones' replies). No roster = all reply in config order; empty roster = "AIs off here". Toggle **"Reply as a critique panel"** so the first AI answers, the middle ones critique, the last merges.

## 3.4 Share context with other people / their AIs
In the hub, **"What your AIs may read from others"** has two independent, 8-hour, off-by-default switches: **Read other people's messages** (human axis) and **Read other people's AIs** (AI axis). **Both sides must opt in** — a one-sided grant shares nothing.

## 3.5 Per-message context marks + inspector
- Long-press a message ▸ **Add to / Remove from AI Context** (global) or **Add to a specific AI**. Multi-select: **Add N to AI Context**.
- **Settings ▸ AI ▸ (tap an AI) ▸ inspector:** pick a conversation to see **exactly what's sent** (the assembled prompt) and per-message **Included** toggles. Remote-AI rows show real names replaced by codenames.

## 3.6 Privacy indicators
- **AI context sharing is on** — purple banner while a grant is active.
- **"<name>'s AI is active · Xm left"** — the AI-window countdown, visible to peers.
- **Egress firewall** banner (only when a remote AI is active): **green** "…names & secrets redacted before this chat reaches your cloud AI" vs **loud orange** "OFF — real names & full context leave your device". Toggle it **per-chat** in **Conversation details ▸ Egress firewall here** (Use default / On / Off). The hub shows the *state* but doesn't toggle it.
- **Per-message eye badge** — how many of your AIs currently see a message (warning glyph when redacted for a cloud AI).

## 3.7 Local agent access (MCP) — expose your *chat* to a local agent
Distinct from the Mac coding agent: Settings ▸ Privacy ▸ **Local agent access (MCP)** lets a local agent on *this* machine (Goose/Xcode/Claude) read **redacted** chat over a loopback, token-gated socket, and draft/mark/send-as-AI only inside an open window. Off by default; **Enable local agent access** reveals a **Socket** path + **Pairing token** (Copy / Regenerate); stops on lock.

---

# Part 4 — The Mac coding agent (Huginn) — optional, **needs the Mac stack**

Makes your Mac's coding agent (LM Studio / Ollama / sybilclaw) appear as one of "My AI" and, with explicit approval, run commands and edit files on the Mac. `[Mac stack]` = needs Huginn + agent + local LLM running; "connection refused" means the stack is down.

## 4.1 Set up + pair
1. **On the Mac:** run Huginn (`xcodebuild … -scheme Huginn build`, or open the workspace). First run is a **Setup Wizard**.
2. **Configuration ▸ Local LLM:** set **Server URL** (e.g. `http://127.0.0.1:1234/v1`), optional token, **Model** → **Test** (health dot green). *(Your LLM server must be running.)*
3. **EldrChat Bridge** tab ▸ **Enable bridge** → a **Pair with EldrChat** QR appears.
4. **On the phone:** Settings ▸ **Pair your Mac-Tethered-AI**, then scan the QR with the system Camera (or use Huginn's **Copy pairing link**). The first device to pair is auto-pinned **Owner**; the Mac shows "Paired with …".

## 4.2 Choose the responder
Bridge tab ▸ **Mac-side responder**: **eldr-acp** (Eldr's own agent + LLM, works standalone) or **sybilclaw assistant** (forwards to your sybilclaw assistant over its local **Gateway :18789**). Switching re-wires live, no restart.

## 4.3 Enable full-tool "Coding & tools" + permissions (phone)
Two phone surfaces write the **same** per-node consent (stay in sync):
- **AI hub ▸ "Coding & tools · <node>"**: **Let this AI run commands & edit files** (dev-control; off = read-only) and **Allow changes without asking each time** (autonomy; disabled until the first is on).
- **Conversation details ▸ "Mac agent control"**: **Drive this agent from here**, **Allow autonomous file & shell changes**, **Share my chat context with this agent**.

**Approval:** with autonomy **off**, every mutating tool (write/edit/run/open-terminal) shows an **Allow once / Always / Deny** card on the phone; reading files never asks; an ignored request is denied by a 120 s node-side timeout (fail-closed). The read-only chat path is never changed here — full tools run only via the phone-approved path. The roster row badges the AI **"read-only"** vs **"runs commands"**.

## 4.4 The live terminal
When the agent opens a shell, a live PTY streams to the phone with a red **Stop**, a **"Type a command…"** field, and **^C / ^D** buttons. Never persisted at rest. Also killable from **Conversation details ▸ Kill live terminal**; revoking autonomy tears it down.

## 4.5 Extras
- **Encrypted AI memory + conversation continuity** (your Mac AI remembers): every owner↔AI turn on the Mac node is recorded to `<configDir>/transcripts/` **envelope-encrypted to the EldrChat bar** — a 256-bit master key wrapped by the **Secure Enclave**, per-record AES-256-GCM, filenames an opaque `SHA256(session key)` (nothing conversation- or identity-derived hits disk in the clear). Each conversation gets a **stable, opaque per-conversation gateway session**, so the AI keeps context **across turns within a chat** and stays **isolated** from every other chat (and from any Discord/Signal session the same assistant runs). **Unpair** (Bridge ▸ Unpair) **cryptographically shreds** the master key — transcripts become unreadable even if files linger. Trade-off: the **sybilclaw** responder keeps its OWN plaintext history outside our control, so choose **eldr-acp** for full at-rest privacy (THREAT_MODEL §2.14). This is a **Huginn.app** feature; a headless `eldr-node` (eldrctl) relies on the responder's own store. (DEVIATIONS AC69–AC71.)
- **Project memory** (Huginn ▸ Configuration): **Self-learning** builds a per-project `eldr.md` the agent reads next session; events + `eldr.md` are **sealed at rest** under a Secure-Enclave-derived key (`deriveKey("acp-metadata-v1")` off the same master key) whenever Huginn spawns the agent — falls back to cleartext-but-redacted only when launched without the key (external Xcode/OpenClaw) or with no Keychain (DEVIATIONS AC72).
- **ContextGraph** (optional): richer retrieval via a local service on `:8302`.
- **eldrctl** (remote setup over SSH): `eldrctl install --target user@host --owner <phone-hex>` stages Huginn/eldr-node + returns a pairing link; seed the LLM token with `eldrctl conduit import-token`. The target needs an **unlocked GUI login session**. Full runbook: `CONDUIT-SETUP.md`.

## 4.6 Turn it off
- **Mac:** Bridge ▸ **Stop advertising** (keeps keys) or **Unpair** (shreds all node/transcript keys — clean slate).
- **Phone:** Conversation details ▸ turn **Drive this agent from here** off (tears down the transport, denies pending prompts).

---

# Part 5 — Build, run, test

> **Toolchain (hard rule):** export the Xcode 27 beta before any `xcodebuild`. A 26.x build does *not* fail — the Private Cloud Compute path self-gates on the SDK version (DEVIATIONS AC125) and is silently compiled out, so you get a working app with PCC missing.
> ```bash
> export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
> ```

## 5.1 Fast package tests (no simulator, no network)
```bash
swift test --package-path Packages/PQRCCore     # crypto, ratchet, PQXDH, padding, gift-wrap
swift test --package-path Packages/PQRCNostr    # wire codec, BIP-340 signing, relay simulator
swift test --package-path Packages/PQRCAgent    # AI providers, skills, reasoning-strip
swift test --package-path Packages/PQRCACP      # coding-agent (eldr-acp) conformance
swift test --package-path Packages/PQRCMCP      # local-agent MCP server
swift build  --package-path Packages/EldrNode   # headless Mac node
```
No unit test touches the network or the real clock (sources are injected), so they run anywhere.
New suites this cycle (in the packages above + the app/Huginn targets): `ConversationMemoryTests`, `ACPMetadataCryptoTests` / `ACPMetadataSinkTests`, `EncryptedStoreDeriveKeyTests`, `AISelectionPolicyTests`, `AgentContextGrantTests`, `ContextSharingWireTests`, Huginn's `GatewayHandshakeTests` / `GatewayReplyTests` / `BridgeTests` (watch-along), EldrNode's `SybilclawGatewayFramingTests` (node/app handshake parity), and the app's `MultiAIBehaviorTests` / `ANSITerminalTextTests`.

## 5.2 App build + test (iOS Simulator)
The scheme/target is **EldrChat** (the old `PQRC` scheme is stale). Discover a simulator first — names drift between Xcode versions:
```bash
xcodebuild -project App/EldrChat.xcodeproj -scheme EldrChat -showdestinations
xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```
On-disk folders `App/PQRCTests` / `App/PQRCUITests` map to targets **EldrChatTests** / **EldrChatUITests**.

## 5.3 Huginn build + test (macOS)
```bash
xcodebuild -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn -destination 'platform=macOS' build
xcodebuild test  -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn -destination 'platform=macOS'
```

## 5.4 The "Local Universe" demo
A full PQRC deployment in one process — five seeded personas + an in-process relay, no bytes leaving the device. Launch it: lock screen ▸ **"See the live demo"**, or Settings ▸ **"Try the demo (Local Universe)"**, or run the `EldrChat` scheme with `--local-universe --demo-script`. A **persona switcher** lets you see both sides. The script walks: a verified 1:1 greeting → an **AI-drafted** (agent-signed) message → a **30-min ai_window** → a shared AI thread ("Plan lunch") → a **>64 KB paste** (relay-chunked) → a **message request** from an unknown sender → a **group of 4**.
*(The animated demo never goes idle, so screenshot tools that wait for app-idle time out — capture a static state.)*

## 5.5 Smoke-test checklist
`[Mac]` = needs the Mac stack; `[HW]` = needs real hardware (Simulator can't fully do it).

| Area | Do this | Expect |
|---|---|---|
| Onboarding `[HW]` | Create account (passphrase + biometric) | Lands in the app; relaunch unlocks |
| Relay | Add `local`, Apply & reconnect | "My keys on relay → Published" offline |
| 1:1 | Start a chat, send both ways | Bubbles decrypt; status "Sent to relay" |
| Group | New group (with/without members) | Header shows roster / "Just you · your AI" |
| Thread | Start thread, invite AI 15 min | Countdown; Withdraw stops it |
| Large paste | Paste >64 KB | Chip "…sends in encrypted chunks"; reader opens |
| AI setup | Add an AI, **Test** | Real reply or exact error |
| AI window | Hub ▸ Responds in chat ▸ Turn on | Peer sees the countdown banner |
| Firewall | Enable a cloud AI, watch the banner | Green "on" vs orange "OFF"; toggles in Details |
| Coding tools `[Mac]` | Pair Mac → Coding & tools ▸ enable → ask it to edit a file | Allow/Deny card → runs on the Mac after Allow |
| Terminal `[Mac]` | Agent opens a shell | Output streams; **Stop** kills it |
| AI memory `[Mac]` | Ask the Mac AI something, then a follow-up that leans on the first | Recalls it within the chat; a *different* chat doesn't see it |
| Unpair shred `[Mac]` | Bridge ▸ Unpair, then re-pair and reopen the chat | Prior transcript is gone (master key shredded) |
| Gateway `[Mac]` | Responder = sybilclaw, ask it something (gateway :18789 up) | Reply returns over the relay; "connection refused" = gateway down |
| eldrctl `[Mac][HW]` | `eldrctl install --target user@host --owner <hex>` on a 2nd Mac | Pairing link returned; the node pairs + serves |

---

# Troubleshooting

- **"Connection refused" / gateway "down" / host errors** → the Mac stack isn't running (Huginn, eldr-node, or LM Studio/sybilclaw not started, or the Mac is at the login window). Check Huginn ▸ Configuration ▸ Connections ▸ **Check** and Local LLM ▸ **Test**. Ports: sybilclaw gateway **18789**, ContextGraph **8302**.
- **Peer can't be added / "hasn't opened EldrChat on this relay"** → they haven't published keys on your relay; use the **Invite** link, or both switch to the same relay.
- **Settings ▸ AI says the build has no Private Cloud Compute API** → you built with Xcode 26.x. That SDK genuinely cannot compile PCC, so it is correctly compiled out; export the Xcode-beta `DEVELOPER_DIR` (Part 5) and rebuild. Do **not** add a build flag — see the locked PCC section in CLAUDE.md.
- **No AI reply / it "forgets"** → confirm the AI is Enabled and **Gathers** isn't "Off"; for in-chat replies you need an **open AI window**; the Mac chat AI is **read-only** until you enable "Coding & tools".
- **Mac AI gives a canned/echo reply** → it's the Demo stub — the node isn't paired+consented yet, or its LLM is unreachable.
- **Nearby/host list empty in Simulator** → Multipeer needs real radios; use a device.

---

*Cross-references:* `USER-GUIDE.md` (end-user walkthrough), `SETUP-GUIDE.md` / `CONDUIT-SETUP.md` (deployment runbooks), `docs/guide/DEMO.md` (demo script), `TEST-PLAN.md` (full test matrix), `Apps/Huginn/README.md` (Mac app).
</content>
