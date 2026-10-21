# Audit 2: second adversarial pass (2026-10-13/14)

Owner: Grok Bot. Exit condition: each row is fixed (DEVIATIONS AC227), or Auston decides it (§2).
Labels: **proven** means a test ran and passed. **unverified** means it was found by reading the code (inspection) and nothing was run.

## 1. Findings

| ID | Area | Severity | Finding | Status |
|---|---|---|---|---|
| M1 | PQRCMCP | **High** (privacy) | MCP conversation ids = peer identity hex, sent to the MCP client | **Fixed**: opaque handles. *proven* |
| L1 | Loop guard (Linux + iOS) | Medium | Peer bot labelled "human" resets guard → unbounded AI replies | **Fixed on Linux** (AutoTurnLimiter) *proven*; iOS = decision D2 |
| R1 | EldrClient (relay flood) | Medium | Unbounded `requests` growth under stranger flood | **Fixed** (cap 32). *proven* |
| H1 | Huginn GTK/Core | Medium (metadata) | Plaintext cwd marker next to sealed, hash-named project memory | **Fixed**. *proven* |
| T1 | iOS thread control | Medium | Any peer can adopt/re-home/rename a thread id | **Fixed** (creator-only, no re-home). *unverified* (not compiled) |
| G1 | Group roster control | — | Covered by AC220/AC226 (admin-only, held invites) | Done earlier |
| N1 | EldrNode | Medium | Node accepts EVERY message request (fetch binding, consume OTP, add contact) before checking it is the owner → strangers can drain OTPs (forcing last-resort-prekey reconnects) and grow contact state. C-3 still blocks driving. | **Open**: decision D3 |
| P1 | Protocol (AC225) | Medium | Two first contacts inside the republish window can collide on one OTP → silent dead session | **Open**: decision D1 |
| MD1 | Metadata | Medium | Ephemeral receiving keys are implemented (`enableEphemeralReceivingKeys`) but enabled NOWHERE, so every inbound wrap is p-tagged with the long-lived identity Nostr key (the relay can count inbound volume/timing per user) | **Open**: decision D4 |
| MD2 | Metadata | Low | Republish right after an OTP consume (AC167) tells the relay "first contact just happened" | Accepted in AC167 |
| S1 | SwiftA2A server | Low | `InMemoryTaskStore` keeps unbounded task count (authenticated clients only; macOS-only server); history is capped | Open (low) |
| K1 | iOS silo keys | Medium | AC170 fix reviewed: prekey-state is sealed now. Per-AI API keys (`AISettingsView`) and Buzz workspace keys are still saved unsealed in the silo Keychain service | Already in BACKLOG; unchanged |
| C1 | Live-log canaries | Low (hygiene) | Product: no plaintext found in Linux logs by grep; the AC221 inbox is encrypted. Box: `/workspace/eldr-test` holds pre-AC221 plaintext inboxes/listen logs and `probe-state/state.json`, an ad-hoc harness file with a TEST identity's private key in clear. All test identities, none of Auston's. | Recommend deleting old test artifacts (not done: needs approval) |
| R2 | pqrc-relay | Info | The Linux `pqrc-relay` is a stub (Network.framework only). The flood test uses the in-process LocalRelaySimulator plus direct event injection, so no network relay was built | Note |

## 2. Decisions for Auston

- **D1 (P1):** when a first contact's OTP is refused, should the responder send a reconnect request, or should the initiator re-handshake when no reply comes? This changes protocol behavior, so it needs a SPEC/NIP note.
- **D2 (L1):** should the iOS port get the same label-independent cap (20 per 10 min), or is a per-thread setting preferred?
- **D3 (N1):** should the node pre-verify the sender's binding against the pinned owner BEFORE accepting (that needs a `fetchVerifiedPeer` seam on NodeMessenger), with town peers pre-provisioned only?
- **D4 (MD1):** turn on ephemeral receiving keys by default (rotation, extra relay subscriptions), or keep them opt-in?
- **D5 (C1):** may I delete the old plaintext test artifacts in `/workspace/eldr-test`?
