// SPDX-License-Identifier: Apache-2.0
import EldrNodeCore
import Foundation
import PQRCCore
import PQRCMCP

// WS-G5 — one factory that assembles the whole town plane from the daemon's
// environment, so `EldrNodeMain` stays a thin wiring site:
//
//   ELDR_TOWN_ID          — this town's wall label. REQUIRED to enable the plane;
//                           absent/empty → returns nil and the node serves no town
//                           plane at all (deny-all, exactly as before WS-G5).
//   ELDR_TOWN_AGENT       — local author agent id (default "orchestrator").
//   ELDR_TOWN_PEERS_FILE  — JSON array of {identityHex, townID, label}
//                           (default <workdir>/.eldr/town-peers.json).
//   ELDR_TOWN_GRANTS_FILE — owner-curated standing-grant file
//                           (default <workdir>/.eldr/town-grants.json; see
//                           `FileStandingGrantStore` for format + revocation posture).
//   ELDR_GOOSEWORLD_SOCKET / ELDR_GOOSEWORLD_PORT + ELDR_GOOSEWORLD_TOKEN
//                         — when set, host the `eldr-gooseworld` loopback socket over
//                           the production bridge (same variable names the extension
//                           binary reads, so one env block configures both sides).
//
// The returned plane wires BOTH gates the design requires: transport admission is the
// OR of the two plane authorizers (a peer with ANY live grant may have frames
// delivered), and `PlaneRoutedTownService` re-verifies the REQUIRED plane per line —
// wall lines reach the wall host only under a live `.wall` grant, and everything else
// needs `.delegate` (serviced by `delegateService`, or dropped fail-closed when the
// node has none).
public enum GooseworldWiring {
    /// Everything `serve` + shutdown need, plus human-readable status lines.
    public struct TownPlane: Sendable {
        public let authorizer: any TownAuthorizer
        public let service: any TownA2AService
        public let host: TownWallHost
        public let socketHost: GooseworldSocketHost?
        public let statusLines: [String]
    }

    public static func fromEnvironment(
        _ env: [String: String],
        ownerHex: String,
        workdir: String,
        chunkTextBudget: Int,
        delegateService: (any TownA2AService)? = nil,
        sendFramed: @escaping @Sendable (String, String) async throws -> Void
    ) async -> TownPlane? {
        guard let townID = env["ELDR_TOWN_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !townID.isEmpty
        else { return nil }

        var status: [String] = []
        let agentID = env["ELDR_TOWN_AGENT"]?.nonEmptyTrimmed ?? "orchestrator"
        let dotDir = (workdir as NSString).appendingPathComponent(".eldr")
        let peersPath =
            env["ELDR_TOWN_PEERS_FILE"]?.nonEmptyTrimmed
            ?? (dotDir as NSString).appendingPathComponent("town-peers.json")
        let grantsPath =
            env["ELDR_TOWN_GRANTS_FILE"]?.nonEmptyTrimmed
            ?? (dotDir as NSString).appendingPathComponent("town-grants.json")

        let peers = loadPeers(path: peersPath)
        status.append(
            "town:     \(townID) as \(agentID) — \(peers.count) paired peer\(peers.count == 1 ? "" : "s") (\(peersPath))"
        )

        let grantStore = FileStandingGrantStore(path: grantsPath, ownerHex: ownerHex)
        let liveGrants: @Sendable () async -> [StandingGrant] = { await grantStore.liveGrants() }
        status.append("grants:   \(grantsPath) (owner-signed; removal = revocation)")

        let host = TownWallHost(
            config: .init(
                localTownID: townID, localAgentID: agentID, ownerHex: ownerHex, peers: peers,
                chunkTextBudget: chunkTextBudget),
            cursorStore: WallCursorStore(
                path: (dotDir as NSString).appendingPathComponent("town-wall-cursors.json")),
            liveGrants: liveGrants,
            sendFramed: sendFramed)

        let authorizer = AnyOfTownAuthorizer([
            StandingGrantTownAuthorizer(
                plane: .wall, requiredGranterHex: ownerHex, liveGrants: liveGrants),
            StandingGrantTownAuthorizer(
                plane: .delegate, requiredGranterHex: ownerHex, liveGrants: liveGrants),
        ])
        let service = PlaneRoutedTownService(
            wall: TownWallService(host: host),
            delegate: delegateService,
            requiredGranterHex: ownerHex,
            liveGrants: liveGrants)

        // The eldr-gooseworld loopback host, when configured. A missing token with a
        // configured endpoint is refused loudly — an unauthenticated local socket to
        // the wall is exactly what the token exists to prevent.
        var socketHost: GooseworldSocketHost?
        let socketPath = env["ELDR_GOOSEWORLD_SOCKET"]?.nonEmptyTrimmed
        let port = env["ELDR_GOOSEWORLD_PORT"]?.nonEmptyTrimmed.flatMap(UInt16.init)
        if socketPath != nil || port != nil {
            if let token = env["ELDR_GOOSEWORLD_TOKEN"]?.nonEmptyTrimmed {
                let endpoint: GooseworldSocketHost.Endpoint =
                    socketPath.map { .unix(path: $0) } ?? .loopbackTCP(port: port ?? 0)
                let mcp = GooseworldMCPServer(bridge: TownWallHostBridge(host: host))
                // WS-D1n: the same socket also answers the dashboard's `world/status`.
                // Not an MCP tool — see `GooseworldSocketHost.statusResponse`.
                let sockHost = GooseworldSocketHost(
                    endpoint: endpoint, token: token, server: mcp,
                    statusProvider: { await host.statusSnapshot() })
                do {
                    try sockHost.start()
                    socketHost = sockHost
                    status.append(
                        "goose:    \(socketPath ?? "127.0.0.1:\(port ?? 0)") (eldr-gooseworld socket, token-gated)"
                    )
                } catch {
                    status.append("goose:    FAILED to host the eldr-gooseworld socket: \(error)")
                }
            } else {
                status.append(
                    "goose:    ELDR_GOOSEWORLD_SOCKET/PORT set but ELDR_GOOSEWORLD_TOKEN missing — refusing an unauthenticated socket"
                )
            }
        }

        return TownPlane(
            authorizer: authorizer, service: service, host: host, socketHost: socketHost,
            statusLines: status)
    }

    /// Load the peer roster (JSON `[TownPeer]`). Missing/corrupt → empty, loudly.
    static func loadPeers(path: String) -> [TownWallHost.TownPeer] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        guard let peers = try? JSONDecoder().decode([TownWallHost.TownPeer].self, from: data)
        else {
            FileHandle.standardError.write(Data(
                "eldr-node: town-peers: \(path) is not a valid [{identityHex,townID,label}] array — treating as EMPTY\n"
                    .utf8))
            return []
        }
        return peers
    }
}

extension String {
    fileprivate var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
