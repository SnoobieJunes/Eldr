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

`onboarding_generatesIdentityAndPublishesBundle` · `roundTrip_aliceToBob_throughSimulator` · `aiDraft_previewThenSendAsAI_rendersAgentBubble` · `aiWindow_bannerAppearsForPeer_andExpires` · `thread_createInviteBothAIs_exchangeRecorded_loopGuardVisible` · `largePaste_200KB_becomesChip_sendsViaBlobPath_uiResponsive` · `group_of4_sendReceive` · `messageRequest_unknownSenderGatedUntilAccepted` · `safetyCodeChange_warningBannerAppears` · `accessibilityAudit_allPrimaryScreens` (`performAccessibilityAudit()`).

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

**Remaining gaps / honest notes:**
- The MCP **in-app `PersonaRuntime` bridge** (Phase 2) and its consent gate are **not yet built**, so only the demo bridge + protocol layer are tested (A35). The ACP **end-to-end run from Xcode 27** is being exercised in a separate worktree; the committed coverage is the headless suite (A36).
- Hardware-only paths remain untested in CI: the Multipeer radio adapters for both direct-Nearby (T11) and the relay hub, and the live self-hosted/LM-Studio integrations (verified manually, noted in A30/A34).
- Performance budgets (§11) still reference the `ptr`/blob path for the 1 MB case; the shipped large-text path is relay **chunking** (N26/A25) and is covered functionally by `ChunkingTests` (size-budget + escape-heavy bucket fit), not yet by a perf budget.
- The frozen vectors (§2) were regenerated pre-freeze for the NIP-40 expiration tag (A22) and deferred-fold rekey semantics (N6); they remain byte-frozen now.
