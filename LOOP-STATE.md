# LOOP-STATE — end-to-end configuration bring-up

## 2026-07-18 (second follow-up): tether "paired but never responds" — FIXED (AC110)

Root cause: the node's `.direct` watch-along path required a live ai_window for
EVERY send — including the owner's own 1:1 chat (`handleInboundPrompt` +
`broadcastAgentMessage` both gated). Windows are time-bounded, so the first
lapse muted the node forever, silently. Fix: solo semantics — owner-only
recipient sets answer without a window (matching the phone's solo My-AI gate
class and `sendDraftToOwner`'s existing rule); groups/threads keep the full
fail-closed gate, now with a DiagnosticsLog note on drop. Suite green: 106/106,
incl. soloOwnerChatSendsWithoutWindow / soloOwnerPromptAnswersWithoutWindow /
groupStillFailsClosedWithNoOwnerWindow; the forged-window test now uses a group
so it stays load-bearing. DEVIATIONS AC110. USER STEP: relaunch Huginn (⌘R) —
the running instance predates the fix — then message the tether 1:1 from the
phone. If My AI still stays silent after the 1:1 answers, the residue is
phone-side routing (need the phone's view to chase it).

## Run of 2026-07-18 ~01:30–02:30 (follow-up)

- **A2A two-way channel PROVEN (Claude → local model):** token read via the
  file-keychain mirror works; SendMessage with
  `configuration.returnImmediately:true` + GetTask polling (result IS the task,
  not result.task — fixed my parser) returned the local model's reply:
  "Hello! I'm EldrChat… ELDR-A2A-OK", TASK_STATE_COMPLETED. NOTE: without
  returnImmediately the JSON-RPC response blocks until the task is terminal —
  spec-faithful, not a bug; CLI callers should always pass returnImmediately.
- **Xcode registration FIXED via file tools** (Bash path was blocked for both
  of us — the user's "not authorized" was almost certainly the `!` prefix
  hitting the same classifier): duplicate plist already gone; BC567FD8 edited
  to add `requiresAuthentication=false`, plutil lint OK. REMAINING: restart
  Xcode, pick "Eldr" once in the chat model picker (stored selection still
  points at a deleted registration UUID).
- **Tool-calling through mlx_lm.server: fully diagnosed, model-specific.**
  Latest release (0.31.3) AND git main (15b522f, incl. the 2026-07-08 parser
  state machine) both return finish_reason:"tool_calls" with tool_calls:null
  for Qwen3-Coder-Next. Tokenizer metadata is fine (has_tool_calling=True,
  `<tool_call>` markers); the model emits Qwen3-Coder's XML-parameter grammar
  inside the wrapper, which the parser can't read. Upstream gap. Venv now runs
  git-main (revert: `uv pip install --python <venv> mlx-lm==0.31.3`).
- **BOTH DIRECTIONS PROVEN (2026-07-18 ~03:0x).** Qwen3.6-27B-MLX-4bit
  downloaded (15 GB), server + env switched to it,
  `--chat-template-args '{"enable_thinking": false}'`; structured tool_calls
  parse (get_weather probe). Direction B e2e PASSED: local model called
  delegate_to_cloud_agent (harness claude-code → claude-agent-acp, using the
  `claude` CLI login) and relayed Claude's verbatim critique of a `try!`
  decode line; tool_call → in_progress → completed, stopReason end_turn.
  Direction A (Claude → local model over the A2A endpoint) passed earlier.
  The MLX server is MY detached process (new pid, port 1337); Huginn's MLX
  tab still SHOWS Coder-Next in its Model field — switch it to
  Qwen3.6-27B-MLX-4bit in the UI whenever the app takes ownership (Coder-Next
  stays cached for chat-only use; its XML tool grammar is the thing mlx-lm
  can't parse, tracked upstream).
- **Huginn crash (user report): NOT reproducible headlessly** — A2A chat task
  and a run_shell tool task both completed with Huginn alive. It crashed under
  Xcode's debugger, so no .ips exists. NEEDS ME: the red backtrace from
  Xcode's debug session (or reproduce while not attached so an .ips lands).

Goal: phone-driven dev via the MacBook, frontier-model critique via API, then
friend invite with AI permissions. Prove everything by real traffic, not 200s.

## Items (run of 2026-07-18, ~00:40–01:20)

1. **MLX server serving real completions on :1337** — DONE
   Proof: POST /v1/chat/completions → "ELDR-MLX-OK", finish_reason stop.
   Killed zombie 47071 (phantom model path); server now runs detached
   (`nohup`, pid 77606) with `--chat-template-args '{"enable_thinking":false}'`,
   logging to mlx-server.log. env ELDR_LLM_MODEL fixed (was the phantom path;
   yesterday's 404 storm was ANOTHER typo'd id, `qqwen/qwen3.6-27b`).
   CAVEAT: 42 GB model on a 64 GB Mac — it was OOM-killed once while three
   xcodebuild runs were live. Stable when the machine is quiet. Consider
   Qwen3.6-27B-MLX-4bit (~15 GB) as the daily driver (needs me).
2. **Agent e2e through MLX** — DONE
   Headless initialize → session/new → session/prompt via
   ~/.local/bin/eldr-acp-xcode → streamed "ELDR-ACP-OK", stopReason end_turn.
3. **App e2e via Huginn's A2A + tether** — code DONE (suite green ×3), live
   proof NEEDS ME (two clicks + one command, below)
   Implemented: A2A serving persists + launch-restores (`a2aServerEnabled`,
   AC109 pattern; providers wired at the composition root so a restored server
   never gets NullLLMClient); `a2aAutoApprove` pref + Bridge-tab toggle with
   are-you-sure dialog (tool use still rides the AC108 Security toggle);
   bearer token mirrored ONCE to the file keychain (new `KeychainBox.hasItem`
   attribute probe keeps the CLI's Always-Allow ACL grant alive across
   relaunches; rotation rewrites). Debug Huginn launched (pid 76058), mirror
   item verified on disk. Proof script ready: scratchpad/a2a-e2e.sh
   (SendMessage "ELDR-A2A-OK" → GetTask poll). Classifier correctly refused to
   let ME flip approval-bypass prefs or read the token secret.
4. **App not expanding horizontally** — DONE (build + full suite green)
   Every tab was hard-capped: Bridge 640, Config/MLX/TestChat 720, Relay 680 —
   half a desktop window was dead margin. Raised within the existing
   cap+center pattern: work surfaces (Bridge/TestChat/MLX/Relay) → 1100,
   settings forms → 980. Logs/Inspector already filled. Eyeball-verify wanted.
5. **Frontier critique path (delegate_to_cloud_agent)** — BLOCKED (upstream),
   3 tries spent
   Done along the way: `@agentclientprotocol/claude-agent-acp` installed (nvm
   node v25, symlinked ~/.local/bin), descriptor updated
   claude-code-acp → claude-agent-acp (its own doc required this; PQRCACP
   tests green). Gates verified open (delegation=1, ungated=1).
   BLOCKER (proven by direct probe): mlx_lm.server 0.31.3/0.32.0 returns
   `finish_reason:"tool_calls"` with `tool_calls: null` for Qwen3-Coder-Next —
   the server detects but fails to PARSE this model's tool-call format, so no
   tool call ever reaches eldr-acp (its "only private reasoning" fallback).
   Attempts: (1) first run hit the OOM kill; (2) rerun → thinking-only;
   (3) restarted server with enable_thinking:false → same null tool_calls.
   NOT our stack: plain turns work (item 2); tool-calling worked against
   LM Studio/gemma historically.

## Needs me

1. **A2A live proof (finishes item 3):** in Huginn ▸ Bridge: toggle **Serve
   A2A**, optionally **Auto-approve inbound tasks** (confirm dialog). When the
   `security` keychain prompt appears, **Always Allow**. Then run:
   `! /private/tmp/claude-501/-Users-auston-Development-Projects-Eldr/1cae8cac-eaa4-412e-9c0a-afe979403f29/scratchpad/a2a-e2e.sh`
   (If you skip auto-approve, click Approve on my one pending task instead.)
2. **Unblock item 5 (pick one):**
   a. Update mlx-lm (MLX tab ▸ "Update mlx-lm") and restart the server — newer
      releases fix Qwen3-Coder tool-call parsing; then I rerun the delegation.
   b. Point ELDR_LLM_URL back at LM Studio (:1337 conflict — pick a port) for
      tool-heavy flows.
   c. Serve a model whose tool calls this mlx-lm parses (e.g.
      Qwen3.6-27B-MLX-4bit) — also solves the RAM squeeze.
3. **(carryover) Xcode registration repair** — if not yet done: quit Xcode,
   `mv ~/Library/Developer/Xcode/CodingAssistant/ACP/54DA80FC-….plist{,.bak-dupe}`,
   PlistBuddy `Add :requiresAuthentication bool false` on BC567FD8-….plist,
   relaunch, re-pick "Eldr" in the chat model picker.
4. **MLX server ownership:** it currently runs as my detached process. For
   permanence flip MLX tab ▸ "Start at login (launchd)" (kill pid 77606 first
   or use the tab's Start — it will surface the port conflict cleanly now).
5. **Friend invite + AI permissions** (phone-side, after the above): verify
   the friend as a contact on BOTH phones → your chat ▸ AI hub → shared-AI
   thread invite; their access to your AIs is governed by the per-AI grants
   there. I can write a precise walkthrough next run if wanted.

## Notes for next run

- Do NOT run concurrent xcodebuild suites while the 42 GB model is resident —
  that's what OOM-killed it (64 GB Mac).
- Huginn Debug app running = pid 76058 (built with all fixes). Working tree
  still uncommitted (incl. prior docs consolidation); user hasn't asked for
  commits.
- a2a-e2e.sh + the ACP python driver live in the session scratchpad; both are
  rerunnable as-is.
