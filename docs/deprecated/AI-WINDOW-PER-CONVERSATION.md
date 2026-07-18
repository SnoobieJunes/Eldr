# AI Window Scope — Per-Conversation Design & Tradeoffs

**Status:** Planning. Nothing here is implemented yet **except** the shipped
local guard (DEVIATIONS **AC54**) and the early-close path (**AC53**). This doc
exists so we can pick an option deliberately before touching the engine. Decision
owner: project lead.

---

## 1. Problem

A conversation `ai_window` ("turn my AI on for everyone here, for N hours") is the
authorization that lets my AI auto-reply to *other people*. Today it is keyed by
**identity alone**, in two places:

- **Engine:** `conversationWindows: [String: Int64]` — `identityHex → activeUntil`.
  One entry per person. There is no conversation dimension.
- **Runtime:** `myWindowConversationID: String?` — a single scalar naming the one
  conversation my window is "for".
- **Wire:** `AIWindowAnnouncement` signs `pqrc-ai-window-v1 ‖ active_until ‖
  enabled_by` — it binds **no** conversation/scope id.

Consequences:

1. **Only one window can be live at a time.** Opening "Responds in chat" in
   conversation B silently overwrites the window you had in A
   (`conversationWindows[me]` and `myWindowConversationID` are single-valued).
2. **Cross-conversation reply/leak (the bug behind AC54).** The gate is global and
   a reply posts to `windowConversation()`, so a message arriving in B while a
   window was open in A passed the gate, built context from B, and posted into A —
   leaking B's content into A. **Shipped mitigation:** `handleReceived` now guards
   `myWindowConversationID == conversationID` (AC54). That stops the active leak
   but leaves the single-window limitation and keeps the structural sharp edge.
3. **Indicator ambiguity.** `activeWindow(for: identityHex)` is identity-keyed, so a
   peer's "Alice's AI is active" indicator can't distinguish which conversation it
   belongs to.
4. **Bridge-node authorization** (`isAuthorizedForOwner(ownerHex)`) is also
   identity-keyed — the owner-gated Mac conduit's autonomy isn't pinned to a
   specific conversation.

SPEC §13.3 actually describes the window as an *"in-conversation announcement to
all parties"* — i.e. per-conversation is the **intended** model. The single-window
collapse is an implementation shortcut, recorded as **DEVIATIONS A3** ("one active
window scope per user in v1").

---

## 2. Background: the three AI-authorization controls

| Control | Purpose | Scope bound **in the signature**? | Engine key |
|---|---|---|---|
| `ai_window` (`AIWindowAnnouncement`) | my AI may auto-**send** in a conversation | **No** — `active_until ‖ enabled_by` only | `conversationWindows[identity]` |
| `ai_invite` (`AIInvite`) | my AI may auto-send in a **thread** | **Yes** — appends `thread_id` | `threadInvites[threadID][identity]` |
| `ai_context_grant` (`AIContextGrant`) | peer's marked context may be **consumed** | **Yes** — appends `scope.tag` (`conversation:<id>` / `thread:<id>`) | `contextGrants[scope.tag][identity]` |

**The window is the only one of the three that binds no scope.** Both siblings
already solved this; the window is the laggard. That asymmetry is the root cause.

---

## 3. The options

### Option 0 — Status quo + AC54 guard *(shipped today)*
Keep the global window; rely on the runtime `myWindowConversationID == conversationID`
check to prevent cross-posting. One window at a time.

### Option 1 — Engine scoping, **no wire change** *(recommended)*
Make the engine + runtime state conversation-keyed; **leave the wire announcement
byte-identical**. The receiver scopes an incoming window to the conversation the
carrying message was routed in (an id it already has from the E2EE-sealed `group`
ref / sender).

- Engine: `conversationWindows: [String: [String: Int64]]` (`conversationID →
  identity → activeUntil`), mirroring `threadInvites`.
- Methods gain a `conversationID`: `startMyWindow`, `endMyWindowEarly`,
  `receiveWindow`, `activeWindow`, `authorizeAutonomousSend`,
  `isAuthorizedForOwner`, `voiceAgentDraft`.
- Runtime: **delete** `myWindowConversationID` (now derivable — "is my window live
  here?" = `activeWindow(conversationID:for: me) != nil`). `runWindowReply` /
  `postAgentReply` thread the originating `conversationID` instead of reading the
  global `windowConversation()`. AC54's guard becomes structural.
- UI: `AppModel.aiWindows` / `activeWindowBanner` / `aiActiveHere` are **already**
  per-conversation — little or no change.

### Option 2 — Engine scoping **+ signed scope** *(wire change, `[upstream-NIP]`)*
Everything in Option 1, **plus** bind the conversation id into the window
signature (give `AIWindowAnnouncement` a `scope` like `AIContextGrant`). This makes
the scope cryptographically non-repudiable / non-reflectable.

### Option 3 — Option 2 with a dual-send transition
Option 2, but during a migration window new clients **send both** a legacy
(unscoped) announcement and the scoped one, and **accept either**, so old and new
clients interoperate without a flag day. Retire the legacy send after the fleet
updates.

---

## 4. Deep tradeoffs

| Dimension | Opt 0 (today) | Opt 1 (engine scope) | Opt 2 (signed scope) | Opt 3 (dual-send) |
|---|---|---|---|---|
| **Multiple simultaneous windows** | ❌ one at a time | ✅ | ✅ | ✅ |
| **Cross-conv leak fixed** | ⚠️ patched (runtime `==`) | ✅ structural | ✅ structural | ✅ structural |
| **Per-conversation indicator correct** | ❌ | ✅ | ✅ | ✅ |
| **Bridge-node auth per-conversation** | ❌ | ✅ | ✅ | ✅ |
| **Anti-reflection is cryptographic** | n/a | relies on `enabledBy==sender` + E2EE seal (see §5) | ✅ signed scope | ✅ signed scope |
| **Wire change** | none | **none** | **breaking** | additive→breaking later |
| **Old client ↔ new client interop** | n/a | ✅ (unscoped window ⇒ scoped by routing) | ❌ old rejects scoped sig | ✅ during transition |
| **At-rest migration** | n/a | **none** (window state is in-memory only) | none | none |
| **Blast radius** | shipped | ~8 engine sigs + conformers; runtime threading; test updates | Opt 1 + wire/NIP + sign/verify + back-compat verify path | Opt 2 + dual-send/accept-either logic + retirement step |
| **Engineering effort** | done | **M** | **L** | **L+** |
| **NIP/SPEC churn** | A3 note | revise A3 (still `[app-only]`) | new NIP wire field (`[upstream-NIP]`) + SPEC §13.3 edit | same as Opt 2 |
| **Risk** | low (but limited) | **medium, contained** | medium-high (signature compat is a flag day) | medium (more moving parts, but no flag day) |

---

## 5. Anti-reflection analysis — *do we actually need the signed scope?*

The only thing Option 2/3 buys over Option 1 is making the conversation binding
**cryptographic**. Whether that matters depends on whether an unsigned (routing-
derived) scope is forgeable in our model.

The reflection attack would be: take Alice's window legitimately signed for
conversation **A** and get it to authorize her AI in conversation **B**. For that to
land, an attacker must deliver, *in conversation B*, a message that:

1. carries Alice's signed `AIWindowAnnouncement`, **and**
2. is accepted by the receiver's `receiveWindow`, which enforces
   `announcement.enabledBy == sender` — i.e. the **sender of the carrying message
   must be Alice**.

The carrying message is gift-wrapped and **seal-signed by the sender's Nostr key**.
So to satisfy (2) the attacker must send a message *as Alice* — which requires
Alice's keys. A relay or a third party cannot. A **malicious participant of A**
can't either: they'd have to re-originate the window under their own identity, at
which point `enabledBy` is theirs, not Alice's, and it only authorizes *their* AI.

**Conclusion:** with `enabledBy == sender` + E2EE seals, the practical reflection
attack is already closed. The signed scope (Opt 2/3) is **defense-in-depth**, not a
gap-closer. It would matter most if a future change relaxed the `enabledBy ==
sender` check, or if we wanted non-repudiation of *which conversation* a window was
for (e.g. for an audit log a third party can verify). Neither is a v1 requirement.

⚠️ One honest caveat for Option 1: the conversation id is derived from the
message's `group` ref / sender, which lives **inside** the E2EE seal. So it is
exactly as trustworthy as the message content itself — which is the same trust we
already place in routing for delivering the message at all. We are not adding new
trust; we are reusing existing trust.

---

## 6. Recommendation

**Do Option 1 now. Defer Option 2/3.**

Rationale: Option 1 fixes every *functional* and *correctness* problem (simultaneous
windows, indicator, bridge auth, structural leak fix), has **no wire change, no
migration, and no interop break**, and is a contained in-memory refactor. The only
thing it doesn't add is a cryptographic scope binding — which §5 shows is redundant
given `enabledBy == sender`. If we later decide we want the cryptographic guarantee
(or relax `enabledBy == sender`), Option 3 layers cleanly on top of Option 1 without
rework.

Revise **A3** to "windows are per-conversation (Option 1)" and keep it `[app-only]`.
If/when we adopt Option 2/3, that becomes an `[upstream-NIP]` entry + a SPEC §13.3 /
NIP wire-table edit.

---

## 7. Open questions for the lead

1. **Signed scope (Opt 2/3): now, later, or never?** My vote: later/never unless we
   relax `enabledBy == sender` or need third-party-auditable window provenance.
2. **`aiActiveSince`** is already per-conversation. Fold it into the same nested
   window map for one source of truth, or leave it separate? (Cosmetic; leaning
   leave-separate to keep the diff small.)
3. **Duration set.** Engine `allowedWindowDurations` vs the UI's 1/8/24 h picker —
   reconcile while we're in here? (Out of scope for the window-scope change, but
   the USER-GUIDE references a stale 15/30/60/120-min set.)

---

## 8. Appendix — Option 1 blast radius (file-by-file)

| File | Change |
|---|---|
| `Packages/PQRCAgent/.../AgentEngine.swift` | `conversationWindows` → nested map; add `conversationID` to `startMyWindow`/`endMyWindowEarly`/`receiveWindow`/`activeWindow`/`authorizeAutonomousSend`/`isAuthorizedForOwner`/`voiceAgentDraft` |
| `App/PQRC/Engine/PersonaRuntime.swift` | delete `myWindowConversationID`; `startAIWindow`/`endMyAIWindow` key per-conversation; `handleReceived` passes routing `conversationID` to `receiveWindow` + authorization; `runWindowReply`/`postAgentReply`/`voiceCodingAgentDraft` thread `conversationID`; `windowConversation()` removed or returns the set of live windows |
| `App/PQRC/Engine/AppModel.swift` | none expected (`aiWindows`/`activeWindowBanner`/`aiActiveHere` already per-conversation) |
| `AgentMessageSink` conformers | signature update where `postAgentReply`/`windowConversation` are referenced |
| Tests (`MultiAIBehaviorTests`, `EndToEndFlowTests`, engine tests) | add `conversationID` to window calls; new tests: two live windows reply independently; close-A-keeps-B; window-in-A + msg-in-B ⇒ no reply (structural); bridge auth only in owner's window conversation; old-format unscoped window scopes to routing conversation |

**Migration:** none. Window state (`conversationWindows`, `aiActiveSince`,
`myWindowConversationID`) is in-memory only and rebuilt from relay-replayed
announcements — confirmed by grep (no persistence/encode path).
