<!-- SPDX-License-Identifier: CC0-1.0 -->

# Agent sponsorship: a human-signed, revocable "this AI account answers to me"

- **Extension URI:** `https://eldr.app/ext/pqrc-agent-sponsorship/v1`
- **Status:** Draft (implemented in `PQRCCore` `AgentSponsorship` + `EldrClientCore`; DEVIATIONS AC162)
- **Model:** the standing-grant model ([`pqrc-ext-standing-grants.md`](pqrc-ext-standing-grants.md)): signed by the human identity key, own domain string, ≤ 7 days (standing grants: 30), revocable, checked per message, rides inside the ciphertext.

## Objects (optional `MessageBody` fields — no new rumor type, no new event kind)

`agent_sponsorship`: `type` `"agent_sponsorship"`, `sponsorship_id` (≤64 B), `agent` (64 lowercase hex PQRC identity),
`label` (optional, ≤64 B, no control chars), `issued_at`, `active_until` (unix s), `enabled_by` (32 B sponsor identity), `sig` (64 B).

Signing message: `"pqrc-agent-sponsorship-v1" ‖ int64BE(active_until) ‖ enabled_by ‖ utf8(scopeTag)`, where
`scopeTag = "agent-sponsorship-v1" + "|<n>:<sponsorship_id>" + "|<n>:<agent>" + "|<n>:label=<label or ->" + "|<n>:issued=<issued_at>"` (length-prefixed, injective).

`agent_sponsorship_revocation`: `type`, `sponsorship_id`, `revoked_at`, `enabled_by`, `sig` over
`"pqrc-agent-sponsorship-revocation-v1" ‖ int64BE(revoked_at) ‖ enabled_by ‖ utf8("<n>:<sponsorship_id>")`.

Both domain strings are non-prefix with every other PQRC signing domain (tested).

## Flow

1. The owner (a **human** persona) signs a sponsorship naming the agent's identity for 1 or 7 days and sends it to the agent in an ordinary human-labeled message.
2. The agent accepts it only if: it is in agent mode, the sender is its **pinned owner**, `enabled_by == sender`, the signature verifies, `agent ==` its own identity, it is unexpired, ≤ 7 days remain, and it is not revoked.
3. In agent mode every send is labeled `participant_type: "agent"` (agent-key signed, SPEC §13.4) and **carries the sponsorship**. With no live sponsorship the send is refused locally.
4. Every receiver checks each agent-labeled message on its own: sponsorship present, `agent == sender`, signature, ≤ 7 days, unexpired, unrevoked. Result: `sponsored(by, label, until)`, `unsponsored`, or `invalid(reason)`. Human messages are `human`.
5. Revocation: signed by the same key, delivered by that key's owner (anything else is ignored). Effective on receipt: the agent drops its sponsorship and stops sending; the sponsor's own view flips at once; contacts the sponsor chooses to notify flip on receipt. Everyone else stops trusting it at `active_until` (≤ 7 days; revocations are deliberately not published, AC219).

## What it is not

- Not an autonomy grant: §13 windows/invites are unchanged; the agent's own client still decides when it may speak.
- Not identity proof of the sponsor: a client MUST show **who** sponsored (contact name, or the sponsor's identity prefix marked unknown). Anyone can mint a human identity and sponsor their own bot; a sponsorship from a stranger means little.
- Older clients ignore both fields (SPEC §12): they show the agent badge from `participant_type` and no sponsorship.
