// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import PQRCNostr
import Testing

@testable import Huginn

/// WS-I7 — the Connections tab's model and supervisor.
///
/// Headless and hermetic (the Huginn test rule): a temp config dir, an isolated
/// Keychain service, and — for the lifecycle test — a fake `eldr-buzz-agent`
/// shell script instead of the real gateway. No relay, no network, no clock.
@MainActor
@Suite("Buzz workspace connections", .serialized)
struct BuzzConnectionTests {

    @MainActor
    private struct Fixture {
        let paths: ConfigPaths
        let store: BuzzConnectionStore
        let keychainService: String
        let dir: String

        init() throws {
            let dir = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("huginn-buzz-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            self.dir = dir
            paths = ConfigPaths(configDir: dir, binDir: dir)
            keychainService = "test-buzz-\(UUID().uuidString)"
            store = BuzzConnectionStore(
                path: paths.buzzConnectionsFile, keychain: KeychainBox(service: keychainService))
        }

        @MainActor
        func cleanup() {
            for connection in store.connections {
                KeychainBox(service: keychainService).delete(account: connection.keychainAccount)
            }
            try? FileManager.default.removeItem(atPath: dir)
        }

        func draft(relay: String = "wss://relay.example.test", channels: [String]? = nil)
            -> BuzzConnection
        {
            BuzzConnection(
                displayName: "Eldr", relayURL: relay,
                channelIds: channels ?? [UUID().uuidString.lowercased()],
                disclosureAcknowledged: true)
        }
    }

    private static let ownerKeyHex = String(repeating: "31", count: 32)

    // MARK: - Store + keys

    @Test("create mints a per-connection key, attests it, and round-trips on disk")
    func createMintsAndPersists() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let created = try fixture.store.create(
            fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)

        // A fresh agent key — never the owner's.
        #expect(created.agentPubkeyHex.count == 64)
        let ownerKeypair = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        #expect(created.agentPubkeyHex != ownerKeypair.publicKeyHex)
        #expect(created.ownerPubkeyHex == ownerKeypair.publicKeyHex)

        // The attestation verifies against the agent key it authorizes — which is
        // exactly what the workspace's relay will check.
        let tag = try #require(created.authTagJSON)
        let verifiedOwner = try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: created.agentPubkeyHex)
        #expect(verifiedOwner == ownerKeypair.publicKeyHex)

        // The private half is in the Keychain, and NOT in the file.
        let privateHex = try #require(fixture.store.agentPrivateKeyHex(id: created.id))
        #expect(Data(hexString: privateHex)?.count == 32)
        let raw = try String(contentsOfFile: fixture.paths.buzzConnectionsFile, encoding: .utf8)
        #expect(!raw.contains(privateHex), "an agent private key must never reach the file")
        #expect(!raw.contains(Self.ownerKeyHex), "the owner key must never be persisted at all")
        #expect(raw.contains(created.agentPubkeyHex))

        // A second store instance sees the same record (the file IS the state).
        let reopened = BuzzConnectionStore(
            path: fixture.paths.buzzConnectionsFile,
            keychain: KeychainBox(service: fixture.keychainService))
        #expect(reopened.connections.map(\.id) == [created.id])
    }

    @Test("remove destroys the agent key")
    func removeDestroysKey() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let created = try fixture.store.create(fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)
        #expect(fixture.store.hasAgentKey(id: created.id))

        fixture.store.remove(id: created.id)
        #expect(fixture.store.connections.isEmpty)
        #expect(!fixture.store.hasAgentKey(id: created.id))
        #expect(fixture.store.agentPrivateKeyHex(id: created.id) == nil)
    }

    @Test("rotate mints a NEW key and re-attests; a key-less rotation drops the stale tag")
    func rotateKeyReAttests() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let created = try fixture.store.create(fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)
        let firstKey = created.agentPubkeyHex
        let firstPrivate = try #require(fixture.store.agentPrivateKeyHex(id: created.id))

        let rotated = try fixture.store.rotateKey(
            id: created.id, ownerPrivateKey: Self.ownerKeyHex)
        #expect(rotated.agentPubkeyHex != firstKey, "rotation must change the public identity")
        #expect(fixture.store.agentPrivateKeyHex(id: created.id) != firstPrivate)
        let tag = try #require(rotated.authTagJSON)
        #expect(
            (try? NIPOA.verifyAuthTag(tag, agentPublicKeyHex: rotated.agentPubkeyHex)) != nil,
            "the re-issued attestation must name the NEW key")

        // Rotating without the owner key can't re-attest — carrying the old tag
        // forward would name a key that no longer exists, and the relay would
        // reject the agent with no explanation. It must be dropped instead.
        let again = try fixture.store.rotateKey(id: created.id, ownerPrivateKey: nil)
        #expect(again.authTagJSON == nil)
    }

    @Test("an invited connection is attested AFTER its key exists, and a foreign tag is refused")
    func applyAttestationAfterTheFactOnly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        // The "I was invited" path: no owner key at creation, so no attestation.
        let created = try fixture.store.create(fixture.draft(), ownerPrivateKey: nil)
        #expect(created.authTagJSON == nil)
        #expect(created.ownerPubkeyHex == nil)

        // The admin can only attest once the agent key EXISTS — that ordering is
        // the whole reason this is a second step and not a wizard field.
        let owner = try NostrKeypair(privateKey: Data(hexString: Self.ownerKeyHex)!)
        let tag = try NIPOA.computeAuthTag(
            ownerPrivateKey: owner.privateKeyData, agentPublicKeyHex: created.agentPubkeyHex,
            conditions: "", randomSource: SystemRandomSource())
        let attested = try fixture.store.applyAttestation(tag, id: created.id)
        #expect(attested.authTagJSON == tag)
        #expect(attested.ownerPubkeyHex == owner.publicKeyHex)

        // A tag issued for a DIFFERENT agent key is refused here rather than
        // stored and then silently rejected by the relay at connect time.
        let someoneElse = try NostrKeypair(randomSource: SystemRandomSource())
        let foreign = try NIPOA.computeAuthTag(
            ownerPrivateKey: owner.privateKeyData, agentPublicKeyHex: someoneElse.publicKeyHex,
            conditions: "", randomSource: SystemRandomSource())
        #expect(throws: (any Error).self) {
            try fixture.store.applyAttestation(foreign, id: created.id)
        }
        #expect(fixture.store.connection(id: created.id)?.authTagJSON == tag, "the good tag survives")
    }

    @Test("attestation refuses a key that isn't a key")
    func attestationRejectsGarbage() {
        #expect(throws: (any Error).self) {
            try BuzzConnectionStore.attest(
                ownerPrivateKey: "not-a-key", agentPublicKeyHex: String(repeating: "a", count: 64))
        }
    }

    // MARK: - Validation

    @Test("a connection must be complete, disclosed, and off plaintext before it may run")
    func validationGates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let good = try fixture.store.create(fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)
        #expect(BuzzConnectionStore.problems(with: good, hasKey: true).isEmpty)

        // The disclosure gate is real: without it, nothing starts (fail closed).
        var undisclosed = good
        undisclosed.disclosureAcknowledged = false
        #expect(
            BuzzConnectionStore.problems(with: undisclosed, hasKey: true)
                .contains(.disclosureNotAcknowledged))

        // SPEC §0: plaintext ws:// off-loopback is refused, exactly as for the
        // relay override it reuses.
        var plaintext = good
        plaintext.relayURL = "ws://buzz.example.test"
        #expect(
            BuzzConnectionStore.problems(with: plaintext, hasKey: true).contains {
                if case .invalidRelay = $0 { return true }
                return false
            })
        var loopback = good
        loopback.relayURL = "ws://127.0.0.1:3000"
        #expect(BuzzConnectionStore.problems(with: loopback, hasKey: true).isEmpty)

        // A restored file whose Keychain items are gone must not launch.
        #expect(BuzzConnectionStore.problems(with: good, hasKey: false).contains(.missingAgentKey))

        var noChannels = good
        noChannels.channelIds = []
        #expect(BuzzConnectionStore.problems(with: noChannels, hasKey: true).contains(.noChannels))

        var badChannel = good
        badChannel.channelIds = ["general"]
        #expect(
            BuzzConnectionStore.problems(with: badChannel, hasKey: true)
                .contains(.invalidChannel("general")))
    }

    @Test("channel lists are parsed the way people paste them")
    func channelParsing() {
        let a = UUID().uuidString
        let b = UUID().uuidString.lowercased()
        #expect(
            BuzzConnectionStore.parseChannelList(" \(a), \(b)\n") == [a.lowercased(), b])
        #expect(BuzzConnectionStore.parseChannelList("   ").isEmpty)
        #expect(BuzzConnectionStore.isChannelID(a))
        #expect(!BuzzConnectionStore.isChannelID("general"))
    }

    // MARK: - Child environment

    @Test("the child's environment carries the agent key and never the owner's")
    func childEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var connection = try fixture.store.create(
            fixture.draft(channels: ["11111111-1111-1111-1111-111111111111"]),
            ownerPrivateKey: Self.ownerKeyHex)
        connection.redactOutbound = true
        connection.respondToMentionsOnly = true
        let agentKey = try #require(fixture.store.agentPrivateKeyHex(id: connection.id))

        let env = BuzzGatewayService.environment(
            for: connection, agentPrivateKeyHex: agentKey,
            llmURL: "http://127.0.0.1:1337/v1", llmModel: "qwen-local", llmToken: "",
            base: [
                // A hostile/stale inherited environment must not survive.
                "ELDR_BUZZ_OWNER_PRIVATE_KEY": Self.ownerKeyHex,
                "ELDR_ACP_FAKE_LLM": "1",
                "PATH": "/usr/bin",
            ])

        #expect(env["BUZZ_PRIVATE_KEY"] == agentKey)
        #expect(env["BUZZ_RELAY_URL"] == connection.relayURL)
        #expect(env["BUZZ_AUTH_TAG"] == connection.authTagJSON)
        #expect(env["ELDR_BUZZ_CHANNELS"] == "11111111-1111-1111-1111-111111111111")
        #expect(env["ELDR_BUZZ_OWNER_PUBKEY"] == connection.ownerPubkeyHex)
        #expect(env["ELDR_BUZZ_MENTIONS_ONLY"] == "1")
        #expect(env["ELDR_BUZZ_PICTURE"] == nil, "no avatar configured ⇒ the var isn't set")
        #expect(env["ELDR_BUZZ_REDACT"] == "1")
        #expect(env["ELDR_LLM_URL"] == "http://127.0.0.1:1337/v1")
        #expect(env["ELDR_LLM_MODEL"] == "qwen-local")
        #expect(env["PATH"] == "/usr/bin", "the rest of the environment is inherited")
        // The two that MUST be scrubbed.
        #expect(
            env["ELDR_BUZZ_OWNER_PRIVATE_KEY"] == nil,
            "the owner key signed the attestation once — the child never sees it")
        #expect(env["ELDR_ACP_FAKE_LLM"] == nil, "an echo brain must never reach a real workspace")
        #expect(env["ELDR_LLM_TOKEN"] == nil, "no token configured ⇒ none passed")
    }

    @Test("a pinned model/endpoint overrides Huginn's current backend")
    func pinnedBrainWins() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var connection = try fixture.store.create(fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)
        connection.model = "pinned/model"
        connection.providerURL = "http://127.0.0.1:9999/v1"
        let env = BuzzGatewayService.environment(
            for: connection, agentPrivateKeyHex: "ab", llmURL: "http://127.0.0.1:1337/v1",
            llmModel: "current", llmToken: "secret-token", base: [:])
        #expect(env["ELDR_LLM_MODEL"] == "pinned/model")
        #expect(env["ELDR_LLM_URL"] == "http://127.0.0.1:9999/v1")
        #expect(env["ELDR_LLM_TOKEN"] == "secret-token")
    }

    @Test("a record missing newer fields decodes with privacy-safe defaults")
    func tolerantDecoding() throws {
        // A file written by an older Huginn (no egress-firewall or disclosure
        // fields) must decode — the file decodes as a WHOLE, so one missing key
        // failing would silently empty the user's connection list — and it must
        // decode to the SAFE side of every gate.
        let json = """
            {"connections":[{"id":"legacy-1","displayName":"Old","relayURL":"wss://r.example",
            "channelIds":["44444444-4444-4444-4444-444444444444"],"agentPubkeyHex":"ab"}]}
            """
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            atPath: (fixture.paths.buzzConnectionsFile as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try json.write(
            toFile: fixture.paths.buzzConnectionsFile, atomically: true, encoding: .utf8)

        let store = BuzzConnectionStore(
            path: fixture.paths.buzzConnectionsFile,
            keychain: KeychainBox(service: fixture.keychainService))
        let restored = try #require(store.connection(id: "legacy-1"))
        #expect(restored.displayName == "Old")
        #expect(restored.redactOutbound, "a pre-firewall record must not post unredacted")
        #expect(!restored.disclosureAcknowledged, "the disclosure gate fails closed")
        #expect(restored.pictureURL.isEmpty)
        #expect(!restored.paused)
    }

    // MARK: - Supervisor lifecycle (fake gateway binary, no network)

    /// A stand-in `eldr-buzz-agent`: prints the SAME status lines the real gateway
    /// emits (that vocabulary is the shared `BuzzGatewayStatus` contract, pinned in
    /// PQRCNostrTests against the real emitter), then parks so it can be stopped.
    private func installFakeGateway(at path: String, channel: String) throws {
        let script = """
            #!/bin/zsh
            echo '\(BuzzGatewayStatus.starting(relay: "wss://relay.example.test", agentPubkey: String(repeating: "ab", count: 32)).line)'
            echo '\(BuzzGatewayStatus.connected(relay: "wss://relay.example.test").line)'
            echo '\(BuzzGatewayStatus.listening(channels: 1).line)'
            echo '\(BuzzGatewayStatus.reply(channel: channel, characters: 120).line)'
            echo '\(BuzzGatewayStatus.tokens(turn: 1500).line)'
            exec sleep 60
            """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test("start → connected → stop, with the status row folded from the child's own output")
    func lifecycleAndCounters() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let channel = "22222222-2222-2222-2222-222222222222"
        let connection = try fixture.store.create(
            fixture.draft(channels: [channel]), ownerPrivateKey: Self.ownerKeyHex)
        let fakePath = (fixture.dir as NSString).appendingPathComponent("fake-eldr-buzz-agent")
        try installFakeGateway(at: fakePath, channel: channel)

        let service = BuzzGatewayService(
            paths: fixture.paths, store: fixture.store, executableProvider: { fakePath })
        #expect(service.state(of: connection.id) == .stopped)

        service.start(
            connection, llmURL: "http://127.0.0.1:1337/v1", llmModel: "m", llmToken: "")
        #expect(service.state(of: connection.id) == .starting)

        // The child's status lines reach the row through the real path: child →
        // log file → LogTailer → counters.
        var connected = false
        for _ in 0..<200 {
            if service.state(of: connection.id) == .connected {
                connected = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(connected, "the gateway's own 'connected' status never reached the UI")
        var counters = service.counters(of: connection.id)
        for _ in 0..<40 where counters.replies == 0 {
            try await Task.sleep(for: .milliseconds(50))
            counters = service.counters(of: connection.id)
        }
        #expect(counters.replies == 1)
        #expect(counters.tokens == 1500)
        #expect(counters.channelsListening == 1)

        // The log the console tails is a real file with the child's output in it.
        let logText = try String(
            contentsOfFile: service.logPath(of: connection.id), encoding: .utf8)
        #expect(logText.contains("eldr-buzz-agent starting"))
        #expect(logText.contains(BuzzGatewayStatus.prefix))

        // Stop is clean — an expected stop must not be reported as a failure.
        service.stop(id: connection.id)
        var stopped = false
        for _ in 0..<200 {
            if service.state(of: connection.id) == .stopped {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(stopped, "the child never reached .stopped")
    }

    @Test("start fails closed on an unacknowledged disclosure and on a missing binary")
    func startFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var connection = try fixture.store.create(
            fixture.draft(), ownerPrivateKey: Self.ownerKeyHex)
        connection.disclosureAcknowledged = false
        fixture.store.update(connection)

        let service = BuzzGatewayService(
            paths: fixture.paths, store: fixture.store,
            executableProvider: { (fixture.dir as NSString).appendingPathComponent("nope") })
        service.start(connection, llmURL: "u", llmModel: "m", llmToken: "")
        guard case .failed(let why) = service.state(of: connection.id) else {
            Issue.record("an unacknowledged disclosure must refuse to start")
            return
        }
        #expect(why.contains("encryption"))
        #expect(!service.isRunning(connection.id))

        // Disclosure fixed, binary still missing: still refuses, with the reason.
        connection.disclosureAcknowledged = true
        fixture.store.update(connection)
        service.start(connection, llmURL: "u", llmModel: "m", llmToken: "")
        guard case .failed(let missing) = service.state(of: connection.id) else {
            Issue.record("a missing gateway binary must refuse to start")
            return
        }
        #expect(missing.contains("isn't installed"))
    }

    @Test("paused connections are not started at launch")
    func pausedStaysDown() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let channel = "33333333-3333-3333-3333-333333333333"
        var connection = try fixture.store.create(
            fixture.draft(channels: [channel]), ownerPrivateKey: Self.ownerKeyHex)
        connection.paused = true
        fixture.store.update(connection)
        let fakePath = (fixture.dir as NSString).appendingPathComponent("fake-eldr-buzz-agent")
        try installFakeGateway(at: fakePath, channel: channel)

        let service = BuzzGatewayService(
            paths: fixture.paths, store: fixture.store, executableProvider: { fakePath })
        service.startEnabledConnections(llmURL: "u", llmModel: "m", llmToken: "")
        #expect(service.state(of: connection.id) == .stopped)
        #expect(!service.isRunning(connection.id))
    }

    // MARK: - Per-connection log source

    @Test("each connection's log is its own console source")
    func perConnectionLogSource() {
        let paths = ConfigPaths(configDir: "/tmp/eldr-test", binDir: "/tmp/eldr-test")
        let source = LogConsoleSource.buzzGateway(connectionID: "abc", name: "Eldr")
        #expect(source.filePath(paths: paths) == "/tmp/eldr-test/buzz/gateway-abc.log")
        #expect(source.title.contains("Eldr"))
        #expect(source.id == "buzz-abc")
        // It is NOT in the fixed picker list (it's per-connection), but it round
        // trips through the Codable window routing.
        #expect(!LogConsoleSource.allCases.contains(source))
        let data = try? JSONEncoder().encode(source)
        #expect((try? JSONDecoder().decode(LogConsoleSource.self, from: data ?? Data())) == source)
    }
}
