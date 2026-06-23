# UX Recommendations — EldrChat & Huginn

**Date:** 2026-06-22
**Reviewer scope:** Source-based usability review of the SwiftUI view layers of the two
apps in this repo:

- **EldrChat** — `App/PQRC/Views/` (Conversations, Thread, Settings, Onboarding,
  Components). Reviewed: `MainView.swift`, `ConversationView.swift`, `ThreadView.swift`,
  `SettingsView.swift`, `ConversationDetailsView.swift`, `AccountGateView.swift`,
  `OnboardingTourView.swift`.
- **Huginn** (eldr-acp GUI) — `Apps/Huginn/Sources/Views/`. Reviewed:
  `HuginnApp.swift`, `ConfigurationView.swift`, `SetupWizardView.swift`,
  `TestChatView.swift`, `BridgeView.swift`, `LogView.swift`, `StatusBarView.swift`.

**Method & honesty caveat:** This is a *static, source-only* review. I read the view
code; I did **not** run either app, exercise it on-device, profile it, or test it with
VoiceOver/Dynamic Type/Switch Control. Everything below is grounded in concrete code at
specific `file:line` locations. Where a claim depends on runtime behavior I could not
observe, it is labeled **inferred** in the closing note. Findings respect the project
constraints: SwiftUI-only, iOS 26 Liquid Glass, text-only, privacy-first, and the
adaptive `NavigationSplitView` layout is preserved (no recommendation regresses it).

---

## Summary

| Rank | Title | App | Effort | On-device verification (2026-06-22) |
|---|---|---|---|---|
| 1 | The conversation's three AI controls overlap and aren't reconciled with each other | EldrChat | M | ✅ Confirmed running (XCUITest + screenshots) |
| 2 | Huginn's Bridge has two silent prerequisites that fail closed with no path to fix them | Huginn | M | ⚠️ Source-confirmed + app runs; live Bridge-tab capture blocked by tooling |
| 3 | Two free-form `TextEditor` fields in Huginn config write to disk with no save/dirty/undo signal | Huginn | M | ✅ Confirmed running (live accessibility-tree read) |
| 4 | The composer ejects pasted text into a chip with no way to view, edit, or recover it | EldrChat | M | ✅ Confirmed running (XCUITest + screenshots) |
| 5 | The account-creation gate's irreversible-loss warning is a checkbox, not a verified-passphrase gate | EldrChat | S | ✅ Confirmed running (XCUITest + screenshot) |

See **Appendix: On-device verification** at the end of this document for method and evidence.

---

## 1. The conversation's three AI controls overlap and aren't reconciled with each other

**App:** EldrChat **Effort:** M

### Problem
A single conversation exposes the AI behavior through three separate surfaces that
partly duplicate each other:

1. The toolbar `aiHereChip` (`ConversationView.swift:175-207`) and a second toolbar
   `sparkles` button (`ConversationView.swift:124-135`) **both open the same
   `AIHereSheet`** (`showAIHere = true` at lines 128 and 177). Two distinct toolbar
   affordances — one a chip with a glanceable label, one a bare icon — do exactly the
   same thing.
2. The `AIHereSheet` itself (`ConversationView.swift:646-784`) hosts an "AI context
   here" picker *and* a "My AI responds" picker.
3. `ConversationDetailsView` (`ConversationDetailsView.swift:18-22`,
   `firewallOverride` at `:21-22`) hosts **another** per-conversation `aiContextMode`
   ("default"/"off"/"marked"/"full") and a per-conversation egress-firewall override —
   the same `aiContextMode` vocabulary the sheet uses.

The composer's `sparkles` "Draft with AI" button (`ConversationView.swift:374-386`) is
a *fourth* AI entry point, and the `AIHereSheet`'s "Drafts privately ▸ Draft a reply
now" button (`:734-743`) does the same on-demand draft. The comment block at
`:639-645` admits the architecture is a migration in progress ("moved here from
Details").

These controls share state through `UserDefaults`/`AppSession.conversationContextMode`,
not `@Observable` state, which is why the code has to manually re-read summaries on
sheet dismiss (`ConversationView.swift:150-153`, `:100-101`). A user who sets context
to "off" in Details and then opens the sheet sees a control that *can* re-enable it;
there is no single source of truth a user can point to and say "this is what my AI is
doing here."

### Why it matters
This is the product's core differentiator ("AI-native") and its #1 stated value
(privacy). Fragmenting the AI-presence controls across a chip, a duplicate toolbar
icon, a sheet, the composer, and Details means a user cannot confidently answer "is my
AI listening / responding / sharing context right now, and where do I turn it off?" For
a privacy-first app, ambiguity about whether the AI is active is the worst possible
failure — it directly undermines the cardinal rule.

### Proposed fix
- **Collapse the two toolbar entry points into one.** Keep the glanceable
  `aiHereChip` (it carries the firewall glyph and effective-mode label); delete the
  bare `sparkles` toolbar button at `ConversationView.swift:124-135`. The chip already
  is the better affordance.
- **Make `AIHereSheet` the single canonical AI control** and have
  `ConversationDetailsView` *link to it* (a `Button`/`NavigationLink` row "AI in this
  conversation → opens the same sheet") rather than re-implementing the
  `aiContextMode` + firewall pickers. One control, one place it's defined.
- **Promote the shared state out of `UserDefaults` into the `@Observable` `AppModel`**
  (or a dedicated `@Observable` per-conversation AI-settings object) so the chip, the
  sheet, and Details react live without the manual `onDismiss`/`onAppear` re-reads at
  `ConversationView.swift:100-101` and `:150-153`. This removes a whole class of
  stale-glance bugs.
- Keep the iOS 26 Liquid Glass treatment, but note the existing chip deliberately uses
  an opaque `Color(.secondarySystemBackground)` fill (`:195`) "because translucent
  materials fail the contrast audit under busy content" — preserve that decision; do
  not switch the canonical chip to `.glassEffect()`.

---

## 2. Huginn's Bridge has two silent prerequisites that fail closed with no path to fix them

**App:** Huginn **Effort:** M

### Problem
The EldrChat Bridge is unusable until two conditions are met, and the UI surfaces both
only *after* the user has already navigated into the tab and started poking:

1. **No owner pinned ⇒ the agent stays silent.** `BridgeView.swift:123-129` shows a
   warning ("No owner pinned — the agent stays silent (fails closed).") — but the
   `ownerBox` that contains it is only rendered when
   `!bridge.activeConversations.isEmpty || bridge.ownerIdentityHex != nil`
   (`:26-28`). Before any device pairs, the warning is **not shown at all**, so a
   first-time user enabling the bridge gets no indication that an owner will be
   required.
2. **No project folder ⇒ tools fail.** `projectDirBox` (`:204-230`) warns "Not set —
   the agent has no project to read or build" and the code comment at `:201-203` calls
   it "load-bearing for anything beyond 'what can you do?'". This is always shown, but
   it sits below the fold inside a `ScrollView` (`:15`), after the state box, pairing
   box, conversations box, and owner box.

The result: a user can `Enable bridge` (`controls`, `:256-266`), see "Advertising,"
pair a phone, and then have the agent silently do nothing — because either no owner is
pinned or no folder is chosen. The failure is correct for privacy (fail-closed,
DEVIATIONS AC9), but the *diagnosability* is poor: the two blockers are scattered and
conditionally hidden.

### Why it matters
The Bridge is the feature that connects Huginn to the actual product (EldrChat). A
fail-closed feature that gives no upfront checklist of what's required reads as
"broken" to the user, who then files it as a bug or abandons it. The README itself
flags the bridge runtime as partially unwired (status note, README lines 179-185),
which makes a clear *client-side readiness* signal even more important so users can
distinguish "I haven't finished setup" from "the feature isn't wired yet."

### Proposed fix
- Add a **persistent readiness checklist** at the top of `BridgeView` (above
  `stateBox`, `:23`) that is always visible and lists the prerequisites with live
  checkmarks: *Paired with a device · Owner pinned · Project folder chosen · At least
  one conversation enabled · At least one share type on.* SwiftUI: a `GroupBox` of
  `Label`s switching `checkmark.circle.fill` (green) vs `circle` (secondary) bound to
  `bridge.ownerIdentityHex != nil`, `bridge.agentWorkdir != nil`, etc.
- **Gate or annotate `Enable bridge`** (`:259-260`): when prerequisites are unmet,
  keep it enabled (advertising-to-pair is itself a step) but show the checklist so the
  user knows what still has to happen before the agent will act.
- Make the owner warning unconditional: move the "No owner pinned" `Label`
  (`:124-129`) out of the conditionally-rendered `ownerBox` so it shows from first
  launch of the tab, or fold it into the readiness checklist above.

---

## 3. Two free-form `TextEditor` fields in Huginn config write to disk with no save/dirty/undo signal

**App:** Huginn **Effort:** M

### Problem
`ConfigurationView` is explicitly a no-Save-button, debounced-autosave form (README
"edits are debounced to disk ~0.5 s after you stop typing — there is no Save button").
That's a defensible pattern for *bounded* controls — steppers, toggles, a server URL
(`:11-95`). But the same silent-autosave applies to two **free-form multi-line
`TextEditor`s**:

- Prompt preamble — `ConfigurationView.swift:82-86`
- Full system-prompt override — `ConfigurationView.swift:87-94` (this one *replaces*
  the built-in system prompt entirely)

There is no dirty indicator, no "saved ✓" confirmation, no visible debounce state, and
no in-form undo. A user editing the system-prompt override — the single most impactful
and most easily-broken field in the app, per the README's own "for when the built-in
prompt fights your model" framing — gets zero feedback that their half-typed edit was
already persisted and will be loaded by the agent's *next* session. Worse: there is no
way to revert to the previous value if they realize the edit was a mistake, since the
old value was overwritten on disk ~0.5s after they stopped typing.

The bordered `TextEditor` (`.border(.quaternary)`, `:85`/`:93`) is also visually
indistinguishable from a read-only display area; nothing marks it as a live,
auto-persisting input.

### Why it matters
The system-prompt override directly determines whether the agent works at all. Silent
autosave of a large free-text field with no undo means a user can quietly corrupt their
agent's behavior and have no obvious way to recover — and no signal that anything was
even saved. For everything else in the form (a stepper, a toggle) silent autosave is
fine because the control's own value *is* the feedback; for free text it is not.

### Proposed fix
- Add a lightweight **per-field save-state affordance** beside each `TextEditor`
  header label (`:80-81`, `:88-89`): a small `Text` that cycles "Editing… → Saved ✓"
  driven by the same debounce the store already runs (the store knows when it flushes).
  This costs one `@Published` "lastSavedAt"/"isDirty" per field on `ConfigurationStore`.
- Add a **Revert button** per free-text field that restores the last on-disk value
  (the store can keep the last-flushed snapshot). This gives the missing undo without
  introducing a global Save button (preserving the deliberate no-Save design for the
  bounded controls).
- For the system-prompt *override* specifically, add a **"Reset to built-in prompt"**
  action that clears the override — the README describes the override as an escape
  hatch, so a one-tap way back to the default is the natural safety net.
- Keep the bounded controls (steppers/toggles/URL) exactly as they are; this change is
  scoped to the two free-text fields where silent persistence is genuinely risky.

---

## 4. The composer ejects pasted text into a chip with no way to view, edit, or recover it

**App:** EldrChat **Effort:** M

### Problem
The composer auto-collapses a large paste into a non-interactive chip. In
`ConversationView.swift:395-407`, any `onChange(of: draftText)` where the delta exceeds
4096 bytes **or** the total exceeds 16384 bytes moves the entire field contents into
`largePaste` and **clears the visible text field** (`largePaste = newValue;
draftText = ""`, `:404-405`).

The resulting chip (`composer`, `:345-369`) offers exactly one action: a remove button
(`xmark.circle.fill`, `:360-365`) that **discards** the content (`largePaste = nil`).
There is:
- no way to **view** what's in the chip (no tap-to-preview),
- no way to **edit** it (e.g. trim a stray header off a pasted log),
- no way to **append** a human note to send alongside it — sending uses
  `largePaste ?? draftText` (`:423`), so once a large paste exists, anything typed
  afterward is ignored on send and only the paste goes out.

The threshold is also low and total-based: the `newValue.utf8.count > 16384` backstop
means a user *typing or growing* a long-but-legitimate message (a detailed
explanation, pasted-then-extended) crosses 16 KB and has their whole draft yanked into
an opaque, uneditable chip mid-composition. The inline comment claims gradual typing
never triggers it, but that only holds for the 4096-delta branch — the 16384 *total*
branch fires regardless of how the text got there.

### Why it matters
This is a **text-only** product (per CLAUDE.md and the blob-transport memory) whose
entire large-content story is "paste big text and it rides the relay in chunks." Large
text *is* a first-class content type here, not an edge case — yet the one UI for it is
view-blind, uneditable, and all-or-nothing. A user who pastes a 100 KB document, then
notices the first line is wrong, must delete the whole thing and re-paste. And a user
writing a genuinely long message can have it silently swept out of the editable field.

### Proposed fix
- Make the chip **tap-to-open** the existing `FullScreenReaderView`
  (`ConversationView.swift:156-158`, already wired for `fullScreenContent`) in an
  **editable** mode, so the user can review and trim the paste before sending. The
  reader is already the app's reference responsive component; extending it with an edit
  affordance reuses proven UI.
- **Allow a covering note:** when `largePaste != nil`, keep the text field live and on
  send combine them (note + attachment) instead of `largePaste ?? draftText`
  (`:423`) — or at minimum disable/grey the field with a clear "the large paste will
  send; clear it to type a message" hint so the silent-drop of typed text is not a
  surprise.
- **Raise/clarify the total threshold** so a long *typed* message isn't ejected: the
  4096-byte single-delta branch already catches genuine pastes; the 16384 total
  backstop (`:403`) should either be much higher or only apply when a single delta also
  looks paste-like, so incremental composition is never swept away mid-sentence.
- Keep the privacy framing intact (the chip's "sends in encrypted chunks" label,
  `:352-356`, is good and should stay).

---

## 5. The account-creation gate's irreversible-loss warning is a checkbox, not a verified-passphrase gate

**App:** EldrChat **Effort:** S

### Problem
`AccountGateView` creates an account whose loss is total and unrecoverable — the app
says so repeatedly ("there is NO recovery", `:179`; "We cannot reset it for you",
`:184`; "If you lose the passphrase there is no recovery", SettingsView `:741`). The
only thing standing between a user and that irreversible state is:

- a single acknowledgment `Toggle` (`AccountGateView.swift:177-182`), and
- for the passphrase path, a `passphrase == confirm` equality check (`canCreate`,
  `:205-209`).

There is **no passphrase strength guidance, no minimum, and no entropy/quality signal
whatsoever** — `canCreate` accepts any non-empty passphrase that equals its
confirmation (`:207`). A user can create a permanently-unrecoverable, hardware-bound
account protected by `"a"`. For the default (biometric/device-unlock) path there's no
passphrase at all, which is fine — but the *hidden* account path, whose passphrase
"is the only way in" (`:174`) and has no recovery, gets no help choosing a survivable
one. Combined with the create form being one of the very first things a brand-new user
sees (`AccountGateView` is "the always-first screen", `:3`), this is a high-stakes,
low-guidance moment.

### Why it matters
The threat model the app itself documents (THREAT_MODEL.md, referenced in SettingsView
`:778`) treats the on-device key as the whole ballgame: lose the passphrase to a hidden
account and the data is gone forever, with no sync and no export by design. A weak
passphrase on such an account is also the *brute-force* surface that the layered
hardware-wrap (CLAUDE.md invariant 10, DEVIATIONS AC31) is meant to defend — a
one-character passphrase undercuts that defense. For a privacy-first product, helping
the user pick a passphrase they can both remember and that resists offline guessing is
squarely on-mission, and the current UI does nothing.

### Why it's only S
The change is localized to one view and is additive: a strength meter and a minimum
in `canCreate`. No engine change, no protocol change.

### Proposed fix
- In the hidden-account branch (`createSection`, `:157-165`), add an inline
  **passphrase strength indicator** below the `SecureField` — a `Gauge` or a labeled
  `ProgressView` driven by a simple length/character-class/entropy estimate, with a
  short `Text` hint ("Use a long phrase you'll remember — there is no reset").
- Add a **minimum** to `canCreate` (`:205-209`) for the passphrase path (e.g. reject
  trivially short/low-entropy passphrases) so the irreversible account cannot be
  protected by a single character. Keep it advisory-but-enforced-at-a-floor rather
  than a rigid composition rule, which fights password managers.
- Keep the existing acknowledgment toggle, but consider pairing it with the strength
  signal so the "no recovery" warning lands next to the control that mitigates it.
- Do **not** add any "recovery" or backup affordance — that would violate the
  device-only, no-export invariant (CLAUDE.md invariant 10). This is purely about
  helping the user pick a passphrase strong enough to be worth the no-recovery
  tradeoff they're accepting.

---

## Closing note: proven vs inferred

**Proven (read directly in source, cited above):**
- The duplicate AI-sheet toolbar entry points, the AI controls split across chip /
  sheet / Details, and the `UserDefaults`-backed state with manual re-read on dismiss
  (`ConversationView.swift`, `ConversationDetailsView.swift`). (Rec 1)
- The Bridge owner-warning being inside a conditionally-rendered box, and the
  project-folder requirement living below the fold (`BridgeView.swift`). (Rec 2)
- The two free-text `TextEditor` fields under the no-Save-button autosave model with no
  dirty/saved/undo affordance (`ConfigurationView.swift`). (Rec 3)
- The composer's paste-to-chip ejection clearing the field, the chip's only action
  being discard, and `largePaste ?? draftText` ignoring typed text on send
  (`ConversationView.swift`). (Rec 4)
- The account create flow gating only on a checkbox + confirm-equality, with no
  passphrase strength/minimum (`AccountGateView.swift`). (Rec 5)

**Inferred (not verified at runtime — would need on-device testing):**
- That the stale-glance ambiguity in Rec 1 actually confuses users in practice — I
  reasoned this from the manual re-read pattern, but did not observe a stale chip.
- That the 16384-byte *total* backstop in Rec 4 ejects a long *typed* message mid-
  composition — this follows from reading the `onChange` logic, but I did not type a
  16 KB message into a running build to confirm the field clears.
- All accessibility, Dynamic Type, VoiceOver, and contrast claims are **out of scope**
  of this review except where the code itself documents a contrast decision (e.g. the
  opaque chip fills); I did not run the accessibility auditor or VoiceOver.
- No performance, layout-on-device, or landscape/iPad/Mac-width behavior was verified;
  the responsive layout is preserved by design in every recommendation, but I did not
  see it render.

---

## Appendix: On-device verification (2026-06-22)

The static findings above were re-checked by **building and running both apps** and
driving the UI to where each issue manifests. This is runtime observation, not a code
re-read. Honesty note (CLAUDE.md): what is marked ✅ was *run and observed*; the one
⚠️ item is source-confirmed and the app runs, but the specific live screen could not be
captured because of host-tooling limits — that gap is stated, not papered over.

**Build/run environment**
- Toolchain: Xcode-beta 27.0 (`DEVELOPER_DIR=/Applications/Xcode-beta.app/...`), per the
  repo's PCC-symbol requirement. Both apps built clean.
- EldrChat: iPhone 17 simulator (iOS 27.0), launched with the repo's existing
  `--uitest` Local Universe + `--reset` harnesses.
- Huginn: ran as a native macOS app and inspected via the accessibility tree.

**EldrChat — driven with XCUITest, screenshots attached to the result bundle.**
A temporary test file, `App/PQRCUITests/UXVerificationTests.swift`, drives the three
EldrChat findings. All three tests pass. (It is clearly marked temporary — delete after
the review is acted on. It is verification scaffolding, not a fix.)

- **Rec 1 — confirmed.** In a conversation: the leading "AI: live" chip opens the
  **"AI here"** sheet (AI-context picker + "My AI responds"). A *separate* sparkles
  "My AI" toolbar button opens the **same** sheet. The info ▸ **Details** screen hosts a
  **third** copy of the same per-conversation "AI context here" picker *and* an "Egress
  firewall here" override. So one conversation exposes the same AI controls through three
  surfaces, exactly as described.
  - **New runtime finding (reinforces Rec 1):** on a stock iPhone in **portrait**, the
    conversation toolbar is so crowded that the sparkles "My AI" button **and**
    "Conversation details" **overflow into a hidden "More" (…) menu** — they are not
    directly visible at all. They only appear on the bar when the device is rotated to
    landscape (verified by rotating mid-test). Worth folding into Rec 1's fix: collapsing
    the duplicate entry points also fixes the overflow.

- **Rec 4 — confirmed, including the silent data-loss path.** A 218 KB paste collapses
  into a chip whose only action is a discard "✕" (no view/edit/preview). With the chip
  present, a typed note ("TYPEDNOTE12345") was entered and Send was tapped: **only the
  paste was sent; the typed note was silently discarded** (`largePaste ?? draftText`).
  Note the asymmetry — a *sent* large message shows an "Open full screen" affordance, but
  the *unsent* chip in the composer offers no way to view what's in it.

- **Rec 5 — confirmed.** On the first-run create screen, choosing the hidden
  (passphrase, "NO recovery") account and entering a **one-character** passphrase
  (`a`/`a`) plus the acknowledgment leaves **"Create account" enabled** — no strength
  meter, no minimum, no guidance. A permanently-unrecoverable account can be protected by
  a single character.

**Huginn — inspected via the live accessibility tree.**
`screencapture` is blocked by the macOS screen-recording permission (not grantable
headlessly), and Huginn has no UI-test target, so evidence here is the running app's
accessibility tree rather than pixels.

- **Rec 3 — confirmed running.** On the live **Configuration** tab the accessibility
  tree shows **exactly two text-editor fields**, labelled "Prompt preamble (appended to
  the built-in system prompt)" and "System prompt override (replaces the built-in prompt
  entirely…)", and **no** "Save / Saved / Unsaved / Editing / Revert / Reset" control
  anywhere on the screen — i.e. the two free-text fields auto-persist with no
  save/dirty/undo signal, as described.

- **Rec 2 — source-confirmed; live Bridge-tab capture blocked.** The current code
  matches the finding: `BridgeView` renders the "No owner pinned — the agent stays
  silent" warning only inside `ownerBox`, which is gated on
  `!activeConversations.isEmpty || ownerIdentityHex != nil` (so it is hidden before any
  device pairs); `projectDirBox` sits below the conditional boxes in a `ScrollView`; and
  there is no upfront readiness checklist. The app builds and launches. I could **not**
  capture the live Bridge tab: macOS exposes the SwiftUI `TabView` toolbar tabs to
  accessibility only intermittently, so programmatic tab-switching to the Bridge view was
  unreliable this session, and screenshots are blocked as noted. This item is therefore
  verified by source + "the app runs," **not** by observing the live Bridge screen.

**What was NOT verified at runtime:** VoiceOver/Dynamic Type/contrast, performance, and
the inferred "does this actually confuse users" claims from the original review — all
still out of scope. Rec 2's live Bridge-tab rendering remains unconfirmed on-device.
