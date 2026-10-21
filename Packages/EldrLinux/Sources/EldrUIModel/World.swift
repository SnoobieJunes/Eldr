// SPDX-License-Identifier: Apache-2.0
import EldrClientCore
import Foundation
import PQRCAgent
import PQRCCore

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

/// World MAP geometry (iOS `PhoneWorldMapLayout`): me in the centre, one town per peer on
/// a ring, 12 o'clock first, clockwise. Pure math so it is tested without GTK. Like the
/// phone, nothing travels along the edges: this device can't see town traffic, so every
/// edge is dashed and still; only the grant's lifetime ring (and a breath near expiry)
/// is drawn, which is a fact this device owns.
public enum WorldMapLayout {
    public static func unitPosition(index: Int, count: Int) -> (x: Double, y: Double) {
        guard count > 0 else { return (0, 0) }
        let a = (Double(index) / Double(count)) * 2 * .pi - .pi / 2
        return (cos(a), sin(a))
    }
    public static func ringRadius(width: Double, height: Double, inset: Double = 52) -> Double {
        max(10, min(width, height) / 2 - inset)
    }
    /// Remaining life as a fraction of the protocol's hard cap, clamped 0…1.
    public static func lifetimeFraction(expiresAt: Int64?, now: Int64, cap: Int64 = PQRCConstants.maxStandingGrantDuration) -> Double {
        guard let expiresAt, cap > 0, expiresAt > now else { return 0 }
        return min(1, Double(expiresAt - now) / Double(cap))
    }
    /// Static 0.5 unless urgent (inside the final day).
    public static func breath(time: Double, urgent: Bool, period: Double = 1.6) -> Double {
        guard urgent, period > 0 else { return 0.5 }
        return (sin(time / period * 2 * .pi) + 1) / 2
    }
    public static func until(_ s: WorldGrantStatus) -> Int64? {
        switch s { case .authorized(let u), .expiringSoon(let u): u; case .expired: nil }
    }
}
