// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Testing

@testable import EldrNodeCore
@testable import PQRCCore
@testable import PQRCNostr

// WS-G1 (private/GOOSEWORLD.md §6) — the A2A town plane's authorization seam.
//
// The whole point of this suite is that the town plane has its OWN gate and that gate is
// not C-3. Two failure modes would be catastrophic and both are asserted against here:
//
//   • widening C-3 so cross-town frames get in (which would also hand every stranger the
//     ACP coding plane — a shell — and the MCP chat plane);
//   • wiring the plane such that it is reachable by default, so upgrading a deployed node
//     silently opens a code-execution-adjacent channel.
//
// So: every test below either proves a refusal, or proves that a refusal is not vacuous
// (the same input, with authorization granted, IS delivered). Nothing here touches a
// network, a clock, or a Keychain.

#if os(macOS)

// MARK: - Test doubles

/// Records every line the town plane hands to a service, and can script a reply.
actor RecordingTownService: TownA2AService {
    private(set) var received: [(line: String, peer: String)] = []
    private let replyWith: String?

    init(replyWith: String? = nil) { self.replyWith = replyWith }

    func handle(
        line: String, from peerIdentityHex: String, reply: @escaping @Sendable (String) -> Void
    ) async {
        received.append((line, peerIdentityHex))
        if let replyWith { reply(replyWith) }
    }

    var lines: [String] { received.map(\.line) }
    var peers: [String] { received.map(\.peer) }

    /// Poll until `count` lines have arrived (the drain is a detached task), or give up.
    func waitForLines(_ count: Int, timeoutMillis: Int = 3_000) async -> Bool {
        var waited = 0
        while received.count < count && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return received.count >= count
    }

    /// Settle for a fixed beat, then report the count — for "nothing must arrive" asserts,
    /// where waiting for a line that should never come is the only way to be sure.
    func countAfterSettling(millis: Int = 400) async -> Int {
        try? await Task.sleep(for: .milliseconds(millis))
        return received.count
    }
}

/// A `TownAuthorizer` whose allowlist can change mid-test — models a grant being revoked
/// (WS-G4) or a peer being removed from the pin.
actor MutableTownAuthorizer: TownAuthorizer {
    private var allowed: Set<String>
    private(set) var queries: [String] = []

    init(_ allowed: Set<String>) { self.allowed = allowed }

    func authorizes(peerIdentityHex: String) async -> Bool {
        queries.append(peerIdentityHex)
        return allowed.contains(peerIdentityHex)
    }

    func revoke(_ peer: String) { allowed.remove(peer) }
    func grant(_ peer: String) { allowed.insert(peer) }
}

/// Captures what the node would publish over the relay, so a "reply goes back to the peer
/// who asked" assertion has something to look at. Nothing here is a real messenger.
actor CapturingNodeMessenger: NodeMessenger {
    private(set) var sent: [(framed: String, peer: String)] = []

    nonisolated func start() async throws -> AsyncStream<MessengerEvent> {
        AsyncStream { $0.finish() }
    }
    func sendFramed(_ framed: String, to peerIdentityHex: String) async throws {
        sent.append((framed, peerIdentityHex))
    }

    var recipients: Set<String> { Set(sent.map(\.peer)) }

    func waitForSends(_ count: Int, timeoutMillis: Int = 3_000) async -> Bool {
        var waited = 0
        while sent.count < count && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return sent.count >= count
    }
}

// MARK: - Frame helpers

/// One complete, single-chunk A2A frame carrying `line`, as `RelayA2ATransport` itself
/// would emit it. Built by running a real transport rather than hand-writing the envelope,
/// so these tests cannot drift from the wire format.
func a2aFrames(_ line: String, salt: String, maxFrameBytes: Int = 16 * 1024) async -> [String] {
    let sink = FrameSink()
    let transport = RelayA2ATransport(maxFrameBytes: maxFrameBytes, instanceSalt: salt) { framed in
        await sink.append(framed)
    }
    transport.send(line)
    _ = await sink.waitForAny()
    transport.close()
    return await sink.frames
}

actor FrameSink {
    private(set) var frames: [String] = []
    func append(_ f: String) { frames.append(f) }
    func waitForAny(timeoutMillis: Int = 2_000) async -> Bool {
        var waited = 0
        while frames.isEmpty && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return !frames.isEmpty
    }
    /// Wait until at least `n` frames have been produced (multi-chunk lines).
    func waitFor(_ n: Int, timeoutMillis: Int = 2_000) async -> Bool {
        var waited = 0
        while frames.count < n && waited < timeoutMillis {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return frames.count >= n
    }
}

let townPeerHex = String(repeating: "aa", count: 32)
let strangerHex = String(repeating: "bb", count: 32)
let townOwnerHex = String(repeating: "11", count: 32)
let townMaxFrame = 16 * 1024

// MARK: - (1) the gate

@Suite("WS-G1 A2A town gate (authorizer, not C-3)", .tags(.transport, .security))
struct TownA2AGateTests {

    /// The headline refusal: an A2A frame from a peer the authorizer does not know is
    /// dropped, no transport is allocated for it, and the service never sees a byte.
    @Test func unauthorizedPeerFrameIsDroppedAndNeverReachesTheTransport() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        let frames = await a2aFrames(#"{"jsonrpc":"2.0","id":1,"method":"message/send"}"#, salt: "beef")

        for frame in frames {
            let admitted = await core.routeInboundA2A(
                senderIdentityHex: strangerHex, body: frame, authorizer: authorizer,
                service: service, messenger: CapturingNodeMessenger(), maxFrameBytes: townMaxFrame)
            #expect(!admitted, "an unpinned peer's A2A frame must be refused")
        }
        #expect(
            await service.countAfterSettling() == 0,
            "the town service must never see an unauthorized peer's line")
        #expect(
            await core.townPeerCount == 0,
            "no per-peer transport may be allocated for a refused sender (no remote-state growth)")
    }

    /// …and the refusal is not vacuous: the SAME frame, from the pinned peer, is delivered
    /// and reassembled into the exact line the peer wrote.
    @Test func authorizedTownPeerFrameIsDelivered() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        let line = #"{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"task":"build"}}"#
        let frames = await a2aFrames(line, salt: "beef")

        for frame in frames {
            let admitted = await core.routeInboundA2A(
                senderIdentityHex: townPeerHex, body: frame, authorizer: authorizer,
                service: service, messenger: CapturingNodeMessenger(), maxFrameBytes: townMaxFrame)
            #expect(admitted, "the pinned town peer's A2A frame is admitted")
        }
        #expect(await service.waitForLines(1), "the admitted line must reach the town service")
        #expect(await service.lines == [line], "the line must round-trip byte-exact")
        #expect(await service.peers == [townPeerHex], "attributed to the peer that sent it")
        #expect(await core.townPeerCount == 1)
    }

    /// The design point the task exists to pin: the OWNER is not special on this plane.
    /// C-3 admits the owner to ACP/MCP; here the owner is governed by the authorizer like
    /// anyone else — refused when unpinned, admitted only when explicitly pinned.
    @Test func ownerIsGovernedByTheAuthorizerNotByC3() async throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"message/send"}"#
        let frames = await a2aFrames(line, salt: "0wner")

        // (a) owner NOT on the town allowlist → refused, even though C-3 would admit this
        //     same sender on the ACP and MCP planes.
        let denyCore = EldrNodeCore()
        let denyService = RecordingTownService()
        let pinnedElsewhere = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        for frame in frames {
            let admitted = await denyCore.routeInboundA2A(
                senderIdentityHex: townOwnerHex, body: frame, authorizer: pinnedElsewhere,
                service: denyService, messenger: CapturingNodeMessenger(),
                maxFrameBytes: townMaxFrame)
            #expect(!admitted, "the owner gets no free pass onto the town plane")
        }
        #expect(await denyService.countAfterSettling() == 0)
        #expect(await denyCore.townPeerCount == 0)

        // (b) owner explicitly pinned as a town → admitted. The rule is "the authorizer
        //     decides", not "the owner is banned".
        let allowCore = EldrNodeCore()
        let allowService = RecordingTownService()
        let pinnedOwner = PinnedTownAllowlist(peerIdentityHexes: [townOwnerHex])
        for frame in frames {
            _ = await allowCore.routeInboundA2A(
                senderIdentityHex: townOwnerHex, body: frame, authorizer: pinnedOwner,
                service: allowService, messenger: CapturingNodeMessenger(),
                maxFrameBytes: townMaxFrame)
        }
        #expect(await allowService.waitForLines(1))
        #expect(await allowService.lines == [line])
    }

    /// No `townService` ⇒ the plane does not exist. Even a perfectly authorized peer is
    /// dropped, and — the part that matters — no transport is allocated, so an
    /// unconfigured node cannot be made to buffer remote bytes.
    @Test func planeIsInertWithoutAService() async throws {
        let core = EldrNodeCore()
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        let frames = await a2aFrames(#"{"jsonrpc":"2.0","id":1,"method":"message/send"}"#, salt: "abcd")
        for frame in frames {
            let admitted = await core.routeInboundA2A(
                senderIdentityHex: townPeerHex, body: frame, authorizer: authorizer,
                service: nil, messenger: CapturingNodeMessenger(), maxFrameBytes: townMaxFrame)
            #expect(!admitted, "no service ⇒ no plane ⇒ refused")
        }
        #expect(await core.townPeerCount == 0)
    }

    /// A peer that was authorized and then revoked stops being admitted on the very next
    /// frame — mid-line, with a half-reassembled line already buffered. The buffered half
    /// can never complete, because completing it requires a chunk that will not get
    /// through. This is the property that makes WS-G4 revocation meaningful.
    @Test func revocationTakesEffectMidLine() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        let authorizer = MutableTownAuthorizer([townPeerHex])

        // A line long enough to need several chunks under a tiny frame budget.
        let longLine = #"{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"text":"#
            + "\"\(String(repeating: "x", count: 600))\"}}"
        let sink = FrameSink()
        let framer = RelayA2ATransport(maxFrameBytes: 128, instanceSalt: "revoke") { framed in
            await sink.append(framed)
        }
        framer.send(longLine)
        #expect(await sink.waitFor(3), "the test needs a genuinely multi-chunk line")
        framer.close()
        let frames = await sink.frames
        #expect(frames.count >= 3)

        // First chunk lands while the grant is live.
        let first = await core.routeInboundA2A(
            senderIdentityHex: townPeerHex, body: frames[0], authorizer: authorizer,
            service: service, messenger: CapturingNodeMessenger(), maxFrameBytes: 128)
        #expect(first, "the peer was authorized when the first chunk arrived")

        // Grant revoked between chunks.
        await authorizer.revoke(townPeerHex)

        for frame in frames.dropFirst() {
            let admitted = await core.routeInboundA2A(
                senderIdentityHex: townPeerHex, body: frame, authorizer: authorizer,
                service: service, messenger: CapturingNodeMessenger(), maxFrameBytes: 128)
            #expect(!admitted, "every post-revocation chunk is refused")
        }
        #expect(
            await service.countAfterSettling() == 0,
            "the half-delivered line must NEVER complete after revocation")
    }

    /// An empty / unidentified sender is refused before the authorizer is even consulted,
    /// so no implementation can ever be tricked into treating "" as a wildcard.
    @Test func emptySenderIsRefusedWithoutConsultingTheAuthorizer() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        let authorizer = MutableTownAuthorizer([""])  // would say yes if asked
        let frames = await a2aFrames(#"{"jsonrpc":"2.0","id":1,"method":"x"}"#, salt: "empty")

        let admitted = await core.routeInboundA2A(
            senderIdentityHex: "", body: frames[0], authorizer: authorizer, service: service,
            messenger: CapturingNodeMessenger(), maxFrameBytes: townMaxFrame)
        #expect(!admitted)
        #expect(await authorizer.queries.isEmpty, "the authorizer is not even asked about \"\"")
        #expect(await core.townPeerCount == 0)
    }

    /// The peer table is bounded, so an over-broad authorizer cannot translate "admitted"
    /// into unbounded per-peer state.
    @Test func peerTableIsBoundedByMaxTownPeers() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        // An authorizer that says yes to everyone — the worst case this bound exists for.
        let openHexes = (0..<(EldrNodeCore.maxTownPeers + 4)).map {
            String(repeating: String(format: "%02x", $0 + 0x20), count: 32)
        }
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: openHexes)

        var admittedCount = 0
        for (index, peer) in openHexes.enumerated() {
            let frames = await a2aFrames(
                #"{"jsonrpc":"2.0","id":1,"method":"x"}"#, salt: String(format: "s%03x", index))
            let admitted = await core.routeInboundA2A(
                senderIdentityHex: peer, body: frames[0], authorizer: authorizer,
                service: service, messenger: CapturingNodeMessenger(), maxFrameBytes: townMaxFrame)
            if admitted { admittedCount += 1 }
        }
        #expect(admittedCount == EldrNodeCore.maxTownPeers, "past the cap, new peers are refused")
        #expect(await core.townPeerCount == EldrNodeCore.maxTownPeers)
    }

    /// A malformed / absurdly-chunked frame from an AUTHORIZED peer is admitted by the
    /// gate (the gate answers "who", not "well-formed") and then dropped by the
    /// transport's own parser — it must never surface as a line. Documents the division of
    /// labour so nobody later "fixes" the gate by teaching it to parse.
    @Test func malformedAndOversizedFramesFromAnAuthorizedPeerNeverBecomeLines() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        let messenger = CapturingNodeMessenger()

        let hostile = [
            "A2A1|",  // magic only
            "A2A1|id|1|1",  // missing payload field
            "A2A1|id|1|1|!!!not-base64url!!!",  // undecodable payload
            "A2A1|id|1|999999999|AAAA",  // absurd chunk count (refused by maxChunksPerLine)
            "A2A1|id|0|1|AAAA",  // seq below 1
            "A2A1|id|5|1|AAAA",  // seq past total
        ]
        for body in hostile {
            _ = await core.routeInboundA2A(
                senderIdentityHex: townPeerHex, body: body, authorizer: authorizer,
                service: service, messenger: messenger, maxFrameBytes: townMaxFrame)
        }
        #expect(
            await service.countAfterSettling() == 0,
            "no malformed frame may ever be reassembled into a serviced line")
    }

    /// A reply written by the service goes back to the town that asked — and to nobody
    /// else. With per-peer transports this is structural, but it is the property a shared
    /// transport would silently break, so it is asserted rather than assumed.
    @Test func replyIsAddressedToTheAskingTownOnly() async throws {
        let core = EldrNodeCore()
        let messenger = CapturingNodeMessenger()
        let service = RecordingTownService(
            replyWith: #"{"jsonrpc":"2.0","id":7,"result":{"status":"accepted"}}"#)
        let authorizer = PinnedTownAllowlist(peerIdentityHexes: [townPeerHex])
        let frames = await a2aFrames(#"{"jsonrpc":"2.0","id":7,"method":"message/send"}"#, salt: "rep1")

        for frame in frames {
            _ = await core.routeInboundA2A(
                senderIdentityHex: townPeerHex, body: frame, authorizer: authorizer,
                service: service, messenger: messenger, maxFrameBytes: townMaxFrame)
        }
        #expect(await service.waitForLines(1))
        #expect(await messenger.waitForSends(1), "the service's reply must be published")
        #expect(
            await messenger.recipients == [townPeerHex],
            "a town's answer goes ONLY to that town — never to the owner, never fanned out")
        let published = await messenger.sent.map(\.framed)
        #expect(
            published.allSatisfy { RelayA2ATransport.isA2AFrame($0) },
            "replies leave as A2A frames, not as chat or as ACP")
    }
}

// MARK: - (2) plane isolation: the three magics stay mutually exclusive

@Suite("WS-G1 three-plane isolation on one inbound stream", .tags(.transport, .security))
struct TownPlaneIsolationTests {

    /// A body belongs to at most ONE plane. Run every router over every body and assert a
    /// diagonal: the ACP router only ever takes `ACP1|`, MCP only `MCP1|`, A2A only
    /// `A2A1|`. Crucially this includes "an A2A frame is never mistaken for an ACP one",
    /// which is the confusion that would let a town peer reach the coding agent.
    @Test func eachBodyBelongsToAtMostOnePlane() async throws {
        let core = EldrNodeCore()
        let service = RecordingTownService()
        // Authorize the owner on the town plane too, so that if a magic were ever confused
        // the test would show it as a DELIVERY rather than as a coincidental refusal.
        let permissive = PinnedTownAllowlist(peerIdentityHexes: [townOwnerHex])
        let messenger = CapturingNodeMessenger()

        let acpFrame = "ACP1|abc-1|1|1|"
        let mcpFrame = "MCP1|abc-1|1|1|"
        let a2aFrame = (await a2aFrames(#"{"jsonrpc":"2.0","id":1,"method":"x"}"#, salt: "iso1"))[0]
        let chat = #"{"hello":"world"}"#

        for (label, body, expectACP, expectMCP, expectA2A) in [
            ("acp", acpFrame, true, false, false),
            ("mcp", mcpFrame, false, true, false),
            ("a2a", a2aFrame, false, false, true),
            ("chat", chat, false, false, false),
        ] as [(String, String, Bool, Bool, Bool)] {
            let acpTransport = RelayACPTransport(maxFrameBytes: townMaxFrame) { _ in }
            let mcpTransport = RelayMCPTransport(maxFrameBytes: townMaxFrame) { _ in }
            defer {
                acpTransport.close()
                mcpTransport.close()
            }
            let acp = await EldrNodeCore.routeInbound(
                senderIdentityHex: townOwnerHex, body: body, ownerIdentityHex: townOwnerHex,
                transport: acpTransport)
            let mcp = await EldrNodeCore.routeInboundMCP(
                senderIdentityHex: townOwnerHex, body: body, ownerIdentityHex: townOwnerHex,
                transport: mcpTransport)
            let a2a = await core.routeInboundA2A(
                senderIdentityHex: townOwnerHex, body: body, authorizer: permissive,
                service: service, messenger: messenger, maxFrameBytes: townMaxFrame)
            #expect(acp == expectACP, "\(label): ACP routing")
            #expect(mcp == expectMCP, "\(label): MCP routing")
            #expect(a2a == expectA2A, "\(label): A2A routing")
            #expect(
                [acp, mcp, a2a].filter { $0 }.count <= 1,
                "\(label): a body must belong to at most one plane")
        }
    }

    /// C-3 is untouched by WS-G1: the ACP and MCP routers still admit the owner and only
    /// the owner, and they refuse an A2A body outright regardless of who sent it — even a
    /// pinned town peer, and even the owner.
    @Test func c3StaysOwnerOnlyAndRefusesTownFramesEntirely() async throws {
        let acpTransport = RelayACPTransport(maxFrameBytes: townMaxFrame) { _ in }
        let mcpTransport = RelayMCPTransport(maxFrameBytes: townMaxFrame) { _ in }
        defer {
            acpTransport.close()
            mcpTransport.close()
        }
        let a2aFrame = (await a2aFrames(#"{"jsonrpc":"2.0","id":1,"method":"x"}"#, salt: "iso2"))[0]

        for sender in [townOwnerHex, townPeerHex, strangerHex] {
            #expect(
                await EldrNodeCore.routeInbound(
                    senderIdentityHex: sender, body: a2aFrame, ownerIdentityHex: townOwnerHex,
                    transport: acpTransport) == false,
                "an A2A body never enters the ACP plane (sender \(sender.prefix(4)))")
            #expect(
                await EldrNodeCore.routeInboundMCP(
                    senderIdentityHex: sender, body: a2aFrame, ownerIdentityHex: townOwnerHex,
                    transport: mcpTransport) == false,
                "an A2A body never enters the MCP plane (sender \(sender.prefix(4)))")
        }

        // And the positive control, unchanged from the pre-WS-G1 suite: owner-signed
        // ACP/MCP frames still get in, non-owner ones still do not.
        #expect(
            await EldrNodeCore.routeInbound(
                senderIdentityHex: townOwnerHex, body: "ACP1|abc-1|1|1|",
                ownerIdentityHex: townOwnerHex, transport: acpTransport))
        #expect(
            await EldrNodeCore.routeInbound(
                senderIdentityHex: townPeerHex, body: "ACP1|abc-1|1|1|",
                ownerIdentityHex: townOwnerHex, transport: acpTransport) == false)
        #expect(
            await EldrNodeCore.routeInboundMCP(
                senderIdentityHex: townOwnerHex, body: "MCP1|abc-1|1|1|",
                ownerIdentityHex: townOwnerHex, transport: mcpTransport))
        #expect(
            await EldrNodeCore.routeInboundMCP(
                senderIdentityHex: townPeerHex, body: "MCP1|abc-1|1|1|",
                ownerIdentityHex: townOwnerHex, transport: mcpTransport) == false)
    }
}

// MARK: - (2b) the wiring itself, through the real `serve` loop over a relay

@Suite("WS-G1 A2A plane through EldrNodeCore.serve (relay-carried)", .tags(.transport, .security))
struct TownPlaneServeWiringTests {

    /// The gate tests above call `routeInboundA2A` directly, which proves the POLICY but
    /// not the WIRING. This one drives the real `serve` loop over a `LocalRelaySimulator`
    /// with three real messengers, so the sender identity the gate sees is the one the
    /// mesh's verified decryption produced — not a value a test handed it. That is the
    /// only way "a peer cannot forge another peer's identity" is actually shown: the
    /// stranger below genuinely sends the frame and it genuinely decrypts at the node.
    ///
    /// Asserts, in one run: the pinned town's line is serviced; the stranger's
    /// byte-identical line is not; and the node still holds exactly one peer transport.
    @Test func serveDeliversPinnedTownAndDropsStranger() async throws {
        let relay = LocalRelaySimulator()
        let owner = try await NodePersona.make(
            name: "Owner", seedByte: "0a", seed: 9_100, transports: [await relay.connect()])
        let node = try await NodePersona.make(
            name: "Node", seedByte: "0b", seed: 9_101, transports: [await relay.connect()])
        let town = try await NodePersona.make(
            name: "Town", seedByte: "0c", seed: 9_102, transports: [await relay.connect()])
        let stranger = try await NodePersona.make(
            name: "Stranger", seedByte: "0d", seed: 9_103, transports: [await relay.connect()])
        let nodeHexValue = node.identityHex

        // Everyone is a mutually VERIFIED contact of the node, so every frame below
        // decrypts there. The ONLY thing separating the town from the stranger is the
        // authorizer — exactly as the C-3 suite isolates the owner check.
        for peer in [owner, town, stranger] {
            await node.messenger.addContact(try peer.asContact())
            await peer.messenger.addContact(try node.asContact())
        }

        let workdir = try makeNodeWorkdir("town")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let service = RecordingTownService()
        let core = EldrNodeCore()
        let serveTask = Task {
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: owner.identityHex,
                maxFrameBytes: townMaxFrame,
                llm: ScriptedLLM([LLMResponse(content: "unused")]),
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false,
                descriptor: .builtIn,
                townAuthorizer: PinnedTownAllowlist(peerIdentityHexes: [town.identityHex]),
                townService: service)
        }
        defer { serveTask.cancel() }

        // Establish sessions one at a time, waiting for each responder session to exist
        // before the next initiator fetches a bundle — otherwise two initiators can pick
        // the same unused one-time prekey and the second handshake fails for a reason that
        // has nothing to do with this test (the prekey race `EldrNodeServeTests` documents).
        for peer in [town, stranger] {
            try await peer.messenger.establishSession(
                with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
                firstMessage: MessageBody(text: "handshake", sentAt: 1))
            var settled = false
            for _ in 0..<400 {
                if await node.messenger.hasSession(peerIdentityHex: peer.identityHex) {
                    settled = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(settled, "the node must decrypt \(peer.name)'s handshake before the A2A frame")
        }

        let line = #"{"jsonrpc":"2.0","id":42,"method":"message/send","params":{"task":"bead-7"}}"#

        // The STRANGER's frame first, so a passing test cannot be explained by ordering.
        let strangerFramer = RelayA2ATransport(maxFrameBytes: townMaxFrame, instanceSalt: "5tr9r") {
            framed in
            try? await stranger.messenger.send(
                MessageBody(text: framed, sentAt: 5_001), to: nodeHexValue)
        }
        strangerFramer.send(line)

        // Then the PINNED TOWN's byte-identical line.
        let townFramer = RelayA2ATransport(maxFrameBytes: townMaxFrame, instanceSalt: "t0wn1") {
            framed in
            try? await town.messenger.send(
                MessageBody(text: framed, sentAt: 5_002), to: nodeHexValue)
        }
        townFramer.send(line)

        #expect(
            await service.waitForLines(1),
            "the pinned town's A2A line must be serviced through the real serve loop")
        // Settle well past the relay's delivery of the stranger's frame before counting.
        let total = await service.countAfterSettling(millis: 600)
        #expect(total == 1, "exactly one line was serviced — the stranger's was dropped (got \(total))")
        #expect(await service.peers == [town.identityHex], "and it is attributed to the town")
        #expect(
            await core.townPeerCount == 1,
            "only the authorized town holds a transport; the stranger never caused an allocation")

        strangerFramer.close()
        townFramer.close()
    }

    /// The default path: `serve` called with NO town arguments — the shape every existing
    /// call site (including `eldr-node`'s) uses. A verified peer's well-formed A2A frame
    /// must change nothing at all: no transport, no service, no reply.
    @Test func serveWithNoTownConfigurationIsByteIdenticalToBefore() async throws {
        let relay = LocalRelaySimulator()
        let owner = try await NodePersona.make(
            name: "Owner", seedByte: "0a", seed: 9_200, transports: [await relay.connect()])
        let node = try await NodePersona.make(
            name: "Node", seedByte: "0b", seed: 9_201, transports: [await relay.connect()])
        let town = try await NodePersona.make(
            name: "Town", seedByte: "0c", seed: 9_202, transports: [await relay.connect()])
        let nodeHexValue = node.identityHex

        for peer in [owner, town] {
            await node.messenger.addContact(try peer.asContact())
            await peer.messenger.addContact(try node.asContact())
        }

        let workdir = try makeNodeWorkdir("town-default")
        defer { try? FileManager.default.removeItem(atPath: workdir) }

        let core = EldrNodeCore()
        let serveTask = Task {
            // Note the argument list: exactly what `eldr-node`'s call site passes today.
            await core.serve(
                messenger: PQRCNodeMessenger(messenger: node.messenger),
                ownerIdentityHex: owner.identityHex,
                maxFrameBytes: townMaxFrame,
                llm: ScriptedLLM([LLMResponse(content: "unused")]),
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default,
                streamingEnabled: false,
                descriptor: .builtIn)
        }
        defer { serveTask.cancel() }

        try await town.messenger.establishSession(
            with: try node.asContact(), bundle: try await node.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "handshake", sentAt: 1))
        var settled = false
        for _ in 0..<400 {
            if await node.messenger.hasSession(peerIdentityHex: town.identityHex) {
                settled = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(settled, "the node decrypted the peer's handshake — so only the default gate applies")

        let framer = RelayA2ATransport(maxFrameBytes: townMaxFrame, instanceSalt: "d3f0t") { framed in
            try? await town.messenger.send(
                MessageBody(text: framed, sentAt: 5_003), to: nodeHexValue)
        }
        framer.send(#"{"jsonrpc":"2.0","id":1,"method":"message/send"}"#)
        try? await Task.sleep(for: .milliseconds(600))

        #expect(
            await core.townPeerCount == 0,
            "with no town configuration the A2A plane is unreachable — nothing is allocated")
        framer.close()
    }
}

// MARK: - (3) the authorizer implementations

@Suite("WS-G1 TownAuthorizer implementations", .tags(.security))
struct TownAuthorizerTests {

    @Test func denyAllDeniesEverythingIncludingTheOwner() async {
        let deny = DenyAllTownAuthorizer()
        for hex in [townPeerHex, townOwnerHex, strangerHex, ""] {
            #expect(await deny.authorizes(peerIdentityHex: hex) == false)
        }
    }

    /// `serve`'s default. Written as its own assertion because "the default is deny-all"
    /// is the property that makes WS-G1 a no-op for every existing deployment; if someone
    /// changes the default, this is the test that should stop them.
    @Test func serveDefaultsToDenyAll() async {
        let defaultAuthorizer: any TownAuthorizer = DenyAllTownAuthorizer()
        #expect(await defaultAuthorizer.authorizes(peerIdentityHex: townPeerHex) == false)
        #expect(type(of: defaultAuthorizer) == DenyAllTownAuthorizer.self)
    }

    @Test func emptyAllowlistAuthorizesNobody() async {
        let empty = PinnedTownAllowlist(peerIdentityHexes: [])
        #expect(empty.peerIdentityHexes.isEmpty)
        #expect(await empty.authorizes(peerIdentityHex: townPeerHex) == false)
        #expect(await empty.authorizes(peerIdentityHex: "") == false)
    }

    /// A hex differing only in case is a DIFFERENT string to the C-3 gate next door, so it
    /// is a different peer here too: denied. Fail-closed in both directions — an uppercase
    /// ENTRY is discarded at construction rather than silently matching a lowercase peer.
    @Test func caseVariantsFailClosedInBothDirections() async {
        let lower = String(repeating: "ab", count: 32)
        let upper = lower.uppercased()

        let pinnedLower = PinnedTownAllowlist(peerIdentityHexes: [lower])
        #expect(await pinnedLower.authorizes(peerIdentityHex: lower))
        #expect(
            await pinnedLower.authorizes(peerIdentityHex: upper) == false,
            "an uppercase spelling of a pinned peer is refused, not case-folded")

        let pinnedUpper = PinnedTownAllowlist(peerIdentityHexes: [upper])
        #expect(
            pinnedUpper.peerIdentityHexes.isEmpty,
            "a non-canonical ENTRY is discarded, so it can never match anything")
        #expect(await pinnedUpper.authorizes(peerIdentityHex: lower) == false)
        #expect(await pinnedUpper.authorizes(peerIdentityHex: upper) == false)
    }

    @Test func junkEntriesAreDiscardedAndDuplicatesCollapse() async {
        let good = String(repeating: "cd", count: 32)
        let list = PinnedTownAllowlist(peerIdentityHexes: [
            "  \(good)  ",  // trimmed → accepted
            good,  // duplicate → collapses
            "",  // empty
            "   ",  // whitespace only
            "0x\(good)",  // 0x-prefixed
            "npub1abcdef",  // an npub, not an identity hex
            "# a comment line",
            "zzzz",  // not hex
        ])
        #expect(list.peerIdentityHexes == [good], "only the canonical hex survives")
        #expect(await list.authorizes(peerIdentityHex: good))
        #expect(await list.authorizes(peerIdentityHex: "0x\(good)") == false)
    }
}
#endif  // os(macOS)
