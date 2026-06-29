# TEST-PLAN.md — PQRC iOS Client v1

The test suite is a deliverable equal to the app. Every MUST in `pqrc-SPEC-v1_1.md` / `NIP-XX-pqrc.md` and every invariant in `CLAUDE.md` maps to at least one named test below. The relay is the **LocalRelaySimulator** throughout — when the real Nostr network stands up, only the `RelayTransport` implementation changes; this suite keeps running against the simulator as the protocol-conformance harness.

## 1. Frameworks & determinism

- **Swift Testing** (`@Test`, `#expect`, `#require`, suites, tags `.crypto .envelope .transport .agent .group .security .perf`) for all logic in the SPM packages.
- **XCTest** only where it is the only option: XCUITest UI tests and `measure`-based performance metrics in the App target.
- **Determinism seams (mandatory):** `RandomSource`, `NonceSource`, `Clock` are injected. Tests use `SeededRandom(seed:)` and `FixedClock`. Where CryptoKit/swift-crypto allow seed-based key construction (Curve25519/Ed25519 from 32-byte seeds; ML-KEM-768 from its FIPS-203 seed representation), vector tests derive keys from seeds. AES-GCM nonces come from `NonceSource`. **No unit test touches the network, the real clock, or system randomness.**

## 2. Frozen test vectors (`TestVectors/*.json`)

Generated once by a `--generate-vectors` test utility, then committed and asserted byte-for-byte forever after (regression lock + future cross-client interop, per the NIP's "second client required" convention). Files:

`agent_derivation.json` (identity seed → agent pub, exercising SPEC §3.2 HKDF salt/info exactly) · `binding_10420.json` (valid + 6 invalid mutations: bad cross-sig, bad outer sig, swapped keys, wrong version, missing tag, agent key mismatch) · `pqxdh_handshake.json` (full transcript: both bundles from seeds, dh1–dh3, KEM ct, SK; with and without one-time prekey; lrp fallback case) · `ratchet_chain.json` (40-message interleaved transcript with per-message keys and ciphertexts) · `pq_rekey.json` (messages 48–52 spanning the rekey boundary, root keys before/after) · `padding.json` (plaintext lengths 0, 1, 255, 256, 257, 1023, 1024, 4095, 16384, 65535, 65536 → bucket + ciphertext length) · `giftwrap.json` (rumor→seal→wrap with seeded one-time key and fixed fuzz offset).

## 3. Suite: crypto correctness (`PQRCCoreTests`)

- `agentKey_derivesPerSpec_andIsOneWay` — matches vector; agent pub ≠ identity pub; derived key cannot produce a signature verifiable under the identity key.
- `binding_verifiesBothDirections` / `binding_rejectsEachMutation` (parameterized over the 6 invalid vectors). **No key from an unverified binding is ever returned by `BindingVerifier`.**
- `pqxdh_bothSidesDeriveSameSK` (with OTP, without OTP, lrp path) · `pqxdh_skDependsOnBothLegs` — corrupt only the KEM secret → SK differs; corrupt only a DH leg → SK differs (hybrid property: breaking one leg is insufficient).
- `handshake_consumedOneTimePrekeyIsDeleted_andReuseRejected` — second handshake referencing the same `otp_used` fails; lrp fallback succeeds and is flagged.
- `prekeySignatures_verifyAgainstBinding` / reject when signed by a different identity key.

## 4. Suite: ratchet, FS, PCS (`.crypto`)

- `ratchet_interleavedConversation_matchesVectors` (40 msgs, alternating, with DH ratchet steps).
- `forwardSecrecy_oldCiphertextsUndecryptableAfterAdvance` — snapshot is *not* kept: after sending/receiving, assert message keys are erased from session state and persisted blobs; re-feeding earlier ciphertext into current state fails.
- `postCompromiseSecurity_snapshotCannotReadFuture` — clone full session state (simulated compromise), continue the live conversation one round-trip, prove the clone cannot decrypt anything after the DH ratchet step.
- `pqRekey_firesAtExactly50_rotatesRoot_andHealsQuantumCompromise` — clone state, advance past message 50, assert clone (even granted "broken X25519" = handed all DH outputs) cannot derive post-rekey keys without the new KEM secret; rekey KEM ct present in header at the boundary and absent elsewhere.
- `skippedKeys_decryptOutOfOrderWithinMaxSkip` (reorder window up to 1000) · `skippedKeys_beyond1000Rejected` · `skippedKeys_deletedAfterUse`.
- `noTimers_keyScheduleHasNoClockDependency` — compile-time/API check: ratchet & rekey modules take no `Clock`; mutate `FixedClock` wildly mid-conversation and assert zero effect on key schedule.

## 5. Suite: envelope, padding, metadata (`.envelope`)

- `padding_roundTripsAllBoundaryLengths` (vector-driven) · `padding_over64KBInlineThrows` · `ciphertextLengths_collapseToBucketSet` — for 500 random plaintexts ≤ 64 KB, the set of ciphertext sizes equals exactly {bucket + AEAD overhead}.
- `ad_bindsContext` — tamper each AD component (`pqrc_version`, `participant_type`, `n`, fuzzed timestamp) → decryption fails; matching AD succeeds.
- `fuzz_timestampWithinTwoDaysPast_neverFuture` (property test, 10k samples) · `fuzz_sameValueUsedInADandWrap`.
- `giftwrap_outerKeyIsFreshPerMessage` — 1000 wraps → 1000 distinct outer pubkeys, none equal to the sender's npub. · `giftwrap_relayVisibleSurfaceLeaksNothing` — outer event contains only kind 1059, fuzzed time, recipient `p` tag, random pubkey; serialized outer JSON contains no sender pubkey, no plaintext canary. · `rumor_isUnsigned` · `seal_signedBySenderNostrKey_verifies` · `wrap_unwrap_unseal_roundTrip`.
- `wire_fieldNamesMatchNIPExactly` (Codable golden files) · `wire_unknownFieldsIgnoredNotFatal`.

## 6. Suite: agent integrity (`.agent`)

- `participantType_agentSignature_requiresAgentLabel` — agent-bound seal + `"human"` label → rejected, protocol-violation event emitted (UI test asserts the red system row).
- `aiWindow_onlyHumanIdentitySignatureAccepted` — agent-signed or third-party-signed window rejected.
- `aiWindow_expiryFailsClosed` — autonomous send at `active_until + 1s` throws; at `−1s` succeeds.
- `silentByDefault_noAutonomousSendWithoutWindowOrInvite` — MockAgentProvider eagerly returns turns; engine emits nothing.
- `aiInvite_threadScoped_perHumanGating` — Alice invites her AI: Alice-AI may post in that thread only; Bob-AI stays silent; neither posts in the parent conversation.
- `recordingGuarantee_allAgentOutputIsThreadMessages` — provider handed side-context emits it only through returned messages; engine API has no other sink (assert via spy transport: every agent-originated envelope decrypts to a thread-tagged rumor).
- `loopGuard_pausesAfterSixConsecutiveAgentTurns` and resumes after a human message.
- `draftFlow_editAndSendAsMe_isHumanSigned` vs `sendAsMyAI_isAgentSignedAndLabeled`.

## 7. Suite: transport simulation (`.transport`) — the local Nostr stand-in

- `simulator_storeAndForward_offlineRecipientReceivesOnConnect`.
- `auth_kind1059ServedOnlyToPTaggedAuthedRecipient` — unauthenticated and wrong-key clients get nothing.
- `replaceableEvents_latest10420_10421_10050Win`.
- `dedupe_duplicateEnvelopeStoredOnce` · `replay_oldEnvelopeRejected`.
- **Chaos matrix** (parameterized): latency jitter {0, 0–2 s} × drop {0, 10 %} × duplicate {0, 10 %} × reorder window {0, 5} over a 200-message conversation with outbox retry → all messages eventually delivered exactly once, ratchet converged, no quarantines beyond injected drops.
- `multiRelay_oneHealthyRelaySuffices` — publish to two simulators, kill one.
- `blossom_blobRoundTrip_sha256Verified_mirrorFallback` · `relayEnvelope_constantSizeRegardlessOfBlobSize`.
- `swapPoint_transportConformanceSuite` — the whole suite above runs against any `RelayTransport`; document that pointing it at the real network later is the acceptance gate.

## 8. Suite: groups (`.group`)

- `group_fanOut_allMembersDecryptSameMessage` (N = 4) · `group_pairwiseSessionsIndependent` — compromising one member's session exposes only that pairwise link.
- `roster_addMemberSeesNothingPrior` · `roster_removedMemberStopsReceiving` · `roster_inconsistentRosterSurfacedAsAsserted`.

## 9. Suite: security & privacy regression (`.security`)

- `atRest_noPlaintextInStoreFiles` — write canary messages, flush, scan raw SQLite/WAL/SHM bytes for canary → absent.
- `keychain_attributesAreThisDeviceOnlyWhenUnlocked` (SecItemCopyMatching in the test host).
- `logs_noPayloadLeakage` — capture OSLog during a full send/receive; canary absent.
- `blocked_senderDroppedPostUnseal_noUITrace`.
- `wipeIdentity_destroysKeysAndStore` — post-wipe, Keychain queries fail and store is unreadable.
- `tamper_flippedCiphertextByteFailsCleanly_sessionSurvives`.

## 10. Suite: app & UI (XCUITest, Local Universe)

`onboarding_generatesIdentityAndPublishesBundle` · `roundTrip_aliceToBob_throughSimulator` · `aiDraft_previewThenSendAsAI_rendersAgentBubble` · `aiWindow_bannerAppearsForPeer_andExpires` · `thread_inviteBothAIs_exchangeRecorded_counterVisible` · `largePaste_200KB_becomesChip_sendsViaBlobPath_uiResponsive` · `group_of4_sendReceive` · `messageRequest_unknownSenderGatedUntilAccepted` · `safetyCodeChange_warningBannerAppears` · `accessibilityAudit_allPrimaryScreens` (`performAccessibilityAudit()`).

## 11. Suite: performance (XCTest `measure` + XCTMetric)

Wired to APP-SPEC §12 budgets: launch (`XCTApplicationLaunchMetric`), send-pipeline and 64 KB-inline clock metrics, 1 MB paste blob path, 10k-message scroll (`XCTOSSignpostMetric` hitch ratio), 500-envelope drain, memory metric. **First CI run records baselines; later runs fail on > 10 % regression.** Absolute budgets are asserted as soft warnings on simulators (hardware-honest numbers come from device runs noted in DEMO.md).

## 12. CI stub

`.github/workflows/ci.yml`: macOS runner with Xcode 26 selected via `xcode-select` (adjust the runner image label to whatever currently hosts Xcode 26); jobs: `swift test` per package (parallel) → `xcodebuild test` (app + UI) → perf job non-blocking with baseline artifact upload. Cache SPM. Fail the build on any `.security`-tagged failure regardless of retry policy. **Add the two new packages to the per-package matrix:** `PQRCMCP` and `PQRCACP` (both headless, network-free — see §13).

## 13. Coverage added after the original v1 cut

Tests landed alongside the post-v1 features (DEVIATIONS A20–A36). The framework, determinism, and "no unit test touches the network/real clock" rules in §1 still hold. Grounded in the actual suites:

- **Deniable silos (A23–A26, A33)** — `App/PQRCTests/SiloKeyTests.swift`: `deterministic_samePassphraseSameSilo`, `differentPassphrase_differentSiloAndKey`, `sealOpen_roundTrips_onlyWithTheRightKey` (the KEK derivation + per-silo seal/open). The launch lock screen / Face-ID-first path is covered app-side (account-gate tests + the `--uitest-biometric` DEBUG harness, A24/b0f7a9f).
- **Multi-AI behavior (A20–A21, A28, A30)** — `App/PQRCTests/MultiAIBehaviorTests.swift` (15 cases): solo-AI chat replies without a window, the per-conversation context override, marked-only default context, and the gate staying intact for conversations with other humans (the AgentIntegrity suite §6 is unchanged and still green for the human-present case).
- **Agent-to-agent skills (A32)** — `Packages/PQRCAgent/.../AgentSkillsTests.swift`: `catalog_hasTheTwentySkills`, `baseInjection_carriesGuardrailsAndScope`, `threadSystemPrompt_injectsPinnedSkillAndInstructions`, `threadSystemPrompt_noSkills_keepsGuardrailsAndPASS`; plus an app test that a pinned skill reaches the AI's thread-turn context.
- **Reasoning-trace stripping + new backends (A30, A34)** — `Packages/PQRCAgent/.../APIProviderTests.swift`: `strippingReasoningTrace_removesThinkBlocks`, `strippingReasoningTrace_handlesChannelFormat`, plus backend-config guards (`openRouter_emptyKey_throwsNotConfigured`, `custom_missingURL_isUnavailable_notNotConfigured`, `custom_endpoint_buildsChatCompletionsURL`, `remoteProviders_emptyKey_allThrowNotConfigured`).
- **Device-hosted relay hub (A31)** — `Packages/PQRCNostr/.../NearbyRelayHubTests.swift` (~7 cases) over `LocalLinkSimulator`: AUTH-gated kind-1059 forwarding (host sees ciphertext only), the opt-in `ai_request`/`ai_response` path, reconnect. The MC radio adapter itself is hardware-only (T11).
- **MCP server protocol (A35)** — `Packages/PQRCMCP/.../MCPServerTests.swift` (9): `initialize_returnsProtocolCapabilitiesAndServerInfo`, `toolsList_isReadOnly_noWriteTools` (the read-only-by-construction guarantee), `toolsCall_readConversation_returnsCodenamesNotIdentities` (firewall-redacted output), `toolsCall_missingRequiredArg_isInvalidParams`, `resources_listAndRead`, plus a full stdio handshake.
- **ACP agent (A36)** — `Packages/PQRCACP/Tests/` (~35 across `ACPAgentTests` + `UnitTests`): handshake, streamed `agent_message_chunk` + `stopReason`, a `read_file` tool round-trip to `tool_call_update: completed`, cancel, the bidirectional outbound-request correlation, and the vendored `strippingReasoningTrace`. Network-free via a mock LLM (`ELDR_ACP_FAKE_LLM=1`).

- **Session 2–4 hardening (AC36–AC40)** — `Packages/PQRCNostr/.../NearbyACPTransportTests.swift`: a replayed/reordered sealed frame from the proven peer is dropped and the channel survives. `Packages/EldrNode/.../EldrNodeServeTests.swift`: the node bootstraps the pinned owner from a message-request and the owner then drives a full ACP turn; a non-owner / accept-failure is rejected (C-3 stays the sole authorizer). `Packages/PQRCACP/.../ACPClientRoundTripTests.swift`: the cancel-vs-permission turn is now deterministic (hammered 50/50). The Phase 2–4 scaffold added `ACPProxyTests.swift` + `StdioHarnessTransportTests.swift` (`runACPProxy` bridges both directions + clean shutdown; `StdioHarnessTransport` stdio round-trip / child-exit / spawn-failure; `HarnessRegistry` contents). Live counts after this work: PQRCCore 67, PQRCNostr 83, PQRCAgent 53, PQRCACP 173, PQRCMCP 15, EldrNode 5 (zeroization changed no derived bytes); Configurator + EldrChat iOS + EldrChat Catalyst all build clean.

- **Encrypted Mac-AI memory + gateway (AC69–AC73, 2026-07-03)** — `Apps/Huginn/Tests/ConversationMemoryTests.swift` (8): encrypted-transcript round-trip/order, per-conversation isolation, on-disk canary (`nothingPlaintextOrIdOnDisk`), torn-line recovery, byte-cap/most-recent, bounded trim, `wipeRemovesTranscript`. `Packages/PQRCACP/.../ACPMetadataCryptoTests.swift` + `ACPMetadataSinkTests.swift` (15): sealed-vs-plaintext distinguishable, wrong/corrupt/short-key fail-closed, 32-byte env parse/reject, legacy passthrough. `Packages/PQRCCore/.../EncryptedStoreDeriveKeyTests.swift` (4): label/master independence, determinism. `Apps/Huginn/Tests/GatewayHandshakeTests.swift` + `GatewayReplyTests.swift` (8): the corrected `connect`/`chat.send`/event-stream framing; `Packages/EldrNode/.../SybilclawGatewayFramingTests.swift` (3, added 2026-07-03): pins the node copy's handshake to the same spec (anti-drift, AC73). `Packages/PQRCAgent/.../AISelectionPolicyTests.swift` + `AgentContextGrantTests.swift`: roster/critique/capability routing + human/ai grant-axis separation. `Packages/PQRCCore/.../ContextSharingWireTests.swift` (8): axis-field wire round-trip + older-client tolerance. Latest local run (2026-07-03, Xcode 27 beta): PQRCCore 82, PQRCNostr 99, PQRCAgent 83, PQRCACP 218, EldrNode 11 all green; Huginn/EldrChat build clean.
- **Known pre-existing reds (environmental / stale — NOT from the memory work above):** (1) `Apps/Huginn/Tests/ConfigStoreTests.swift::LLMTokenAtRestTests` (2 cases) fail under headless `xcodebuild test` — they write the real macOS Keychain, which the unsigned test host can't access; they pass on hardware. (2) `App/PQRCTests/BackendRegistryTests.swift::perAIKeyAccount_matchesLegacyRule` — the `acp` backend now has `usesPerAIKey:false` (correct: Mac-Tethered-AI carries no API key) yet the legacy-rule test still expects `acp` in the key-account set; the test is stale after the per-AI-hub registry refactor (or the registry dropped acp's account by mistake — owner to confirm which). Both were verified to fail identically on the clean pre-review tree.

**Remaining gaps / honest notes:**
- The MCP **in-app `PersonaRuntime` bridge** (A35 Phase 2) now **ships**: `RuntimeSecureChatBridge` + `LocalMCPServer` (loopback Unix socket, first-line pairing-token gate, OFF-by-default toggle, stops-on-lock). The committed package suite still covers only the demo bridge + protocol layer; the in-app surface should grow tests for (a) `LocalMCPServer` token enforcement — a bad/missing first line is dropped before any method runs, constant-time compare; (b) the redaction accessors (`PersonaRuntime.mcpMessages`/`mcpSearch`/`mcpContextPreview`) emitting **codenames + ≤64 KB** *unconditionally* (not gated on the per-AI firewall toggle); (c) `lockSilo()`/toggle-off tearing the server down and the bridge fail-closing (weak `AppModel` gone ⇒ empty). The ACP **end-to-end run from Xcode 27** is exercised separately; the committed coverage is the headless suite (A36) — worth adding a case that `write_file`/`run_shell` call `session/request_permission` and honor a denial.
- **Display-only chat color (A-PartyColor)** — `PartyColor` is pure value math (deterministic FNV-1a hue from identity hex, no state, nothing on the wire). A unit test should assert determinism (same hex ⇒ same color across runs) and white-on-solid WCAG contrast; it never affects redaction.
- **Per-silo UI prefs (A33)** — `MutedConversations` and any new `UserDefaults` are namespaced via `AppSession.siloDefaultsKey` (siloID-suffixed); a test should assert one silo's muted/relay/etc. keys are invisible to another silo, and that only non-secret IDs (not keys/passphrases) ever land in `UserDefaults`.
- Hardware-only paths remain untested in CI: the Multipeer radio adapters for both direct-Nearby (T11) and the relay hub, and the live self-hosted/LM-Studio integrations (verified manually, noted in A30/A34).
- Performance budgets (§11) still reference the `ptr`/blob path for the 1 MB case; the shipped large-text path is relay **chunking** (N26/A25) and is covered functionally by `ChunkingTests` (size-budget + escape-heavy bucket fit), not yet by a perf budget.
- The frozen vectors (§2) were regenerated pre-freeze for the NIP-40 expiration tag (A22) and deferred-fold rekey semantics (N6); they remain byte-frozen now.

---

## 14. Live bring-up & manual end-to-end test (phone ↔ Mac node ↔ LLM ↔ Xcode) + troubleshooting

This section is the **manual runbook** for the ACP-router stack — the part the headless
suites above can't cover (real radios, real relay, real LLM, real Xcode). Use it to
stand the system up and to self-diagnose when a piece goes dark. Added 2026-06-20.

### 14.0 Topology — know what runs where

```
 iPhone: EldrChat ──┐                                   ┌── Xcode-beta (ACP client)
 (client + router)  │                                   │     spawns ~/.local/bin/eldr-acp-xcode
                    ▼                                    ▼
            wss://relay.lerants.com  ◀──E2EE──▶  Mac: EldrACPConfigurator (the "Eldr node")
            (khatru, NIP-42 AUTH)                      ├─ messaging node (PQRC identity, relay)
                    ▲                                   ├─ ACP host (drives a harness)
 Mac: EldrChat ─────┘                                   └─ LLM: LM Studio  http://127.0.0.1:1337/v1
 (Catalyst, optional second client)
```

Two **separate** ACP paths — don't conflate them when debugging:
- **Path A — eldr-acp *in Xcode*** (DEVIATIONS A36): Xcode-beta spawns `eldr-acp` over
  stdio so your LM-Studio model pilots Xcode. This is the "agent icon in Xcode" path.
- **Path B — EldrChat *router*** (AC33–AC35): the phone drives the Mac node's harness
  over the relay. This is the chat/messaging path. The relay matters here, **not** for Path A.

### 14.1 Pre-flight (verify each layer in isolation, bottom-up)

1. **Relay reachable?** `curl -s -H "Accept: application/nostr+json" https://relay.lerants.com`
   → must return the NIP-11 JSON (`"name":"PQRC Anchor Relay"`, `supported_nips` incl. 42).
   If this fails, the relay/DNS/TLS is the problem — nothing client-side will help.
   (Confirmed UP on 2026-06-20.)
2. **LLM reachable?** `curl -s http://127.0.0.1:1337/v1/models` → must list your loaded model.
   Empty/refused ⇒ LM Studio isn't serving; start its server + load a model. Prefer an
   **instruct** model with tool/function-calling, not a reasoning model (A37).
3. **Agent binary smoke test (Path A, no model needed):**
   `ELDR_ACP_FAKE_LLM=1 ~/.local/bin/eldr-acp-xcode` then paste an `initialize` JSON-RPC
   line — it must reply immediately. No reply ⇒ launcher/env/path problem.

### 14.2 Observability — stop flying blind

The planned in-app Agent Inspector / Nearby scanner are **not built yet**, so use the OS log
and the agent log file. Run these in a terminal *while* you reproduce a problem:

```bash
# The Mac node (Configurator): relay connect/AUTH, pairing, ACP host
log stream --level debug --predicate 'subsystem == "chat.eldr"'
# EldrChat (iOS app on Mac/Catalyst, or via `xcrun simctl spawn booted log stream` on a sim)
log stream --level debug --predicate 'subsystem == "chat.pqrc"'
# The ACP agent's own stderr (tool calls, LLM errors, finish_reason):
tail -f ~/.config/eldr-acp/eldr-acp.log
# Opt-in structured ACP event log (set in ~/.config/eldr-acp/env, then restart):
#   ELDR_ACP_EVENTS_FILE=~/.config/eldr-acp/events.jsonl
tail -f ~/.config/eldr-acp/events.jsonl
```

What to look for: a relay session is healthy when you see connect → `["AUTH",challenge]`
→ our signed `AUTH` → `["OK",...]` → `REQ`/`EOSE`. **No AUTH line = the node never loaded
its identity** (see 14.4) and the relay will not serve it kind-1059.

### 14.3 Bring-up sequence (the order that works)

1. Open **`Eldr.xcworkspace`** (root) in Xcode — both apps build from here (one shared
   package graph). Run **EldrACPConfigurator**.
2. In the Configurator wizard: set LLM URL `http://127.0.0.1:1337/v1`, **Test** (must go
   green), **Install** the agent + launcher.
3. **Path A (Xcode agent icon):** in **Xcode-beta ▸ Settings ▸ Intelligence ▸ Add an Agent**,
   Name `Eldr`, Executable `/Users/<you>/.local/bin/eldr-acp-xcode`, no interpreter/args,
   **Add**. The agent only appears in **Xcode-beta** (the toolchain with the beta SDK),
   not stable Xcode — that is why "I don't see the icon" usually means it was added to the
   wrong Xcode or not at all. The Configurator writes the *launcher*; the **Add an Agent**
   step in Xcode is still manual (Xcode exposes no API to register it).
4. **Path B (phone ↔ Mac):** start the node (pairing screen shows a QR). On the phone,
   EldrChat ▸ scan the QR ▸ accept the request. **Both** the phone and the Mac node must
   list the **same** relay (`wss://relay.lerants.com`) in Settings ▸ Servers — a relay
   mismatch is the #1 "messages don't arrive" cause after AUTH.
5. Send a message phone→Mac; it should appear in the node's conversation within a few
   seconds. Watch both `log stream`s if it doesn't.

### 14.4 Troubleshooting by symptom (what we hit on 2026-06-20)

- **5 Keychain prompts → you hit Deny → relay "broke," test chat empty.**
  Root cause: the node reads ~5 Keychain items at startup (`bridge-nostr-identity`,
  `bridge-pqrc-identity-seed`, `bridge-identity-dh`, `bridge-prekey-state`, plus
  `llm-token`). On macOS, when the app's **code signature changes** (a rebuild, a new
  `DEVELOPMENT_TEAM`, or changed entitlements — all of which happened), the legacy
  Keychain prompts once per item because the old ACL no longer matches the new binary.
  **Deny → the identity load returns nil → the messaging node never starts → no relay
  AUTH → no messages.** The LLM still works because that path injects the token directly.
  **Fix:** on each prompt click **Always Allow** (adds the new binary to the item's ACL,
  permanently). If it's wedged, reset and re-pair:
  ```bash
  for a in bridge-nostr-identity bridge-pqrc-identity-seed bridge-identity-dh bridge-prekey-state; do
    security delete-generic-password -s 'chat.eldr.acp.configurator' -a "$a" 2>/dev/null
  done
  # then Unpair in the Configurator and pair the phone again (see 14.3 step 4)
  ```
  Stale `llm-token` nagging with LM Studio (no token needed)? Remove it:
  `security delete-generic-password -s 'chat.eldr.acp.configurator' -a 'llm-token'`.
  *Durable code fix (recommended, not yet applied): store node Keychain items in the
  data-protection keychain (`kSecUseDataProtectionKeychain: true`), keyed to the team's
  access group — stable across rebuilds, never prompts. Tradeoff: the launcher's
  `security` CLI read of `llm-token` would need the same change.*

- **Messages from the phone never show on the Mac (relay).** Walk the ladder: (1) relay
  up? (14.1.1 — it is). (2) node AUTHed? (14.2 — look for the AUTH line; if absent, it's
  the Keychain-deny above). (3) same relay on both ends? (14.3 step 4). (4) handshake
  done? You can only message a peer after pairing + the 10420/10421 exchange — if you
  unpaired mid-session, re-pair cleanly (the unpair now clears all four identity items;
  before 2026-06-20 it left three behind, so an old re-pair could be half-stale).
  **(5) Mac receiver suspended?** A Catalyst app that loses focus is App-Napped by the OS —
  `[app<chat.eldr.app>] Suspending task` in Console — which freezes its relay WebSocket and
  stops inbound delivery. AC37 added a Mac-only `ProcessInfo.beginActivity` assertion held for
  the socket's life, so a **visible** EldrChat window keeps receiving even when not frontmost.
  A **minimized/hidden** window can still be backgrounded by the OS — keep the window visible.

- **Agent makes tool calls but not visible in Xcode's ACP.** That's Path A vs the
  Configurator's *in-app* test chat (which drives the agent directly). The agent working
  in the Configurator proves the binary/LLM are fine; to get the Xcode icon do 14.3 step 3
  **in Xcode-beta**.

- **LLM stops responding / model "went away" / test chat stops recording.** Check
  `~/.config/eldr-acp/eldr-acp.log` and the **LM Studio server log** together. Usual
  causes: LM Studio unloaded the model (idle TTL) — reload it; context flooded (a big
  `read_file`/`xcodebuild` dump pushed out the system prompt) — lower the context-budget
  knobs in `~/.config/eldr-acp/env` (A37); or a reasoning model emitted only a scratchpad —
  switch to an instruct model. If the test chat froze right after a Keychain Deny, it's the
  identity-load failure above, not the LLM.

- **"Operation not permitted" connecting to the LLM (macOS).** The Configurator must be
  **unsandboxed** (a sandboxed app with no `network.client` EPERMs every socket). Verify:
  `codesign -d --entitlements - "$(mdfind -name EldrACPConfigurator.app | head -1)"` must
  show `app-sandbox = false`. (Fixed 2026-06-20; see DEVIATIONS AC36 / statusreport §2.7.)

- **"Operation not permitted" connecting to the LLM (iOS, real device).** Needs
  `NSLocalNetworkUsageDescription` (added 2026-06-20) **and** the Local Network permission
  granted on the device (Settings ▸ EldrChat ▸ Local Network). A plaintext `http://` LAN
  LLM also relies on `NSAllowsLocalNetworking` (present).

### 14.5 What to automate next (close the manual gaps)
- A `make doctor` / diagnostic command that runs 14.1 + the AUTH-line check and prints a
  green/red ladder, so bring-up isn't a manual log hunt.
- ✅ **SHIPPED (2026-06-20, AC37):** the **Agent Inspector** (Configurator → *Inspector* tab —
  live LLM round-trips with latency + request summary, tool calls, node/relay events, and an
  explicit red **"EMPTY answer — reasoning-only"** flag) and the **Nearby scanner**
  (Configurator → *Nearby* tab, `NWBrowser` Bonjour scan of `_eldr-acp`/`_pqrc-relay`/`_pqrc-local`)
  — they replace most of 14.2. Also shipped: a Test Chat **"Raw LLM stream"** toggle (a
  collapsible `DisclosureGroup`, OFF by default) showing the model's **pre-strip** output, so a
  reasoning model's `<|channel>thought…` is visible when you need it; and a Mac **App-Nap
  assertion** (`ProcessInfo.beginActivity`, Catalyst-only, held for the relay socket's life) so a
  visible-but-unfocused EldrChat window keeps receiving (fixes the 14.4 suspend item below for
  the visible-window case — a *minimized/hidden* window can still be backgrounded by the OS).
- A headless **relay round-trip** integration test (gated, opt-in like T9): publish a
  gift-wrap to `relay.lerants.com` as identity A, AUTH as B, confirm delivery — catches an
  AUTH/relay regression the in-memory `LocalRelaySimulator` (§7) can't.
