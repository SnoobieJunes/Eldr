# EldrChat — Beta Tester Guide

Welcome, and thank you for testing EldrChat. This guide walks you through
everything the app does today, in plain language. No jargon required.

## What EldrChat is

EldrChat is a private messenger — think "iMessage for the AI age."

- **End-to-end encrypted.** Only you and the people you're talking to can read
  your messages. Not us, not the servers in between.
- **Post-quantum.** The encryption is built to stay safe even against future
  quantum computers.
- **Decentralized.** It runs over the open Nostr network instead of one
  company's servers. No phone number, no email, no account.
- **Text-only, by design.** EldrChat is for words and ideas — and for working
  with AI. For photos and video, use iMessage. That's deliberate.
- **AI-native.** You can bring your own AI assistant into your chats, openly and
  on your terms. This is the part that makes EldrChat different.

The number one rule of the app is **your privacy**. When there's ever a
trade-off, privacy wins.

## Getting started

The first time you open EldrChat, you create your account:

1. **Pick a display name and a passphrase.** Your account lives only on this
   device, encrypted under your passphrase. Each passphrase opens its **own
   separate account**, and nothing on the device reveals how many you have
   (deniable multi-account — handy for keeping work and personal apart, or a
   decoy).
2. **Read the "No recovery — by design" warning.** **If you lose your passphrase,
   that account and all its messages are gone forever — never backed up, synced,
   or exported, and we cannot reset it.** You'll tick a box to confirm.
3. **Face ID is the default.** After you create the account, the lock screen uses
   Face ID / Touch ID so you don't retype your passphrase every time (it prompts
   automatically at launch). Turn it off in **Settings ▸ Account** for
   passphrase-only high-security mode. To open a *different* or hidden account,
   ignore Face ID and type that account's passphrase instead.

### Your address: the npub

Your shareable address is called an **npub** — a long string starting with
`npub1…`. Think of it like a username you can hand out, except it's also your
encryption key. Find it in **Settings ▸ Identity**, where you can copy it, show a
**QR code**, or tap **Share my address**.

### Adding a contact

Tap the **compose** button (pencil icon) on the conversation list and either:

- **Paste their npub**, type a first message, and tap *Start encrypted
  conversation*; or
- **Scan their QR code** with your iPhone camera — it opens EldrChat with their
  address already filled in.

If they haven't joined yet, the app offers an **invite** link you can send them.

## Friendly names (codenames)

Real identities are long keys, so EldrChat gives every person — and every AI — a
friendly **codename** like `clever-otter-glides-204`.

- These names are **invented privately on your device**. They are **never sent
  over the network**, so your codename for someone is different from everyone
  else's.
- You can **rename anyone** in **Settings ▸ Contacts**. Your name always wins
  over the one a contact picked for themselves.

## Messaging basics

- **Send a message:** type in the box at the bottom and tap the send arrow.
- **List vs. detail:** on the left (or the main screen on iPhone) is your
  conversation list; tapping one opens it. On iPad, Mac, and iPhone in landscape,
  list and conversation show **side by side**.
- **Big pastes are welcome.** Paste a huge block of text and it collapses into a
  tidy chip showing its size, so the box never chokes. It still sends as
  encrypted text — large content is split into encrypted chunks behind the
  scenes; nothing is uploaded to a file server.
- **Full-screen reader.** Long messages with formatting (Markdown or HTML) can be
  opened full screen: long-press the message and choose *View full screen*. There
  you can **pinch to zoom**, scroll, and flip between the **Rendered** view and
  the **Source** view to see exactly what the sender wrote.

## The AI features

This is what sets EldrChat apart. AI is always **visible and on your terms** —
no one ever talks to an AI without knowing it.

### Your tethered AI(s)

In **Settings ▸ AI** you can set up **one or more** AI assistants and name each
one:

- **On-device Core AI** — runs entirely on your iPhone. Nothing leaves the
  device.
- **Off-device API integrations** — more capable, but message content is sent to
  that provider. You paste an API key (stored only in your device's Keychain):
  - **Claude** (Anthropic)
  - **OpenAI** (ChatGPT)
  - **Gemini** (Google)
  - **OpenRouter** — one key, many models
  - **Groq** — very fast, low cost
- **Self-hosted** — run a model on your own machine with **Ollama** or **LM
  Studio** and point EldrChat at it (Custom / OpenAI-compatible). On the same
  Wi-Fi, nothing goes to the cloud — your content never leaves your devices.
  Plaintext `http://` is allowed for local-network addresses (no certificate
  needed). *(A direct Wi-Fi / Multipeer link, for use without a shared router,
  is planned.)*
- A **Demo** option gives simple simulated replies for testing.

Each AI has its own **Context & behavior** (Settings ▸ AI): custom
**instructions** (a persona), what it **gathers** (live conversation while
active · only messages you add to context · off), how deep, and what it **does**
(participate · draft only · summarize). You can also override the context per
conversation in that conversation's **Details**.

**Each AI is independent.** Toggle any model **on/off** without deleting it; give
two AIs of the **same** provider their **own** API keys (just add a second one);
and set each one's instructions, what it gathers, how deep, and whether it drafts
or posts.

**Transparency first:** see exactly what each model receives in **Settings ▸ AI ▸
What your AI sees**. Tap **Test primary AI now** to confirm it works (it shows the
real reply or the exact error).

#### Running your own model (self-hosted)

Run a model on your Mac/PC with **LM Studio** or **Ollama** and point EldrChat at
it — private, no cloud, no subscription:

1. Start the server and **enable local-network serving** (LM Studio: *Developer ▸
   Server ▸ Serve on Local Network*; Ollama: launch with `OLLAMA_HOST=0.0.0.0`).
   Note the port (LM Studio default `1234`, Ollama `11434`).
2. In **Settings ▸ AI**, add an AI with backend **Custom / self-hosted**.
3. **Server URL:** your computer's **LAN IP**, e.g. `http://192.168.1.20:1234`.
   EldrChat appends the OpenAI path for you (you can also paste the full
   `…/v1`). Don't use `localhost` from a real phone — that only works in the
   iOS Simulator; on a device, use the computer's network address.
4. **Model:** the exact model id LM Studio / `ollama list` shows (e.g.
   `qwen/qwen3-…`). No API key needed.

EldrChat speaks the **OpenAI-compatible Chat Completions** API — `POST /v1/chat/
completions` with a `messages` array — which is exactly what LM Studio and Ollama
serve. (Their *other*, non-OpenAI endpoints like `/api/...` won't work; use the
OpenAI one, which is what the steps above set up.)

### "My AI" — your private solo chat

Tap the **brain icon** to open a chat with just **you and your AI(s)**. It's a
private staging ground — brainstorm, draft, think out loud. You can **add people
to it later** to turn it into a real conversation.

### Two ways to use AI in a chat

Open any conversation and tap the **sparkles icon** for AI options:

- **Draft with AI (sparkles in the composer):** your AI writes a suggested reply
  and drops it into your message box. **Nothing is sent** — you read it, edit it,
  and decide. You can also send it labeled *as your AI*.
- **Turn your AI "on" (an AI window):** give your AI permission to talk to
  **everyone in the chat** for a set time (15, 30, 60, or 120 minutes). While
  it's on, **everyone in the conversation sees a banner** saying your AI is active
  and counting down. AIs can never switch themselves on — only you can.

### Threads: AIs collaborating

Inside a conversation, tap the **thread icon** to start a **thread** and invite
each person's AI to join for a set time. The AIs can work together and share
context, and **everything they say is recorded right there in the thread.** To
prevent runaway chatter, AIs pause after a few back-to-back messages until a
human speaks again.

**Skills (a shared vocabulary).** In a thread, tap **Skills** to pin shared
"skills" — *plan-sync, tech-spec, code-debug, schema-propose, context-export,
conflict-resolve,* and more. They give both people's AIs a common format, so a
handoff from one is something the other can parse and act on instead of free-form
chatter. Tell EldrChat what your device brings to the table in **Settings ▸ AI ▸
This workstation's context domain** (e.g. "iOS / Xcode" or "backend / staging");
each AI advertises its domain so the two divide the work without either side
dumping its private context. The PQRC rules still hold underneath: scope stays in
the thread, only granted context is shared, and after a few turns the AIs pause
for a human.

### Context control — what your AI can see

By default, **your AI does not read your whole history.** It only sees:

- Messages you specifically share by **long-pressing ▸ "Add to AI Context"** (or
  selecting several at once with the checklist button); and
- The recent conversation **while it's actively turned on** (a window, a thread
  invite, or your solo "My AI" chat).

A peer's marked messages reach your AI only when **both of you** have turned on
context sharing. You can **see exactly what your AI receives** anytime in
**Settings ▸ AI ▸ View tethered LLM context** — it's read-only and sent nowhere.

### AI privacy in one line

On-device AI stays on your device. A **remote API receives your message
content** — EldrChat warns you clearly before you enable one, and again whenever
a name or alias you type might be included in what's sent.

## Connecting in crowded places — no router needed

On airport Wi-Fi, a train, or a road trip you may not have — or trust — a network.
EldrChat can run **with no router and no server**, directly between devices over
Wi-Fi/Bluetooth:

- **Nearby (1:1, automatic).** With **Settings ▸ Nearby** on, messages to a
  contact in the same room go straight device-to-device, even fully offline.

- **Host a pocket relay (a group, one host).** In **Settings ▸ Servers**, type the
  keyword **`host`** as your server: that device becomes a tiny relay for everyone
  around it. Companions type **`nearby`** and connect to it over the radio — no
  router, no internet, no third party. It's your own private relay in your pocket,
  and *more* private than a café's Wi-Fi or a public relay because nothing leaves
  the little circle of devices.

  - **Messages stay end-to-end encrypted exactly as on the internet:** the host
    relays sealed envelopes and never sees the content of messages you send to
    other people.
  - The host can also **share its on-device AI** — companions use the host's Apple
    Intelligence over the same link. This is the one exception to the line above:
    if *you* choose to use the host's AI, the message text *you* send to that AI
    goes to the host's device so its model can answer (contact names are still
    replaced with codenames while the firewall is on). EldrChat asks you to
    confirm before enabling it, just like any off-device AI — so it's your call,
    not the host's.

*(These radio features need real hardware — they don't run on the iOS Simulator.)*

## Staying safe

- **Verify a contact (safety code).** Each contact has a 60-digit **safety
  code**. Comparing it in person (or over a trusted channel) confirms you're
  really talking to them. Verified contacts show a green **shield**. If a
  contact's safety code ever changes, a red banner asks you to re-verify before
  trusting new messages.
- **Message Requests.** First messages from strangers wait in a **Message
  Requests** area — nothing is shown until you **Accept**. You can temporarily
  open your inbox to anyone in **Settings ▸ Reachability** (it auto-closes).
- **Nearby (no server).** In **Settings ▸ Nearby** you can deliver messages
  directly to people in the same room over Wi-Fi/Bluetooth, even offline.
  Strangers nearby can never read or join anything.
- **Block & manage.** Manage everyone in **Settings ▸ Contacts**; copy keys,
  rename, or message them from there.

### Honest limits

- **One device, no recovery.** Lose the device, lose the identity and all
  history. There's no cloud backup (that's the privacy trade).
- **No deniability.** Messages are signed — a recipient can prove you wrote
  them.
- **Endpoints aren't magic.** Whoever you message can screenshot or forward what
  you send, and if *they* enable a remote AI, the chats *they* take part in go to
  *their* provider.

## Privacy in plain terms

**Stays on your device (never leaves):**

- Your identity keys — generated here, never exported, synced, or backed up.
- Your contacts, their codenames, your aliases, and your message history.
- Anything handled by your **on-device** AI.

**What a server (relay) can see:**

- Your **IP address** and when you connect. (Use a VPN if that matters to you;
  EldrChat doesn't hide it.)
- That an **encrypted envelope** exists for a recipient, and roughly when — but
  **not who sent it and not what it says.**

**What a remote AI provider can see (only if you turn one on):**

- The **decrypted message content** of the conversations it's used in, plus any
  names you've set. Your signing keys never leave the device. This is a clear,
  consented trade of privacy for capability — leave it off to keep everything
  local.

That's it. Message someone, try drafting with AI, open the full-screen reader on
a long note, and tell us what feels rough. Thank you for testing EldrChat.

---

### For developers & power users

Two integrations are available if you run EldrChat on a Mac:

- **Let an AI agent (Goose, Xcode, Claude) read your secure chat** — turn on
  **Settings ▸ Local agent access**; EldrChat shows a one-line command + token to
  paste into your MCP client. It's read-only and your contacts' names are replaced
  with codenames before anything leaves the app.
- **Let EldrChat's self-hosted LLM pilot Xcode 27** (write code, build, run on
  simulators) via the `eldr-acp` Agent Client Protocol agent.

Both are off by default and documented step-by-step in **docs/SETUP-GUIDE.md §9**
(Xcode 27 registration) and the in-app Settings.
