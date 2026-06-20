import Foundation
import Testing

@testable import EldrACPConfigurator

/// Generator-logic tests for the relay-provisioning wizard. They prove the install
/// script carries the right NON-secret structure, that NO secret token value leaks into
/// the generated text, and that validation rejects bad inputs.
@Suite("Relay provisioner — script generation + validation")
struct RelayProvisionerTests {

    /// A token VALUE that must never appear in any generated script.
    private static let secretTokenCanary = "cf-secret-canary-9f8e7d6c5b4a"
    private static let adminTokenCanary = "admin-secret-canary-deadbeef00"

    private static let pubkeyA = String(repeating: "a", count: 64)
    private static let pubkeyB =
        "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"  // valid 64-hex

    private static func goodConfig() -> RelayProvisioner.Config {
        RelayProvisioner.Config(
            domain: "relay.example.com",
            httpPort: 7777,
            allowedPubkeys: [pubkeyA, pubkeyB],
            relayName: "Eldr Relay",
            relayDescription: "Private PQRC relay.",
            tlsMode: .cloudflare,
            maxContentLength: 262_144)
    }

    // MARK: Install-script structure (non-secret)

    @Test func installScriptCarriesNonSecretStructure() throws {
        let bundle = try RelayProvisioner(config: Self.goodConfig()).generateBundle()
        let install = bundle.install

        // Domain.
        #expect(install.contains("relay.example.com"))
        // Host port → container port mapping.
        #expect(install.contains("7777"))
        #expect(install.contains("\"$RELAY_PORT:8080\""))
        // Pinned image (supply chain).
        #expect(install.contains(RelayProvisioner.khatruImage))
        #expect(install.contains(":v"))  // a version-tagged pin, not :latest
        #expect(!install.contains(":latest"))
        // NIP-42 AUTH allowlist: enabled + both keys present.
        #expect(install.contains("auth_required = true"))
        #expect(install.contains("[authorized_keys]"))
        #expect(install.contains(Self.pubkeyA))
        #expect(install.contains(Self.pubkeyB))
        // Tuned content-length default.
        #expect(install.contains("262144"))
    }

    @Test func installScriptIsIdempotentAndPromptsForSecrets() throws {
        let install = try RelayProvisioner(config: Self.goodConfig()).generateBundle().install
        // `up -d` re-reads the pinned files → idempotent.
        #expect(install.contains("docker compose"))
        #expect(install.contains("up -d"))
        // Secrets are read interactively (hidden) or required from the env, not baked in.
        #expect(install.contains("read -rs"))
        #expect(install.contains("${RELAY_ADMIN_TOKEN:?"))
    }

    @Test func generatesUpdateStopUninstallScripts() throws {
        let bundle = try RelayProvisioner(config: Self.goodConfig()).generateBundle()
        // Update re-pulls the pinned image.
        #expect(bundle.update.contains("pull"))
        #expect(bundle.update.contains(RelayProvisioner.khatruImage))
        // Stop is teardown-safe (guards on the compose file existing).
        #expect(bundle.stop.contains("if [ -f"))
        #expect(bundle.stop.contains("down"))
        // Uninstall keeps data unless --purge, and is safe when nothing is installed.
        #expect(bundle.uninstall.contains("--purge"))
        #expect(bundle.uninstall.contains("nothing to remove"))
    }

    // MARK: Secret handling — no token value in the generated text

    @Test func noSecretTokenValueAppearsInAnyScript() throws {
        // Build a config; secrets are NOT part of Config at all (by design) — but to be
        // thorough, confirm that even if the canary strings were floating around, they're
        // absent from every generated script. The env-var NAMES may appear; the VALUES
        // must not.
        let bundle = try RelayProvisioner(config: Self.goodConfig()).generateBundle()
        for script in [bundle.install, bundle.update, bundle.stop, bundle.uninstall] {
            #expect(!script.contains(Self.secretTokenCanary))
            #expect(!script.contains(Self.adminTokenCanary))
        }
        // The install script references the env-var NAMES (so the host can supply them)…
        #expect(bundle.install.contains("CF_API_TOKEN"))
        #expect(bundle.install.contains("RELAY_ADMIN_TOKEN"))
        // …and clipboard text equals the script (the security property is "no value in
        // the script", which holds because no secret is ever interpolated).
        #expect(RelayProvisioner.clipboardText(bundle.install) == bundle.install)
        #expect(!RelayProvisioner.clipboardText(bundle.install).contains(Self.secretTokenCanary))
    }

    @Test func cloudflareSecretOmittedWhenNotUsingCloudflare() throws {
        var config = Self.goodConfig()
        config.tlsMode = .none
        let install = try RelayProvisioner(config: config).generateBundle().install
        // No Cloudflare TLS → no Cloudflare token prompt in the script.
        #expect(!install.contains("Cloudflare API token (input hidden"))
        // The admin token is still required regardless of TLS mode.
        #expect(install.contains("${RELAY_ADMIN_TOKEN:?"))
    }

    // MARK: Validation — rejects bad inputs

    @Test func validationRejectsBadDomain() {
        var config = Self.goodConfig()
        config.domain = "not a domain"
        let errors = RelayProvisioner(config: config).validate()
        #expect(errors.contains(.invalidDomain("not a domain")))
        // And no script is emitted for invalid input.
        #expect(throws: RelayProvisioner.ValidationError.self) {
            try RelayProvisioner(config: config).generateBundle()
        }
        // A few more shapes that must be rejected.
        for bad in ["", "localhost", "relay.", "-bad.com", "http://relay.example.com", "1.2.3.4"] {
            #expect(!RelayProvisioner.isValidDomain(bad), "expected \(bad) to be invalid")
        }
        // …and a good one accepted.
        #expect(RelayProvisioner.isValidDomain("relay.example.com"))
        #expect(RelayProvisioner.isValidDomain("a.b.co"))
    }

    @Test func validationRejectsOutOfRangePort() {
        for badPort in [0, -1, 65_536, 99_999] {
            var config = Self.goodConfig()
            config.httpPort = badPort
            let errors = RelayProvisioner(config: config).validate()
            #expect(errors.contains(.portOutOfRange(badPort)), "expected \(badPort) rejected")
        }
        // Boundaries are accepted.
        for okPort in [1, 7777, 65_535] {
            var config = Self.goodConfig()
            config.httpPort = okPort
            #expect(!RelayProvisioner(config: config).validate().contains(.portOutOfRange(okPort)))
        }
    }

    @Test func validationRejectsNon64HexPubkey() {
        // Too short, too long, non-hex, npub-ish — all rejected.
        let bad = [
            "deadbeef",  // 8 chars
            String(repeating: "a", count: 63),  // 63
            String(repeating: "a", count: 65),  // 65
            String(repeating: "g", count: 64),  // non-hex
            "npub1" + String(repeating: "a", count: 59),  // bech32, not hex
        ]
        for key in bad {
            #expect(!RelayProvisioner.isValidPubkey(key), "expected \(key) invalid")
            var config = Self.goodConfig()
            config.allowedPubkeys = [Self.pubkeyA, key]
            let errors = RelayProvisioner(config: config).validate()
            #expect(
                errors.contains(.invalidPubkey(key.trimmingCharacters(in: .whitespaces).lowercased())),
                "expected validation to flag \(key)")
        }
        // A valid key passes.
        #expect(RelayProvisioner.isValidPubkey(Self.pubkeyB))
        // Empty allowlist is rejected with its own error.
        var empty = Self.goodConfig()
        empty.allowedPubkeys = []
        #expect(RelayProvisioner(config: empty).validate().contains(.noPubkeys))
    }

    @Test func goodConfigValidatesClean() {
        #expect(RelayProvisioner(config: Self.goodConfig()).validate().isEmpty)
        #expect(RelayProvisioner(config: Self.goodConfig()).isValid)
    }
}
