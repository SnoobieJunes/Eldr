// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import PQRCAgent
import PQRCCore
import PQRCMCP
import PQRCNostr
import Testing

@testable import EldrChat

// Closes the TEST-PLAN §13 flagged gap for the in-app MCP surface (A35 Phase 2):
//  (a) the loopback server's pairing-token gate drops a bad/missing first line
//      BEFORE any MCP method runs,
//  (b) `stop()` hangs up live clients, removes the socket node and refuses new
//      connections (the lock-silo / toggle-off teardown path),
//  (c) the `PersonaRuntime` redaction accessors emit codenames + a 64 KB bound
//      UNCONDITIONALLY (they take no firewall input at all), and
//  (d) `RuntimeSecureChatBridge` fails closed once its model is gone.

/// Records whether ANY bridge method was ever invoked (the token gate must keep
/// this false for an unauthenticated client).
private actor TouchFlag {
    private(set) var touched = false
    func set() { touched = true }
}

private struct RecordingStubBridge: SecureChatBridge {
    let flag: TouchFlag
    func conversations() async -> [MCPConversation] {
        await flag.set()
        return []
    }
    func messages(conversationID: String, limit: Int) async -> [MCPMessage] {
        await flag.set()
        return []
    }
    func search(query: String, limit: Int) async -> [MCPMessage] {
        await flag.set()
        return []
    }
    func contextPreview(conversationID: String) async -> [MCPMessage] {
        await flag.set()
        return []
    }
    func draftReply(conversationID: String, text: String) async -> MCPWriteResult {
        await flag.set()
        return .failedClosed(reason: "stub")
    }
    func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async
        -> MCPWriteResult
    {
        await flag.set()
        return .failedClosed(reason: "stub")
    }
    func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult {
        await flag.set()
        return .failedClosed(reason: "stub")
    }
}

/// Minimal blocking UDS client for driving the server exactly like the
/// `pqrc-mcp-bridge` shim does. Reads are bounded by SO_RCVTIMEO so a server
/// bug can never wedge the whole suite.
private enum UDSClient {
    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        guard rc == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func send(_ line: String, fd: Int32) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Reads until a newline, EOF, or the 5 s receive timeout. nil ⇒ the server
    /// hung up (or never answered) without sending a full line.
    static func readLine(fd: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if let nl = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            }
        }
    }
}

@Suite("Local MCP loopback server — token gate + teardown (A35 Phase 2)", .serialized)
struct LocalMCPServerGateTests {
    private static let initializeLine =
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}"#

    /// A UDS path short enough for sun_path (104 bytes) in every environment.
    private func shortSocketPath() -> String {
        "/tmp/eldr-mcp-t-\(UUID().uuidString.prefix(8)).sock"
    }

    @Test func badOrMissingToken_dropsBeforeAnyMethodRuns() async throws {
        let flag = TouchFlag()
        let server = LocalMCPServer(
            bridge: RecordingStubBridge(flag: flag), token: "correct-horse",
            socketPath: shortSocketPath())
        try await server.start()
        defer { Task { await server.stop() } }

        // Wrong token, then a well-formed request that must never be served.
        let fd = try #require(UDSClient.connect(await server.socketPath))
        UDSClient.send("wrong-token", fd: fd)
        UDSClient.send(Self.initializeLine, fd: fd)
        #expect(UDSClient.readLine(fd: fd) == nil, "a bad token gets bytes back")
        close(fd)

        // A client that sends nothing and hangs up must also never reach a method.
        let silent = try #require(UDSClient.connect(await server.socketPath))
        close(silent)

        try await Task.sleep(for: .milliseconds(100))
        #expect(await !flag.touched, "no MCP method may run before the token gate passes")
        await server.stop()
    }

    @Test func goodToken_initializeRoundTrips() async throws {
        let flag = TouchFlag()
        let server = LocalMCPServer(
            bridge: RecordingStubBridge(flag: flag), token: "correct-horse",
            socketPath: shortSocketPath())
        try await server.start()

        let fd = try #require(UDSClient.connect(await server.socketPath))
        UDSClient.send("correct-horse", fd: fd)
        UDSClient.send(Self.initializeLine, fd: fd)
        let response = try #require(UDSClient.readLine(fd: fd))
        #expect(response.contains("protocolVersion"), "authenticated initialize is served")
        close(fd)
        await server.stop()
    }

    @Test func stop_hangsUpLiveClients_removesSocket_refusesReconnect() async throws {
        let server = LocalMCPServer(
            bridge: RecordingStubBridge(flag: TouchFlag()), token: "correct-horse",
            socketPath: shortSocketPath())
        try await server.start()
        let path = await server.socketPath

        // A live, authenticated client...
        let fd = try #require(UDSClient.connect(path))
        UDSClient.send("correct-horse", fd: fd)
        UDSClient.send(Self.initializeLine, fd: fd)
        _ = try #require(UDSClient.readLine(fd: fd))

        // ...is hung up by stop() (the lock-silo / toggle-off path):
        await server.stop()
        #expect(UDSClient.readLine(fd: fd) == nil, "stop() severs in-flight clients")
        close(fd)
        #expect(
            !FileManager.default.fileExists(atPath: path),
            "stop() removes the socket node")
        #expect(UDSClient.connect(path) == nil, "nothing accepts after stop()")
    }
}

@Suite("MCP redaction accessors — unconditional (A35)", .serialized)
struct MCPRedactionAccessorTests {
    /// `seed` MUST differ per persona in one test: the random source derives the
    /// Nostr keypair, and two personas with one seed share an identity — the
    /// relay then cannot tell them apart and delivery silently collapses.
    private func makeRuntime(
        _ name: String, seed: UInt64, relay: LocalRelaySimulator? = nil
    ) async -> PersonaRuntime {
        let transport: any RelayTransport =
            if let relay { await relay.connect() } else { await LocalRelaySimulator().connect() }
        return await PersonaRuntime(
            displayName: name, transports: [transport],
            blobStore: LocalBlossomSimulator(), ais: [],
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-mcpgate-\(name)-\(UUID().uuidString)")
    }

    /// The accessors have NO firewall/toggle input — redaction is structural.
    /// My own sender is "you" (never the display name), and text is byte-bounded
    /// to 64 KB even when the stored message is larger.
    @Test func mcpMessages_selfSenderIsYou_textBoundedTo64KB() async throws {
        let runtime = await makeRuntime("Me", seed: 761)
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()

        let big = String(repeating: "a", count: 70_000)
        try await runtime.sendMessage(big, conversationID: chatID)

        let lines = await runtime.mcpMessages(conversationID: chatID, limit: 10)
        let line = try #require(lines.last)
        #expect(line.sender == "you", "self sender is the literal codename, not 'Me'")
        #expect(line.text.utf8.count <= 64 * 1024, "64 KB bound holds for oversized bodies")
        #expect(line.text.hasPrefix("aaaa"), "bounded text is a truncation, not a placeholder")
    }

    /// A peer's sender resolves to the device-local codename — never the peer's
    /// chosen display name, never identity hex (in sender OR conversation title).
    @Test func mcpAccessors_peerIsLocalCodename_neverDisplayNameOrHex() async throws {
        let relay = LocalRelaySimulator()
        let alice = await makeRuntime("Alice", seed: 771, relay: relay)
        let bob = await makeRuntime("Bob", seed: 781, relay: relay)
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: "hi")
        let aliceHex = await alice.identityHex
        let bobHex = await bob.identityHex
        try await bob.sendMessage("psst — secret plan", conversationID: aliceHex)

        // Poll for delivery instead of a fixed sleep (relay processing is async).
        var lines = await alice.mcpMessages(conversationID: bobHex, limit: 10)
        for _ in 0..<40 where !lines.contains(where: { $0.sender != "you" }) {
            try await Task.sleep(for: .milliseconds(100))
            lines = await alice.mcpMessages(conversationID: bobHex, limit: 10)
        }
        let fromBob = try #require(lines.first { $0.sender != "you" })
        #expect(fromBob.sender != "Bob", "never the peer's self-chosen display name")
        #expect(!fromBob.sender.contains(bobHex), "never identity hex")
        #expect(!fromBob.sender.isEmpty)

        let title = await alice.mcpConversationTitle(bobHex)
        #expect(!title.contains(bobHex), "title never degrades to identity hex")
        #expect(title == fromBob.sender, "title and sender share one codename source")

        // Search is redacted through the same single path.
        let hits = await alice.mcpSearch(query: "secret plan", limit: 5)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { !$0.sender.contains(bobHex) && $0.sender != "Bob" })

        await alice.shutdown()
        await bob.shutdown()
    }

    /// The bridge holds its model weakly: silo gone ⇒ every read is empty, every
    /// write refuses — never stale data, never an autonomous send.
    @Test func bridge_failsClosedOnceTheModelIsGone() async throws {
        let runtime = await makeRuntime("Me", seed: 791)
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("hello", conversationID: chatID)

        var model: AppModel? = await MainActor.run {
            AppModel(runtime: runtime, personaName: "Me")
        }
        let bridge = RuntimeSecureChatBridge(model: model!)
        model = nil  // silo locked / torn down

        #expect(await bridge.conversations().isEmpty)
        #expect(await bridge.messages(conversationID: chatID, limit: 10).isEmpty)
        let write = await bridge.sendAsMyAI(conversationID: chatID, text: "speak!")
        guard case .failedClosed = write else {
            Issue.record("a write with no model must fail closed, got \(write)")
            return
        }
    }
}
