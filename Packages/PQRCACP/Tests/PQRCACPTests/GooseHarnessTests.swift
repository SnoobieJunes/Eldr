// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

// WS-G2 (private/GOOSEWORLD.md §6) — goose as an ACP harness.
//
// Two suites, deliberately split by what they need:
//
//  1. `GooseHarnessRegistryTests` — pure data assertions on the `goose-acp` descriptor and
//     on the AC94 command-override plumbing. These run EVERYWHERE (CI included): they touch
//     no binary, so they can never be "green because goose isn't installed."
//
//  2. `GooseHarnessLiveHandshakeTests` — the honest verification: SPAWN the real `goose acp`
//     through the PRODUCTION path (`runHarness` → `StdioHarnessTransport` → `runACPProxy`)
//     and drive a real ACP `initialize`. This is the same standard WS3d held Claude Code and
//     Gemini CLI to — a hand-typed shell probe does not count, because it exercises neither
//     the spawn seam's env scrubbing nor the proxy's line framing. It is `.enabled(if:)`-gated
//     on goose actually being resolvable, so a machine (or CI runner) without goose SKIPS it
//     rather than failing — and, critically, rather than passing vacuously.
//
// Node-only (macOS + Linux): `StdioHarnessTransport` needs `Foundation.Process`,
// which iOS lacks — exactly like the rest of the harness-spawn surface.

// MARK: - (1) registry shape — always runs

@Suite("WS-G2 goose descriptor (registry shape)")
struct GooseHarnessRegistryTests {

    @Test func registryCarriesGooseACPWithTheDocumentedLaunchSpec() {
        let goose = HarnessRegistry.descriptor(id: "goose-acp")
        #expect(goose != nil, "the registry must carry the WS-G2 goose row")
        #expect(goose?.kind == .stdioSpawn)
        #expect(goose?.command == "goose")
        #expect(goose?.args == ["acp"], "goose's ACP-agent mode is the `acp` subcommand")
        // goose brings its OWN provider config (`goose configure` writes ~/.config/goose),
        // so there is no single vendor-key env var for the node to inject — unlike the
        // cloud CLIs. Declaring one would be a lie the Keychain lookup would then act on.
        #expect(goose?.vendorKeyEnvVar == nil)
        #expect(goose?.a2aCardURL == nil)
        #expect(goose?.env.isEmpty == true, "no secrets at rest in the static registry")
    }

    /// AC94 — the PATH caveat applies to goose HARDER than to anything else in the registry:
    /// goose's own installer puts the binary in `~/.local/bin`, which is NOT on a
    /// GUI-launched Huginn.app's or a launchd-spawned eldr-node's default PATH. So the
    /// override env var is the supported escape hatch, and its exact spelling is load-bearing
    /// (Huginn's Bridge picker writes it into the agent env file by this name).
    @Test func commandOverrideEnvVarSpellingAndHonouring() {
        #expect(
            HarnessRegistry.commandOverrideEnvVar(for: "goose-acp") == "ELDR_HARNESS_CMD_GOOSE_ACP")

        let overridden = HarnessRegistry.resolvedDescriptor(
            id: "goose-acp",
            environment: ["ELDR_HARNESS_CMD_GOOSE_ACP": "/Users/op/.local/bin/goose"])
        #expect(overridden?.command == "/Users/op/.local/bin/goose")
        // Everything else survives the copy — most importantly the `acp` subcommand, without
        // which an overridden path launches goose's INTERACTIVE mode and wedges the proxy.
        #expect(overridden?.args == ["acp"])
        #expect(overridden?.id == "goose-acp")
        #expect(overridden?.kind == .stdioSpawn)
        #expect(overridden?.isProvisional == HarnessRegistry.descriptor(id: "goose-acp")?.isProvisional)

        // No override / a whitespace-only override → the registry command stands.
        #expect(
            HarnessRegistry.resolvedDescriptor(id: "goose-acp", environment: [:])?.command == "goose")
        #expect(
            HarnessRegistry.resolvedDescriptor(
                id: "goose-acp", environment: ["ELDR_HARNESS_CMD_GOOSE_ACP": "   "]
            )?.command == "goose")
    }
}

// MARK: - (2) the live handshake — the actual verification

#if os(macOS) || os(Linux)
@Suite("WS-G2 goose ACP initialize handshake (live, macOS)")
struct GooseHarnessLiveHandshakeTests {

    /// Where goose actually is on this machine, or nil if it isn't installed. Checked in
    /// override → PATH → `~/.local/bin/goose` order, mirroring how a node resolves it.
    static let gooseBinary: String? = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["ELDR_HARNESS_CMD_GOOSE_ACP"],
            fm.isExecutableFile(atPath: override)
        {
            return override
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent("goose")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let home = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/goose")
        return fm.isExecutableFile(atPath: home) ? home : nil
    }()

    enum GooseTestError: Error { case streamEnded }

    /// Drive a REAL ACP `initialize` through `runHarness` (which spawns
    /// `StdioHarnessTransport` and runs `runACPProxy` internally — the exact code path the
    /// node uses) and assert the reply is a well-formed ACP initialize RESULT.
    ///
    /// The request is byte-for-byte the shape `ACPClientDriver.initializeParams` produces, so
    /// this is not a bespoke probe: it is what the phone sends. We read the raw line rather
    /// than going through `ACPClient.start()` because `start()` also issues `session/new`,
    /// which goose can refuse without a configured provider — and conflating "no provider
    /// configured" with "the harness doesn't speak ACP" is exactly the dishonest result this
    /// suite exists to avoid.
    @Test(.enabled(if: gooseBinary != nil))
    func gooseSpeaksACPInitializeThroughTheProductionPath() async throws {
        let binary = try #require(Self.gooseBinary)
        // Resolve the SHIPPED descriptor and pin its command to the discovered path — this
        // proves the registry row (`args: ["acp"]`) is what launches, not a bespoke one.
        let descriptor = try #require(
            HarnessRegistry.resolvedDescriptor(
                id: "goose-acp", environment: ["ELDR_HARNESS_CMD_GOOSE_ACP": binary]))
        #expect(descriptor.args == ["acp"])

        try await withTimeout(90) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let runTask = Task {
                await runHarness(descriptor: descriptor, client: clientSide, llm: EchoLLMClient())
            }
            defer {
                phone.close()
                runTask.cancel()
            }

            let request =
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"#
                + #""clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"#
                + #""terminal":false}}}"#
            phone.send(request)

            // goose cold-starts (config load, extension discovery), so allow a generous read
            // window; a fast machine answers in well under a second.
            let reply = try await withTimeout(60) { () -> String in
                for await line in phone.inboundLines() where !line.isEmpty {
                    // Ignore any notification goose emits before the response.
                    guard line.contains("\"id\"") else { continue }
                    return line
                }
                throw GooseTestError.streamEnded
            }

            // Printed so the verification transcript is reproducible from a test run, not
            // just from a one-off shell session. No secret is involved (no credential is set).
            print("── WS-G2 goose acp transcript ──")
            print("→ \(request)")
            print("← \(reply)")

            // A well-formed ACP initialize RESULT: JSON-RPC 2.0, our id, a `result` (not an
            // `error`), and a negotiated `protocolVersion` inside it.
            let value = try #require(JSONValue.parse(reply))
            #expect(value["jsonrpc"]?.stringValue == "2.0")
            #expect(value["id"]?.intValue == 1)
            #expect(value["error"] == nil, "goose returned a JSON-RPC error: \(reply)")
            let result = try #require(value["result"], "no `result` object in: \(reply)")
            #expect(
                result["protocolVersion"]?.intValue != nil,
                "an ACP initialize result must negotiate protocolVersion; got: \(reply)")
        }
    }
}
#endif  // os(macOS) || os(Linux)
