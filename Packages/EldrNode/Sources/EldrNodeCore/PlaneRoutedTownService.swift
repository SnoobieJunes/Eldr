// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import PQRCCore

// WS-G5 — the per-LINE plane containment boundary for a node serving BOTH town planes.
//
// Transport admission (`TownAuthorizer`, consulted by `routeInboundA2A`) answers one
// question: "may this peer's A2A frames be delivered at all". When a node serves both
// the wall (`.wall` grants) and the flock (`.delegate` grants), admission is necessarily
// the OR of the two (`AnyOfTownAuthorizer`) — which means an admitted LINE still needs a
// second, plane-scoped decision, or a wall-only peer could reach the task-delegation
// service just by being admitted for the wall. That leak is this workstream's version of
// the AC131 crown jewel (a `.delegate` grant must not open the C-3 ACP plane): a `.wall`
// grant must not open the delegation channel, and a `.delegate` grant must not let a
// peer write the wall.
//
// So this service routes each admitted line by its JSON-RPC method — `world/wall.*` to
// the wall service, everything else to the delegate service — and RE-VERIFIES the
// sender's grants for the REQUIRED plane before the inner service ever sees the line,
// using the same `StandingGrantAdmission` predicate the transport authorizer runs (one
// predicate, no drift). A line whose plane the sender is not granted is DROPPED
// (fail-closed, no reply, no buffering); an inner service that is nil means the node
// does not serve that plane and the line is dropped the same way.
public struct PlaneRoutedTownService: TownA2AService {
    /// Method prefix that marks a line as WALL-plane traffic. Everything else is the
    /// delegate plane (the historical catch-all — including unparseable lines, which
    /// therefore still require a `.delegate` grant and land on a service built to refuse
    /// garbage, never on the wall).
    public static let wallMethodPrefix = "world/wall."

    private let wall: (any TownA2AService)?
    private let delegate: (any TownA2AService)?
    /// Canonical-lowercase owner hex, or nil to disable the granter pin (tests only —
    /// production always pins; see `StandingGrantTownAuthorizer.requiredGranterHex`).
    private let requiredGranterHex: String?
    private let now: @Sendable () -> Int64
    private let liveGrants: @Sendable () async -> [StandingGrant]

    public init(
        wall: (any TownA2AService)?,
        delegate: (any TownA2AService)?,
        requiredGranterHex: String?,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        liveGrants: @escaping @Sendable () async -> [StandingGrant]
    ) {
        self.wall = wall
        self.delegate = delegate
        // Same normalization contract as StandingGrantTownAuthorizer: canonical lowercase
        // once at init; empty-after-trim is a caller bug refused rather than read as
        // "honor everyone".
        let trimmed = requiredGranterHex?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.requiredGranterHex = (trimmed?.isEmpty == true) ? nil : trimmed
        self.now = now
        self.liveGrants = liveGrants
    }

    /// Whether `line` is wall-plane traffic: a parseable JSON-RPC object whose `method`
    /// starts with `world/wall.`. Parsed, never substring-matched — a delegate-plane
    /// payload that merely MENTIONS the method name in a string stays on the delegate
    /// plane.
    public static func isWallLine(_ line: String) -> Bool {
        guard let method = JSONValue.parse(line)?["method"]?.stringValue else { return false }
        return method.hasPrefix(wallMethodPrefix)
    }

    public func handle(
        line: String, from peerIdentityHex: String,
        reply: @escaping @Sendable (String) -> Void
    ) async {
        let plane: StandingGrant.Plane = Self.isWallLine(line) ? .wall : .delegate
        // The plane re-check — the reason this type exists. Same predicate as transport
        // admission, narrowed to the plane THIS line needs; consulted per line so a
        // revocation bites on the very next one.
        guard StandingGrantAdmission.admits(
            peer: peerIdentityHex, plane: plane, requiredGranterHex: requiredGranterHex,
            cutoff: now(), grants: await liveGrants())
        else { return }  // fail-closed drop: wrong-plane grant, expired, tampered, none
        switch plane {
        case .wall:
            await wall?.handle(line: line, from: peerIdentityHex, reply: reply)
        case .delegate:
            await delegate?.handle(line: line, from: peerIdentityHex, reply: reply)
        }
    }
}
