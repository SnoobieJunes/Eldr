// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCAgent

/// Guards the Private Cloud Compute BUILD GATE (DEVIATIONS AC125).
///
/// This suite exists because the PCC gate silently regressed twice with no test
/// to catch it: once hardcoded ON (broke stable Xcode + 3 of 5 CI jobs, AC123),
/// then as an `ELDR_PCC_SDK` environment/flag-file opt-in that Dock-launched
/// Xcode builds never inherited — so the shipped app told the owner "compiled
/// without the Private Cloud Compute SDK" on a device that fully supports it.
/// Both times the failure surfaced on a phone instead of in CI.
///
/// The gate is now the SDK's own module version — `canImport(FoundationModels,
/// _version: 2.0)` — so these tests assert the behavior CORRECT FOR WHATEVER
/// TOOLCHAIN THEY ARE COMPILED WITH. That is the point: they must stay green on
/// Xcode 26.x (where PCC genuinely cannot compile) *and* on Xcode 27+ (where it
/// must). A test that simply demanded "PCC is on" would recreate the AC123 bug.
///
/// These are compile-time/wiring assertions. They never touch the network and
/// never invoke a model — availability is read, not exercised.
@Suite("PCC build gate")
struct PCCBuildGateTests {

    /// The exact user-visible string the degraded path returns. Kept as a literal
    /// so that editing the message in the provider without updating the test is a
    /// deliberate, visible act.
    private static let noSDKReason =
        "This build was compiled against an SDK without the Private Cloud Compute API (Xcode 26 or earlier). Rebuild with Xcode 27 or later to enable it — replies use the Demo stub until then."

    // This #if MUST stay byte-identical to the provider's gate — if they drift, the
    // test compiles the wrong branch and stops guarding the thing it exists to guard.
    #if canImport(FoundationModels, _version: 2.0) && (os(iOS) || os(macOS))

        /// Built against an SDK that HAS the PCC API (Xcode 27+): the provider must
        /// never claim the SDK is missing. If someone reintroduces a manual flag and
        /// forgets to set it, or breaks the `#if`, this is the assertion that fires —
        /// in CI, not in the owner's hands. (Verified: re-gating `availabilityReason`
        /// behind an undefined `ELDR_PCC_SDK` makes this test go red.)
        ///
        /// SCOPE — read this before trusting it: this guards the BUILD GATE (is the PCC
        /// branch compiled in), NOT runtime availability. It cannot catch PCC
        /// *over-claiming* to be usable when the entitlement is unapproved or the device
        /// is ineligible — that path runs `PrivateCloudComputeLanguageModel().availability`,
        /// which is `@available(macOS 27)` and so is untestable on any machine or CI
        /// runner that exists today (all are macOS 26 / no PCC hardware). Runtime
        /// correctness needs a real iOS 27 device with the entitlement — see the honest
        /// remaining-reasons list in DEVIATIONS AC125.
        @Test func pccSDKPresent_neverReportsMissingSDK() {
            let reason = PCCFoundationModelsProvider.availabilityReason
            #expect(
                reason != Self.noSDKReason,
                """
                PCC was compiled OUT despite building against an SDK that vends the \
                PCC API. The build gate in PCCFoundationModelsProvider.swift is broken — \
                do NOT "fix" this by adding a build flag; see DEVIATIONS AC125.
                """)
        }

        /// The reasoning-level mapping is PCC-only code, so it is only compilable —
        /// and only worth asserting — on a PCC-capable SDK. Unknown and nil both fall
        /// back to `.moderate` (the documented default).
        @available(iOS 27, macOS 27, *)
        @Test func reasoningLevelMapping_defaultsToModerate() {
            #expect(PCCFoundationModelsProvider.mapReasoning("light") == .light)
            #expect(PCCFoundationModelsProvider.mapReasoning("deep") == .deep)
            #expect(PCCFoundationModelsProvider.mapReasoning("moderate") == .moderate)
            #expect(PCCFoundationModelsProvider.mapReasoning("DEEP") == .deep)
            #expect(PCCFoundationModelsProvider.mapReasoning(nil) == .moderate)
            #expect(PCCFoundationModelsProvider.mapReasoning("nonsense") == .moderate)
        }

    #elseif canImport(FoundationModels)

        /// Built against a 26.x SDK: PCC genuinely cannot compile, and the provider
        /// must degrade with the specific actionable reason (→ Demo fallback), never
        /// crash and never silently pretend to be available.
        @Test func pccSDKAbsent_degradesWithActionableReason() {
            #expect(PCCFoundationModelsProvider.availabilityReason == Self.noSDKReason)
            #expect(PCCFoundationModelsProvider.isAvailable == false)
        }

    #endif

    /// True on every toolchain: an unavailable PCC provider fails CLOSED — it throws
    /// rather than returning an empty or fabricated draft. The caller turns this into
    /// the Demo stub; it must never become a silent confidentiality downgrade
    /// (CLAUDE.md cardinal rule).
    /// NOTE: the thrown reason is deliberately NOT compared to `availabilityReason`.
    /// The entry points re-check `#available` first and throw their own (shorter)
    /// OS-version message, so the two strings legitimately differ when the SDK has
    /// the API but the host OS predates iOS/macOS 27. What matters is that it throws
    /// a typed provider error rather than yielding a draft.
    @Test func unavailablePCC_throwsRatherThanReturningAnEmptyDraft() async {
        guard PCCFoundationModelsProvider.availabilityReason != nil else {
            // PCC is genuinely available on this machine — nothing to assert about
            // the failure path; the happy path needs a device + entitlement.
            return
        }
        let provider = PCCFoundationModelsProvider()
        let context = AgentContext(myIdentityHex: "00", myDisplayName: "Me", transcript: [])
        await #expect(throws: AgentProviderError.self) {
            _ = try await provider.draftReply(context: context)
        }
    }
}
