// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import EldrChat

/// The Apple Private Cloud Compute tier (A40): off-device + consent-gated, but
/// EXEMPT from the name-redaction egress firewall. These pin the classifier
/// decoupling so a future edit can't silently re-couple consent and firewall.
@Suite("PCC tier classification")
struct PCCTierTests {

    @Test func pcc_isRemoteAndRequiresConsent() {
        #expect(ConfiguredAI.isRemote("pcc"))
        #expect(ConfiguredAI.requiresConsent("pcc"))
    }

    @Test func pcc_isExemptFromEgressFirewall() {
        // The whole point of the Apple PCC tier: off-device, but NOT firewalled.
        #expect(ConfiguredAI.appliesEgressFirewall("pcc") == false)
    }

    @Test func thirdPartyVendors_stayFirewalled() {
        for kind in ["claude", "openai", "gemini", "openrouter", "groq", "custom", "hub"] {
            #expect(ConfiguredAI.isRemote(kind), "\(kind) should be off-device")
            #expect(ConfiguredAI.appliesEgressFirewall(kind), "\(kind) should be firewalled")
        }
    }

    @Test func onDeviceTiers_areNeitherRemoteNorFirewalled() {
        for kind in ["ondevice", "demo"] {
            #expect(ConfiguredAI.isRemote(kind) == false)
            #expect(ConfiguredAI.appliesEgressFirewall(kind) == false)
        }
    }

    @Test func pcc_needsNoAPIKeyAccount() {
        let pcc = ConfiguredAI(id: "x", name: "n", kind: "pcc")
        #expect(pcc.apiKeyAccount == nil)
    }

    @Test func reasoning_defaultsToModerate() {
        let pcc = ConfiguredAI(id: "x", name: "n", kind: "pcc")
        #expect(pcc.effectiveReasoning == "moderate")
        let deep = ConfiguredAI(id: "y", name: "n", kind: "pcc", reasoningLevel: "deep")
        #expect(deep.effectiveReasoning == "deep")
    }
}
