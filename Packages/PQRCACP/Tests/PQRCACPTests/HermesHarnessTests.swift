// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

// Hermes (Nous Research) as an ACP harness — the same drop-in pattern as the goose row,
// held to the same honest verification split as `GooseHarnessTests`:
//
//  1. `HermesHarnessRegistryTests` — pure data assertions on the `hermes-acp` descriptor
//     and the AC94 command-override plumbing. These run EVERYWHERE: they touch no binary,
//     so they can never be "green because Hermes isn't installed."
//
//  2. `HermesHarnessLiveHandshakeTests` — SPAWN the real `hermes acp` through the PRODUCTION
//     path (`runHarness` → `StdioHarnessTransport` → `runACPProxy`) and drive a real ACP
//     `initialize`. `.enabled(if:)`-gated on `hermes` being resolvable, so a machine without
//     it SKIPS rather than passing vacuously. Hermes is NOT installed here, so this is the
//     row's honest status: shipped `isProvisional: true`, awaiting a live run to promote it.
//
// Node-only (macOS + Linux) for the live half: `StdioHarnessTransport` spawns `Process`.

// MARK: - (1) registry shape — always runs

@Suite("Hermes descriptor (registry shape)")
struct HermesHarnessRegistryTests {

    @Test func registryCarriesHermesACPWithTheDocumentedLaunchSpec() {
        let hermes = HarnessRegistry.descriptor(id: "hermes-acp")
        #expect(hermes != nil, "the registry must carry the Hermes row")
        #expect(hermes?.kind == .stdioSpawn)
        #expect(hermes?.command == "hermes")
        #expect(hermes?.args == ["acp"], "Hermes' ACP-agent mode is the `acp` subcommand")
        // PROVISIONAL: Hermes isn't installed here, so the launch spec is documented, not
        // verified — matching the Codex/OpenCode/Cursor rows, unlike the goose row.
        #expect(hermes?.isProvisional == true)
        // Hermes brings its OWN provider config (`~/.hermes/config.yaml`), so there is no
        // single vendor-key env var for the node to inject — same reasoning as goose.
        #expect(hermes?.vendorKeyEnvVar == nil)
        #expect(hermes?.a2aCardURL == nil)
        #expect(hermes?.env.isEmpty == true, "no secrets at rest in the static registry")
    }

    /// AC94 — the PATH caveat applies to Hermes as hard as to goose: a uv/pipx install lands
    /// outside a GUI-launched Huginn.app's or a launchd-spawned eldr-node's default PATH, so
    /// the override env var is the supported escape hatch and its exact spelling is
    /// load-bearing (Huginn's Bridge picker writes it into the agent env file by this name).
    @Test func commandOverrideEnvVarSpellingAndHonouring() {
        #expect(
            HarnessRegistry.commandOverrideEnvVar(for: "hermes-acp") == "ELDR_HARNESS_CMD_HERMES_ACP")

        let overridden = HarnessRegistry.resolvedDescriptor(
            id: "hermes-acp",
            environment: ["ELDR_HARNESS_CMD_HERMES_ACP": "/Users/op/.local/bin/hermes"])
        #expect(overridden?.command == "/Users/op/.local/bin/hermes")
        // Everything else survives the copy — most importantly the `acp` subcommand, without
        // which an overridden path launches Hermes' interactive mode and wedges the proxy.
        #expect(overridden?.args == ["acp"])
        #expect(overridden?.id == "hermes-acp")
        #expect(overridden?.kind == .stdioSpawn)
        #expect(overridden?.isProvisional == HarnessRegistry.descriptor(id: "hermes-acp")?.isProvisional)

        // No override / a whitespace-only override → the registry command stands.
        #expect(
            HarnessRegistry.resolvedDescriptor(id: "hermes-acp", environment: [:])?.command == "hermes")
        #expect(
            HarnessRegistry.resolvedDescriptor(
                id: "hermes-acp", environment: ["ELDR_HARNESS_CMD_HERMES_ACP": "   "]
            )?.command == "hermes")
    }
}

// MARK: - (2) the live handshake — the actual verification (skips without Hermes)

#if os(macOS) || os(Linux)
@Suite("Hermes ACP initialize handshake (live, macOS)")
struct HermesHarnessLiveHandshakeTests {

    /// Where Hermes actually is on this machine, or nil if it isn't installed. Checked in
    /// override → PATH → `~/.local/bin/hermes` order, mirroring how a node resolves it.
    static let hermesBinary: String? = {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["ELDR_HARNESS_CMD_HERMES_ACP"],
            fm.isExecutableFile(atPath: override)
        {
            return override
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = (String(dir) as NSString).appendingPathComponent("hermes")
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let home = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/hermes")
        return fm.isExecutableFile(atPath: home) ? home : nil
    }()

    enum HermesTestError: Error { case streamEnded }

    /// Drive a REAL ACP `initialize` through `runHarness` (which spawns `StdioHarnessTransport`
    /// and runs `runACPProxy` internally — the exact code path the node uses) and assert the
    /// reply is a well-formed ACP initialize RESULT. Same shape/rationale as the goose suite:
    /// we read the raw `initialize` reply rather than going through `ACPClient.start()`, so a
    /// harness that speaks ACP but has no provider configured is not conflated with one that
    /// doesn't speak ACP at all.
    @Test(.enabled(if: hermesBinary != nil))
    func hermesSpeaksACPInitializeThroughTheProductionPath() async throws {
        let binary = try #require(Self.hermesBinary)
        let descriptor = try #require(
            HarnessRegistry.resolvedDescriptor(
                id: "hermes-acp", environment: ["ELDR_HARNESS_CMD_HERMES_ACP": binary]))
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

            let reply = try await withTimeout(60) { () -> String in
                for await line in phone.inboundLines() where !line.isEmpty {
                    guard line.contains("\"id\"") else { continue }
                    return line
                }
                throw HermesTestError.streamEnded
            }

            print("── Hermes acp transcript ──")
            print("→ \(request)")
            print("← \(reply)")

            let value = try #require(JSONValue.parse(reply))
            #expect(value["jsonrpc"]?.stringValue == "2.0")
            #expect(value["id"]?.intValue == 1)
            #expect(value["error"] == nil, "Hermes returned a JSON-RPC error: \(reply)")
            let result = try #require(value["result"], "no `result` object in: \(reply)")
            #expect(
                result["protocolVersion"]?.intValue != nil,
                "an ACP initialize result must negotiate protocolVersion; got: \(reply)")
        }
    }
}
#endif  // os(macOS) || os(Linux)
