# WS-N6: the Linux ELDR agent drives Auston's Mac node over eldr-acp (sponsored-driver design)

Status: **plan only, 2026-10-13. Nothing is built.** Approved for planning by Auston (task 3C).
Owner: Grok Bot (Linux/ELDR side), with Auston for the Mac and iPhone/Huginn UI and the on-device test.
Exit condition: Phase 4 of `docs/guide/OWNER-TEST-PLAN.md` passes on Auston's Mac with this
design. In particular, every check in §6 (theft drills) passes, each with a test and a
DEVIATIONS entry.

Labels: everything below is a *design* (**unverified**) unless marked *verified* (read in source this session).

## 1. Goal and threat model

ELDR (the Linux agent identity) drives `eldr-acp` on Auston's Mac (builds, tests, Xcode) over
the existing E2EE relay. **Design rule: assume the ELDR private key is stolen.** A thief holding
it must get nothing: no file reads outside the jail, no writes, no shell, no secrets. The Mac
enforces every one of these limits. Nothing is trusted on the Linux side.

## 2. Requirements → enforcement on the Mac

| # | Requirement | Mac-side enforcement |
|---|---|---|
| R1 | Accept ELDR only under a **live, short sponsorship** | The node verifies an `AgentSponsorship` (sponsor = Auston's owner identity, agent = the ELDR key, max 7 days per AC219, 1 day by default for this use) on **every** ACP session open **and on every tool call** (`verify(presentedBy:now:)`, *verified* to exist in PQRCCore). Expired → session closed. |
| R2 | **Human approval for every write/shell/build** | Every mutating tool, including file writes, terminal/shell, build and test runs, and Xcode actions, goes over `ACPPERM1` (*verified*: `ACPPermissionChannel.swift`) to Auston's Mac (Huginn) **or** his iPhone. The card shows the **exact command / path + diff summary**, labeled "requested by sponsored agent ELDR (key fp …, sponsorship expires …)". Timeout (default 60 s) → **deny**. **No "Always" for sponsored agents.** Standing consent is disabled for this principal. |
| R3 | **Dedicated test-workdir jail** | The sponsored session is pinned to a node-chosen directory (e.g. `~/EldrJail/<session>`), never one the client names. ToolExecutor's no-follow jail (AC223, openat + O_NOFOLLOW, no `..`, nlink check) applies to all I/O. Delegated `fs/*` must move onto the same fd walk (the residual noted in AC223). Shell/build commands run with `cwd` = jail and a scrubbed env. |
| R4 | **Secrets never leave the Mac** | The env passed to tools is an allow-list only (no `*_TOKEN`, keychain, `~/.ssh`, signing identities). Read tools are limited to the jail. Outbound tool results go through the existing redaction plus a size cap. Signing/notarization is not available to sponsored agents. If a build needs signing, Auston runs that step himself. |
| R5 | **Immediate revocation** | A revoke in Huginn/iPhone updates the node's local `RevocationSet` (AC212) and **kills live sessions and child processes right away** (process group SIGKILL). Pending approvals auto-deny. No relay round-trip is needed when he revokes on the Mac itself. From the phone, revocation travels as an owner→node control frame. Revocations are not published (AC219). |

## 3. Code changes needed (estimates, unverified)

1. **eldr-node / eldr-acp multi-principal.** Today the node has a single `--owner` (*verified*: `eldr-acp/main.swift`, `EldrClient.swift`). Add `Principal = .owner(hex) | .sponsoredAgent(hex, AgentSponsorship)`, plus a policy table: owner = current behavior; sponsored agent = R1–R5 (no standing consent, jail-pinned, env allow-list). Sponsorships are stored on the node and pushed by the owner (the owner presents them, never the agent alone).
2. **Per-call sponsorship check** in the ACP dispatch path (`ACPAgent` / `ToolExecutor` entry), plus a session reaper on expiry or revocation.
3. **Approval routing.** Extend the `ACPPERM1` req with `principal`, `agentFingerprint`, `sponsorshipExpiry`, `command` (exact argv/cwd) and `diffSummary`, while staying within `maxTitleLength`/single-event limits. If needed, send a hash plus a fetch-by-id. Fan out to the Mac (Huginn) and the phone; the first answer wins and the rest are cancelled.
4. **iOS approval card** (`PersonaRuntime.decidePermission` / ConversationView): a "sponsored agent" variant with no "Always" button and the full command shown. **Needs Auston's Mac/iPhone test.**
5. **Huginn (macOS) approval card + revoke button**, with session kill.
6. **Delegated `fs/*` onto the no-follow fd walk** (closes the AC223 residual).
7. **Linux client**: `RelayACPTransport` + `ACPClientDriver` on `EldrClient`, `eldr-chat acp <node>` (this is the missing row in LINUX-PARITY WS-N6). It presents the sponsorship and surfaces denials.
8. **Spec**: NIP/extension note for the sponsored-principal ACP mode and the `ACPPERM1` v2 fields. Spec first, then code.

## 4. Order of work

Spec note (8) → node principal + policy (1, 2) → fs/* fd walk (6) → ACPPERM1 v2 + Huginn card (3, 5) → iOS card (4) → Linux client (7) → theft drills (§6) on the Mac.

## 5. Open questions

- The approval timeout length, and whether the phone or the Mac takes priority when both are online.
- Whether builds are approved per invocation or per "build target + jail state hash" for a short window. The current design is per invocation, with no Always.
- Network egress for build tools (SwiftPM fetches): allow, proxy, or vendor everything ahead of time?
- How Xcode actions (xcodebuild vs the IDE) map onto exact-command cards.
- Whether the jail is a plain directory or a separate macOS user/sandbox-exec profile (stronger isolation, more setup).
- Whether the node needs its own clock check, since the sponsorship expiry relies on the Mac's clock.
- Who may issue a sponsorship to the node: only the owner identity, or also a paired phone acting for him?

## 6. Theft drills (exit checks)

Each of these runs with a stolen ELDR key and no human approval:

1. A write is denied after the timeout.
2. Shell is denied.
3. A read outside the jail is refused.
4. A symlink or `..` escape is refused.
5. An env dump shows no secrets.
6. After expiry, the session is closed.
7. After revoke, the running build is killed within 1 s.
8. A sponsorship for another node is rejected.
