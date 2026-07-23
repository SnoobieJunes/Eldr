// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import ConduitProvisioner

/// Tests for `eldrctl found-town` (GOOSEWORLD §6 WS-G6). Pure, headless string/shape
/// assertions — the same style as `ConduitProvisionerTests` (`validateRejectsBadOwner`,
/// `installScriptHasTheRequiredShapeAndNoSecret`, `runbookCoversTheKeySteps`). No SSH, no
/// host, no network.

private func validTownConfig() -> FoundTownProvisioner.Config {
    FoundTownProvisioner.Config(
        ownerHex: String(repeating: "a", count: 64),
        hubURL: "wss://relay.lerants.com",
        gooseProvider: "ollama")
}

// MARK: - validate()

@Test func townValidateAcceptsAGoodConfig() throws {
    try FoundTownProvisioner(config: validTownConfig()).validate()
}

@Test func townValidateRejectsBadOwner() {
    // A bad owner bubbles up from the reused conduit validator (found-town rejects exactly
    // what `install` does).
    var short = validTownConfig(); short.ownerHex = "abc"
    #expect(throws: ConduitProvisioner.ValidationError.invalidOwner("abc")) {
        try FoundTownProvisioner(config: short).validate()
    }
    var nonHex = validTownConfig(); nonHex.ownerHex = String(repeating: "z", count: 64)
    #expect(throws: (any Error).self) { try FoundTownProvisioner(config: nonHex).validate() }

    var empty = validTownConfig(); empty.ownerHex = "  "
    #expect(throws: ConduitProvisioner.ValidationError.emptyOwner) {
        try FoundTownProvisioner(config: empty).validate()
    }
}

@Test func townValidateRejectsBadHubAndProvider() {
    // Wrong scheme is caught by the conduit relay validator first (hub == relay).
    var wrongScheme = validTownConfig(); wrongScheme.hubURL = "https://relay.example.com"
    #expect(throws: (any Error).self) { try FoundTownProvisioner(config: wrongScheme).validate() }

    // A prefix-valid but metacharacter-carrying hub is caught by found-town's stricter check.
    var injectHub = validTownConfig(); injectHub.hubURL = "wss://relay.example.com/$(id)"
    #expect(throws: FoundTownProvisioner.ValidationError.self) {
        try FoundTownProvisioner(config: injectHub).validate()
    }

    var spaceHub = validTownConfig(); spaceHub.hubURL = "wss://relay a.com"
    #expect(throws: FoundTownProvisioner.ValidationError.self) {
        try FoundTownProvisioner(config: spaceHub).validate()
    }

    // Provider metacharacters / uppercase / emptiness are refused.
    var badProvider = validTownConfig(); badProvider.gooseProvider = "ollama; rm -rf ~"
    #expect(throws: FoundTownProvisioner.ValidationError.self) {
        try FoundTownProvisioner(config: badProvider).validate()
    }
    var emptyProvider = validTownConfig(); emptyProvider.gooseProvider = ""
    #expect(throws: FoundTownProvisioner.ValidationError.self) {
        try FoundTownProvisioner(config: emptyProvider).validate()
    }
}

// MARK: - isSafeHubURL / isSafeProvider (adversarial charset guards)

@Test func hubURLGuard_rejectsMetacharsAndBadScheme_acceptsRealHubs() {
    // Shell-metacharacter injection (the vector unique to found-town: hub lands in a
    // generated goose config, the invite link, and argv).
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h`id`.com"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h$(id).com"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h.com;rm -rf ~"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h.com|sh"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h .com"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h'.com"))
    #expect(!FoundTownProvisioner.isSafeHubURL("wss://h\".com"))
    // Wrong scheme.
    #expect(!FoundTownProvisioner.isSafeHubURL("https://relay.example.com"))
    #expect(!FoundTownProvisioner.isSafeHubURL(""))
    // Real hubs pass, including a port + path + query.
    #expect(FoundTownProvisioner.isSafeHubURL("wss://relay.lerants.com"))
    #expect(FoundTownProvisioner.isSafeHubURL("ws://192.168.1.20:7777"))
    #expect(FoundTownProvisioner.isSafeHubURL("wss://relay.lerants.com:443/nostr?x=1"))
}

@Test func providerGuard_rejectsJunk_acceptsRealProviders() {
    #expect(!FoundTownProvisioner.isSafeProvider(""))
    #expect(!FoundTownProvisioner.isSafeProvider("Open AI"))
    #expect(!FoundTownProvisioner.isSafeProvider("a;b"))
    #expect(!FoundTownProvisioner.isSafeProvider("a$(b)"))
    #expect(!FoundTownProvisioner.isSafeProvider("UPPER"))
    #expect(!FoundTownProvisioner.isSafeProvider(String(repeating: "a", count: 41)))
    #expect(FoundTownProvisioner.isSafeProvider("ollama"))
    #expect(FoundTownProvisioner.isSafeProvider("openai"))
    #expect(FoundTownProvisioner.isSafeProvider("lm-studio"))
    #expect(FoundTownProvisioner.isSafeProvider("anthropic"))
}

// MARK: - townScriptArguments()

@Test func townScriptArgumentsCarryParamsButNoSecret() {
    var cfg = validTownConfig()
    cfg.gooseProvider = "openai"
    cfg.payloadDir = "/tmp/stage"
    let args = FoundTownProvisioner(config: cfg).townScriptArguments()
    #expect(contiguousArgs(args, "--hub", cfg.hubURL))
    #expect(contiguousArgs(args, "--goose-provider", "openai"))
    #expect(contiguousArgs(args, "--payload", "/tmp/stage"))
    // Never a token/secret flag.
    #expect(!args.joined(separator: " ").lowercased().contains("token"))
}

@Test func townScriptArgumentsOmitPayloadWhenEmpty() {
    let args = FoundTownProvisioner(config: validTownConfig()).townScriptArguments()
    #expect(!args.contains("--payload"))
}

// MARK: - townScript (shape + no-secret + honesty)

@Test func townScriptHasTheRequiredShapeAndNoSecret() {
    let s = FoundTownProvisioner.townScript
    for token in [
        "set -euo pipefail",
        "command -v goose",          // GENUINE goose preflight
        "eldr-gooseworld",           // installs the extension binary
        "ELDR_GOOSEWORLD_SOCKET",    // extension reads its config from the env
        "goose configure",           // the documented registration-verify step
        "10420",                     // states the node's binding step
        "--hub",
    ] {
        #expect(s.contains(token), "town script missing required token: \(token)")
    }
    // Honesty: found-town must NOT fabricate a goose installer — it fails closed.
    #expect(s.contains("does not auto-install goose"))
    #expect(s.contains("PLACEHOLDER"))
    // C-8 / secret-free: the gooseworld pairing token is NEVER assigned a value here. The
    // env-var NAME never appears with an '=' (no `ELDR_GOOSEWORLD_TOKEN=<value>`).
    #expect(!s.contains("ELDR_GOOSEWORLD_TOKEN="))
    #expect(!s.lowercased().contains("--llm-token"))
}

// MARK: - townInvite / npub extraction

@Test func townInviteFormatIsDistinctFromCodingAgentPairing() {
    // Distinct scheme path: `pqrc:town`, not `pqrc:add` — routes to town/standing-grant
    // pairing, not coding_agent pairing.
    let plain = FoundTownProvisioner.townInvite(npub: "npub1abc", hub: nil)
    #expect(plain == "pqrc:town?npub=npub1abc")

    let withHub = FoundTownProvisioner.townInvite(npub: "npub1abc", hub: "wss://relay.lerants.com")
    #expect(withHub == "pqrc:town?npub=npub1abc&hub=wss://relay.lerants.com")
    // A reserved char in the hub IS encoded (space → %20), same discipline as pairingLink.
    let spaced = FoundTownProvisioner.townInvite(npub: "npub1abc", hub: "wss://r x.com")
    #expect(spaced.hasSuffix("&hub=wss://r%20x.com"))
}

@Test func npubIsExtractedFromThePairingLink() {
    // The exact shape eldr-node --print-pairing-link emits.
    let link = "pqrc:add?npub=npub1exampleabc&type=coding_agent&relay=wss%3A%2F%2Fr"
    #expect(FoundTownProvisioner.npub(fromPairingLink: link) == "npub1exampleabc")
    // npub last / only field also works.
    #expect(FoundTownProvisioner.npub(fromPairingLink: "pqrc:add?npub=npub1xyz") == "npub1xyz")
    // Junk / empty npub / no query → nil (the caller then fails closed).
    #expect(FoundTownProvisioner.npub(fromPairingLink: "not a link") == nil)
    #expect(FoundTownProvisioner.npub(fromPairingLink: "pqrc:add?type=coding_agent") == nil)
    #expect(FoundTownProvisioner.npub(fromPairingLink: "pqrc:add?npub=&type=coding_agent") == nil)
}

// MARK: - conduitConfig() reuse

@Test func conduitConfigReusesTheHubAsTheRelayAndValidates() throws {
    var cfg = validTownConfig()
    cfg.hubURL = "wss://hub.example.com"
    cfg.workdir = "/Users/me/proj"
    cfg.payloadDir = "/tmp/stage"
    let conduit = FoundTownProvisioner(config: cfg).conduitConfig()
    #expect(conduit.relayURL == "wss://hub.example.com")  // hub IS the relay (§3)
    #expect(conduit.ownerHex == cfg.ownerHex)
    #expect(conduit.workdir == "/Users/me/proj")
    #expect(conduit.payloadDir == "/tmp/stage")
    // The reused conduit config is itself valid — the node install path is unchanged.
    try ConduitProvisioner(config: conduit).validate()
}

// MARK: - FoundTownRunbook

@Test func foundTownRunbookCoversTheKeySteps() {
    let r = FoundTownRunbook.text
    for token in [
        "eldrctl found-town",
        "goose",
        "eldr-gooseworld",
        "--hub",
        "owner",
        "invite",
        "pqrc:town",
        "unlocked",                    // the logged-in-session requirement
        "does not auto-install goose", // the honest limit
    ] {
        #expect(r.contains(token), "found-town runbook missing: \(token)")
    }
}

// MARK: - helpers

/// True if `a` then `b` appear adjacently in `args`.
private func contiguousArgs(_ args: [String], _ a: String, _ b: String) -> Bool {
    for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b { return true }
    return false
}
