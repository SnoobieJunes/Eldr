// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(Glibc)
import Glibc
#endif
import Foundation
import PQRCCore
import PQRCNostr
import Testing
@testable import HuginnCore

@Suite("Supervisor, bridge, Buzz, registration, world, relay")
struct OpsTests {
    @Test("supervisor: start logs output, stop terminates (nothing left running), exit status reported")
    func supervisor() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let sup = ChildSupervisor()
        let log = tmp.sub("logs/c.log")
        let st = await sup.start(id: "c", executable: "/bin/sh", arguments: ["-c", "echo started; exec sleep 30"], environment: [:], logPath: log)
        guard case .running(let pid) = st else { Issue.record("not running: \(st)"); return }
        for _ in 0..<40 where !((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").contains("started") {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(try String(contentsOfFile: log, encoding: .utf8).contains("started"))
        // Second start is a no-op while running.
        #expect(await sup.start(id: "c", executable: "/bin/sh", arguments: [], environment: [:], logPath: log) == st)
        await sup.stopAll()
        #expect(await sup.state("c") == .stopped)
        #expect(kill(pid, 0) != 0)  // gone
        let e = await sup.start(id: "e", executable: "/bin/sh", arguments: ["-c", "exit 3"], environment: [:], logPath: log)
        #expect(e.isRunning)
        for _ in 0..<80 where await sup.state("e").isRunning { try await Task.sleep(for: .milliseconds(25)) }
        #expect(await sup.state("e") == .exited(status: 3))
        let bad = await sup.start(id: "x", executable: tmp.sub("missing"), arguments: [], environment: [:], logPath: log)
        if case .failedToStart = bad {} else { Issue.record("expected failedToStart") }
        #expect(await sup.runningIDs.isEmpty)
    }

    @Test("supervisor escalates to SIGKILL for a child that ignores SIGTERM")
    func sigkill() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let sup = ChildSupervisor()
        let st = await sup.start(id: "s", executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while true; do sleep 0.1; done"], environment: [:], logPath: tmp.sub("s.log"))
        guard case .running(let pid) = st else { Issue.record("not running"); return }
        try await Task.sleep(for: .milliseconds(200))
        await sup.stop(id: "s", grace: .milliseconds(300))
        #expect(kill(pid, 0) != 0)
    }

    @Test("bridge: refuses without an owner; arguments carry owner/relay/workdir/responder")
    func bridge() {
        let tmp = TempDir(); defer { tmp.remove() }
        var b = BridgeSettings()
        #expect(b.problems.contains(.missingOwner))
        b.ownerHex = "ABCD12"; b.workdir = tmp.path; b.relayURL = "wss://relay.lerants.com"
        #expect(b.problems.isEmpty)
        #expect(b.arguments() == ["--owner", "abcd12", "--relay", "wss://relay.lerants.com", "--workdir", tmp.path, "--responder", "eldr-acp"])
        b.ownerHex = "xyz"; b.relayURL = "ws://example.com"
        #expect(b.problems.contains(.badOwner))
        #expect(b.problems.contains(.badRelay(RelayURL.Problem.plaintextOffLoopback.message)))
        #expect(b.save(tmp.paths))
        #expect(BridgeSettings.load(tmp.paths) == b)
    }

    @Test("relay URL policy")
    func relayURL() {
        #expect((try? RelayURL.validate("wss://x.y").get()) != nil)
        #expect((try? RelayURL.validate("ws://127.0.0.1:7777").get()) != nil)
        #expect(throws: RelayURL.Problem.plaintextOffLoopback) { try RelayURL.validate("ws://x.y").get() }
        #expect(throws: RelayURL.Problem.unsupportedScheme) { try RelayURL.validate("https://x.y").get() }
        #expect(throws: RelayURL.Problem.empty) { try RelayURL.validate(" ").get() }
    }

    @Test("Buzz: create attests with the owner key (never stored), key in keystore, child env rules")
    func buzz() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let secrets = testSecrets(tmp)
        let store = BuzzConnectionStore(path: tmp.paths.buzzConnectionsFile, secrets: secrets)
        let owner = try NostrKeypair(randomSource: SystemRandomSource())
        var draft = BuzzConnection()
        draft.relayURL = "wss://w.communities.buzz.xyz"
        draft.channelIds = BuzzConnectionStore.parseChannelList("6F9619FF-8B86-D011-B42D-00C04FC964FF, nope")
        let made = try store.create(draft, ownerPrivateKey: owner.privateKeyData.hexString)
        #expect(made.ownerPubkeyHex == owner.publicKeyHex)
        #expect(try NIPOA.verifyAuthTag(made.authTagJSON ?? "", agentPublicKeyHex: made.agentPubkeyHex) == owner.publicKeyHex)
        let file = try String(contentsOfFile: tmp.paths.buzzConnectionsFile, encoding: .utf8)
        #expect(!file.contains(owner.privateKeyData.hexString))
        let key = try #require(store.agentPrivateKeyHex(id: made.id))
        #expect(!file.contains(key))
        #expect(try NostrKeypair(privateKey: #require(Data(hexString: key))).publicKeyHex == made.agentPubkeyHex)
        let probs = BuzzConnectionStore.problems(with: made, hasKey: true)
        #expect(probs.contains(.invalidChannel("nope")))
        #expect(probs.contains(.disclosureNotAcknowledged))
        let env = BuzzConnectionStore.environment(
            for: made, agentPrivateKeyHex: key, llmURL: "http://l/v1", llmModel: "m", llmToken: "",
            base: ["ELDR_BUZZ_OWNER_PRIVATE_KEY": "leak", "ELDR_ACP_FAKE_LLM": "1", "ELDR_LLM_TOKEN": "stale"])
        #expect(env["ELDR_BUZZ_OWNER_PRIVATE_KEY"] == nil && env["ELDR_ACP_FAKE_LLM"] == nil && env["ELDR_LLM_TOKEN"] == nil)
        #expect(env["BUZZ_PRIVATE_KEY"] == key && env["BUZZ_AUTH_TAG"] == made.authTagJSON)
        #expect(env["ELDR_BUZZ_REDACT"] == "1" && env["ELDR_LLM_URL"] == "http://l/v1")
        // Rotate without an owner key drops the stale attestation.
        let rotated = try store.rotateKey(id: made.id, ownerPrivateKey: nil)
        #expect(rotated.authTagJSON == nil && rotated.agentPubkeyHex != made.agentPubkeyHex)
        #expect(throws: BuzzConnectionStore.StoreError.self) { try store.applyAttestation(made.authTagJSON ?? "", id: made.id) }
        try store.remove(id: made.id)
        #expect(store.load().isEmpty && store.agentPrivateKeyHex(id: made.id) == nil)
    }

    @Test("Buzz: tolerant decode keeps the list when fields are missing; missing redact ⇒ ON, ack ⇒ OFF")
    func buzzDecode() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        write(#"{"connections":[{"id":"a"}]}"#, tmp.paths.buzzConnectionsFile)
        let list = BuzzConnectionStore(path: tmp.paths.buzzConnectionsFile, secrets: testSecrets(tmp)).load()
        #expect(list.count == 1 && list[0].redactOutbound && !list[0].disclosureAcknowledged)
    }

    @Test("registration: acpx write + idempotent; Zed JSONC is never rewritten; backup kept")
    func registration() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let home = tmp.path
        let plan = try HarnessRegistration.plan(target: .acpxGlobal, launcherPath: "/l", home: home)
        #expect(try HarnessRegistration.apply(plan, gatewayRunning: false) == .wrote(path: plan.path, backup: nil))
        #expect(HarnessRegistration.isRegistered(target: .acpxGlobal, home: home))
        let again = try HarnessRegistration.plan(target: .acpxGlobal, launcherPath: "/l", home: home)
        #expect(try HarnessRegistration.apply(again, gatewayRunning: false) == .unchanged(path: plan.path))
        let zed = HarnessRegistration.path(for: .zed, home: home)
        write("{\n  // my settings\n  \"theme\": \"One\"\n}\n", zed)
        #expect(throws: HarnessRegistration.RegError.notJSONObject(zed)) {
            try HarnessRegistration.plan(target: .zed, launcherPath: "/l", home: home)
        }
        write(#"{"theme":"One"}"#, zed)
        let zp = try HarnessRegistration.plan(target: .zed, launcherPath: "/l", home: home)
        guard case .wrote(_, let backup) = try HarnessRegistration.apply(zp, gatewayRunning: false) else { Issue.record("no write"); return }
        #expect(backup == zed + ".huginn.bak")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: zed))) as? [String: Any]
        #expect(root?["theme"] as? String == "One")
        #expect(HarnessRegistration.isRegistered(target: .zed, home: home))
        let gw = try HarnessRegistration.plan(target: .gateway(path: tmp.sub("oc.json")), launcherPath: "/l", home: home)
        #expect(try HarnessRegistration.apply(gw, gatewayRunning: true) == .deferredGatewayRunning(path: gw.path, json: gw.json))
    }

    @Test("world status over a unix socket: token first, decode, wrong token ⇒ noResponse")
    func world() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let sock = "/tmp/hw-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(sock) }
        let reply = #"{"jsonrpc":"2.0","id":1,"result":{"nodeTownID":"n1","localAgentID":"a1","towns":[{"townID":"t1","label":"Oak","wallGranted":true,"delegateGranted":false,"lastSeen":5,"grantExpiry":null}],"droppedInboundCount":2,"generatedAt":9}}"#
        let server = try UnixLineServer(path: sock, token: "tok", reply: reply)
        let t = Thread { server.serve(count: 2) }
        t.start()
        write("ELDR_GOOSEWORLD_TOKEN=tok\nELDR_GOOSEWORLD_SOCKET=\(sock)\n", tmp.paths.gooseworldEnvFile)
        let w = try await WorldStatusClient.fetch(paths: tmp.paths)
        #expect(w.nodeTownID == "n1" && w.towns.first?.label == "Oak" && w.droppedInboundCount == 2)
        let bad = WorldStatusClient.Config(socketPath: sock, port: nil, token: "wrong")
        await #expect(throws: WorldStatusError.noResponse) { try await WorldStatusClient.fetch(bad) }
        await #expect(throws: WorldStatusError.notConfigured) { try await WorldStatusClient.fetch(paths: TempDir().paths) }
        server.close()
    }

    @Test("relay provisioner: valid config yields the pinned script; invalid yields every problem")
    func relay() {
        var c = RelayProvisioner.Config()
        #expect(RelayProvisioner(config: c).installScriptIfValid() == nil)
        #expect(RelayProvisioner(config: c).validate().contains(.emptyDomain))
        c.domain = "relay.example.com"
        c.allowedPubkeys = [String(repeating: "a", count: 64)]
        let script = RelayProvisioner(config: c).installScriptIfValid()
        #expect(script?.contains(RelayProvisioner.khatruImage) == true)
        #expect(script?.contains("relay.example.com") == true)
    }

    @Test("LLM health parses OpenAI /models")
    func health() {
        #expect(LLMHealth.parseModels(Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)) == ["a", "b"])
        #expect(LLMHealth.parseModels(Data("nope".utf8)) == nil)
        #expect(LLMHealth.modelsURL("http://h:1/v1/")?.absoluteString == "http://h:1/v1/models")
    }
}

/// Minimal blocking AF_UNIX server: reads the token line + request, replies only when the
/// token matches (the node closes silently otherwise).
final class UnixLineServer: @unchecked Sendable {
    let fd: Int32
    let token: String
    let reply: String
    init(path: String, token: String, reply: String) throws {
        self.token = token; self.reply = reply
        fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
    }
    func serve(count: Int) {
        for _ in 0..<count {
            let c = accept(fd, nil, nil)
            guard c >= 0 else { return }
            var data = [UInt8]()
            var buf = [UInt8](repeating: 0, count: 4096)
            while data.filter({ $0 == 10 }).count < 2 {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data += buf[0..<n]
            }
            let firstLine = String(decoding: data.prefix(while: { $0 != 10 }), as: UTF8.self)
            if firstLine == token {
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
            }
            Glibc.close(c)
        }
    }
    func close() { Glibc.close(fd) }
}
