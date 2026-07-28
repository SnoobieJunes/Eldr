// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// WS-BM1 / WS-BM2 — the human-member workspace client.
///
/// Companion to `BuzzInteropCryptoTests` (which pins the *agent*-plane codecs
/// against Block's own vectors). These pin the *workspace* plane: the NIP-98
/// credential that gets an Eldr user through Buzz's invite door, the invite link
/// grammar, the NIP-29 read models, and the three subscription rules Buzz's read
/// gate actually enforces.
///
/// No test here touches the network (CLAUDE.md): the REST calls run against a
/// stub transport, the relay calls against `LocalRelaySimulator`.

private let workspaceRandom = SeededRandomSource(seed: 0xB0_22_00_01)

private func testKeypair(_ byte: String) throws -> NostrKeypair {
    try NostrKeypair(privateKey: hexData(String(repeating: byte, count: 32)))
}

// MARK: - NIP-98

@Suite("Buzz workspace — NIP-98 HTTP auth")
struct BuzzNIP98Tests {

    @Test("header is `Nostr <base64>` and decodes to a valid signed kind-27235")
    func headerShape() throws {
        let keypair = try testKeypair("a1")
        let body = Data(#"{"code":"abc.def"}"#.utf8)
        let url = "https://relay.example/api/invites/claim"

        let header = try NIP98.authorizationHeader(
            method: "post", url: url, body: body, keypair: keypair,
            randomSource: workspaceRandom)

        #expect(header.hasPrefix("Nostr "))
        let event = try #require(NIP98.event(fromHeader: header))
        #expect(event.kind == 27235)
        #expect(event.pubkey == keypair.publicKeyHex)
        // Buzz verifies the Schnorr signature over the NIP-01 id.
        #expect(NostrKeypair.verify(event))
        #expect(event.firstTagValue("u") == url)
        // Their verifier compares the method case-insensitively; we still send
        // the canonical upper form.
        #expect(event.firstTagValue("method") == "POST")
    }

    @Test("payload tag is SHA-256 of the body — the anti-substitution binding")
    func payloadTagBindsBody() throws {
        let keypair = try testKeypair("a2")
        let body = Data(#"{"code":"abc.def"}"#.utf8)
        let event = NIP98.authorizationEvent(
            method: "POST", url: "https://r.example/x", body: body,
            pubkeyHex: keypair.publicKeyHex)
        #expect(event.firstTagValue("payload") == sha256(body).hexString)
    }

    @Test("no payload tag when there is no body")
    func noPayloadTagWithoutBody() throws {
        let keypair = try testKeypair("a3")
        let event = NIP98.authorizationEvent(
            method: "GET", url: "https://r.example/api/join-policy", body: nil,
            pubkeyHex: keypair.publicKeyHex)
        #expect(event.firstTagValue("payload") == nil)
        #expect(event.firstTagValue("method") == "GET")
    }

    @Test("URL normalisation matches Buzz's: lowercase host, strip trailing slash")
    func urlNormalisation() {
        #expect(
            NIP98.normalizedURL("https://Relay.Example/api/x/")
                == NIP98.normalizedURL("https://relay.example/api/x"))
        // A different path is still a different URL — normalisation is narrow.
        #expect(
            NIP98.normalizedURL("https://relay.example/api/x")
                != NIP98.normalizedURL("https://relay.example/api/y"))
    }

    @Test("a non-NIP-98 header decodes to nil rather than throwing")
    func malformedHeader() {
        #expect(NIP98.event(fromHeader: "Bearer token") == nil)
        #expect(NIP98.event(fromHeader: "Nostr !!!not-base64!!!") == nil)
        #expect(NIP98.event(fromHeader: "") == nil)
    }
}

// MARK: - Invite links

@Suite("Buzz workspace — invite links")
struct BuzzInviteLinkTests {

    @Test("canonical https invite maps to the wss relay + code")
    func httpsInvite() throws {
        let link = try #require(
            BuzzInviteLink.parse("https://auston.communities.buzz.xyz/invite/payload.mac"))
        #expect(link.relayURL == "wss://auston.communities.buzz.xyz")
        #expect(link.code == "payload.mac")
        #expect(link.policyReceipt == nil)
    }

    @Test("http invite maps to ws, and a port survives")
    func httpInviteWithPort() throws {
        let link = try #require(BuzzInviteLink.parse("http://localhost:3000/invite/abc.def"))
        #expect(link.relayURL == "ws://localhost:3000")
        #expect(link.code == "abc.def")
    }

    @Test("buzz://join handoff carries relay, code and policy receipt")
    func buzzJoinHandoff() throws {
        let link = try #require(
            BuzzInviteLink.parse(
                "buzz://join?relay=wss://relay.example&code=abc.def&policy_receipt=r123"))
        #expect(link.relayURL == "wss://relay.example")
        #expect(link.code == "abc.def")
        #expect(link.policyReceipt == "r123")
    }

    @Test("half-formed links parse to nil, never a partial target")
    func rejectsMalformed() {
        #expect(BuzzInviteLink.parse("https://relay.example/invite/") == nil)
        #expect(BuzzInviteLink.parse("https://relay.example/notinvite/abc") == nil)
        #expect(BuzzInviteLink.parse("buzz://join?relay=wss://r.example") == nil)  // no code
        #expect(BuzzInviteLink.parse("buzz://message?channel=x&id=y") == nil)  // wrong verb
        #expect(BuzzInviteLink.parse("buzz://join?relay=https://r.example&code=c") == nil)
        #expect(BuzzInviteLink.parse("nonsense") == nil)
    }

    @Test("REST endpoints are derived from the relay host, ws→http")
    func endpointDerivation() throws {
        #expect(
            try BuzzInviteClient.endpoint(
                relayURL: "wss://relay.example", path: "/api/invites/claim")
                == "https://relay.example/api/invites/claim")
        #expect(
            try BuzzInviteClient.endpoint(relayURL: "ws://localhost:3000", path: "/api/join-policy")
                == "http://localhost:3000/api/join-policy")
        // Buzz resolves the tenant from the Host header, so a non-ws scheme is
        // a programming error, not something to coerce.
        #expect(throws: BuzzInviteError.unsupportedRelayScheme("https")) {
            try BuzzInviteClient.endpoint(relayURL: "https://relay.example", path: "/x")
        }
    }
}

// MARK: - Invite claim (stub HTTP)

/// Records requests and replays canned responses — no network.
private actor StubHTTPTransport: BuzzHTTPTransport {
    private var responses: [BuzzHTTPResponse]
    private(set) var requests: [BuzzHTTPRequest] = []

    init(_ responses: [BuzzHTTPResponse]) { self.responses = responses }

    func send(_ request: BuzzHTTPRequest) async throws -> BuzzHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { return BuzzHTTPResponse(status: 500, body: Data()) }
        return responses.removeFirst()
    }
}

private func json(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

@Suite("Buzz workspace — invite claim")
struct BuzzInviteClaimTests {

    @Test("claim posts NIP-98-signed JSON to /api/invites/claim and decodes membership")
    func claimHappyPath() async throws {
        let keypair = try testKeypair("b1")
        let http = StubHTTPTransport([
            BuzzHTTPResponse(
                status: 200,
                body: json([
                    "status": "joined", "community_id": "c-1", "host": "relay.example",
                    "role": "member",
                ]))
        ])
        let client = BuzzInviteClient(
            relayURL: "wss://relay.example", randomSource: workspaceRandom, http: http)

        let result = try await client.claim(code: "abc.def", keypair: keypair)

        #expect(result.status == "joined")
        #expect(result.isNewMember)
        #expect(result.communityID == "c-1")
        #expect(result.role == "member")

        let requests = await http.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "POST")
        #expect(request.url == "https://relay.example/api/invites/claim")
        #expect(request.headers["Content-Type"] == "application/json")

        // The header must be a NIP-98 event over THIS url/method/body, or the
        // relay's verifier rejects it.
        let header = try #require(request.headers["Authorization"])
        let event = try #require(NIP98.event(fromHeader: header))
        #expect(NostrKeypair.verify(event))
        #expect(event.firstTagValue("u") == request.url)
        #expect(event.firstTagValue("method") == "POST")
        #expect(event.firstTagValue("payload") == sha256(try #require(request.body)).hexString)
        // The claiming pubkey is the one that becomes a member.
        #expect(event.pubkey == keypair.publicKeyHex)
    }

    @Test("a repeat claim is idempotent — already_member is not an error")
    func idempotentClaim() async throws {
        let http = StubHTTPTransport([
            BuzzHTTPResponse(
                status: 200,
                body: json([
                    "status": "already_member", "community_id": "c-1", "host": "h", "role": "member",
                ]))
        ])
        let client = BuzzInviteClient(
            relayURL: "wss://relay.example", randomSource: workspaceRandom, http: http)
        let result = try await client.claim(code: "abc.def", keypair: try testKeypair("b2"))
        #expect(result.isNewMember == false)
    }

    @Test("relay error codes map to typed errors")
    func errorMapping() async throws {
        let cases: [(Int, String, BuzzInviteError)] = [
            (403, "invite_expired", .expired),
            (403, "invite_invalid", .invalid),
            (403, "join_policy_required", .joinPolicyRequired),
            // Buzz's accept-policy handler returns this when the displayed
            // policy version is stale or an age attestation is missing.
            (400, "join_policy_not_accepted", .joinPolicyNotAccepted),
            (429, "too many invite claim attempts, slow down", .rateLimited),
        ]
        for (status, message, expected) in cases {
            let http = StubHTTPTransport([
                BuzzHTTPResponse(status: status, body: json(["error": message]))
            ])
            let client = BuzzInviteClient(
                relayURL: "wss://relay.example", randomSource: workspaceRandom, http: http)
            await #expect(throws: expected) {
                try await client.claim(code: "x", keypair: try testKeypair("b3"))
            }
        }
    }

    @Test("join policy decodes, and absent policy is nil not an error")
    func joinPolicy() async throws {
        let withPolicy = StubHTTPTransport([
            BuzzHTTPResponse(
                status: 200,
                body: json([
                    "policy": [
                        "terms_markdown": "# Terms", "privacy_markdown": "# Privacy",
                        "age_attestation_required": true, "version": "v3",
                    ]
                ]))
        ])
        let policy = try await BuzzInviteClient(
            relayURL: "wss://r.example", randomSource: workspaceRandom, http: withPolicy
        ).joinPolicy()
        #expect(policy?.version == "v3")
        #expect(policy?.ageAttestationRequired == true)

        let noPolicy = StubHTTPTransport([BuzzHTTPResponse(status: 200, body: json([:]))])
        let none = try await BuzzInviteClient(
            relayURL: "wss://r.example", randomSource: workspaceRandom, http: noPolicy
        ).joinPolicy()
        #expect(none == nil)
    }

    @Test("link claim fetches a policy receipt first when the operator requires one")
    func claimViaLinkAcquiresReceipt() async throws {
        let http = StubHTTPTransport([
            BuzzHTTPResponse(
                status: 200,
                body: json(["policy": ["age_attestation_required": false, "version": "v1"]])),
            BuzzHTTPResponse(status: 200, body: json(["receipt": "receipt-abc"])),
            BuzzHTTPResponse(
                status: 200,
                body: json([
                    "status": "joined", "community_id": "c", "host": "h", "role": "member",
                ])),
        ])
        let client = BuzzInviteClient(
            relayURL: "wss://relay.example", randomSource: workspaceRandom, http: http)
        let link = try #require(BuzzInviteLink.parse("https://relay.example/invite/abc.def"))

        _ = try await client.claim(link: link, keypair: try testKeypair("b4"))

        let requests = await http.requests
        #expect(requests.count == 3)
        #expect(requests[0].url.hasSuffix("/api/join-policy"))
        #expect(requests[1].url.hasSuffix("/api/invites/accept-policy"))
        #expect(requests[2].url.hasSuffix("/api/invites/claim"))
        // The receipt from step 2 must reach step 3, or the relay 403s.
        let body =
            try JSONSerialization.jsonObject(with: try #require(requests[2].body)) as? [String: Any]
        #expect(body?["policy_receipt"] as? String == "receipt-abc")
    }
}

// MARK: - Read models

@Suite("Buzz workspace — read models")
struct BuzzWorkspaceModelTests {

    @Test("kind:39000 decodes to a channel, flags included")
    func channelMetadata() throws {
        let event = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 39000,
            tags: [
                ["d", "uuid-1"], ["name", "general"], ["about", "the main room"], ["closed"],
                ["private"],
            ], content: "")
        let channel = try #require(BuzzChannel.from(metadataEvent: event))
        #expect(channel.id == "uuid-1")
        #expect(channel.name == "general")
        #expect(channel.about == "the main room")
        #expect(channel.isClosed)
        #expect(channel.isPrivate)
        #expect(channel.isHidden == false)
    }

    @Test("a Buzz DM channel is marked hidden — server-side, NOT an Eldr encrypted chat")
    func hiddenDMChannel() throws {
        let event = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 39000,
            tags: [["d", "dm-1"], ["name", "dm"], ["closed"], ["hidden"]], content: "")
        #expect(try #require(BuzzChannel.from(metadataEvent: event)).isHidden)
    }

    @Test("rosters decode and merge without losing the other half")
    func rosterMerge() throws {
        let adminsEvent = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 39001,
            tags: [["d", "uuid-1"], ["p", "AAA", "owner"], ["p", "bbb", "admin"]], content: "")
        let membersEvent = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 39002,
            tags: [["d", "uuid-1"], ["p", "aaa"], ["p", "bbb"], ["p", "ccc"]], content: "")
        let admins = try #require(BuzzRoster.admins(from: adminsEvent))
        let members = try #require(BuzzRoster.members(from: membersEvent))
        #expect(admins.admins["aaa"] == "owner")  // lowercased
        let merged = admins.merging(members)
        #expect(merged.admins.count == 2)
        #expect(merged.members == ["aaa", "bbb", "ccc"])
    }

    @Test("kind:9 and Buzz-only kind:40002 decode identically")
    func messageKindsAreEquivalent() throws {
        for kind in [9, 40002] {
            let event = NostrEvent(
                pubkey: "author", createdAt: 42, kind: kind,
                tags: [["h", "uuid-1"], ["p", "MENTIONED"], ["mention", "referenced"]],
                content: "hello")
            let message = try #require(BuzzMessage.from(event))
            #expect(message.content == "hello")
            #expect(message.channelID == "uuid-1")
            #expect(message.mentions == ["mentioned", "referenced"])
            #expect(message.isSystem == false)
            #expect(message.kind == kind)
        }
    }

    @Test("NIP-10 markers resolve root vs reply")
    func threadReferences() throws {
        let nested = NostrEvent(
            pubkey: "a", createdAt: 1, kind: 9,
            tags: [["h", "c"], ["e", "root-1", "", "root"], ["e", "parent-1", "", "reply"]],
            content: "x")
        let message = try #require(BuzzMessage.from(nested))
        #expect(message.threadRootEventID == "root-1")
        #expect(message.replyToEventID == "parent-1")

        // Direct reply: one marked e-tag is both.
        let direct = NostrEvent(
            pubkey: "a", createdAt: 1, kind: 9,
            tags: [["h", "c"], ["e", "root-1", "", "reply"]], content: "x")
        let flat = try #require(BuzzMessage.from(direct))
        #expect(flat.threadRootEventID == "root-1")
        #expect(flat.replyToEventID == "root-1")
    }

    @Test("a message without an h tag is not a channel message")
    func requiresChannelTag() {
        let event = NostrEvent(pubkey: "a", createdAt: 1, kind: 9, tags: [], content: "x")
        #expect(BuzzMessage.from(event) == nil)
    }

    @Test("membership notifications decode both directions")
    func membershipNotifications() throws {
        let added = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 44100, tags: [["p", "ME"], ["h", "c1"]],
            content: "")
        let change = try #require(BuzzMembershipChange.from(added))
        #expect(change.change == .added)
        #expect(change.pubkey == "me")
        #expect(change.channelID == "c1")

        let removed = NostrEvent(
            pubkey: "relay", createdAt: 1, kind: 44101, tags: [["p", "me"]], content: "")
        #expect(try #require(BuzzMembershipChange.from(removed)).change == .removed)
    }

    /// The keystone for WS-BM4. Buzz's relay validates only that kind:0 content is
    /// valid JSON and stores it verbatim; its side-effect handler reads just
    /// display_name/name/picture/about/nip05. That is what lets a PQRC prekey
    /// bundle live in a profile on a Buzz relay — but kind:0 is ABSOLUTE state,
    /// so a naive republish drops whatever else was there.
    @Test("profile merge preserves unknown fields — the kind:0 clobber guard")
    func profileMergePreservesUnknownFields() throws {
        let event = NostrEvent(
            pubkey: "abc", createdAt: 1, kind: 0, tags: [],
            content: #"{"display_name":"Ada","eldr_bundle":"BUNDLE","nip05":"ada@relay.example"}"#)
        let profile = try #require(BuzzProfile.from(event))
        #expect(profile.displayName == "Ada")
        #expect(profile.field("eldr_bundle") == "BUNDLE")

        let updated = profile.mergedContent(setting: ["display_name": "Ada L."])
        let object =
            try JSONSerialization.jsonObject(with: Data(updated.utf8)) as? [String: Any] ?? [:]
        #expect(object["display_name"] as? String == "Ada L.")
        #expect(object["eldr_bundle"] as? String == "BUNDLE")  // survived
        #expect(object["nip05"] as? String == "ada@relay.example")  // survived

        // An explicit nil removes exactly one key and nothing else.
        let cleared = profile.mergedContent(setting: ["eldr_bundle": nil])
        let after = try JSONSerialization.jsonObject(with: Data(cleared.utf8)) as? [String: Any] ?? [:]
        #expect(after["eldr_bundle"] == nil)
        #expect(after["display_name"] as? String == "Ada")
    }
}

// MARK: - Builders

@Suite("Buzz workspace — event builders")
struct BuzzWorkspaceBuilderTests {

    @Test("a channel message carries the h tag Buzz requires")
    func messageHasHTag() {
        let event = BuzzEvents.streamMessage(
            pubkey: "me", channelId: "uuid-1", content: "hi")
        #expect(event.kind == 9)
        #expect(event.firstTagValue("h") == "uuid-1")
    }

    @Test("reaction, deletion, join and leave carry their required tags")
    func memberActions() {
        let reaction = BuzzEvents.reaction(
            pubkey: "me", channelId: "c", targetEventId: "e1", targetAuthorPubkey: "AUTH",
            emoji: "🎉")
        #expect(reaction.kind == 7)
        #expect(reaction.content == "🎉")
        #expect(reaction.firstTagValue("e") == "e1")
        #expect(reaction.firstTagValue("p") == "auth")

        let deletion = BuzzEvents.deleteMessage(pubkey: "me", channelId: "c", targetEventId: "e1")
        #expect(deletion.kind == 5)
        #expect(deletion.firstTagValue("e") == "e1")

        #expect(BuzzEvents.joinRequest(pubkey: "me", channelId: "c").kind == 9021)
        #expect(BuzzEvents.leaveRequest(pubkey: "me", channelId: "c").kind == 9022)
        #expect(BuzzEvents.typingIndicator(pubkey: "me", channelId: "c").kind == 20002)
    }

    /// Not a style assertion — Buzz's `required_scope_for_kind` is a CLOSED
    /// allowlist whose fall-through is `restricted: unknown event kind`. Any
    /// kind we emit must be in their registry; PQRC's own 10420/10421/10422 are
    /// not, which is why identity bootstrap cannot ride a Buzz relay.
    @Test("every kind we emit is in Buzz's registry")
    func emittedKindsAreInBuzzRegistry() {
        let buzzRegistry: Set<Int> = [
            0, 5, 7, 9, 1059, 9000, 9001, 9007, 9021, 9022, 10100, 20001, 20002, 24200, 27235,
            30078, 39000, 39001, 39002, 40002, 40003, 40099, 44100, 44101, 44200,
        ]
        let emitted: Set<Int> = [
            BuzzEvents.Kind.profile, BuzzEvents.Kind.deletion, BuzzEvents.Kind.reaction,
            BuzzEvents.Kind.streamMessage, BuzzEvents.Kind.putUser, BuzzEvents.Kind.joinRequest,
            BuzzEvents.Kind.leaveRequest, BuzzEvents.Kind.typing, BuzzEvents.Kind.agentProfile,
            BuzzEvents.Kind.turnMetric, BuzzEvents.Kind.observerFrame, BuzzEvents.Kind.httpAuth,
        ]
        #expect(emitted.isSubset(of: buzzRegistry))
        // And the PQRC kinds are NOT — the documented reason identity bootstrap
        // needs an Eldr relay (or the kind:0 carrier).
        #expect(buzzRegistry.isDisjoint(with: [10420, 10421, 10422, 10050]))
    }
}

// MARK: - Client against the in-process relay

/// Wraps a transport and records every filter it is asked to subscribe with, so
/// the subscription rules Buzz's read gate enforces can be asserted.
private actor RecordingTransport: RelayTransport {
    private let inner: LocalRelayConnection
    private(set) var filters: [[NostrFilter]] = []

    init(_ inner: LocalRelayConnection) { self.inner = inner }

    func publish(_ event: NostrEvent) async throws -> PublishAck { try await inner.publish(event) }

    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        self.filters.append(filters)
        return await inner.subscribe(filters)
    }

    func subscribeFrames(_ filters: [NostrFilter]) async -> AsyncThrowingStream<
        SubscriptionFrame, Error
    > {
        self.filters.append(filters)
        return await inner.subscribeFrames(filters)
    }

    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        try await inner.authenticate(keypair: keypair, randomSource: randomSource)
    }

    func maxContentLength() async -> Int? { await inner.maxContentLength() }
}

@Suite("Buzz workspace — client over the in-process relay")
struct BuzzWorkspaceClientRelayTests {

    /// Seeds a relay with a channel, its roster and some history, then returns a
    /// connected client. `relaySigner` stands in for buzz-relay's own keypair,
    /// which signs the 39000/39001/39002 discovery events.
    private func makeClient() async throws -> (
        client: BuzzWorkspaceClient, transport: RecordingTransport, member: NostrKeypair,
        peer: NostrKeypair
    ) {
        let relay = LocalRelaySimulator()
        let relaySigner = try testKeypair("cc")  // stands in for buzz-relay's own key
        let member = try testKeypair("c1")
        let peer = try testKeypair("c2")
        let publisher = await relay.connect()

        // Relay-signed group state.
        let relayState: [NostrEvent] = [
            NostrEvent(
                pubkey: relaySigner.publicKeyHex, createdAt: 100, kind: 39000,
                tags: [["d", "uuid-1"], ["name", "general"], ["closed"]], content: ""),
            NostrEvent(
                pubkey: relaySigner.publicKeyHex, createdAt: 100, kind: 39000,
                tags: [["d", "uuid-2"], ["name", "announcements"], ["closed"]], content: ""),
            NostrEvent(
                pubkey: relaySigner.publicKeyHex, createdAt: 100, kind: 39002,
                tags: [["d", "uuid-1"], ["p", member.publicKeyHex], ["p", peer.publicKeyHex]],
                content: ""),
            NostrEvent(
                pubkey: relaySigner.publicKeyHex, createdAt: 100, kind: 39001,
                tags: [["d", "uuid-1"], ["p", peer.publicKeyHex, "owner"]], content: ""),
        ]
        for event in relayState {
            _ = try await publisher.publish(
                try relaySigner.sign(event, randomSource: workspaceRandom))
        }

        // Member-authored history — signed by the author, as a relay requires.
        let peerHistory: [NostrEvent] = [
            NostrEvent(
                pubkey: peer.publicKeyHex, createdAt: 110, kind: 9, tags: [["h", "uuid-1"]],
                content: "first"),
            NostrEvent(
                pubkey: peer.publicKeyHex, createdAt: 120, kind: 40002, tags: [["h", "uuid-1"]],
                content: "second (rich)"),
            // Noise in another channel — must not leak into uuid-1's history.
            NostrEvent(
                pubkey: peer.publicKeyHex, createdAt: 130, kind: 9, tags: [["h", "uuid-2"]],
                content: "elsewhere"),
        ]
        for event in peerHistory {
            _ = try await publisher.publish(try peer.sign(event, randomSource: workspaceRandom))
        }

        let transport = RecordingTransport(await relay.connect())
        let client = BuzzWorkspaceClient(
            transport: transport, keypair: member, randomSource: workspaceRandom,
            configuration: .init(relayURL: "wss://relay.example", storedEventTimeout: .seconds(2)))
        try await client.connect()
        return (client, transport, member, peer)
    }

    @Test("channels() returns the relay-signed group list, newest per d tag")
    func discoversChannels() async throws {
        let (client, _, _, _) = try await makeClient()
        let channels = try await client.channels()
        #expect(channels.map(\.id).sorted() == ["uuid-1", "uuid-2"])
        #expect(channels.first(where: { $0.id == "uuid-1" })?.name == "general")
    }

    @Test("roster() merges admins and members for one channel")
    func readsRoster() async throws {
        let (client, _, member, peer) = try await makeClient()
        let roster = try await client.roster(channelID: "uuid-1")
        #expect(roster.members.contains(member.publicKeyHex))
        #expect(roster.members.contains(peer.publicKeyHex))
        #expect(roster.admins[peer.publicKeyHex] == "owner")
    }

    @Test("history() is channel-scoped, ordered, and includes Buzz's kind:40002")
    func readsHistory() async throws {
        let (client, _, _, _) = try await makeClient()
        let history = try await client.history(channelID: "uuid-1")
        #expect(history.map(\.content) == ["first", "second (rich)"])
        #expect(history.contains { $0.kind == 40002 })
        #expect(history.allSatisfy { $0.channelID == "uuid-1" })
    }

    @Test("send() publishes a signed kind:9 carrying the h tag")
    func sendsMessage() async throws {
        let (client, _, member, _) = try await makeClient()
        let sent = try await client.send("hello workspace", to: "uuid-1")
        #expect(sent.kind == 9)
        #expect(sent.pubkey == member.publicKeyHex)
        #expect(sent.firstTagValue("h") == "uuid-1")
        #expect(NostrKeypair.verify(sent))

        let history = try await client.history(channelID: "uuid-1")
        #expect(history.contains { $0.content == "hello workspace" })
    }

    @Test("timeline() delivers live messages as decoded events")
    func liveTimeline() async throws {
        let (client, _, _, _) = try await makeClient()
        let stream = await client.timeline(channelID: "uuid-1", since: 1_000)
        let collector = Task { () -> BuzzWorkspaceEvent? in
            for try await event in stream { return event }
            return nil
        }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await client.send("live one", to: "uuid-1")

        let received = try await collector.value
        guard case .message(let message) = try #require(received) else {
            Issue.record("expected a message event, got \(String(describing: received))")
            return
        }
        #expect(message.content == "live one")
    }

    /// Buzz rejects a REQ that could match a p-gated kind unless every `#p` is
    /// the authenticated pubkey — and omitting `kinds` trips exactly that gate.
    @Test("every subscription enumerates kinds; p-gated ones filter on our own pubkey")
    func subscriptionRules() async throws {
        let (client, transport, member, _) = try await makeClient()
        _ = try await client.channels()
        _ = try await client.roster(channelID: "uuid-1")
        _ = try await client.history(channelID: "uuid-1")
        _ = await client.membershipChanges()
        _ = await client.timeline(channelID: "uuid-1")

        let recorded = await transport.filters.flatMap { $0 }
        #expect(!recorded.isEmpty)
        for filter in recorded {
            #expect(filter.kinds?.isEmpty == false, "a REQ without explicit kinds trips Buzz's gate")
        }
        let pGated = recorded.filter { filter in
            (filter.kinds ?? []).contains { [44100, 44101, 1059].contains($0) }
        }
        #expect(!pGated.isEmpty)
        for filter in pGated {
            #expect(filter.pTags == [member.publicKeyHex])
        }
    }

    @Test("over-long content is rejected, never silently truncated")
    func refusesToTruncate() async throws {
        let relay = LocalRelaySimulator()
        let transport = TinyLimitTransport(await relay.connect())
        let client = BuzzWorkspaceClient(
            transport: transport, keypair: try testKeypair("c9"), randomSource: workspaceRandom,
            configuration: .init(relayURL: "wss://relay.example"))
        await #expect(throws: BuzzWorkspaceError.contentTooLong(bytes: 40, limit: 16)) {
            try await client.send(String(repeating: "x", count: 40), to: "uuid-1")
        }
    }
}

/// A transport that advertises a tiny NIP-11 content limit, to prove the client
/// refuses rather than truncates.
private actor TinyLimitTransport: RelayTransport {
    private let inner: LocalRelayConnection
    init(_ inner: LocalRelayConnection) { self.inner = inner }
    func publish(_ event: NostrEvent) async throws -> PublishAck { try await inner.publish(event) }
    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        await inner.subscribe(filters)
    }
    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        try await inner.authenticate(keypair: keypair, randomSource: randomSource)
    }
    func maxContentLength() async -> Int? { 16 }
}

// MARK: - EOSE boundary

@Suite("Buzz workspace — stored/live boundary")
struct SubscriptionFrameTests {

    @Test("the in-process relay replays its backlog, then marks end-of-stored")
    func simulatorSurfacesEOSE() async throws {
        let relay = LocalRelaySimulator()
        let signer = try testKeypair("d1")
        let publisher = await relay.connect()
        for index in 0..<3 {
            let event = NostrEvent(
                pubkey: signer.publicKeyHex, createdAt: Int64(100 + index), kind: 9,
                tags: [["h", "c"]], content: "m\(index)")
            _ = try await publisher.publish(try signer.sign(event, randomSource: workspaceRandom))
        }

        let frames = await relay.connect().subscribeFrames([NostrFilter(kinds: [9], hTags: ["c"])])
        var stored: [String] = []
        for try await frame in frames {
            switch frame {
            case .event(let event): stored.append(event.content)
            case .endOfStoredEvents:
                #expect(stored == ["m0", "m1", "m2"])
                return
            }
        }
        Issue.record("stream ended without an end-of-stored-events marker")
    }

    @Test("the default implementation forwards events without claiming a boundary")
    func defaultImplementationHasNoBoundary() async throws {
        let transport = NoBoundaryTransport()
        let frames = await transport.subscribeFrames([NostrFilter(kinds: [9])])
        var seen = 0
        for try await frame in frames {
            if case .endOfStoredEvents = frame {
                Issue.record("default implementation must not synthesise a boundary")
            }
            seen += 1
        }
        #expect(seen == 1)
    }
}

/// Minimal conformer exercising the protocol-extension default.
private struct NoBoundaryTransport: RelayTransport {
    func publish(_ event: NostrEvent) async throws -> PublishAck {
        PublishAck(eventID: event.id, accepted: true)
    }
    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                NostrEvent(pubkey: "a", createdAt: 1, kind: 9, tags: [["h", "c"]], content: "only"))
            continuation.finish()
        }
    }
    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {}
}
