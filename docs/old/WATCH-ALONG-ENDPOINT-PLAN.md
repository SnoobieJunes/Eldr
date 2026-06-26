# Watch-Along §13.5 Endpoint Hardening — design + plan

**Status:** implemented this session (headless layers tested green; iOS layer compile-checked).
**Goal:** make a watch-along agent message cryptographically *the owner's* agent (SPEC §3.3
binding) instead of *the Mac's*, by moving the group fan-out + redaction onto the owner's
phone — without ever exporting the owner's identity key (invariant 10).

## Why the hardening exists (recap)

In the **direct** model (DEVIATIONS AC20) the Mac is a full group participant: it pairs with
every member and fans an answer out itself — raw to the owner, `‹redacted:…›` to others. That
works, but the Mac is a trusted third party to everyone, and the redaction is Mac-enforced and
unverifiable. The raw secret is one redaction-decision away from a non-owner.

In the **endpoint** model the Mac talks to *only the owner's phone*. The phone holds the secret,
redacts, and voices the answer to the group **signed with the owner's agent key** (derived from
the owner's identity key, which lives only on the phone). So:
- the group trusts only the owner's phone (the SPEC's endpoint model);
- the raw secret never transits a Mac→non-owner link at all;
- the agent message is cryptographically the owner's agent (§3.3), not a separate Mac key.

The signing **must** happen on the phone — `AgentKeyDeriver.deriveAgentKey(from:)` needs the
owner's identity private key, which never leaves the phone. That's why this is an endpoint
round-trip, and why it depends on the live Mac↔phone PQRC channel.

## Data flow

```
owner prompts (in the group)
        │
        ▼
  Mac: eldr-acp inference  ──►  COMPLETE answer (raw, may contain a secret)
        │
        │  PQRC message, participant_type:.agent, MessageBody.agentDraft set,
        │  sent to the OWNER ONLY (pairwise, E2EE to the owner). NOT to the group.
        ▼
  owner's phone: handleReceived sees agentDraft from a coding_agent contact
        │
        ├─ gate: owner's own ai_window/invite active?  (engine.authorizeAutonomousSend)
        │        └─ no → fail closed (drop; optional local "window off" note)
        │
        ▼  yes
  engine.voiceAgentDraft(rawText): scrub → redactedText
        │
        ▼
  phone → group (every member): redactedText, participant_type:.agent,
                                signed with the OWNER'S agent key
  phone local store:            rawText  (owner sees the real answer in the group timeline)
```

Only the **local echo** carries raw; **every wire copy is redacted**. The owner sees raw because
it's on their own device.

## Components (by layer — each independently testable)

### Layer 1 — shared wire + redactor (PQRCCore)
- `MessageBody.agentDraft: AgentDraft?` — inside the ciphertext (private), CodingKey
  `agent_draft`, optional (older clients ignore it, SPEC §12). `AgentDraft { agentName?, voiceInto?, threadID? }`:
  - `agentName` — local codename for labeling;
  - `voiceInto` — the conversation id (group id / peer hex) the phone should voice into;
  - `threadID` — optional thread scope.
- `CredentialRedactor` **moved** PQRCACP → PQRCCore (PQRCACP stays dependency-free; the CLI never
  used it; the bridge + engine + iOS all import PQRCCore). Tests move too.

### Layer 2 — voicing gate (PQRCAgent)
- `AgentMessageSink.postAgentDraft(redacted body:, rawText:, threadID:, agentName:)` with a safe
  default (posts the redacted body; raw dropped if a sink doesn't special-case it).
- `AgentEngine.voiceAgentDraft(rawText:threadID:agentName:)`: `authorizeAutonomousSend` (fail
  closed) → `CredentialRedactor.scrub` → builds the redacted `MessageBody` → `postAgentDraft`.
  Returns whether it posted. The scrub lives in the engine so the wire copy is guaranteed
  scrubbed regardless of sink.

### Layer 3 — Mac endpoint mode (Configurator bridge)
- `WatchAlongMode { .direct, .endpoint }` on `ACPBridgeService` (default `.endpoint`).
- Endpoint: `sendDraftToOwner(_ answer:, conversation:)` → `messaging.send(MessageBody(text:
  answer, agentDraft: AgentDraft(agentName, voiceInto: conversation.id, threadID:)), to:
  ownerIdentityHex, participantType: .agent)`. No redaction on the Mac (the phone does it); no
  per-recipient fan-out (single recipient = the owner).
- `handleInboundPrompt` routes by mode: `.direct` → `broadcastAgentMessage` (AC20, unchanged);
  `.endpoint` → `sendDraftToOwner`.
- Endpoint mode needs no owner *window* on the Mac (the draft is private to the owner); the phone
  enforces the group gate. Direct mode keeps its Mac-side gate.

### Layer 4 — iOS receive→voice glue (EldrChat app)
- `PersonaRuntime.handleReceived`: if `received.participantType == .agent`,
  `received.body.agentDraft != nil`, and `contactType(senderHex) == "coding_agent"` → call
  `voiceCodingAgentDraft(received, draft:)` and **return** (don't store the raw draft as a normal
  1:1 message).
- `voiceCodingAgentDraft`: resolve target = `draft.voiceInto`; run `engine.voiceAgentDraft(...)`
  routed through `RuntimeSink.postAgentDraft` → `sendMessage(redacted, localTextOverride: raw,
  participantType:.agent)`. If the gate is closed, store a local-only system row ("coding agent
  replied — your AI window is off") so the behavior is fail-closed *and* visible.
- `PersonaRuntime.sendMessage` gains `localTextOverride: String? = nil` — the local `StoredMessage`
  uses `localTextOverride ?? body.text`; the wire always uses `body.text` (redacted). Existing
  callers unaffected (default nil).
- `RuntimeSink.postAgentDraft` implements the raw/redacted split via `localTextOverride`.

## Security invariants preserved
- **Invariant 10:** the owner's identity key never leaves the phone; signing happens on the phone.
- **Invariant 8:** voiced messages are `participant_type:.agent`, signed with the owner's agent key.
- **Invariant 9:** voicing is gated by the owner's own active window (fail closed).
- **§0:** every wire copy is redacted; raw is local-only. Redaction is in the engine (guaranteed).

## What remains the live boundary (user-tested)
- The Mac↔phone PQRC channel (the existing `BridgeMessaging` runtime boundary, AC23) must be wired
  for the Mac to deliver the draft. Endpoint mode is otherwise complete and headless-tested.
- The two-device behavior (owner sees raw, second phone sees redacted, window-off ⇒ silent) is the
  manual test.

## Fallback
`.direct` mode (AC20) remains intact and tested. If the endpoint iOS glue misbehaves on-device,
flip `watchAlongMode` to `.direct` for a working demo.

## Test matrix (headless)
- PQRCCore: `AgentDraft` Codable round-trip + unknown-field tolerance; CredentialRedactor suite.
- PQRCAgent: `voiceAgentDraft` gate-closed (no post) / gate-open (posts; wire redacted, raw
  preserved via the spy).
- Configurator: endpoint mode sends a single draft to the owner carrying the full answer +
  `agentDraft`; direct mode unchanged.
- iOS: `xcodebuild build` (compile-check); live behavior = manual two-device test.

---

## When you're back — what to test

### Verified already (green this session)
```
swift test --package-path Packages/PQRCCore     # 66 — incl. AgentDraft wire + redactor
swift test --package-path Packages/PQRCAgent    # 41 — incl. voiceAgentDraft gate/redact
swift test --package-path Packages/PQRCACP      # 134
# Configurator app + tests:
xcodebuild test -project Apps/EldrACPConfigurator/EldrACPConfigurator.xcodeproj \
  -scheme EldrACPConfigurator -destination 'platform=macOS'        # TEST SUCCEEDED
# iOS app build:
xcodebuild build -project App/EldrChat.xcodeproj -scheme EldrChat \
  -destination 'platform=iOS Simulator,name=iPhone 17'             # BUILD SUCCEEDED
```
Re-run any of these to confirm. The endpoint MODEL — wire marker, gate, scrub, fan-out vs
draft-to-owner, contact tagging — is complete and tested at every layer that can be tested
without a second device.

### Testable now without a second device
- **The agent itself:** `./Packages/PQRCACP/run-agent.sh --dir <project>` (or
  `ELDR_ACP_FAKE_LLM=1 … --yes`). The new `edit_file`/`search` tools, streaming, timeout/cancel.
- **The Configurator UI:** the "Owner device" panel and the watch-along **mode toggle**
  (Endpoint vs Direct) — see below; add it to `BridgeView` if you want it on screen.

### The messaging seam is now built (AC25)
The Mac↔phone PQRC seam that was the AC23 boundary is implemented: the Configurator now stands
up a real `PQRCMessenger` (`startMessagingNode`, from "Enable bridge"), publishes its
10420/10421 to `relay.lerants.com`, subscribes to its inbox, auto-accepts the pairing request,
and routes inbound messages. So "Pair with EldrChat" should now resolve the agent's keys instead
of erroring. **Use Xcode-beta to build both apps** (the iOS PCC tier needs the beta SDK).

### Live pairing — do this first
1. **Same relay.** Both default to `wss://relay.lerants.com`. If you changed the phone's relay in
   Settings ▸ Servers, change it back (or the Mac won't be found).
2. **Mac:** run the Configurator, Bridge tab ▸ **Enable bridge**. It now publishes its keys to the
   relay (watch for the agent appearing; the state goes to *advertising*).
3. **Phone:** Settings ▸ **Mac coding agent ▸ Connect your Mac coding agent**, then scan the
   Configurator's QR (or "Open in EldrChat" on the same Mac). It pairs + tags the contact
   `coding_agent`. The Mac auto-accepts and flips to *paired*.
4. **1:1 first (simplest, `.direct` mode — the default):** in that chat, enable your AI window,
   then ask the agent something (e.g. "read config.env"). The agent runs your local LLM and
   replies in the chat. (In a 1:1 there's no "everyone else," so redaction divergence isn't
   visible — that needs a group.)

### The full owner-raw / others-redacted demo (group)
Create a group with the Mac agent + a second phone, enable your AI window, ask the agent to read
`config.env`:
- **`.direct` (default):** the Mac fans out — you see the **raw** key, the second phone sees
  **`‹redacted:api-key›`**. Works today.
- **`.endpoint` (hardened, §13.5):** flip the Owner panel's *Watch-along mode* to **Endpoint**.
  Now the Mac drafts to your phone, and your phone voices the redacted answer to the group signed
  as *your* agent (the raw key never traverses a non-owner link). Window off ⇒ the phone shows a
  local "turn on your AI window" note and nothing goes to the group (fail closed).

### Known v1 limits (tell me if these bite)
- **Sessions are in-memory on the Mac:** if you quit/relaunch the Configurator, re-pair (identity
  + keys persist; the ratchet session doesn't yet).
- **Group roster on the Mac:** the node fully supports 1:1; for a group the Mac replies to the
  sender's link. Full group-roster fan-out from the Mac is the next increment.
- If pairing still errors with "keys aren't here," it's almost always a **relay mismatch** or the
  Mac's **Enable bridge** wasn't on when the phone tried — check both, then retry.
