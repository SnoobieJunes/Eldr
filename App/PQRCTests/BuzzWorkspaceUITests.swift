// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrChat

/// WS-BM3 — the app-side workspace surface: routing, the per-workspace key
/// lifecycle, and the errors the UI has to render honestly.
///
/// No test here touches the network (CLAUDE.md): the invite claim runs against a
/// stub HTTP transport, and every Keychain service is unique per test so runs
/// cannot contaminate each other.
@Suite("Buzz workspaces (WS-BM3)")
struct BuzzWorkspaceUITests {

    private func freshRegistry() -> BuzzWorkspaceRegistry {
        let silo = "buzztest-\(UUID().uuidString)"
        return BuzzWorkspaceRegistry(
            siloID: silo, keychain: KeychainStore(service: "test-buzz-\(silo)"))
    }

    // MARK: - Routing

    /// A workspace channel rides `MainView`'s existing `String?` selection as a
    /// prefixed route. If this ever collided with a conversation id, selecting a
    /// channel would open someone's chat — so both directions are pinned.
    @Test("workspace routes round-trip and never collide with conversation ids")
    func routeRoundTrip() throws {
        let selection = BuzzRoute.selection(workspace: "ws-1", channel: "uuid-abc")
        let parsed = try #require(BuzzRoute.parse(selection))
        #expect(parsed.workspace == "ws-1")
        #expect(parsed.channel == "uuid-abc")

        // An Eldr conversation id (identity hex, or a group id) is never a route.
        #expect(BuzzRoute.parse(String(repeating: "ab", count: 32)) == nil)
        #expect(BuzzRoute.parse("group-123") == nil)
        #expect(BuzzRoute.parse("") == nil)
        // Malformed routes decode to nil rather than a half-formed target.
        #expect(BuzzRoute.parse("buzz:") == nil)
        #expect(BuzzRoute.parse("buzz:ws-only") == nil)
        #expect(BuzzRoute.parse("buzz:/channel") == nil)
        #expect(BuzzRoute.parse("buzz:ws/") == nil)
    }

    @Test("a channel id containing a slash still decodes")
    func routeWithSlashInChannel() throws {
        let parsed = try #require(BuzzRoute.parse(BuzzRoute.selection(workspace: "w", channel: "a/b")))
        #expect(parsed.workspace == "w")
        #expect(parsed.channel == "a/b")
    }

    // MARK: - Keys

    @Test("each workspace gets its OWN key, kept in the Keychain, never the Eldr identity")
    func perWorkspaceKeys() throws {
        let registry = freshRegistry()
        let first = try registry.mintKeypair(for: "ws-1")
        let second = try registry.mintKeypair(for: "ws-2")

        // Distinct keys — joining two workspaces must not link them.
        #expect(first.publicKeyHex != second.publicKeyHex)

        let record = BuzzWorkspaceRecord(
            id: "ws-1", relayURL: "wss://relay.example", name: "Test", communityID: "c",
            role: "member", pubkeyHex: first.publicKeyHex, joinedAt: 0)
        #expect(try registry.keypair(for: record).publicKeyHex == first.publicKeyHex)
        #expect(record.keychainAccount == "buzzws.ws-1")
    }

    @Test("forgetting a workspace destroys its key, not just the row")
    func forgetDestroysKey() throws {
        let registry = freshRegistry()
        let keypair = try registry.mintKeypair(for: "ws-1")
        let record = BuzzWorkspaceRecord(
            id: "ws-1", relayURL: "wss://relay.example", name: "Test", communityID: "c",
            role: "member", pubkeyHex: keypair.publicKeyHex, joinedAt: 0)
        registry.save([record])

        registry.forget(record)

        #expect(registry.load().isEmpty)
        // A leftover key is a usable workspace credential on a device the user
        // believes they have left.
        #expect(throws: (any Error).self) { try registry.keypair(for: record) }
    }

    @Test("records persist across registry instances")
    func recordsPersist() throws {
        let registry = freshRegistry()
        let record = BuzzWorkspaceRecord(
            id: "ws-1", relayURL: "wss://relay.example", name: "Test", communityID: "c",
            role: "member", pubkeyHex: "abc", joinedAt: 7)
        registry.save([record])

        let reopened = BuzzWorkspaceRegistry(siloID: registry.siloID, keychain: registry.keychain)
        #expect(reopened.load() == [record])
        #expect(reopened.load().first?.host == "relay.example")
    }

    // MARK: - Joining

    @Test("joining claims the invite with the fresh key and stores the record")
    func joinStoresRecord() async throws {
        let registry = freshRegistry()
        let http = StubClaimTransport(
            responses: [
                BuzzHTTPResponse(status: 200, body: Data("{}".utf8)),  // no join policy
                BuzzHTTPResponse(
                    status: 200,
                    body: Data(
                        #"{"status":"joined","community_id":"c-9","host":"relay.example","role":"member"}"#
                            .utf8)),
            ])
        let link = try #require(BuzzInviteLink.parse("https://relay.example/invite/abc.def"))

        let record = try await registry.join(link: link, name: "Test WS", http: http, now: 42)

        #expect(record.communityID == "c-9")
        #expect(record.role == "member")
        #expect(record.name == "Test WS")
        #expect(record.joinedAt == 42)
        #expect(registry.load() == [record])
        // The stored key is the one that claimed — the claiming pubkey is what
        // the relay made a member.
        #expect(try registry.keypair(for: record).publicKeyHex == record.pubkeyHex)
        let claim = try #require(await http.requests.last)
        let header = try #require(claim.headers["Authorization"])
        let event = try #require(NIP98.event(fromHeader: header))
        #expect(event.pubkey == record.pubkeyHex)
    }

    /// A claim that fails must not leave a usable credential behind for a
    /// workspace the user never joined.
    @Test("a failed claim leaves no orphan key and no record")
    func failedJoinCleansUp() async throws {
        let registry = freshRegistry()
        let http = StubClaimTransport(
            responses: [
                BuzzHTTPResponse(status: 200, body: Data("{}".utf8)),
                BuzzHTTPResponse(status: 403, body: Data(#"{"error":"invite_expired"}"#.utf8)),
            ])
        let link = try #require(BuzzInviteLink.parse("https://relay.example/invite/abc.def"))

        await #expect(throws: BuzzInviteError.expired) {
            try await registry.join(link: link, http: http)
        }
        #expect(registry.load().isEmpty)
        // Nothing was written to the Keychain that could still authenticate.
        let leaked = KeychainStore(service: registry.keychain.service)
        #expect(leaked.loadIfPresent(account: "buzzws.") == nil)
    }

    // MARK: - Error text

    /// The UI has to say something true. The relay's own words are more useful
    /// than "something went wrong", and a plaintext boundary must never be
    /// described as encrypted.
    @Test("errors render as honest, specific text")
    func errorText() {
        #expect(
            BuzzWorkspaceModel.describe(BuzzInviteError.expired)
                == "That invite has expired. Ask for a fresh link.")
        #expect(
            BuzzWorkspaceModel.describe(BuzzWorkspaceError.rejected(reason: "restricted: not a member"))
                .contains("restricted: not a member"))
        let tooLong = BuzzWorkspaceModel.describe(
            BuzzWorkspaceError.contentTooLong(bytes: 900, limit: 256))
        #expect(tooLong.contains("900"))
        #expect(tooLong.contains("256"))
        // Never silently truncated — the user is told to split it themselves.
        #expect(tooLong.lowercased().contains("split"))
    }

    // MARK: - Model over an in-process relay

    /// Drives the whole app-side loop — connect, discover, open, send, receive —
    /// against `LocalRelaySimulator` through the injected transport seam.
    @MainActor
    @Test("the model connects, lists channels, and round-trips a sent message")
    func modelRoundTrip() async throws {
        let registry = freshRegistry()
        let keypair = try registry.mintKeypair(for: "ws-1")
        let record = BuzzWorkspaceRecord(
            id: "ws-1", relayURL: "wss://relay.example", name: "Test", communityID: "c",
            role: "member", pubkeyHex: keypair.publicKeyHex, joinedAt: 0)
        registry.save([record])

        let relay = LocalRelaySimulator()
        let relaySigner = try NostrKeypair(randomSource: SystemRandomSource())
        let publisher = await relay.connect()
        let metadata = NostrEvent(
            pubkey: relaySigner.publicKeyHex, createdAt: 100, kind: 39000,
            tags: [["d", "uuid-1"], ["name", "general"], ["closed"]], content: "")
        _ = try await publisher.publish(
            try relaySigner.sign(metadata, randomSource: SystemRandomSource()))

        let model = BuzzWorkspaceModel(
            registry: registry, makeTransport: { _ in await relay.connect() })
        await model.connect(record)

        #expect(model.connectionState("ws-1") == .connected)
        #expect(model.channels["ws-1"]?.map(\.id) == ["uuid-1"])

        await model.openChannel("uuid-1", in: "ws-1")
        let sent = await model.send("hello workspace", to: "uuid-1", in: "ws-1")
        #expect(sent)
        #expect(model.lastError["ws-1"] == nil)

        // The message comes back through the live subscription, decoded and
        // attributed to us.
        try await Task.sleep(for: .milliseconds(200))
        let messages = model.messages[BuzzWorkspaceModel.key("ws-1", "uuid-1")] ?? []
        let mine = try #require(messages.first { $0.content == "hello workspace" })
        #expect(model.isMine(mine, in: "ws-1"))
    }

    /// SwiftUI re-runs a row's `.task` on rebuild; without the guard this would
    /// open a second socket and orphan the first.
    @MainActor
    @Test("connecting twice does not open a second transport")
    func connectIsIdempotent() async throws {
        let registry = freshRegistry()
        let keypair = try registry.mintKeypair(for: "ws-1")
        let record = BuzzWorkspaceRecord(
            id: "ws-1", relayURL: "wss://relay.example", name: "Test", communityID: "c",
            role: "member", pubkeyHex: keypair.publicKeyHex, joinedAt: 0)
        registry.save([record])

        let relay = LocalRelaySimulator()
        let counter = DialCounter()
        let model = BuzzWorkspaceModel(
            registry: registry,
            makeTransport: { _ in
                await counter.increment()
                return await relay.connect()
            })

        await model.connect(record)
        await model.connect(record)
        await model.connect(record)

        #expect(await counter.count == 1)
    }

    @Test("the disclosure says plainly who can read a workspace message")
    func disclosureIsHonest() {
        let text = BuzzWorkspaceModel.disclosure.lowercased()
        #expect(text.contains("readable by whoever runs it"))
        #expect(text.contains("not end-to-end encrypted"))
        // And it must not leave the reader thinking Eldr chats lost anything.
        #expect(text.contains("your eldr chats"))
    }
}

/// Counts how many times the transport factory was asked to dial.
private actor DialCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// Canned HTTP for the invite flow.
private actor StubClaimTransport: BuzzHTTPTransport {
    private var responses: [BuzzHTTPResponse]
    private(set) var requests: [BuzzHTTPRequest] = []

    init(responses: [BuzzHTTPResponse]) { self.responses = responses }

    func send(_ request: BuzzHTTPRequest) async throws -> BuzzHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { return BuzzHTTPResponse(status: 500, body: Data()) }
        return responses.removeFirst()
    }
}
