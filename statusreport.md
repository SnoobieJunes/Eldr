# EldrChat / PQRC — End-to-End Status Report

**Date:** 2026-06-20 · **Branch:** `ACP-APP` (10 commits ahead of `origin`) · **Toolchain:** Swift 6.3.2, Xcode 26.5 (17F42)
**Scope:** full codebase audit — build/test ground truth, crypto & protocol core, the new ACP router/node, the iOS app UX/accessibility, and the Mac "Eldr node" app — plus a reconciliation of `APP-SPEC.md` against the June 18–20 work.

**Method.** Every claim is tagged by how I know it:
- **(RAN)** — I executed it and saw the output (tests, builds).
- **(READ)** — I read the exact code at the cited `file:line`.
- **(AUDIT)** — surfaced by a focused static-analysis pass; `file:line` cited, but not independently re-executed by me. Treat as high-confidence-but-unverified.

Per `CLAUDE.md`: nothing below is called "working" unless I ran it. Where I only compile-checked or read code, it says so.

---

## 0. Executive verdict

The **protocol/crypto core is in good shape** and the discipline around it is real: 379 package tests pass, and all 12 hard invariants hold in code. **The product around it is mid-flight and was committed in a non-building state.**

Three things you should act on first:

1. **The iOS app did not build as committed.** Two stacked package-manifest defects (not app-code bugs) stopped `xcodebuild` cold. The package unit tests stayed green because they build for **macOS**, so the breakage was invisible to `swift test`. I applied two config-only fixes and the app then **built clean (RAN, exit 0)**. This is the textbook case `CLAUDE.md` warns about — a feature/commit reported done that was never run on the target platform.
2. **The ACP router's safety guarantees are weaker than the plan claims.** The "fail-closed on a cancelled tool" property is an **intermittent fail-open race** (a real test caught a `write_file` executing after cancel, 1 failure in 5 runs). The in-app ACP backend **auto-grants every mutating-tool permission**, and the cloud-egress credential scrub (**G4**) is **absent** on the PQRCACP→LLM path. The identity trust boundary (C-3) itself does hold.
3. **The headline new feature is a stub presented as live.** Selecting "Mac coding harness (ACP)" with no paired node yields silent **Demo replies** with no "not connected" signal. Combined with several destructive actions (Block/Delete/Decline) that fire with **no confirmation**, the new UX has trust/data-loss gaps.

Nothing in the **crypto core** rises to Critical or High. The Critical/High items are all in the **new router, the build config, and app UX** — i.e. the June 18–20 surface that the stale spec doesn't even describe yet.

---

## 1. Build & test — ground truth (what I actually ran)

### 1.1 Package unit tests — `swift test` per package (RAN)

| Package | Result | Notes |
|---|---|---|
| PQRCCore | **67 / 67 pass** | crypto, ratchet, padding, envelope, silo key |
| PQRCNostr | **81 / 81 pass** | events, BIP-340, relay, gift wrap |
| PQRCAgent | **53 / 53 pass** | agent engine, selection policy |
| **PQRCACP** | **159 / 160 — 1 intermittent failure** | see §2.3 — `cancelRacingPermissionNeverWritesAndResolvesOnce()` |
| PQRCMCP | **15 / 15 pass** | MCP server (still shipped — see §5) |
| EldrNode | **3 / 3 pass** | brand-new standalone node |

**379 tests, all green except one intermittent race in PQRCACP.** That one test failed in the first full-suite run and **passed on 4 subsequent runs** (3× isolated + 1× full-suite). It is a genuine timing-dependent **fail-open**, not a flake to ignore — details in §2.3.

### 1.2 iOS app build — `xcodebuild build -scheme EldrChat` (RAN)

| Attempt | Destination | Result | Cause |
|---|---|---|---|
| As committed | iOS 26.5 sim | **BUILD FAILED (65)** | PQRCACP has no iOS platform floor → `AsyncStream`/`Task`/`CheckedContinuation` "only available in iOS 13.0 or newer" |
| + iOS floor only | iOS 26.5 / 27.0 | **FAILED (65/74)** | `ELDR_PCC_SDK` force-defined for iOS → references `PrivateCloudComputeLanguageModel`/`ContextOptions`, absent from **both** the 26.5 and 27.0 SDKs |
| + both fixes | iOS 26.5 sim | **BUILD SUCCEEDED (0)** | app compiles clean end-to-end |

> **I did not run the full `xcodebuild test` (UI/XCUITest) suite** — only the build. UI smoke tests, the accessibility audit, and the performance budgets are therefore **unverified**. The build success proves the app *compiles and links* for the simulator; it does not prove the screens behave.

### 1.3 Two fixes I applied (config-only, to answer "does it build")

Both are in package manifests, match the sibling packages' established pattern, and align with documented intent. I kept them because the app cannot build without them; flag if you'd rather review before keeping.

1. **`Packages/PQRCACP/Package.swift`** — added the iOS platform floor and bumped the tools version so the `.v26` enum exists:
   - `// swift-tools-version: 6.0` → `// swift-tools-version:6.2` (every sibling is `6.2`)
   - `platforms: [.macOS(.v14)]` → `platforms: [.iOS(.v26), .macOS(.v14)]`
   - *Why:* commit `0604448` ("make PQRCACP compile on iOS") guarded the node-side `Process` code but never declared an iOS deployment target, so SwiftPM linked the package into the iOS app at a pre-iOS-13 baseline.
2. **`Packages/PQRCAgent/Package.swift`** — removed `.define("ELDR_PCC_SDK", .when(platforms: [.iOS]))`.
   - *Why:* DEVIATIONS **A40** states the PCC symbols are absent even in the Xcode 27.0 seed and the path must be **OFF by default**. The manifest comment claimed "the installed Xcode-beta SDK now vends the PCC symbols," but they are absent from this Xcode's 26.5 **and** 27.0 SDKs (RAN — both builds failed identically). PCC was non-functional regardless; gating it off restores the documented state and unblocks the build. PCC can be re-enabled with an explicit `.define("ELDR_PCC_SDK")` on a toolchain whose SDK actually has the symbols.

---

## 2. Critical & High findings

### 2.1 [CRITICAL — FIXED] iOS app did not build (two stacked manifest defects) — (RAN)
Covered in §1.2/§1.3. **Root cause is config, not app code** — once fixed, the app builds clean. **Action:** keep (or re-derive) the two manifest fixes and **add the iOS app build to CI** (it currently isn't catching this — see §2.9). Re-confirm PCC's intended status: is it a real future tier (then it needs an SDK that vends the symbols + an explicit opt-in), or dead code to delete?

### 2.2 [HIGH] ACP cancel/permission is an intermittent **fail-open** — a cancelled `write_file`/`run_shell` can still execute on the node — (RAN + AUDIT)
`Packages/PQRCACP/Sources/PQRCACP/ACPAgent.swift:465` is the C-1 re-check meant to abort a mutating tool if the turn was cancelled while permission was pending. But `runACPAgent` dispatches **each inbound JSON-RPC line on its own detached `Task`** (`ACPTransport.swift:91-100`), so there is **no happens-before** between `session/cancel` setting `cancelledSessions` (`ACPAgent.swift:154-155`) and the permission grant resuming and reaching line 465. If the grant wins the scheduler, the re-check reads an empty set and `executor.run` writes the file (`ACPAgent.swift:481`).
- **Evidence (RAN):** `cancelRacingPermissionNeverWritesAndResolvesOnce()` (`ACPClientRoundTripTests.swift:288-336`) asserts the file is *never* written; it **failed once in 5 runs** (the file existed). The same `runACPAgent` driver is the production node path (`EldrNode/.../EldrNodeCore.swift:110-114`), so this is not test-only.
- **Fix:** order cancel-vs-resume — drain `session/cancel` through the actor before resuming the turn, or race the permission request against cancellation inside one actor-isolated `await`. The line-465 check is necessary but insufficient without an ordering guarantee.

### 2.3 [HIGH] In-app `acp` backend auto-grants **every** mutating-tool permission — (READ)
`App/PQRC/Engine/PersonaRuntime.swift:252-254`: the live `ACPAgentProvider` is built with `permissionHandler: { _, _ in true }`. Once the owner consents to a node, all `write_file`/`edit_file`/`run_shell` proceed with **no per-action prompt**. The code comments rationalize this ("driving the agent IS authorizing its work; the node still enforces its C-2 jail"), so it is a deliberate decision — but it means the plan's "permission prompts surface to the node owner" is **not** realized on the in-app path, and it compounds §2.2: with auto-grant, the cancel-race is the *only* remaining brake on a cancelled destructive call. **Fix:** gate auto-approval behind an explicit "allow autonomous file/shell mutation" toggle, or surface destructive tool kinds even when a node is consented.

### 2.4 [HIGH] G4 cloud-egress credential scrub is **missing** on the PQRCACP→LLM path — (READ)
The in-app remote-AI path scrubs (`PersonaRuntime.swift:393` → `CredentialRedactor.scrub`). But PQRCACP's `OpenACompatibleLLMClient.makeRequest` sends `messages` **verbatim** (`Packages/PQRCACP/Sources/PQRCACP/LLMClient.swift:253`) — no scrub anywhere on this path — and `ELDR_LLM_URL` is unvalidated (loopback by default but nothing enforces it). If a node operator points the ACP agent's LLM at a cloud endpoint, secrets pasted into a prompt egress unredacted. **Fix:** run `CredentialRedactor.scrub` on outgoing messages when the endpoint host is non-loopback, or hard-gate/warn on a non-loopback `ELDR_LLM_URL`.

### 2.5 [HIGH] "Mac coding harness (ACP)" backend is a **Demo stub presented as a working backend** — (READ)
`App/PQRC/Engine/BackendRegistry.swift:169` — `makeProvider` for the `acp` tag returns `DemoAgentProvider()` unconditionally. `PersonaRuntime.rebindRelayACPProviders` swaps in a real provider **only** when a consented node exists, else "leave the Demo stub in place" (`PersonaRuntime.swift:247`). `AISettingsView` has no `acp`-specific status line, so a user who selects the headline feature with no paired node gets **silent simulated replies** believing they are driving their Mac. **Fix:** give `acp` an explicit status ("Not connected — pair a Mac node first; replies are simulated until then") and a disabled/"coming online" visual state.

### 2.6 [HIGH] Destructive actions fire with **no confirmation** → silent, unrecoverable data loss — (READ)
None of these has a `confirmationDialog`/`.alert` (verified by grep — there are none in `MainView.swift`):
- Swipe-to-delete a conversation — `App/PQRC/Views/Conversations/MainView.swift:147-148` → `deleteConversation` (removes the conversation + all messages + threads, `AppModel.swift:542`).
- Context-menu **Block** (`MainView.swift:255-256`) and **Delete** (`:263-264`).
- **Decline** a message request (`MainView.swift:333-334`).
- **Block** in conversation details (`ConversationDetailsView.swift:111`).
A mis-tap destroys a conversation with no undo. **Fix:** gate each behind a confirmation (the app already uses this pattern correctly for wipe/firewall/MCP in `SettingsView`).

### 2.7 [HIGH] Mac node: uncommitted entitlements change enables the sandbox with **zero exceptions** — breaks all node functionality — (AUDIT)
`Apps/EldrACPConfigurator/EldrACPConfigurator.entitlements` (uncommitted working-tree change) flips `com.apple.security.app-sandbox` to `true` but declares **no** exceptions. The app's whole job — `InstallerService` writing `~/.local/bin` (`InstallerService.swift:63-75`), `ConfigurationStore` writing `~/.config/eldr-acp` (`ConfigurationStore.swift:161-170`), spawning `/bin/zsh`/the harness, Multipeer/relay networking — would be blocked at runtime, and `ConfigPaths.standard` resolves the **real** `$HOME`, not a container, so every write lands outside the sandbox and fails. **Fix:** decide deliberately — revert to unsandboxed + Developer-ID/notarization (what the deleted comment intended), **or** add the full exception set (`files.user-selected.read-write` + temporary-exceptions for the two dirs + `network.client`/`network.server`) and gate `~/.local/bin` writes behind a security-scoped bookmark. Do not ship it half-converted. *(The companion `project.pbxproj` change is benign — it just wires automatic signing with a development team.)*

---

## 3. Medium findings

### Crypto / protocol core
- **[MED] No zeroization of secret key material** — (AUDIT) `DoubleRatchet.swift` / `RatchetSnapshot.swift` / `PrekeyManager.swift`: `Data` extracted from keys (`rawData`, seeds, snapshots, transient IKM in the KDFs) is never wiped. CryptoKit zeros its own `SymmetricKey`/`SharedSecret`, but every `Data` copy lingers in the heap. Exploitation needs heap/cold-boot access, hence Medium. **Fix:** a scrub-on-deinit wrapper for extracted secret `Data`; at minimum clear transient IKM buffers and snapshot byte arrays.
- **[MED] SPEC §8.3 ⟂ NIP/code disagreement on the AEAD AD** — (AUDIT) `SPEC.md:341` defines `AD = … sender_role …`; the NIP (`NIP-XX-pqrc.md:213`) and code (`PQRCSession.swift:9-15`) use `participant_type`. Code follows the NIP (correct per the conflict order, and the stronger binding), but the SPEC text is now wrong and would make a second implementer non-interoperable. **Fix:** correct SPEC §8.3 to `participant_type`; add a test pinning the AD bytes.

### ACP router / node / transport
- **[MED] "Permission prompts surface to the node owner" is not implemented for the relay path** — (AUDIT) `ACPAgent.swift:544-561` routes the request back over the same relay to the remote driver, who answers its own prompt; there is no host-local approval seam. Safe only because C-3 makes the driver == the owner, but a compromised owner-side client self-approves with no out-of-band host confirmation. **Fix:** add a host-local confirmation (TTY/notification) for mutating tools served over the relay, or document that the gate authorizes the remote owner-driver.
- **[MED] `NearbyACPTransport` sealed channel has no replay/reorder protection** — (AUDIT) `Packages/PQRCNostr/.../NearbyACPTransport.swift:250-264`: per-line ChaChaPoly seal, but no sequence number and no AD, so a captured `fs/write_text_file` frame from the proven peer can be replayed by anyone who can inject on the link. (The relay path gets anti-replay from the Double Ratchet; this local seal has no ratchet under it.) **Fix:** thread a per-connection monotonic counter into each frame and into the AEAD AD; reject non-increasing counters.
- **[MED] Standalone `eldr-node` daemon never bootstraps the owner as a verified contact → serves no one** — (AUDIT/READ) `EldrNodeCore.serve` only forwards frames whose sender is the pinned owner; an unknown sender's frame is a `messageRequest` and is dropped (`EldrNodeCore.swift:130-134`). No `addContact`/`acceptRequest` exists in `EldrNode/Sources` (only the test harness pairs the owner). Fail-closed, so not a vuln — but the Phase-4 daemon as committed can't actually be driven. **Fix:** at startup, resolve+verify+add the `--owner` identity as a contact (or auto-accept the message-request that maps to the pinned owner).
- **[MED] `RelayACPTransport` reconstructs line order from an unauthenticated `lineId`/`seq`; overflow silently skips lines** — (AUDIT) `RelayACPTransport.swift:155-264`. Safe against outsiders under C-3, but an authorized-but-malicious sender can reorder by lying about `seq`, and a `session/update` can be force-skipped ahead of its `end_turn`. **Fix:** carry sequence inside the authenticated envelope; treat gaps as turn failure, not silent skip.

### iOS app — UX / performance / correctness
- **[MED] Per-second ticker re-renders the whole chat `body`** — (AUDIT) `ConversationView.swift:37,83-85` and `ThreadView.swift:20,81-83`: a 1 s `Timer.publish` mutates `now`, re-evaluating the entire view (incl. the `LazyVStack` message list) every second whether or not an AI window is active → battery drain + scroll jank in long chats. **Fix:** run the countdown only when a banner/invite is active, or isolate it into a small subview that owns `now`.
- **[MED] `threadMessages(_:)` is O(all messages across all conversations)** — (AUDIT) `AppModel.swift:553-555` flat-maps every conversation's messages on each call, invoked from `ThreadView`'s `ForEach`/`onChange`/`onAppear`. **Fix:** index by `threadID`, or scope the flatMap to `thread.conversationID`.
- **[MED] Reading-width cap applied to the whole screen, not just the bubbles** — (AUDIT) `ConversationView.swift:71-72`: `.frame(maxWidth: 760)` wraps the composer and banners too, so on iPad/Mac the input bar floats in a centered 760 pt island with empty gutters. **Fix:** cap only the message list; let the composer/full-width banners span.
- **[MED] "Message" from Contacts pushes a chat *inside the Settings sheet*** — (AUDIT) `ContactsView.swift:135-139`: a `NavigationLink` to `ConversationView` inside the modal Settings `NavigationStack`, disconnected from the split-view selection; "Done" dismisses the whole thing. **Fix:** dismiss Settings and set `MainView.selection` instead.
- **[MED] 60-digit safety code has no wrap/scaling guidance** — (AUDIT) `ConversationDetailsView.swift:44-46` uses `.font(.body.monospaced())` with no `lineLimit`/wrapping/`textSelection`; at large Dynamic Type or narrow widths the code (the core verification ritual) can truncate/wrap unpredictably. **Fix:** explicit wrapping monospaced layout + enable text selection.
- **[MED] `agentError` alert is model-wide, can surface on the wrong conversation** — (AUDIT) `ConversationView.swift:170-179` binds to the shared `AppModel.agentError` (`AppModel.swift:195-196`); an AI error from one chat can alert over another (notably in split view). **Fix:** scope agent errors per-conversation or clear on conversation change.
- **[MED] "PQRC" jargon leaks throughout the user-facing UI** — (READ) The home screen title is `"PQRC"` (`MainView.swift:180`; the UI test even asserts it at `PQRCUITests.swift:107`), and "PQRC" appears in the invite ShareLink, the peer-not-joined error, and the Report sheet (`MainView.swift:520-522,541`, `ConversationDetailsView.swift:218,221`). The product is "EldrChat" everywhere else. **Fix:** replace user-facing "PQRC" with "EldrChat" (and update the UI-test expectation).

### Mac node
- **[MED] `ContextGraphService` runs `pip install` + an arbitrary `install-service.sh` from a user-picked folder on one button press** — (AUDIT) `ContextGraphService.swift:90-97,135-137`: paths are correctly POSIX-quoted (no injection), but the wizard executes third-party code from a chosen directory with no "here's what will run" confirmation. **Fix:** surface the exact commands and require explicit confirmation.
- **[MED] Node config written cleartext at rest (token excepted)** — (AUDIT) `ConfigurationStore.swift:114-133`: the LLM token is correctly Keychained (C-8), but the pinned-owner identity (`owner` file — the C-3 gate target), `ELDR_LLM_URL`, and workdir are cleartext at `0600`. The `owner` file is integrity-sensitive (tampering re-targets the gate). **Fix:** store the pinned-owner hex in the Keychain alongside the identity.

---

## 4. Low / polish / tech-debt
- **[LOW] `processedWrapIDs` dedupe set is unbounded** — (AUDIT) `PQRCMessenger.swift:79,633-651`: only ever inserted, never evicted (grows only with legitimately-addressed traffic, so not attacker-inflatable). **Fix:** LRU/ring or prune by NIP-40 expiry horizon.
- **[LOW] `Padding.unpad` reads the length prefix before the `count>=4` guard** — (AUDIT) `Padding.swift:31-43`. Functionally safe (helper returns nil; input is AEAD-authenticated first) but order-fragile. **Fix:** hoist the size check.
- **[LOW] Credential redactor is duplicated and can drift** — (AUDIT) `ACPEvents.swift`/`ACPLogRedactor` re-implements `PQRCCore.CredentialRedactor` ("keep in sync") because PQRCACP is dependency-free; the node uses the duplicate. Also the entropy arm misses a 40+ char all-alphabetic secret (`ACPEvents.swift:99`). **Fix:** add an all-alpha high-length arm; add a test that diffs the two redactors.
- **[LOW] `NearbyRelayHub` authorize default is allow-all** — (AUDIT) `NearbyRelayHub.swift:121` defaults `authorize = { _ in true }` (prod overrides it, C-5 verified live). **Fix:** default deny-all.
- **[LOW] Per-session `cwd` from `session/new` relocates the C-2 jail root** — (AUDIT) `ACPAgent.swift:205`; `--workdir` is advisory, not a ceiling. Owner-authority-equivalent, not a stranger escape. **Fix:** clamp per-session `cwd` within `--workdir`, or document it as default-not-boundary.
- **[LOW] `remoteDevControlConsent` + `coding_agent` tag live in plain UserDefaults** — (AUDIT) `PersonaRuntime.swift:814-817`; not wire-reachable, but on-device file access could flip it. **Fix:** persist in the silo-sealed store.
- **[LOW] Composer `TextField` has an identifier but no `accessibilityLabel`** — (AUDIT) `ConversationView.swift:387`, `ThreadView.swift:204`. **Fix:** `.accessibilityLabel("Message")`.
- **[LOW] Deleting the last tethered AI leaves zero AIs until relaunch** — (AUDIT) `AISettingsView.swift:36-42`; primary-AI resolution then yields `nil` and AI silently goes "off". **Fix:** prevent deleting the last AI, or show an empty-state prompt.
- **[LOW] Identicon hashes synchronously in `body` for every visible row** — (AUDIT) `MainView.swift:451-475`. **Fix:** memoize by seed.
- **[LOW] `SecureEnclaveKeyWrapper.unwrap` length guard is looser than the format** — (AUDIT) `SecureEnclaveKeyWrapper.swift:46` (`> 65` vs the true ≥ 65+28+1). Cosmetic.

---

## 5. Spec vs reality — what changed and what `APP-SPEC.md` now says

`APP-SPEC.md` (last edited June 15) predates the entire June 18–20 build-out and was wrong/stale in three material ways. I have **updated it** (see the companion edit) to reflect:

1. **The ACP-router architecture (new §24a)** — EldrChat as an ACP *client*/router; selectable ACP backends via a data-driven `BackendRegistry`; `ACPAgentProvider`; the `AISelectionPolicy`/`CapabilityRoutingPolicy` routing seam; sealed `NearbyACPTransport` + relay-carried `RelayACPTransport`; the `ACPNodeHost`/`ACPRelayHost` and the standalone `eldr-node` daemon. None of this existed in the spec.
2. **Key custody (§3, §19) — corrected.** The spec described `passphrase → PBKDF2 → KEK` *deriving* the at-rest key. That model was **reverted** (DEVIATIONS **AC31**, commits KS-1…KS-4): each account's silo key is now a **random 256-bit key hardware-wrapped by the Secure Enclave**, with the passphrase an **optional second factor nested *under* the SE wrap** and otherwise only the deniable namespace selector. I rewrote §3/§19 to match `AccountVault.swift`/`SiloKey.swift`/`SecureEnclaveKeyWrapper.swift`, including the SE-availability tripwire (G3) and the honest account-*count* deniability limit (now an accepted limit, not a Phase-2 TODO).
3. **MCP is NOT removed.** The ACP plan's step 6 says "Remove MCP," but `PQRCMCP`, the in-app `LocalMCPServer`/`RuntimeSecureChatBridge`, the "Local agent access (MCP)" Settings toggle, and the PQRCMCP CI lane are **all still present and green (RAN: 15/15)**. I added a reconciliation note to §24 so the spec doesn't read as if removal happened. **Decision needed:** keep MCP alongside ACP, or actually execute the removal.

New DEVIATIONS IDs from this window, for reference: **A40** (Private Cloud Compute tier, firewall-exempt; SDK symbols absent → build-gated), **A41** (Mac Catalyst), **A42** (OpenClaw as a first-class ACP client), **A43** (contextgraph backend); **AC26–AC30** (the C-1…C-8 security fixes), **AC31** (key-storage reversal), **AC32** (per-chat firewall override), **AC33** (relay-carried ACP), **AC34** (task routing), **AC35** (standalone node). Note the easy-to-conflate collision: **A33 (per-silo namespacing) ≠ AC33 (relay-carried ACP).**

---

## 6. What's verified working (so it isn't re-litigated)

**Crypto core (AUDIT, against the 12 invariants):** all 12 hold in code — message-driven rotation with no timers, single-use message keys + `MAX_SKIP=1000` purge, `PQ_REKEY_INTERVAL=50`, bucket padding with >64 KB never inlined, timestamps never in any KDF, correct gift-wrap layering (unsigned rumor → sender seal → fresh one-time wrap key, past-only fuzz), bidirectional 10420 verification, honest `participant_type` with human-under-agent rejected, `WhenUnlockedThisDeviceOnly` non-syncable Keychain items, SE-wrapped master key with the passphrase nested under it, consumed-prekey deletion, and `privacy:.private` logging with size-metadata compiled out of Release. No custom crypto; vetted CryptoKit/swift-crypto/secp256k1 only.

**Router trust boundary (AUDIT):** the **C-3 owner-identity gate holds** — an unverified/unauthenticated peer cannot open a session, send a prompt, or trigger a tool (`EldrNodeCore`/`ACPRelayHost.routeInbound` pin `sender == ownerIdentityHex` on top of BIP-340 + both-direction binding). **C-2** path jail (symlinks resolved before the prefix check; tested for read/write/edit/list/search), **C-5** live paired-peer allowlist, **C-6** at-rest log redaction, and **C-8** Keychain token (never in the env file) are all implemented correctly. **No command injection** — `run_shell` uses an argv array with a hardcoded shell; ripgrep uses `--` before the literal; the peer can't choose the spawned binary.

**iOS app UX (AUDIT/READ), correct as built:** the no-recovery warning is unskippable (`AccountGateView` `canCreate` requires acknowledgement); the app never auto-boots (`PQRCApp.swift:192-194`); the AI-vs-human distinction survives grayscale (sparkles glyph + "⟡ name" + outline, not color alone); status copy says "Sent to relay"/"Queued"/"Not sent", never "delivered"; the `ai_window` banner shows for peers with a countdown + accessibility label; the egress-firewall state is always visible when a remote AI is active; `NavigationSplitView` is genuinely adopted with a bounded sidebar; the egress-firewall "can't turn off" bug is fixed with a documented custom binding.

---

## 7. Prioritized action plan — "what else we need to implement"

> **Progress (2026-06-20, session 2).** Done since the report: build fixes landed; Mac node **un-sandboxed** (entitlements fixed — "operation not permitted" resolved); the Agent **Inspector** + **Nearby scanner** diagnostic tools shipped in the Configurator; EldrChat Mac window made **resizable** (Catalyst enabled — A41 was documented but never applied); self-hosted AI **URL field** fixed; node **`unpair()`** now clears all identity items; the reasoning-stripper **rescues** one-pipe `<\|channel>final` answers and the agent no longer returns a silent blank. Struck-through items below are complete.
>
> **Progress (2026-06-20, session 3).** P0 security pair done: the **cancel/permission fail-open** is closed (wire-order fix, verified 50/50) and the in-app ACP **auto-grant** is replaced with a default-OFF per-node consent. **Catalyst keychain regression fixed** — account create/sign-in on Mac was broken by the AC37 Catalyst switch (legacy file keychain); `KeychainStore` now uses the data-protection keychain (compile-verified; user runtime-confirm pending). Raw-LLM-stream toggle, Mac App-Nap visibility fix, and confirmations shipped. **CI:** added EldrNode to the matrix + fixed a stale `PQRC.xcodeproj` path; the intermittent cancel-race was the likely no-retry CI failure (now deterministic).
>
> **Progress (2026-06-20, session 4).** **All remaining P1 and P2 items are done** (items 4–12 below, struck through). Verified clean integration of 7 parallel fixes: PQRCCore 67/67, PQRCNostr 83/83 (+2 replay tests), PQRCAgent 53/53, PQRCACP 160/160, PQRCMCP 15/15, EldrNode 5/5 (+2 owner-bootstrap tests); Configurator + EldrChat iOS + EldrChat Catalyst all BUILD SUCCEEDED. **Account creation on Mac:** the `kSecUseDataProtectionKeychain` flag was necessary but not sufficient on Catalyst — added the `keychain-access-groups` entitlement (`errSecMissingEntitlement`); both now present; the remaining requirement is **signing with the team** (not "Sign to Run Locally"), which is the user's runtime confirm. **MCP:** decided to KEEP (revisit at ACP parity). The only carry-over is adding the **iOS app build to CI** (the `app` job exists; the structural blocker — the flaky cancel-race in the no-retry `packages` job — is now fixed).
>
> **Progress (2026-06-21, session 5).** Ran a fresh 4-pass regression audit (crypto core / ACP router / iOS app / build-config-docs) — **core regression-free, trust boundary intact, no CRITICAL/HIGH**. Fixed the actionable findings: **secret zeroization actually wired** (it was dead code — now wipes snapshots after encryption in SwiftDataStore/PersonaRuntime/eldr-node, fold-aliasing hardened, PQXDH IKM wiped); **G4 widened** (tool-call arguments scrubbed; contextgraph loopback-gated); **build/config/doc cleanup** (killed a duplicate `NSLocalNetworkUsageDescription` shipping stale "PQRC" wording, deleted stale `PQRC.xcscheme`, dropped bogus visionOS family, fixed PCC comment + APP-SPEC §2 / CLAUDE.md / CI doc drift). Built the **Phase 2–4 scaffold** (`HarnessRegistry` + `StdioHarnessTransport` + `runACPProxy`/`runHarness` in PQRCACP, +13 tests) so adding a backend is "append a descriptor + call `runHarness`" — not yet wired to UI. Caught + fixed an iOS-only break in the scaffold (`homeDirectoryForCurrentUser`→`NSHomeDirectory()`), reinforcing the lone carry-over: **add the iOS app build to CI** (twice now `swift test`-on-macOS hid an iOS-only regression). Final state verified all-green (DEVIATIONS AC41).

**P0 — before any further feature work**
1. ~~Land the two build fixes (§1.3)~~ **✅ done** — still **add the iOS app build to CI** (TODO; `swift test` alone hid it). Decide PCC's fate (real tier needing an SDK + opt-in, or delete).
2. ~~Fix the **cancel/permission fail-open race** (§2.2)~~ **✅ done** — wire-order fix in `runACPAgent` (only `session/prompt` runs on a Task; cancel/responses inline); **verified 50/50** on the previously-flaky test.
3. ~~Replace the in-app ACP **auto-grant** (§2.3)~~ **✅ done** — mutating tools (`edit`/`execute`) fail closed unless a new per-node *"Allow autonomous file & shell changes"* consent is ON (default OFF); read tools still work.

**P1 — before exposing the ACP router to users**
4. ~~Give the `acp` backend an honest **"not connected / replies simulated"** state (§2.5)~~ **✅ done** — Settings shows an orange "Not connected — replies are simulated" until a node is consented; can't show "connected" on the Demo stub.
5. ~~Add **confirmation dialogs** to Block/Delete/Decline (§2.6)~~ **✅ done**.
6. ~~Apply the **G4 credential scrub** on the PQRCACP→LLM path (§2.4)~~ **✅ done** — scrubs message content for non-loopback (cloud) endpoints; loopback/LM Studio unaffected.
7. ~~Resolve the Mac node entitlements (§2.7)~~ **✅ done (un-sandboxed)** + ~~**bootstrap the owner contact** in the standalone daemon (§3)~~ **✅ done** — `eldr-node` accepts the pinned owner's first frame; C-3 intact (+2 tests, EldrNode 5/5).
8. ~~Add **replay/sequence protection** to `NearbyACPTransport` (§3)~~ **✅ done** — per-connection monotonic counter bound into the AEAD; replays/reorders dropped (+2 tests, PQRCNostr 83/83).

**P2 — quality, performance, polish**
9. ~~Kill the **per-second full-`body` re-render** and the O(n) `threadMessages` (§3)~~ **✅ done** — countdown isolated into child views (message list no longer re-renders each tick); `threadMessages` scoped to its own conversation.
10. ~~Sweep **"PQRC" → "EldrChat"** + iPad/Mac reading-width + Contacts-nav (§3)~~ **✅ done** — user-facing strings + UI test updated; reading width caps the bubbles only (composer/banners span); Contacts "Message" selects in the split view instead of dead-ending in the sheet.
11. ~~Crypto hygiene: **secret zeroization** + SPEC §8.3 `participant_type` (§3)~~ **✅ done** — secret `Data` zeroized after use (PQRCCore 67/67 unchanged); SPEC §8.3 corrected.
12. ~~Decide **MCP's** future relative to ACP (§5)~~ **✅ decided: KEEP** — read-only, working, green; revisit removal once the ACP router reaches parity (recorded in APP-SPEC §24 / DEVIATIONS).

**New this session (not in the original plan):** a **chat raw-LLM-stream toggle** and **Mac syncs while the window is open** (not only when focused) — both in progress.

**Suggested verification once P0–P1 land:** run the full `xcodebuild test -scheme EldrChat` (UI smoke + `performAccessibilityAudit()` + perf budgets) — none of that is verified yet — and re-run the PQRCACP suite under load several times to confirm the cancel race is closed.
