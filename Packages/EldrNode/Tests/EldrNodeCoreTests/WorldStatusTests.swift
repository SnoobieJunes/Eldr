// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import EldrNodeCore
@testable import EldrNodeGooseworld
@testable import PQRCCore
@testable import PQRCMCP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// WS-D1n — the DASHBOARD read model (`world/status`).
//
// The dashboard's entire claim is that a human can look at one view and know who the node
// is actually connected to, without that view either lying (showing authorization as
// liveness) or leaking (carrying message content or identity keys to a surface built for
// rendering). These tests pin exactly those properties, plus the one that keeps the agent
// side safe: `world/status` must NOT be reachable as a tool by any goose flock.

#if os(macOS)

@Suite("WS-D1n world/status — dashboard read model", .tags(.security))
struct WorldStatusTests {

    static let issuedAt = GooseworldTwoTownE2ETests.issuedAt
    static let liveNow = GooseworldTwoTownE2ETests.liveNow

    private func grant(
        owner: PQRCIdentity, peerHex: String, planes: [StandingGrant.Plane], days: Int64,
        grantID: String
    ) throws -> StandingGrant {
        try GooseworldTwoTownE2ETests.ownerSignedGrant(
            owner: owner, peerHex: peerHex, planes: planes, days: days, grantID: grantID)
    }

    /// Every key in a JSON tree, at any depth — for the canary's allowlist comparison.
    private func allKeys(_ any: Any) -> Set<String> {
        if let dict = any as? [String: Any] {
            return dict.reduce(into: Set(dict.keys)) { $0.formUnion(allKeys($1.value)) }
        }
        if let arr = any as? [Any] {
            return arr.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
        }
        return []
    }

    // MARK: - (1) Planes and the authorization horizon

    /// The snapshot must report per-plane authorization and, for `grantExpiry`, the
    /// LATEST expiry among live covering grants — the moment authorization fully lapses.
    /// A peer with no grant is a legitimate row (paired but not authorized), NOT an
    /// omission: hiding it is how "why won't this town talk?" becomes unanswerable.
    @Test func statusSnapshot_reportsPlanesAndAuthorizationHorizon() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x71, count: 32))
        let both = String(repeating: "ab", count: 32)
        let ungranted = String(repeating: "cd", count: 32)
        // Two grants on ONE peer: wall for 3 days, delegate for 9. The horizon is 9.
        let grants = [
            try grant(owner: owner, peerHex: both, planes: [.wall], days: 3, grantID: "w"),
            try grant(owner: owner, peerHex: both, planes: [.delegate], days: 9, grantID: "d"),
        ]
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [
                    .init(identityHex: both, townID: "both-town", label: "Both"),
                    .init(identityHex: ungranted, townID: "cold-town", label: "Cold"),
                ]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: { grants },
            sendFramed: { _, _ in })

        let snap = await host.statusSnapshot()
        #expect(snap.nodeTownID == "home")
        #expect(snap.localAgentID == "flock")
        #expect(snap.generatedAt == Self.liveNow, "the row's 'confirmed at' is the node clock")
        #expect(snap.towns.count == 2, "an unauthorized peer is still a row")

        let hot = try #require(snap.towns.first { $0.townID == "both-town" })
        #expect(hot.wallGranted)
        #expect(hot.delegateGranted)
        #expect(
            hot.grantExpiry == Self.issuedAt + 9 * PQRCConstants.secondsPerDay,
            "the horizon is the LATEST live expiry, not the soonest")

        let cold = try #require(snap.towns.first { $0.townID == "cold-town" })
        #expect(!cold.wallGranted)
        #expect(!cold.delegateGranted)
        #expect(cold.grantExpiry == nil, "no live grant ⇒ no horizon, never a stale one")
    }

    /// A grant signed by someone OTHER than the owner must not produce a horizon — the
    /// same granter pin admission uses. Otherwise a peer could mint itself a reassuring
    /// "authorized until" row in the owner's own dashboard.
    @Test func statusSnapshot_ignoresForeignSignedGrants() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x72, count: 32))
        let impostor = try PQRCIdentity(seed: Data(repeating: 0x73, count: 32))
        let peer = String(repeating: "ab", count: 32)
        let foreign = try grant(
            owner: impostor, peerHex: peer, planes: [.wall, .delegate], days: 30,
            grantID: "forged")
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [.init(identityHex: peer, townID: "t", label: "T")]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: { [foreign] },
            sendFramed: { _, _ in })

        let town = try #require(await host.statusSnapshot().towns.first)
        #expect(!town.wallGranted)
        #expect(!town.delegateGranted)
        #expect(town.grantExpiry == nil, "a foreign-signed grant grants nothing, shows nothing")
    }

    // MARK: - (2) The privacy canary

    /// The snapshot is METADATA ONLY. With a real post on the wall, the encoded snapshot
    /// must contain neither the post body nor the peer's identity hex, and its key set
    /// must stay inside the declared allowlist — so a future field that could carry
    /// content fails here rather than shipping to a rendering surface.
    @Test func worldStatusSnapshotCarriesNoMessageContent() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x74, count: 32))
        let peer = String(repeating: "ab", count: 32)
        let secret = "CANARY-oauth2-token-refresh-under-clock-skew"
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [.init(identityHex: peer, townID: "t", label: "T")]),
            cursorStore: nil, now: { Self.liveNow },
            liveGrants: {
                (try? GooseworldTwoTownE2ETests.ownerSignedGrant(
                    owner: owner, peerHex: peer, planes: [.wall], days: 5, grantID: "g"))
                    .map { [$0] } ?? []
            },
            sendFramed: { _, _ in })
        // Put real content on the wall, so "no content" is a proven absence, not vacuous.
        _ = await host.post(text: secret, priorityForHuman: true, targets: [])
        if case .success(let read) = await host.read(reader: "probe", limit: nil, fromStart: true) {
            #expect(read.posts.count == 1, "the canary post must actually be on the wall")
        } else {
            Issue.record("the wall read failed — the canary would be vacuous")
        }

        let data = try JSONEncoder().encode(await host.statusSnapshot())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(secret), "message content must never reach the dashboard model")
        #expect(!text.contains("CANARY"), "not even a fragment of it")
        #expect(!text.contains(peer), "peer identity hex must not ship; the view joins on townID")

        let keys = allKeys(try JSONSerialization.jsonObject(with: data))
        let undeclared = keys.subtracting(TownStatusSnapshot.allowedFieldNames)
        #expect(
            undeclared.isEmpty,
            "undeclared field(s) \(undeclared) — add to allowedFieldNames only after confirming they cannot carry content"
        )
    }

    // MARK: - (3) The agent surface is unchanged

    /// `world/status` is a DASHBOARD method, not a capability. It must not appear in
    /// `tools/list`, and the four agent tools must still be exactly the four.
    @Test func worldStatus_isNotReachableAsAnAgentTool() async throws {
        let server = GooseworldMCPServer(bridge: DemoGooseworldBridge())
        let listed = await server.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#)
        let text = try #require(listed)
        #expect(!text.contains("world/status"), "the dashboard method must not be a tool")
        for tool in ["world_wall_post", "world_wall_read", "world_delegate", "world_towns"] {
            #expect(text.contains(tool), "the agent surface must still carry \(tool)")
        }
        // And calling it as a tool must not succeed.
        let called = try #require(
            await server.handle(
                line:
                    #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"world/status","arguments":{}}}"#
            ))
        #expect(
            called.contains("isError") || called.contains("error"),
            "invoking the dashboard method as a tool must refuse, not answer: \(called)")
    }

    // MARK: - (4) Token-gated, over the real socket

    /// The dashboard rides the SAME token gate as the agent surface: a connection that
    /// cannot present the token gets no snapshot, and a valid one decodes structurally.
    @Test func worldStatus_isTokenGated_thenReturnsAStructuredSnapshot() async throws {
        let owner = try PQRCIdentity(seed: Data(repeating: 0x75, count: 32))
        let peer = String(repeating: "ab", count: 32)
        let host = TownWallHost(
            config: .init(
                localTownID: "home", localAgentID: "flock",
                ownerHex: owner.publicKeyData.hexString,
                peers: [.init(identityHex: peer, townID: "acme-town", label: "Acme")]),
            cursorStore: nil, now: { Self.liveNow }, liveGrants: { [] }, sendFramed: { _, _ in })

        let sockPath = "/tmp/eldr-gw-status-\(UInt32.random(in: 0..<UInt32.max)).sock"
        defer { unlink(sockPath) }
        let sockHost = GooseworldSocketHost(
            endpoint: .unix(path: sockPath), token: "sekrit",
            server: GooseworldMCPServer(bridge: TownWallHostBridge(host: host)),
            statusProvider: { await host.statusSnapshot() })
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
            #expect(ok == 0)
            return fd
        }
        func send(_ fd: Int32, _ s: String) {
            _ = Array(s.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        }
        func readLine(_ fd: Int32) -> String? {
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while out.count < 1_000_000 {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { return out.isEmpty ? nil : String(decoding: out, as: UTF8.self) }
                out.append(contentsOf: buf[0..<n])
                if out.contains(UInt8(ascii: "\n")) {
                    return String(
                        decoding: out.prefix(while: { $0 != UInt8(ascii: "\n") }), as: UTF8.self)
                }
            }
            return nil
        }
        let request = #"{"jsonrpc":"2.0","id":7,"method":"world/status"}"#

        // Wrong token: no snapshot, connection closed unserviced.
        let bad = try connectClient()
        send(bad, "wrong\n" + request + "\n")
        #expect(readLine(bad) == nil, "the dashboard must not bypass the token gate")
        close(bad)

        // Right token: a decodable snapshot comes back, id echoed.
        struct Envelope: Decodable {
            let id: Int
            let result: TownStatusSnapshot
        }
        let good = try connectClient()
        send(good, "sekrit\n" + request + "\n")
        let response = try #require(readLine(good))
        close(good)
        let env = try JSONDecoder().decode(Envelope.self, from: Data(response.utf8))
        #expect(env.id == 7, "the reply must echo the caller's id")
        #expect(env.result.nodeTownID == "home")
        #expect(env.result.towns.map(\.townID) == ["acme-town"])
        #expect(env.result.towns[0].label == "Acme")
    }
}

#endif  // os(macOS)
