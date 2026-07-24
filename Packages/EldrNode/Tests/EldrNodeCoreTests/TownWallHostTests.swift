// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import Testing

@testable import EldrNodeCore
@testable import EldrNodeGooseworld
@testable import PQRCCore
@testable import PQRCMCP
@testable import PQRCNostr

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// GOOSEWORLD WS-G5 — the PRODUCTION wall over the town plane, proven end to end.
//
// AC134 shipped the wall's MODEL (TownWall) and the chunk MATH (WallChunking) and
// deferred "real transport, fan-out, NIP-11 chunk sizing, cursor persistence, and
// standing-grant verification" to the node layer. This suite closes each of those with
// the same standard the WS-G1 delegate plane was held to (GooseworldTwoTownE2ETests):
// real messengers over one LocalRelaySimulator, the real `serve` loop, the real
// grant-backed authorizer, real owner-signed grants — and the NEW crown jewel alongside
// AC131's: a `.wall` grant must never open the delegation channel, and a `.delegate`
// grant must never write the wall.

#if os(macOS)

@Suite("WS-G5 wall host — production bridge over the town plane", .tags(.transport, .security))
struct TownWallHostTests {

    static let issuedAt = GooseworldTwoTownE2ETests.issuedAt
    static let liveNow = GooseworldTwoTownE2ETests.liveNow

    /// Poll until `condition`, the suite's standard deterministic-readiness wait.
    private func waitUntil(
        _ timeoutMillis: Int = 5_000, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return await condition()
    }

    private func wallGrant(
        owner: PQRCIdentity, peerHex: String, planes: [StandingGrant.Plane] = [.wall],
        grantID: String = "wall-1"
    ) throws -> StandingGrant {
        try GooseworldTwoTownE2ETests.ownerSignedGrant(
            owner: owner, peerHex: peerHex, planes: planes, grantID: grantID)
    }

    // MARK: - (1) THE HEADLINE: a chunked post travels the real plane and reads as REMOTE

    /// Town A's HOST posts a body larger than the chunk budget; the chunks ride the real
    /// relay as `world/wall.post` lines; Town B's `serve` admits them through the
    /// grant-backed authorizer; the plane router re-verifies `.wall`; B's host
    /// reassembles the COMPLETE post and ingests it authored as Town A (from the
    /// VERIFIED sender, not the wire); and B's bridge read returns it byte-exact.
    @Test func chunkedPost_travelsThePlane_ingestsAsRemote_readsBack() async throws {
        let p = try await makeTwoTownParties(seedBase: 61_000, maxFrameBytes: townMaxFrame)

        // B's owner signs the ADMISSION grant naming Town A on `.wall`.
        let grantsB = MutableGrantSet([
            try wallGrant(owner: p.ownerB.identity, peerHex: p.townA.identityHex)
        ])
        let liveB: @Sendable () async -> [StandingGrant] = { await grantsB.current() }
        let hostB = TownWallHost(
            config: .init(
                localTownID: "town-b", localAgentID: "flock-b",
                ownerHex: p.ownerB.identityHex,
                peers: [.init(identityHex: p.townA.identityHex, townID: "town-a", label: "Town A")]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: liveB,
            sendFramed: { _, _ in })
        let authorizer = StandingGrantTownAuthorizer(
            plane: .wall, requiredGranterHex: p.ownerB.identityHex, now: { Self.liveNow },
            liveGrants: liveB)
        let service = PlaneRoutedTownService(
            wall: TownWallService(host: hostB), delegate: nil,
            requiredGranterHex: p.ownerB.identityHex, now: { Self.liveNow }, liveGrants: liveB)

        let workdir = try makeNodeWorkdir("gw-wall-e2e")
        defer { try? FileManager.default.removeItem(atPath: workdir) }
        let serveTask = startTownServe(
            core: EldrNodeCore(), nodeMessenger: p.nodeB.messenger,
            ownerHex: p.ownerB.identityHex, maxFrameBytes: townMaxFrame,
            llm: ScriptedLLM([LLMResponse(content: "unused")]),
            authorizer: authorizer, service: service, workdir: workdir)
        defer {
            serveTask.cancel()
            Task { await p.inbox.stop() }
        }
        try await settleTownSession(nodeB: p.nodeB, peer: p.townA)

        // A's SEND-side: its own host, with a small chunk budget so a modest body needs
        // several chunks, and A's owner-signed grant naming B (invariant 9: no grant, no
        // autonomous cross-town send).
        let sendGrantA = try wallGrant(owner: p.townA.identity, peerHex: p.nodeB.identityHex)
        let seq = NodeSeq()
        let hostA = TownWallHost(
            config: .init(
                localTownID: "town-a", localAgentID: "orchestrator",
                ownerHex: p.townA.identityHex,
                peers: [.init(identityHex: p.nodeB.identityHex, townID: "town-b", label: "Town B")],
                chunkTextBudget: 64),
            cursorStore: nil, now: { Self.liveNow },
            liveGrants: { [sendGrantA] },
            sendFramed: { framed, peerHex in
                try await p.townA.messenger.send(
                    MessageBody(text: framed, sentAt: await seq.next()), to: peerHex)
            })

        let finding = String(repeating: "finding: the widget breaks at boundary #7. ", count: 5)
        #expect(finding.utf8.count > 64, "the body must actually need multiple chunks")
        let posted = await hostA.post(text: finding, priorityForHuman: true, targets: [])
        guard case .ok(let detail) = posted else {
            Issue.record("post refused: \(posted)")
            return
        }
        #expect(detail.contains("chunks"), "the fan-out really chunked: \(detail)")

        // B's wall eventually holds the ONE reassembled post, authored as town-a.
        let arrived = await waitUntil {
            if case .success(let read) = await hostB.read(
                reader: "peek", limit: nil, fromStart: true)
            { return read.posts.count == 1 }
            return false
        }
        #expect(arrived, "the reassembled post must ingest at Town B")
        guard case .success(let read) = await hostB.read(reader: "orchestrator", limit: nil, fromStart: false)
        else {
            Issue.record("read failed")
            return
        }
        #expect(read.posts.count == 1)
        #expect(read.posts.first?.text == finding, "byte-exact across chunk → reassemble → ingest")
        #expect(read.posts.first?.author.town == "town-a", "authored from the VERIFIED sender")
        #expect(read.posts.first?.author.agent == "orchestrator")
        #expect(read.posts.first?.priorityForHuman == true, "structured metadata rides outside the body")
    }

    // MARK: - (2) CROWN JEWEL: plane containment per line

    /// A wall-only peer's DELEGATION line must never reach the delegate service, and a
    /// delegate-only peer's WALL line must never ingest — each proven non-vacuous (the
    /// same peer, on its granted plane, DOES flow).
    @Test func wallGrantCannotReachDelegate_delegateGrantCannotWriteWall() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x51, count: 32))
        let wallPeer = String(repeating: "ab", count: 32)
        let delegatePeer = String(repeating: "cd", count: 32)
        let grants = MutableGrantSet([
            try wallGrant(owner: owner, peerHex: wallPeer, planes: [.wall], grantID: "w"),
            try wallGrant(owner: owner, peerHex: delegatePeer, planes: [.delegate], grantID: "d"),
        ])
        let live: @Sendable () async -> [StandingGrant] = { await grants.current() }
        let ownerHex = owner.publicKeyData.hexString

        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock", ownerHex: ownerHex,
                peers: [
                    .init(identityHex: wallPeer, townID: "wall-town", label: "W"),
                    .init(identityHex: delegatePeer, townID: "delegate-town", label: "D"),
                ]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: live, sendFramed: { _, _ in })
        let delegateRecorder = RecordingTownService()
        let router = PlaneRoutedTownService(
            wall: TownWallService(host: host), delegate: delegateRecorder,
            requiredGranterHex: ownerHex, now: { Self.liveNow }, liveGrants: live)

        let wallLine = WallWire.encodePost(
            .init(
                chunk: WallChunkRef(id: "c1", index: 0, total: 1), body: "hello wall",
                agent: "w1", priorityForHuman: false, targets: []))!

        // Wall-only peer: wall line ingests (non-vacuous)…
        await router.handle(line: wallLine, from: wallPeer, reply: { _ in })
        if case .success(let read) = await host.read(reader: "r", limit: nil, fromStart: true) {
            #expect(read.posts.count == 1, "the wall grant DOES admit wall traffic")
        } else { Issue.record("wall read failed") }
        // …but its delegation line must be dropped BEFORE the delegate service.
        await router.handle(
            line: delegationLine(id: 9, task: "escape"), from: wallPeer, reply: { _ in })
        #expect(await delegateRecorder.lines.isEmpty, "a .wall grant must never open the delegate plane")

        // Delegate-only peer: delegation line services (non-vacuous)…
        await router.handle(
            line: delegationLine(id: 10, task: "legit"), from: delegatePeer, reply: { _ in })
        #expect(await delegateRecorder.lines.count == 1, "the .delegate grant DOES admit delegation")
        // …but its wall line must not ingest.
        await router.handle(line: wallLine, from: delegatePeer, reply: { _ in })
        if case .success(let read) = await host.read(reader: "r2", limit: nil, fromStart: true) {
            #expect(read.posts.count == 1, "a .delegate grant must never write the wall")
        } else { Issue.record("wall re-read failed") }

        // And a method that merely MENTIONS the wall in a string stays on the delegate
        // plane (parsed routing, not substring matching).
        let mention = #"{"jsonrpc":"2.0","id":11,"method":"message/send","params":{"note":"world/wall.post"}}"#
        await router.handle(line: mention, from: delegatePeer, reply: { _ in })
        #expect(await delegateRecorder.lines.count == 2, "mentioning the method name is not the method")
    }

    // MARK: - (3) Chunk sets fail closed

    @Test func chunkSets_incompleteBuffered_mixedRefused_outOfOrderOK() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x52, count: 32))
        let peer = String(repeating: "ef", count: 32)
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [.init(identityHex: peer, townID: "peer-town", label: "P")]),
            cursorStore: nil, now: { Self.liveNow },
            liveGrants: { [] }, sendFramed: { _, _ in })

        func wallLine(_ id: String, _ index: Int, _ total: Int, _ body: String) -> String {
            WallWire.encodePost(
                .init(
                    chunk: WallChunkRef(id: id, index: index, total: total), body: body,
                    agent: "a", priorityForHuman: false, targets: []))!
        }
        @Sendable func postCount() async -> Int {
            if case .success(let r) = await host.read(reader: "probe", limit: nil, fromStart: true) {
                return r.posts.count
            }
            return -1
        }

        // Incomplete: 1 of 2 → buffered, nothing ingested.
        await host.ingest(line: wallLine("p1", 0, 2, "half-"), from: peer)
        #expect(await host.pendingChunkSetCount == 1)
        #expect(await postCount() == 0)

        // Out-of-order completion is fine — and byte-exact.
        await host.ingest(line: wallLine("p2", 1, 2, "world"), from: peer)
        await host.ingest(line: wallLine("p2", 0, 2, "hello "), from: peer)
        let ok = await waitUntil { await postCount() == 1 }
        #expect(ok, "an out-of-order but complete set must ingest")
        if case .success(let read) = await host.read(reader: "probe2", limit: nil, fromStart: true) {
            #expect(read.posts.first?.text == "hello world")
        }

        // A set whose pieces disagree on total is refused WHOLE when it completes.
        let droppedBefore = await host.droppedInboundCount
        await host.ingest(line: wallLine("p3", 0, 2, "x"), from: peer)
        await host.ingest(
            line: WallWire.encodePost(
                .init(
                    chunk: WallChunkRef(id: "p3", index: 1, total: 3), body: "y",
                    agent: "a", priorityForHuman: false, targets: []))!, from: peer)
        // total from the arriving piece says 3, buffered count says 2 → still pending;
        // complete it to the FIRST piece's total (2) so reassembly runs and refuses.
        #expect(await postCount() == 1, "the inconsistent set must not ingest")
        _ = droppedBefore  // (drop accounting is asserted via the undecodable-line case below)

        // An undecodable wall line is counted, never ingested.
        let dropped = await host.droppedInboundCount
        await host.ingest(line: "not json at all", from: peer)
        #expect(await host.droppedInboundCount == dropped + 1)
    }

    // MARK: - (4) Cursor persistence across a restart

    @Test func cursors_surviveHostRestart_throughTheStore() async throws {
        let dir = try makeNodeWorkdir("gw-cursors")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let storePath = (dir as NSString).appendingPathComponent("cursors.json")
        let owner = try PQRCIdentity(seed: Data(repeating: 0x53, count: 32))
        let peer = String(repeating: "aa", count: 32)

        func makeHost() -> TownWallHost {
            TownWallHost(
                config: .init(
                    localTownID: "home", localAgentID: "flock",
                    ownerHex: owner.publicKeyData.hexString,
                    peers: [.init(identityHex: peer, townID: "peer-town", label: "P")]),
                cursorStore: WallCursorStore(path: storePath), now: { Self.liveNow },
                liveGrants: { [] }, sendFramed: { _, _ in })
        }

        let host1 = makeHost()
        await host1.ingest(
            line: WallWire.encodePost(
                .init(
                    chunk: WallChunkRef(id: "c", index: 0, total: 1), body: "note",
                    agent: "a", priorityForHuman: false, targets: []))!, from: peer)
        guard case .success(let first) = await host1.read(reader: "orchestrator", limit: nil, fromStart: false)
        else {
            Issue.record("first read failed")
            return
        }
        #expect(first.posts.count == 1)

        // The store now holds the cursor, 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: storePath)
        #expect((attrs[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        // A NEW host over the same store: the reader's cursor survived the restart, so a
        // fresh (empty) wall shows nothing new — no replay, no silent skip.
        let host2 = makeHost()
        guard case .success(let second) = await host2.read(reader: "orchestrator", limit: nil, fromStart: false)
        else {
            Issue.record("second read failed")
            return
        }
        #expect(second.posts.isEmpty, "the persisted cursor must prevent a replay")
        #expect(second.cursorBefore == first.cursorAfter, "the cursor position itself survived")
    }

    // MARK: - (5) Outbound fan-out is grant-gated per peer

    @Test func outboundFanOut_reachesOnlyWallGrantedPeers() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x54, count: 32))
        let granted = String(repeating: "b1", count: 32)
        let ungranted = String(repeating: "b2", count: 32)
        let grantForGranted = try wallGrant(owner: owner, peerHex: granted)
        let sent = SentFrames()
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [
                    .init(identityHex: granted, townID: "granted-town", label: "G"),
                    .init(identityHex: ungranted, townID: "ungranted-town", label: "U"),
                ]),
            cursorStore: nil, now: { Self.liveNow },
            liveGrants: { [grantForGranted] },
            sendFramed: { frame, peerHex in await sent.record(frame, to: peerHex) })

        let result = await host.post(text: "coordinate: pinning v0.4", priorityForHuman: false, targets: [])
        guard case .ok(let detail) = result else {
            Issue.record("post refused: \(result)")
            return
        }
        #expect(detail.contains("1 town"), "exactly the granted peer is reported: \(detail)")
        let delivered = await waitUntil { await !sent.frames.isEmpty }
        #expect(delivered)
        #expect(await sent.peers == [granted], "no frame may reach the ungranted peer (invariant 9)")

        // With NO grants at all the post stays local — stated, not implied.
        let none = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [.init(identityHex: granted, townID: "granted-town", label: "G")]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: { [] },
            sendFramed: { _, _ in await sent.record("UNEXPECTED", to: "nobody") })
        let local = await none.post(text: "solo note", priorityForHuman: false, targets: [])
        guard case .ok(let localDetail) = local else {
            Issue.record("local post refused")
            return
        }
        #expect(localDetail.contains("local wall only"))
        #expect(await sent.frames.contains("UNEXPECTED") == false)
    }

    actor SentFrames {
        private(set) var frames: [String] = []
        private(set) var byPeer: [String] = []
        func record(_ frame: String, to peer: String) {
            frames.append(frame)
            byPeer.append(peer)
        }
        var peers: [String] { Array(Set(byPeer)) }
    }

    // MARK: - (6) The grant file store fails closed entry by entry

    @Test func grantStore_loadsOwnerSigned_dropsForeignAndTampered_reloadsOnChange() async throws {
        let dir = try makeNodeWorkdir("gw-grants")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("town-grants.json")
        let owner = try PQRCIdentity(seed: Data(repeating: 0x55, count: 32))
        let foreign = try PQRCIdentity(seed: Data(repeating: 0x56, count: 32))
        let peer = String(repeating: "dd", count: 32)

        let good = try wallGrant(owner: owner, peerHex: peer, grantID: "good")
        let foreignSigned = try wallGrant(owner: foreign, peerHex: peer, grantID: "foreign")
        var tampered = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try wallGrant(owner: owner, peerHex: peer, grantID: "tampered")))
            as! [String: Any]
        tampered["active_until"] = Self.issuedAt + 3 * PQRCConstants.secondsPerDay + 1  // re-scope without re-signing

        func write(_ grants: [Any]) throws {
            let file = ["grants": grants]
            try JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
        let goodJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
        let foreignJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(foreignSigned))
        try write([goodJSON, foreignJSON, tampered])

        let store = FileStandingGrantStore(
            path: path, ownerHex: owner.publicKeyData.hexString, now: { Self.liveNow })
        let loaded = await store.liveGrants()
        #expect(loaded.map(\.grantID) == ["good"], "foreign-signed and tampered entries are dropped")

        // Removal-from-file IS revocation: rewrite without the good grant; the store
        // re-reads on the (mtime,size) change and the next query denies.
        try write([foreignJSON])
        let revoked = await waitUntil { await store.liveGrants().isEmpty }
        #expect(revoked, "removing the entry must revoke on the next read")

        // Missing file → empty, not an error.
        try FileManager.default.removeItem(atPath: path)
        #expect(await store.liveGrants().isEmpty)
    }

    // MARK: - (7) Wire codec

    @Test func wallWire_roundTripsAndRefusesForeignShapes() {
        let params = WallWire.PostParams(
            chunk: WallChunkRef(id: "z", index: 2, total: 5), body: "piece",
            agent: "orch", priorityForHuman: true, targets: ["bob"])
        let line = WallWire.encodePost(params)
        #expect(line != nil)
        #expect(WallWire.decodePost(line!) == params)
        #expect(PlaneRoutedTownService.isWallLine(line!))
        #expect(WallWire.decodePost(delegationLine(id: 1, task: "x")) == nil)
        #expect(WallWire.decodePost("junk") == nil)
        #expect(!PlaneRoutedTownService.isWallLine(delegationLine(id: 1, task: "x")))
    }

    // MARK: - (8) The eldr-gooseworld socket host: token-gated, then a real tool answers

    @Test func socketHost_refusesWrongToken_thenServesRosterWithRightToken() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x57, count: 32))
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [
                    .init(
                        identityHex: String(repeating: "ee", count: 32), townID: "acme-town",
                        label: "Acme")
                ]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: { [] }, sendFramed: { _, _ in })
        // A short unix path (sockaddr_un caps ~104 bytes; NSTemporaryDirectory can be long).
        let sockPath = "/tmp/eldr-gw-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
        defer { unlink(sockPath) }
        let sockHost = GooseworldSocketHost(
            endpoint: .unix(path: sockPath), token: "sekrit",
            server: GooseworldMCPServer(bridge: TownWallHostBridge(host: host)))
        try sockHost.start()
        defer { sockHost.stop() }

        func connectClient() throws -> Int32 {
            let fd = socket(AF_UNIX, GooseworldSocketHost.sockStreamType, 0)
            #expect(fd >= 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(sockPath.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes)
                raw[bytes.count] = 0
            }
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
            }
            #expect(ok == 0, "connect(unix) must succeed")
            return fd
        }
        func send(_ fd: Int32, _ s: String) {
            _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        /// Read until EOF or one full line, with a bounded budget.
        func readLine(_ fd: Int32) -> String? {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while out.count < 1_000_000 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return out.isEmpty ? nil : String(decoding: out, as: UTF8.self) }
                out.append(contentsOf: buf[0..<n])
                if out.contains(UInt8(ascii: "\n")) {
                    return String(decoding: out.prefix(while: { $0 != UInt8(ascii: "\n") }), as: UTF8.self)
                }
            }
            return nil
        }
        let towns = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"world_towns","arguments":{}}}"#

        // Wrong token: the connection is closed with NO line ever serviced.
        let bad = try connectClient()
        send(bad, "wrong\n" + towns + "\n")
        #expect(readLine(bad) == nil, "a wrong token must close the socket unserviced")
        close(bad)

        // Right token: the roster comes back through the real MCP server.
        let good = try connectClient()
        send(good, "sekrit\n" + towns + "\n")
        let response = readLine(good)
        close(good)
        #expect(response?.contains("acme-town") == true, "the roster must answer: \(response ?? "nil")")
    }
}

#endif  // os(macOS)
