// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import Huginn

/// WS-D2h — the World dashboard's read path and status vocabulary. Headless: no node, no
/// network, no subprocess (the Huginn test rule). The status derivation is pure by
/// construction, so every row of the honest-status table is table-testable here.
@Suite("World dashboard — status derivation and node read path")
struct WorldStatusTests {

    private func town(
        townID: String = "t", label: String = "T", wall: Bool = true, delegate: Bool = false,
        lastSeen: Int64 = 0, grantExpiry: Int64? = nil
    ) throws -> TownStatusWire.Town {
        // Built through the DECODER, not a memberwise init: the wire shape is the
        // contract, so a field rename must fail these tests.
        let json = """
            {"townID":"\(townID)","label":"\(label)","wallGranted":\(wall),
             "delegateGranted":\(delegate),"lastSeen":\(lastSeen),
             "grantExpiry":\(grantExpiry.map(String.init) ?? "null")}
            """
        return try JSONDecoder().decode(TownStatusWire.Town.self, from: Data(json.utf8))
    }

    // MARK: - The honest-status table

    /// Permission and connection are DIFFERENT facts and must never collapse into one
    /// another. This is the property the whole dashboard rests on.
    @Test func authorizedIsNotConnected_andConnectedNeedsRecentTraffic() throws {
        let now: Int64 = 1_800_000_000

        // A live grant with no traffic is "authorized", never "connected".
        let quiet = try town(wall: true, lastSeen: 0, grantExpiry: now + 86_400)
        #expect(
            WorldStatusDerivation.townStatus(quiet, now: now) == .authorized(until: now + 86_400),
            "a grant is permission, not a connection")

        // Traffic inside the window is "connected".
        let busy = try town(wall: true, lastSeen: now - 30, grantExpiry: now + 86_400)
        #expect(WorldStatusDerivation.townStatus(busy, now: now) == .live(lastSeen: now - 30))

        // Traffic OUTSIDE the window decays back to authorized — not stuck on green.
        let stale = try town(
            wall: true, lastSeen: now - WorldStatusDerivation.liveWindowSeconds - 1,
            grantExpiry: now + 86_400)
        #expect(WorldStatusDerivation.townStatus(stale, now: now) == .authorized(until: now + 86_400))

        // Exactly at the boundary still counts as live (inclusive).
        let edge = try town(
            wall: true, lastSeen: now - WorldStatusDerivation.liveWindowSeconds,
            grantExpiry: now + 86_400)
        #expect(
            WorldStatusDerivation.townStatus(edge, now: now)
                == .live(lastSeen: now - WorldStatusDerivation.liveWindowSeconds))
    }

    /// Losing the grant is EXACTLY when a dashboard must stop saying "connected" — even
    /// if the node's `lastSeen` is a second old. Authorization is checked first for this
    /// reason; a regression here would show a revoked town as green.
    @Test func revokedTownNeverReadsAsConnected_evenWithFreshTraffic() throws {
        let now: Int64 = 1_800_000_000
        let justRevoked = try town(wall: false, delegate: false, lastSeen: now - 1, grantExpiry: nil)
        #expect(
            WorldStatusDerivation.townStatus(justRevoked, now: now) == .notAuthorized,
            "revocation must beat recency — otherwise the kill switch looks like it failed")
    }

    /// A paused Buzz connection is the owner's choice, not a fault; and an unprobed one
    /// is honestly unknown rather than optimistically fine.
    @Test func buzzStatusDistinguishesPausedFromUnreachableFromUnprobed() {
        #expect(WorldStatusDerivation.buzzStatus(paused: true, probe: nil) == .notAuthorized)
        #expect(WorldStatusDerivation.buzzStatus(paused: false, probe: nil) == .unknown("not probed yet"))
        #expect(
            WorldStatusDerivation.buzzStatus(
                paused: false,
                probe: BuzzRelayProbeResult(
                    reachable: true, membershipGated: true, relayName: "n", detail: "ok"))
                == .live(lastSeen: 0))
        #expect(
            WorldStatusDerivation.buzzStatus(paused: false, probe: .failure("refused"))
                == .unreachable("refused"))
    }

    /// An unauthorized peer is still a ROW. Hiding it is how "why won't this town talk?"
    /// becomes unanswerable — the exact failure this panel exists to prevent.
    @Test func unauthorizedTownStillAppearsAsARow() throws {
        let snapshot = TownStatusWire(
            nodeTownID: "home", localAgentID: "flock",
            towns: [try town(townID: "cold", label: "Cold", wall: false, delegate: false)],
            droppedInboundCount: 0, generatedAt: 1_800_000_000)
        let rows = WorldStatusDerivation.townRows(snapshot, now: 1_800_000_000)
        #expect(rows.count == 1)
        #expect(rows[0].status == .notAuthorized)
        #expect(rows[0].subtitle.contains("no live grant"))
        #expect(rows[0].confirmedAt == snapshot.generatedAt, "every row carries when it was confirmed")
    }

    // MARK: - The wire contract with the node

    /// Huginn deliberately does not link EldrNode, so `TownStatusWire` is a MIRROR of the
    /// node's `TownStatusSnapshot`. This pins the field names: if the node renames one,
    /// this fails instead of the dashboard silently decoding to defaults.
    @Test func worldStatusWireMatchesTheNodeContract() throws {
        let json = """
            {"nodeTownID":"home","localAgentID":"flock","droppedInboundCount":2,
             "generatedAt":1800000000,
             "towns":[{"townID":"town-b","label":"Town B","wallGranted":true,
                       "delegateGranted":false,"lastSeen":1799999990,"grantExpiry":1800086400}]}
            """
        let wire = try JSONDecoder().decode(TownStatusWire.self, from: Data(json.utf8))
        #expect(wire.nodeTownID == "home")
        #expect(wire.localAgentID == "flock")
        #expect(wire.droppedInboundCount == 2)
        #expect(wire.towns.count == 1)
        #expect(wire.towns[0].townID == "town-b")
        #expect(wire.towns[0].wallGranted)
        #expect(!wire.towns[0].delegateGranted)
        #expect(wire.towns[0].grantExpiry == 1_800_086_400)

        // The declared field set must be exactly what the type decodes — the same set the
        // node asserts against in `worldStatusSnapshotCarriesNoMessageContent`.
        let keys = Set(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]).keys)
        #expect(keys.isSubset(of: TownStatusWire.fieldNames))
    }

    // MARK: - Config resolution

    /// The process environment must WIN over the env file, so a Huginn launched from the
    /// same shell as the node agrees with the node rather than with a stale template.
    @Test func processEnvironmentOverridesTheEnvFile() throws {
        let dir = NSTemporaryDirectory() + "huginn-world-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envFile = dir + "/mcp-town.env"
        try """
            # a comment
            ELDR_GOOSEWORLD_SOCKET=/from/file.sock
            ELDR_GOOSEWORLD_TOKEN="quoted-file-token"
            """.write(toFile: envFile, atomically: true, encoding: .utf8)

        let parsed = WorldStatusClient.parseEnvFile(at: envFile)
        #expect(parsed["ELDR_GOOSEWORLD_SOCKET"] == "/from/file.sock")
        #expect(parsed["ELDR_GOOSEWORLD_TOKEN"] == "quoted-file-token", "quotes are stripped")
    }

    /// The template file ships with every value COMMENTED OUT. It must read as "not
    /// configured" — never as a literal token of placeholder text, which would then be
    /// sent to the socket and rejected with a confusing auth failure.
    @Test func commentedTemplateReadsAsNotConfigured() throws {
        let dir = NSTemporaryDirectory() + "huginn-world-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let envFile = dir + "/mcp-town.env"
        try """
            # ELDR_GOOSEWORLD_SOCKET=/path/to/loopback.sock
            # ELDR_GOOSEWORLD_TOKEN=paste-the-pairing-token-here
            """.write(toFile: envFile, atomically: true, encoding: .utf8)
        #expect(WorldStatusClient.parseEnvFile(at: envFile).isEmpty)
    }
}
