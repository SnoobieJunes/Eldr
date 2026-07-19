# LOOP-STATE — end-to-end configuration bring-up

## 2026-07-18 (MLX overhaul): WS-M3 model library polish — DONE (AC118)

Suite 197/197, green on TWO consecutive full runs (21 new tests). Shipped in the
Models library: a determinate download `ProgressView` driven by a tqdm parser + a
free-disk guard before the job starts (AC103f); format-honesty warnings on non-MLX
search results when the filter is off (the NVFP4 lesson); a per-model detail
popover (size / last used / quant / path + Reveal / Serve / Try); and a
cache-hygiene sort (Largest / Recently used / Name, Largest = the "free up space"
default).

PREMISES VERIFIED against the live venv (mlx-lm 0.31.3, hf_hub 1.24.0) — one was
FALSE, per the AC116 lesson:

- **Download output reality:** the plan's "percent/rate parsed from the tqdm
  line" implied a byte bar. Captured by running the app's EXACT `snapshot_download`
  command through a non-TTY pipe: hf_hub 1.24.0 emits a **file-count** bar
  (`Fetching N files: P%|…| x/N [el<rem, rate]`); per-file byte bars are suppressed
  off a TTY. So progress is files-based and the rate is files/s — the ProgressView
  is captioned in tqdm's own wording, NOT a fake MB%/MB-rate. 4 real frames + the
  0%+unauth-Warning concatenation frozen as fixtures.
- The plan's example id `mlx-community/SmolLM2-135M-Instruct-4bit` DOESN'T EXIST
  (401). Used `mlx-community/SmolLM2-135M-Instruct` — downloaded (273.9 MB), loads
  (0.318 GB peak). That is the 2nd loadable MLX model WS-M1's NEEDS-OWNER wanted on
  this Mac. Also captured a real `RepositoryNotFoundError` (401) failure frame.
- **Format truth** (read the 0.31.3 loader): `load_model` requires
  `model*.safetensors` and there is NO GGUF path in generate/server/utils → GGUF
  cannot load; `compressed-tensors` is force-mapped to affine 4-bit, which can't
  unpack NVFP4 (`unsloth/…-NVFP4`: has safetensors, arch `qwen3_5` = SAME as the
  working model, no `mlx` tag). Classifier keys off tag+id: mlx → loads; gguf →
  cannot; nvfp4 → cannot; else → "not an MLX build". NVFP4-cannot-load is taken
  from the plan + code inspection, **NOT re-verified by a live load** (27B + the
  resident 15 GB :1337 server = OOM risk).
- **Last used:** atime IS live on this APFS volume (probe: +1 s on read; the
  working model's blob atime 02:21 > mtime 02:02 from the server's load).
  `scanModels` now captures max atime in the SAME walk that sums size; nil → "—".
- **Disk guard:** `volumeAvailableCapacityForImportantUsage` (112 GiB free now) +
  true size from the HF tree API (sum of file sizes = 273.9 MB, verified;
  `usedStorage` over-counts — 75 GB vs ~23 GB actual — rejected). The guard is a
  pure fn: block only when free < size+margin; unknown size → warn-if-low, never
  block; nil free → never block. The live BLOCK path is NOT triggerable at 112 GiB
  free — pure-tested only.

LOOP 2 (adversarial) + the full-suite self-check CAUGHT a REAL regression + bugs:

- **Keychain interaction (the big one):** the first full run failed 6 keychain/
  token tests. Proven via git-stash it was MINE, not environmental — clean HEAD
  full = green (those 6 pass), my tree = red, the 6 also pass in isolation on HEAD.
  The Huginn keychain tests carry a PRE-EXISTING parallelism sensitivity
  (concurrent securityd/SecItem under Swift-Testing parallelism → `load == nil`
  after save); a WS-M3 test that spawned a subprocess tipped it. A first patch
  (empty `cacheDir` + echo-exit wiring test) passed ONCE (196) then FAILED AGAIN
  the next run — proving the subprocess itself was the trigger, not the cache scan.
  FINAL fix: WS-M3 tests now spawn ZERO subprocesses — the download-wiring test was
  replaced by a pure `latestProgress` unit test (frame-picking covered without a
  child process). Green twice after (197 ×2). The pre-existing keychain flake is
  flagged for a future test-infra cleanup (serialize the keychain suites) — out of
  WS-M3 scope.
- quant "full precision" over-claim → "—" (nil quant also covers an unreadable
  config, so asserting full-precision would sometimes be false).
- integer-overflow traps in `downloadDiskGuard`'s margin add + `sumTreeDownloadBytes`'s
  running sum on hostile/absurd network sizes → `addingReportingOverflow`,
  clamp-and-block (matching the AC116 trap discipline).
- a force-unwrap in the atime walk → `.map`.

Publish hygiene held: `downloadProgress` dedupe-guarded, set only on a real change
in `flushJobLog` (`.download` only), reset in `startJob`, cleared in `finishJob`;
`MLXModelsSection ==` gains `downloadProgress` so only that section re-renders on a
tick. Library stays usable with `mlx.managed` OFF (only Serve is gated). No new
payload log sinks (inv. 12). `cacheDir` made an injectable init param (no test
scans the real cache).

NEEDS OWNER: (1) on-device feel of the ProgressView / detail popover / sort at
desk. (2) the free-disk BLOCK path can't be exercised here (112 GiB free) —
pure-tested only. (3) NVFP4-cannot-load is code+plan-inferred, not live-loaded
(OOM risk). (4) the pre-existing keychain-parallelism flake — WS-M3 no longer
triggers it; serialize the keychain suites in a future cleanup. Next: WS-M4 (owner
sends it — context kept, NOT started).

## 2026-07-18 (MLX overhaul): WS-M1 serve surface — DONE (AC116)

Suite 138/138 (21 new tests). Shipped: `MLXBrainCard` (model/state/uptime/RSS/
port + Eldr-backend badge; environment demoted to a chip, install card
auto-appears only when needed); one-click `makeBrain` brain swap on every cached
model row (validate → restart → wait-answering → wire backend, fail-closed with
an lsof OWNERSHIP gate — launchd bootstrap "succeeds" even when the python loses
the bind race and LM Studio answers instead); port-conflict diagnosis in plain
language on four trigger paths; first-class Reasoning (thinking) toggle emitting
`--chat-template-args` with a one-time absorb of the hand-typed extra-arg;
menu-bar Start/Stop + "MLX tab" jump (`MainWindow.openTab`); Configuration ▸
Local LLM "Managed by the MLX tab" chip. KV decision (owner, after the plan's
server-flags premise was falsified against mlx-lm 0.31.3): server got its REAL
cache knobs (`--prompt-cache-size/-bytes`), the `--kv-*` quartet went to the
Playground where it actually exists. Details: DEVIATIONS AC116.
NEEDS OWNER: (1) live acceptance — swap between two cached models while Test
Chat is up; blocked on TWO fronts: the :1337 production brain is a DETACHED
process (Huginn doesn't own it — flip "Huginn manages the model server" ON when
ready to adopt it, config port 1337), and only ONE loadable MLX model is cached
(download any small mlx-community build first). (2) On-device feel check of the
new card + menu bar. Next: WS-M2 log console.

## 2026-07-18 (tech-week): WS-C + WS-D + WS-E — DONE (AC114/AC115)

Shipped (details: DEVIATIONS AC115): C1 composer-refill fix (epoch + justSent
re-clear in ConversationView/ThreadView; regression UI test green); C2 stable
messageID in message #0 / nearby-start / roster fan-out + receiver stable-id
dedup; C3 honest send states (DeliveryRoute from the messenger, "Sending…"/
"Sent nearby"/"Sent to relay"/failed, 12-attempt retry, .relayReconnected
auto-resend); C4 approval card in its own alert-level passthrough window +
haptic + opt-in local notification + in-chat "expired" row (phone mirrors the
120 s C-1 deny); C5 tether configured at pairing ingest + consents/link/
notification toggle on the acp AI detail; C6 ONE ConversationAIContextSection
shared by Details + AI hub (duplicate pickers deleted); C7 Nearby auto-apply +
live peer count + honest prerequisites; WS-D CustomCommand chips (PQRCACP
type) in the phone terminal AND Huginn Test Chat (seeded from enabled skills,
editors in both). WS-E: DEVIATIONS AC114 (retro-records the WS-B5 gateway
merge) + AC115; AGENTS.md verified; memory updated (composer-refill-fix; C6
note in ui-ux-overload; Xcode memory already carried the corrected non-OAuth
diagnosis).
VERIFIED: all 8 packages green (Core 82 / Nostr 114 incl. chaos / Agent 84 /
ACP 267 / MCP 15 / Node 10 / ctl 10 / A2A 58); Huginn suite green; EldrChat
124/125 with the 1 red root-caused to the a11y audit racing the still-streaming
demo thread (nil-element "potentially inaccessible text"; C3's sending→sent
flip widened the window) — audit now waits for a quiet screen and passes on a
fresh sim. Full iOS suite was green on the same app build; only the TEST file
changed after, not re-run end-to-end. NEEDS OWNER (on-device/manual): composer
feel-check on hardware; approval card + notification with a live node while a
sheet is up; two-device Multipeer (radios); pairing-ingest tether flow.

## 2026-07-18 (MLX overhaul): WS-M0 perf foundation + kill-switch — DONE (AC113)

Suite 117/117 (9 new tests). Shipped: probe/serverState publish dedupe; job-log +
tailer publishes coalesced to ~4 Hz batches; `MLXView` split into six Equatable
child sections with the 300-row log windows precomputed in the service
(`serverLogWindow`/`jobLogWindow`, `jobPaneState(for:)`); `LogView` render bounded
to 300 lines; LogTailer stop/start now RESUMES instead of re-seeding (fixed a
duplicate-history-on-tab-switch bug); and the owner-requested `mlx.managed`
kill-switch — OFF stops child/launchd server, idles monitor+tailer, hands
`llmURL`/`llmModel` to the persisted external (LM Studio) pair; ON restores +
rewires + resumes (`mlx.resumeMode`). Details: DEVIATIONS AC113.
NEEDS OWNER: on-device feel check (Instruments hang-detection before/after wasn't
runnable headless) — if the tab still stutters under a real download+server flood,
WS-M0 step 4 (@Observable migration) is the sanctioned next lever. NOTE: the MLX
tab's Server section now has the "Huginn manages the model server" toggle at top;
your detached mlx server (port 1337) is untouched by this change until Huginn
takes ownership. Next workstream: WS-M1 (serve card, brain swap, menu-bar
controls, reasoning toggle, KV-cache flags).

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



3. **(carryover) Xcode registration repair** — DONE on disk 2026-07-18 pm.
   The old UUIDs in this note (54DA80FC / BC567FD8) were STALE — re-registration
   minted a new one. LIVE plist is now the ONLY real one:
   `~/Library/Developer/Xcode/CodingAssistant/ACP/EB68F751-5F32-463D-9CED-29EE59168AB5.plist`
   (BC567FD8 survives only as `.bak-ws0`, which Xcode ignores). Applied:
   `requiresAuthentication=false` added (plutil OK). Stored chat-model selection
   already points at EB68F751 (verified — the dead-UUID cause is gone). REMAINING
   USER STEP: quit Xcode-beta (running as pid 1247 at edit time) and relaunch so it
   re-reads the plist, then re-pick "Eldr" in the chat model picker.
   SECOND BLOCKER (new): the local model endpoint is DOWN — nothing on :1337 (nor
   LM Studio :1234), no mlx_lm.server process. eldr-acp env targets
   `http://127.0.0.1:1337/v1` model `Qwen3.6-27B-MLX-4bit`; auth being fixed won't
   produce replies until that server is serving again (my detached pid 77606 is gone).
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
