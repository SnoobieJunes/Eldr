<!-- SPDX-License-Identifier: CC0-1.0 -->

# Standing town grants: a day-scale, scoped, revocable authorization for cross-town agent autonomy

- **Extension URI:** `https://eldr.app/ext/pqrc-standing-grants/v1`
- **Type:** Signed control-object extension to PQRC (SPEC §13 family)
- **Status:** Draft
- **Protocol version covered:** PQRC v1.1
- **Implementation:** Eldr (Swift) — `StandingGrant` / `StandingGrantRevocation` in [`PQRCCore`](../Packages/PQRCCore), enforced by `AgentEngine` in [`PQRCAgent`](../Packages/PQRCAgent)
- **Companion:** the transport that carries the traffic a grant authorizes is [`A2A-PQRC-EXTENSION.md`](A2A-PQRC-EXTENSION.md); the product framing is `private/GOOSEWORLD.md` §5.

## 0. Status of this document

This is a Draft describing a working, unit-tested implementation. It has not been
proposed for the NIP. The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**,
**SHOULD**, **MAY**, and **OPTIONAL** are to be interpreted as in RFC 2119/8174 when,
and only when, they appear in all capitals.

## 1. Motivation

PQRC SPEC §13 (and CLAUDE.md invariant 9) require that an agent's autonomous sends be
authorized by something **signed with the human identity key, time-bounded, and rendered
as a visible indicator in every client**. The two existing objects that satisfy this are
`ai_window` (conversation scope) and `ai_invite` (thread scope). Both are minutes-to-hours
scale by design, because both govern a human sitting in a live chat.

A cross-town co-build (GOOSEWORLD §5) has neither property. It runs for **days**, so an
hours-scale window lapses in the middle of it — this is exactly the AC110 "the tether went
silent forever" failure mode surfacing on the cross-town path. And it produces **hundreds
of wall posts and task frames**, so per-message human approval is unusable.

The wrong fix is to widen `ai_window`/`ai_invite`'s duration bounds, or to add a per-surface
exception each time a new plane appears. GOOSEWORLD §5 is explicit that *"widening gates ad
hoc per surface is how invariant 9 erodes."* The right fix is one new first-class object that
keeps all three §13 properties while adding the scope and budget a multi-day, multi-plane
authorization needs — and that plugs into a **separate** enforcement path so the existing
gate is provably untouched.

## 2. The two objects

Both ride **inside the ratchet ciphertext**, as optional fields on `MessageBody`
(`standing_grant`, `standing_grant_revocation`) — never as public event metadata, never
unencrypted. A client that does not understand the fields ignores them (SPEC §12 forward
compatibility) and therefore simply never opens the town gate: the unknown-field direction is
fail-closed.

There is deliberately **no dedicated outer `RumorType`** on the wire. Like `ai_context_grant`,
these are optional members of an ordinary `.message` body; a new outer rumor kind would make
older clients fail to decode the whole rumor rather than tolerate the extension.

### 2.1 `standing_grant`

| field | wire key | type | notes |
|---|---|---|---|
| type | `type` | string | constant `"standing_grant"` |
| grant id | `grant_id` | string, ≤64 bytes | issuer-minted, opaque; revocation targets it |
| peer town | `peer` | 64-char lowercase hex | the peer's PQRC (Ed25519) identity pubkey |
| planes | `planes` | array of string | ≥1, no duplicates, no empty names; `"wall"` and/or `"delegate"` today. Unknown strings round-trip and stay bound in the signature, but authorize nothing (fail-closed forward compat) |
| budget | `budget` | object | see below |
| expiry | `active_until` | int64 (unix seconds) | MUST be ≤ 30 days from `now` at receipt |
| signer | `enabled_by` | 32 bytes | the granter's **human identity** pubkey |
| signature | `sig` | 64 bytes | Ed25519 over §3's signing message |

`budget` object: `messages_per_day` (int, `0` = none), `bytes_per_day` (int, `0` = none),
`max_concurrent_tasks` (int, `0` = none), and `tool_ceiling` (`[string]?`, **omitted** when
absent — "no ceiling" — vs an empty list meaning "no tools at all"). Ranges enforced at
receipt: messages ≤ 1e6, bytes ≤ 1e9, tasks ≤ 1024, tool list ≤ 256 entries × ≤ 128 bytes.

### 2.2 `standing_grant_revocation`

| field | wire key | type | notes |
|---|---|---|---|
| type | `type` | string | constant `"standing_grant_revocation"` |
| grant id | `grant_id` | string | the `grant_id` of the grant being revoked |
| revoked at | `revoked_at` | int64 (unix seconds) | informational; revocation is effective on receipt regardless |
| signer | `enabled_by` | 32 bytes | MUST be the SAME human identity that signed the grant |
| signature | `sig` | 64 bytes | Ed25519 over §3's revocation signing message |

## 3. Signing messages (domain-separated)

**Grant:**

```
"pqrc-standing-grant-v1" ‖ int64BE(active_until) ‖ enabled_by ‖ utf8(scopeTag)
```

`scopeTag` is a canonical, **injective** encoding of every scoped field. It begins with
`"standing-grant-v1"` and then appends, for every component, `"|<utf8-byte-count>:<value>"`:

```
standing-grant-v1
  |<n>:<grant_id>
  |<n>:<peer>
  |<n>:planes=<count>   then for each plane  |<n>:<plane>
  |<n>:m=<messages_per_day>
  |<n>:b=<bytes_per_day>
  |<n>:c=<max_concurrent_tasks>
  |<n>:tools=*                       (when tool_ceiling is absent)
  |<n>:tools=<count>   then for each tool  |<n>:<tool>   (when present)
```

Length-prefixing is what makes this safe. A naive delimiter-join is **actively unsafe**
here: `["", "wall"]` and `["+wall"]` join to the identical `"+wall"`, but the first
authorizes the `wall` plane and the second authorizes nothing — so a signature over the
harmless grant could be transplanted onto the powerful one. (This bug was written, then
caught in review; the regression test `emptyPlaneStringCannotCollideWithAJoinedPlane` is the
tombstone.) Because plane and tool **order and multiplicity** are also bound (a count field,
then each element), a reorder or a duplicate changes the tag and fails verification.

**Revocation:**

```
"pqrc-standing-grant-revocation-v1" ‖ int64BE(revoked_at) ‖ enabled_by ‖ utf8("<len>:<grant_id>")
```

The four domain strings in this family — `pqrc-ai-window-v1`, `pqrc-ai-context-grant-v1`,
`pqrc-standing-grant-v1`, `pqrc-standing-grant-revocation-v1` — are mutually non-prefix, so
no signature is ever valid in two roles. A test asserts cross-replay fails in both directions
for all four.

## 4. Receiver validation (all fail-closed)

1. `enabled_by` (as hex) **MUST** equal the claimed sender's identity, checked before any
   crypto (`standingGrantNotFromHumanIdentity`). **Agents cannot self-grant** — a grant
   signed by anything other than the sending human's own identity key is rejected.
2. Structure: `type` correct; `grant_id` non-empty and ≤ 64 bytes; `peer` exactly 32 bytes of
   lowercase hex; `planes` non-empty, de-duplicated, no empty names; `enabled_by` 32 bytes;
   budget within the §2.1 ranges.
3. Signature **MUST** verify against `enabled_by` over §3's message (`standingGrantSignatureInvalid`).
4. Duration **MUST** satisfy `active_until − now ≤ 30 days` (`standingGrantDurationUnbounded`).
   An unbounded or over-long grant is refused, never truncated.
5. Only planes the client understands are enforced; unknown planes round-trip (kept in the
   signature so the grant still verifies) but gate nothing.
6. Re-storing the same `grant_id` **preserves** its day-budget counters — a replay is not a
   budget refill. A new `grant_id` starts fresh counters.
7. **The gate is separate** (§5).
8. Revocation is effective on receipt: verify signature + `enabled_by == sender`, then remove
   grants with that `grant_id` **whose granter is the signer**. An unknown `grant_id` is a
   silent no-op — never an error, so the object cannot be used as a state-probe oracle.

## 5. Enforcement is a SEPARATE path — `authorizeAutonomousSend` is unchanged

This is the load-bearing design constraint. A standing grant is enforced ONLY through new
engine entry points:

- `authorizeTownSend(peerIdentityHex:plane:bytes:)` — throws unless a live, unrevoked,
  in-budget grant covers that exact (peer, plane); charges nothing (the check is pure).
- `recordTownSend(peerIdentityHex:plane:bytes:)` — the explicit, message-driven budget debit.
- `beginTownTask` / `endTownTask` — the concurrent-task ceiling.
- `toolAuthorizedForTown(peerIdentityHex:tool:)` — the optional tool allow-list.

`authorizeAutonomousSend(threadID:)` — the §13 gate for ordinary window/thread sends — is
**byte-identical** to before this extension. A test asserts that holding a live standing grant
does **not** make an ordinary conversation or thread send succeed. Distinct error cases
(`townSendNotAuthorized`, `townBudgetExhausted`, `townTaskLimitReached`, …) keep a caller from
ever confusing the two gates.

Budgets are **message-driven, never timer-driven** (SPEC §5.2 / invariant 1): the current
UTC-day index is computed from `clock.now()` at call time, and day rollover is **monotone** —
a clock that moves backwards never refills a budget. There is no `Timer`, no
`DispatchSourceTimer`, no scheduled reset anywhere in this path.

## 6. Visibility (the third §13 property)

The engine exposes `activeStandingGrant(peerIdentityHex:plane:)` and `activeStandingGrants()`,
each returning the grant's expiry **and** its remaining budget (messages, bytes, tasks
in-flight, tool ceiling). Every client **MUST** render an indicator for a live grant's
lifetime, the same transparency property as the `ai_window` banner. A grant that is not
surfaced to the human is not a valid deployment of this extension.

## 7. Relationship to the transport gate

A standing grant is the human-signed authorization; it is *consumed* on the **sending** side,
where the agent's autonomous send actually happens. The receiving node's transport admission
check for the A2A town plane (`TownAuthorizer`, `EldrNode`) is a distinct, complementary gate:
`StandingGrantTownAuthorizer` answers "may this peer's frames reach my A2A plane at all" from
the same live grant set (owner-signed, unexpired, plane-covering), while a peer's own
`authorizeTownSend` governs what that peer is allowed to emit. Admission to a channel is never
a budget grant; the two gates enforce independently and both fail closed.

## 8. Security considerations

- **No self-authorization.** §4.1's `enabled_by == sender` check, plus the transport
  authorizer's owner-granter pin, mean a peer cannot admit itself by signing a grant naming
  itself. This is the cross-town analogue of the confused-deputy the node's C-3 gate prevents.
- **Revocation latency is one frame.** The transport authorizer consults the live grant set
  per inbound frame (no cache), so a revocation removes admission on the very next frame.
- **A grant is a delegation-exfiltration surface** (GOOSEWORLD §4 class 2): the task text a
  grant authorizes *is* the leak to the remote town. Scoping (peer, plane, budgets, tool
  ceiling) is what makes that exposure a deliberate, bounded, revocable choice rather than an
  open pipe. The per-chat egress firewall still governs what leaves toward cloud LLM backends.
- **This does not soften invariants 8–9.** Anything a town interaction causes to be *rendered*
  in a conversation is agent-authored and MUST carry `participant_type: "agent"`; the grant
  authorizes autonomy, it never relabels authorship.

## 9. References

- PQRC SPEC v1.1 §13 (AI participation), §12 (forward compatibility), §5.2 (message-driven schedule)
- `docs/A2A-PQRC-EXTENSION.md` — the transport this authorizes
- `private/GOOSEWORLD.md` §4 (threat model delta), §5 (this object)
- `docs/DEVIATIONS.md` AC126 (this object), AC128 (the transport gate), AC130 (the grant-backed authorizer)
