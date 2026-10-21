# PROPOSED spec patch: group admins + invite approval (AC220 / AC226)

Status: **proposal only, 2026-10-13. NOT applied.** APP-SPEC, NIP-XX and the SPEC are law
and change only with Auston's approval. Code already implements this behind DEVIATIONS
AC220 (Linux, *proven* by tests) and AC226 (iOS, *unverified*, needs Mac test). Owner: Grok Bot
drafts; Auston approves. Exit: Auston approves (then apply verbatim, strike AC220/AC226
as spec-conformant) or rejects (then revert the code to "any current member").

## 1. docs/APP-SPEC.md §7 (line ~172)

```diff
-Roster changes are new `group_create` revisions from any current member; clients render roster-change system rows.
+Roster changes (members, name, admins) are new `group_create` revisions from a current
+**admin**; a revision from a non-admin member is ignored, except a member's own departure
+(a revision whose only change is removing the asserter). The creator is the first admin;
+`admins` travels in `group_create` (absent ⇒ legacy group: the last accepted asserter is the
+sole admin). A departing admin is removed from `admins`; admins must be members.
+A `group_create` for a group the recipient has not joined is an **invite**: it is held like a
+message request (nothing rendered, no AI ingestion) until the user Joins or Declines.
+Declining drops held posts and silences later traffic for that `group_id`. Posts naming a
+group the recipient has not joined, or sent by a non-member, are never filed under the
+group. Clients render roster-change system rows.
```

Honest-limitations sentence gets one addition:

```diff
-… (a malicious member can present inconsistent rosters — display "roster as asserted by X"), …
+… (a malicious ADMIN can still present inconsistent rosters to different members — display
+"roster as asserted by X"; admin status is itself only as consistent as the creator's
+fan-out), …
```

## 2. docs/APP-SPEC.md decisions table (D1 row, line ~513)

```diff
-| D1 | Groups v1 = pairwise fan-out of PQRC sessions; `conversation_type:"group"`, `group_create` rumor; MLS in v2 per SPEC §12 | upstream-NIP |
+| D1 | Groups v1 = pairwise fan-out of PQRC sessions; `conversation_type:"group"`, `group_create` rumor with optional `admins`; admin-only roster changes; invites held for approval; MLS in v2 per SPEC §12 | upstream-NIP |
```

## 3. docs/NIP-XX-pqrc.md §11

```diff
 - `group_create`: `{"group_id", "name", "members": [identity_hex...],
-  "conversation_type": "group", "revision"}` — pairwise fan-out (D1), roster
-  tracked per asserter, revisions monotonic.
+  "conversation_type": "group", "revision", "admins"?: [identity_hex...]}` —
+  pairwise fan-out (D1), roster tracked per asserter, revisions monotonic.
+  Receivers MUST accept a revision only from a sender in the current `admins`
+  (or, when `admins` is absent, the last accepted asserter), except a revision
+  whose sole change is the sender leaving. `admins` entries not in `members` MUST
+  be dropped. A `group_create` for an unjoined group SHOULD be held for user
+  approval and MUST NOT be rendered or fed to agents before approval.
+  Older clients ignore `admins` (unknown field) and keep "any member" semantics —
+  a mixed group is only as strict as its least strict member.
```

## 4. THREAT_MODEL addition (suggested §2.x)

"Group roster hijack by a non-admin member: mitigated (AC220). Unsolicited group adds as a
spam/tracking vector: mitigated by held invites. Residual: admin equivocation; old clients."

## 5. Open questions for Auston

1. Should admins be able to add admins (current code: yes, via `admins` in a revision)?
2. Should a group with zero remaining admins promote the oldest member, or freeze? (Code: freezes.)
3. Interop: bump a capability flag (e.g. `pqrc_capabilities: "group-admins"`) so a creator can warn when a member's client is old?
