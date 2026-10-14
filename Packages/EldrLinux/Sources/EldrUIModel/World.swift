// SPDX-License-Identifier: Apache-2.0
import EldrClientCore
import Foundation
import PQRCAgent

/// "World" (iOS WorldView, WS-D1a): what THIS device authorized, joined and tethered.
/// Like the phone, a town is authorized / expiring / expired and never "connected":
/// liveness lives in the node, which this view can't observe.
public enum WorldGrantStatus: Equatable, Sendable {
    case authorized(until: Int64), expiringSoon(until: Int64), expired
    public var label: String {
        switch self { case .authorized: "authorized"; case .expiringSoon: "expiring soon"; case .expired: "expired" }
    }
}

public struct WorldTownRow: Equatable, Sendable {
    public let peerIdentityHex: String
    public let title: String
    public let planes: String
    public let status: WorldGrantStatus
}

public enum WorldDerivation {
    public static let expiringWindowSeconds: Int64 = 86_400

    public static func status(activeUntil: Int64, now: Int64) -> WorldGrantStatus {
        if activeUntil <= now { return .expired }
        if activeUntil - now <= expiringWindowSeconds { return .expiringSoon(until: activeUntil) }
        return .authorized(until: activeUntil)
    }

    /// One row per PEER (grants arrive per plane); horizon = the latest expiry.
    public static func townRows(_ grants: [AgentEngine.StandingGrantStatus], now: Int64) -> [WorldTownRow] {
        let byPeer = Dictionary(grouping: grants, by: \.peerIdentityHex)
        return byPeer.keys.sorted().map { peer in
            let e = byPeer[peer] ?? []
            let planes = Set(e.map { $0.plane.rawValue }).sorted()
            return WorldTownRow(
                peerIdentityHex: peer, title: String(peer.prefix(12)) + "…",
                planes: planes.isEmpty ? "no planes" : planes.joined(separator: " + "),
                status: status(activeUntil: e.map(\.activeUntil).max() ?? 0, now: now))
        }
    }
}
