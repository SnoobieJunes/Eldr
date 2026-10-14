# Owner test plan — October 2026 (iOS PRs #26/#27, Linux parity, ELDR as an AI, ELDR drives Xcode)

Owner: Auston. Exit: every box below is ticked or has a filed issue. Times are PT.
Automated suites live in [`../TEST-PLAN.md`](../TEST-PLAN.md); this is the hands-on pass on real devices.
Keep the relay at `wss://relay.lerants.com` on every device.

Who is who:
- **You**: EldrChat on iPhone/Mac (identity `68f9b28d…`).
- **ELDR (human)**: the Linux `eldr-chat`/`eldr-gtk` account `91f7ce9e…`. It's already a contact.
- **ELDR (AI)**: a new AI account on Linux. It needs your sponsorship before it can say anything:
  - identity `b111686cabdce22812781b5361d269c6123e2f448e5d16667a1a560622985d41`
  - link `pqrc:add?npub=npub1jztm8zh54x5luegpg4ve75yd6qc0dyp9gt23s92l7zma9hfmteas3uepfu&relay=wss://relay.lerants.com`

## Phase 0: builds (10 min)
- [ ] iOS: build from `feature/polish-sponsorship-ui` (PR #27; it contains PR #26) with `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
- [ ] Mac: Huginn and `eldr-node` built from the same branch (needed for Phases 3–4).
- [ ] Linux: ELDR runs `scripts/linux-ci.sh` (green) on `feature/linux-parity` (PR #28).

## Phase 1: iOS fixes from PRs #26/#27 (20 min)
- [ ] **Reset recovery (AC165).** Delete and reinstall EldrChat (or reset the identity), then message ELDR (human). It arrives, and ELDR's reply comes back with no manual step.
- [ ] **Reconnect when prekeys run out (AC166).** ELDR exhausts your one-time prekeys and re-handshakes. You see a "reconnect" request. Approving lets messages flow; declining keeps the old session.
- [ ] **Spent prekey republished (AC167).** After the step above, ELDR's `eldr-chat` log no longer lists that one-time prekey.
- [ ] **Sponsorship UI (AC168).** Sponsor ELDR (AI) for 1 day. Its messages show the AI badge plus "sponsored by you until …". Revoke it: the next ELDR (AI) message is refused (ELDR confirms the `failed` outbox entry).
- [ ] **Silo prekey fix (AC170).** In a silo, force-quit and relaunch: there's no "prekey state" error, and a message sent to the silo still decrypts.

## Phase 2: Linux ↔ iOS interop (20 min)
- [ ] 1:1 both ways (iOS → `eldr-chat`, `eldr-gtk` → iOS), including emoji and a 5,000-word Markdown paste. It arrives intact and renders headings, bold and code in both apps.
- [ ] Group: you, ELDR (human), plus one more. Create it on iOS and on Linux, send from each, then rename it on Linux and leave it from Linux. iOS shows the rename and the left roster.
- [ ] Thread: create it on iOS, reply from `eldr-gtk`, then create one on Linux. Each side sees the other's thread title.
- [ ] QR: `eldr-gtk` ▸ Show QR, scanned from iOS ▸ Add contact. The contact is added.

## Phase 3: your Mac model and ELDR (AI) collaborating in a thread (30 min)
Setup:
- [ ] Add ELDR (AI) on iOS using the link above, then **Sponsor 1 day**.
- [ ] Point iOS Settings ▸ AI at your Mac model (LM Studio/Ollama on the Mac, or through Huginn/`eldr-node`).

Tests:
- [ ] Create the thread "build plan" with ELDR (AI) and **invite your AI 1h**. Say "ELDR and my AI: plan the next build."
- [ ] **Turn-taking:** ELDR (AI) and your model alternate. Every AI message carries its badge, and ELDR's shows your sponsorship.
- [ ] **Loop guard at 50:** let them run. AI turns pause after 50 in a row with no human message (iOS and Linux both default to 50, AC179). Post one line yourself and they resume.
- [ ] **Window expiry:** open your AI's 1h window in your 1:1 with ELDR (human). ELDR's messages get your model's replies; after an hour (or **Off**) they stop. AI accounts can't open windows themselves (refused by design, AC174).
- [ ] **Revocation:** revoke ELDR (AI)'s sponsorship mid-thread. Its next reply is refused on Linux ("no live sponsorship"), and your model keeps working.
- [ ] Withdraw your AI invite: your model stops replying in the thread.

## Phase 4: ELDR drives Xcode on your Mac (eldr-acp), currently BLOCKED
Read the gaps first.

How it connects (from `EldrNode`/`PQRCACP`):
- **Transport:** `eldr-node` on the Mac runs `--responder eldr-acp`. The ACP JSON-RPC stream travels inside E2EE Eldr messages (`RelayACPTransport`, PQRCNostr) over `wss://relay.lerants.com`. There is no inbound port on the Mac.
- **Pairing and gate (C-3):** `eldrctl install --target you@mac --owner <hex> --responder eldr-acp --workdir ~/Developer/Eldr` prints the node's pairing link. **Only the single `--owner` identity can drive it.** For ELDR, that means a second node instance with `--owner 91f7ce9e…` (ELDR's human account), or a multi-owner gate (gap 2).
- **Path jail (C-2):** file tools resolve symlinks and must stay inside `--workdir`. `run_shell` runs with cwd = workdir but is **not** path-jailed. It's gated by C-1 instead.
- **Permission prompts (C-1):** `write_file`, `edit_file`, `run_shell`, `open_terminal` and `delegate_to_cloud_agent` each send `session/request_permission` to the driving client. A timeout (`ELDR_ACP_PERMISSION_TIMEOUT`) counts as a deny. A client that declares it can't prompt never sees those tools unless `ELDR_ACP_ALLOW_UNGATED_TOOLS=1` (don't).
- **Commands ELDR would ask for** (from CLAUDE.md; the launcher exports `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`):
  - `xcodebuild -project App/EldrChat.xcodeproj -scheme EldrChat -showdestinations`
  - `xcodebuild test -project App/EldrChat.xcodeproj -scheme EldrChat -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation` (never `CODE_SIGNING_ALLOWED=NO`)
  - `xcodebuild test -project Apps/Huginn/Huginn.xcodeproj -scheme Huginn -destination 'platform=macOS' -skipPackagePluginValidation`

Gaps blocking this phase (WS-N6 in `docs/plan/LINUX-PARITY.md`):
1. **No Linux ACP-over-relay client.** iOS drives the node from `PersonaRuntime`. Linux has `RelayACPTransport` and `ACPClientDriver` but no command that joins them on top of `EldrClient` and surfaces permission prompts to ELDR (e.g. `eldr-chat acp <node>` with an outbox-style approve/deny).
2. **The node has a single owner.** ELDR can't share your node. It needs either its own node instance (separate Keychain service and LaunchAgent label, unverified that `eldr-node` supports two side by side) or a delegated-driver grant from you.
3. **The node's model makes the tool calls, not ELDR.** ELDR sends prompts; your local model picks the tools. For ELDR to run an exact `xcodebuild` line, the model has to follow the instruction, or there needs to be a "run this command" skill. Unverified.

When those exist:
- [ ] ELDR asks for `-showdestinations`. You see a permission prompt and approve it, and the destinations list comes back to ELDR.
- [ ] ELDR runs the EldrChat test command, and the pass/fail summary comes back over the relay.
- [ ] Deny a `write_file` prompt: no file changes.
- [ ] A path outside the workdir is refused.
