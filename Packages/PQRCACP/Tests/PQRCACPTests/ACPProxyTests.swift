// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

// Phase 1 / the selectable-backend scaffold (docs/ACPRouterplan.md): prove the
// transport-agnostic `runACPProxy` bridges an external harness BOTH ways, and that the
// data-driven `HarnessRegistry` stays the drop-in seam. Headless, network-free, and with NO
// real external binary — a fake "harness" is just another `InMemoryACPTransport` end that
// canned-responds to `initialize`/`session/new`, exactly the shape `StdioHarnessTransport`
// would feed the proxy from a real child's stdout.
//
// Topology under test (the proxy sits in the middle, dumb-piping):
//
//   phone  ⇄  clientSide ── runACPProxy ── harnessSide  ⇄  fakeHarness
//   └─ test drives ─┘     (client)        (harness)      └─ test scripts ─┘
//
// `makePair()` cross-wires each pair, so `phone.send` arrives on `clientSide.inbound` (which
// the proxy forwards to `harnessSide.send` → `fakeHarness.inbound`), and a `fakeHarness.send`
// flows back the same way to `phone.inbound`.

@Suite("runACPProxy bidirectional bridge + HarnessRegistry seam")
struct ACPProxyTests {

    /// Read the next non-empty parsed JSON-RPC line from a transport's inbound stream, bounded
    /// so a missing reply fails the test instead of hanging the suite forever.
    private func nextMessage(
        _ transport: any ACPTransport, timeout seconds: Double = 5
    ) async throws -> JSONValue {
        try await withTimeout(seconds) {
            for await line in transport.inboundLines() {
                if let value = JSONValue.parse(line) { return value }
            }
            throw ProxyTestError.streamEndedBeforeMessage
        }
    }

    enum ProxyTestError: Error { case streamEndedBeforeMessage }

    // 1 ─ Both directions. The phone sends an `initialize` request through the proxy; the fake
    // harness must receive it verbatim, reply, and the phone must receive that reply — proving
    // client→harness AND harness→client forwarding. Then a `session/new` round-trip proves the
    // pipe keeps flowing for multiple messages, not just the first.
    @Test func proxyForwardsBothDirections() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let (harnessSide, fakeHarness) = InMemoryACPTransport.makePair()

            let proxyTask = Task { await runACPProxy(client: clientSide, harness: harnessSide) }
            defer { proxyTask.cancel() }

            // Fake harness: echo-aware canned responder. Reads requests off ITS inbound (which
            // is whatever the proxy forwarded from the phone) and replies by id — the same
            // newline-framed JSON-RPC a real child would print to stdout.
            let harnessTask = Task {
                for await line in fakeHarness.inboundLines() {
                    guard let msg = JSONValue.parse(line),
                        let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    switch method {
                    case "initialize":
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"fake-harness","version":"9.9"}}}"#
                        )
                    case "session/new":
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"proxy-sess-1"}}"#)
                    default:
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                    }
                }
            }
            defer { harnessTask.cancel() }

            // Phone → (proxy) → harness: send initialize.
            phone.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
            // Harness → (proxy) → phone: the reply must arrive on the PHONE's inbound.
            let initReply = try await nextMessage(phone)
            #expect(initReply["id"]?.intValue == 1)
            #expect(initReply["result"]?["agentInfo"]?["name"]?.stringValue == "fake-harness")

            // A second round-trip proves the pipe stays open both ways.
            phone.send(#"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{}}"#)
            let newReply = try await nextMessage(phone)
            #expect(newReply["id"]?.intValue == 2)
            #expect(newReply["result"]?["sessionId"]?.stringValue == "proxy-sess-1")
        }
    }

    // 1b ─ The real client stack drives the proxy. Instead of hand-sending frames, run an
    // actual `ACPClient` (the phone-side actor) THROUGH the proxy against the fake harness:
    // `start()` must complete `initialize`+`session/new`, and a `session/update` the harness
    // emits during a prompt must surface as a typed UI event on the client — i.e. the proxy is
    // transparent to the genuine client logic, not just to hand-crafted lines.
    @Test func realACPClientDrivesAFakeHarnessThroughTheProxy() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let (harnessSide, fakeHarness) = InMemoryACPTransport.makePair()

            let proxyTask = Task { await runACPProxy(client: clientSide, harness: harnessSide) }
            defer { proxyTask.cancel() }

            let harnessTask = Task {
                for await line in fakeHarness.inboundLines() {
                    guard let msg = JSONValue.parse(line),
                        let id = msg["id"]?.intValue,
                        let method = msg["method"]?.stringValue
                    else { continue }
                    switch method {
                    case "initialize":
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":1,"agentInfo":{"name":"fake-harness","version":"9.9"}}}"#
                        )
                    case "session/new":
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"sessionId":"proxy-sess-2"}}"#)
                    case "session/prompt":
                        // Stream one assistant chunk, then end the turn — exercises the
                        // harness→client notification path through the proxy.
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"proxy-sess-2","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi from harness"}}}}"#
                        )
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"result":{"stopReason":"end_turn"}}"#)
                    default:
                        fakeHarness.send(
                            #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"x"}}"#)
                    }
                }
            }
            defer { harnessTask.cancel() }

            // The genuine phone client speaks to the fake harness purely through the proxy.
            let client = ACPClient(transport: phone)
            let events = Task { () -> [ACPUIEvent] in
                var collected: [ACPUIEvent] = []
                for await event in client.events { collected.append(event) }
                return collected
            }

            let info = try await client.start()
            #expect(info.agentName == "fake-harness")
            #expect(info.sessionId == "proxy-sess-2")
            let stop = try await client.prompt("hello")
            #expect(stop == "end_turn")
            await client.shutdown()

            let text = await events.value.compactMap { event -> String? in
                if case .assistantText(let t) = event { return t } else { return nil }
            }.joined()
            #expect(text.contains("hi from harness"))
        }
    }

    // 2 ─ Clean shutdown when the HARNESS side closes (a real child exiting). The proxy must
    // close the phone side so the phone sees EOF (its inbound finishes) rather than hanging.
    @Test func harnessCloseTearsDownPhoneSide() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let (harnessSide, fakeHarness) = InMemoryACPTransport.makePair()

            let proxyTask = Task { await runACPProxy(client: clientSide, harness: harnessSide) }
            defer { proxyTask.cancel() }

            // The phone's inbound must FINISH once the harness closes (proxy closed it).
            let phoneDrained = Task {
                for await _ in phone.inboundLines() {}
                return true  // only reached if the stream finishes
            }

            // Simulate the harness/child going away.
            fakeHarness.close()

            // Phone side finished (no hang) and the proxy task returned.
            #expect(await phoneDrained.value == true)
            await proxyTask.value  // proxy returns after closing both sides
        }
    }

    // 2b ─ Clean shutdown when the PHONE side closes (transport dropped). Symmetric: the proxy
    // must close the harness side so a real child's stdin gets EOF and it can exit.
    @Test func phoneCloseTearsDownHarnessSide() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let (harnessSide, fakeHarness) = InMemoryACPTransport.makePair()

            let proxyTask = Task { await runACPProxy(client: clientSide, harness: harnessSide) }
            defer { proxyTask.cancel() }

            let harnessDrained = Task {
                for await _ in fakeHarness.inboundLines() {}
                return true
            }

            phone.close()  // the phone transport drops

            #expect(await harnessDrained.value == true)
            await proxyTask.value
        }
    }

    // 3 ─ The registry is the drop-in seam: it MUST contain the built-in plus the named
    // Phase-2 descriptors, so adding a harness stays "append one entry." If a Phase-2 id is
    // dropped or the built-in regresses, this fails.
    @Test func registryContainsBuiltInAndPhase2Descriptors() {
        let ids = Set(HarnessRegistry.all.map { $0.id })

        // Built-in reference harness — the only `.builtIn` kind.
        #expect(ids.contains("eldr-acp"))
        let builtIn = HarnessRegistry.descriptor(id: "eldr-acp")
        #expect(builtIn?.kind == .builtIn)
        #expect(HarnessRegistry.all.filter { $0.kind == .builtIn }.count == 1)

        // Installed launchers (not provisional) + the five Phase-2 placeholders.
        for required in [
            "xcode-acp", "openclaw", "claude-code", "codex", "gemini-cli", "opencode", "cursor",
            "goose-acp",  // WS-G2
        ] {
            #expect(ids.contains(required), "registry missing \(required)")
        }

        // Stable ids: no duplicates (a dup would shadow on lookup).
        #expect(ids.count == HarnessRegistry.all.count)
    }

    // 3b ─ Kind/provisional discipline: every non-built-in is a `.stdioSpawn` with a non-empty
    // command; the three remaining Phase-2 placeholders are flagged provisional (commands to
    // confirm), while the built-in, the two installed launchers, AND claude-code/gemini-cli
    // (WS3d — confirmed against the real installed binaries, see HarnessDescriptor.swift) are
    // NOT.
    @Test func descriptorKindsAndProvisionalFlagsAreConsistent() {
        for descriptor in HarnessRegistry.all where descriptor.kind == .stdioSpawn {
            #expect(!descriptor.command.isEmpty, "\(descriptor.id) has empty command")
        }
        // Built-in carries no launch command.
        #expect(HarnessDescriptor.builtIn.command.isEmpty)

        let provisional = Set(
            HarnessRegistry.all.filter { $0.isProvisional }.map { $0.id })
        #expect(provisional == ["codex", "opencode", "cursor", "a2a-local-sample"])
        // Installed/built-in/WS3d-verified are confirmed, not provisional.
        #expect(HarnessRegistry.descriptor(id: "xcode-acp")?.isProvisional == false)
        #expect(HarnessRegistry.descriptor(id: "openclaw")?.isProvisional == false)
        #expect(HarnessRegistry.descriptor(id: "eldr-acp")?.isProvisional == false)
        #expect(HarnessRegistry.descriptor(id: "claude-code")?.isProvisional == false)
        #expect(HarnessRegistry.descriptor(id: "gemini-cli")?.isProvisional == false)
        // WS-G2 — goose's `acp` subcommand was driven through a real initialize handshake
        // (see `GooseHarnessTests`), so it is verified, not scaffolding.
        #expect(HarnessRegistry.descriptor(id: "goose-acp")?.isProvisional == false)
    }
}

// AC94 — the executable-path override: GUI/launchd processes get a minimal PATH, so
// bare nvm/npm command names in the registry only resolve when the operator pins an
// absolute path (Huginn UI → UserDefaults + the agent env file → this seam).
@Suite("HarnessRegistry command override (AC94)")
struct HarnessCommandOverrideTests {

    @Test func envVarNameDerivesFromID() {
        #expect(
            HarnessRegistry.commandOverrideEnvVar(for: "claude-code")
                == "ELDR_HARNESS_CMD_CLAUDE_CODE")
        #expect(HarnessRegistry.commandOverrideEnvVar(for: "codex") == "ELDR_HARNESS_CMD_CODEX")
    }

    @Test func overrideReplacesCommandAndKeepsEverythingElse() {
        let env = [
            "ELDR_HARNESS_CMD_CLAUDE_CODE": "/Users/op/.nvm/versions/node/v25/bin/claude-agent-acp"
        ]
        let resolved = HarnessRegistry.resolvedDescriptor(id: "claude-code", environment: env)
        #expect(resolved?.command == "/Users/op/.nvm/versions/node/v25/bin/claude-agent-acp")
        // Identity, args, and the vendor-key declaration survive the copy.
        let original = HarnessRegistry.descriptor(id: "claude-code")!
        #expect(resolved?.id == original.id)
        #expect(resolved?.args == original.args)
        #expect(resolved?.vendorKeyEnvVar == original.vendorKeyEnvVar)
    }

    @Test func noOverrideAndEmptyOverrideKeepTheRegistryCommand() {
        let original = HarnessRegistry.descriptor(id: "gemini-cli")!
        #expect(
            HarnessRegistry.resolvedDescriptor(id: "gemini-cli", environment: [:])?.command
                == original.command)
        #expect(
            HarnessRegistry.resolvedDescriptor(
                id: "gemini-cli", environment: ["ELDR_HARNESS_CMD_GEMINI_CLI": "  "]
            )?.command == original.command)
    }

    @Test func overrideIsStdioSpawnOnly() {
        // `.builtIn` has no executable; an override must not invent one.
        let builtIn = HarnessDescriptor.builtIn.withCommand("/tmp/evil")
        #expect(builtIn.command.isEmpty)
        // `.a2aRemote` is reached over HTTP; same rule.
        let a2a = HarnessRegistry.descriptor(id: "a2a-local-sample")!.withCommand("/tmp/x")
        #expect(a2a.command.isEmpty)
    }

    @Test func vendorKeyStacksOnTopOfCommandOverride() {
        let env = ["ELDR_HARNESS_CMD_CLAUDE_CODE": "/opt/bin/claude-agent-acp"]
        let resolved = HarnessRegistry.resolvedDescriptor(id: "claude-code", environment: env)!
            .withVendorKey("sk-test")
        #expect(resolved.command == "/opt/bin/claude-agent-acp")
        #expect(resolved.env["ANTHROPIC_API_KEY"] == "sk-test")
    }
}
