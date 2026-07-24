// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import Testing

@testable import Huginn

/// WS-G5 Phase-2 gate — the Town Grants panel's model. Headless, temp-dir, no
/// subprocess (the Huginn test rule): file round-trips in the EXACT shapes the node
/// consumes, per-entry verification labeling, import refusal for tampered/foreign
/// grants, and removal-as-revocation.
@MainActor
@Suite("Town grants panel model")
struct TownGrantsModelTests {
    private func tempPaths() throws -> (grants: String, peers: String, dir: String) {
        let dir = NSTemporaryDirectory() + "huginn-towngrants-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir + "/town-grants.json", dir + "/town-peers.json", dir)
    }

    private func mintGrant(
        owner: PQRCIdentity, peer: String, grantID: String = "g1", days: Int64 = 7
    ) throws -> StandingGrant {
        try StandingGrant.make(
            grantID: grantID, peer: peer, planes: [.wall],
            budget: .init(messagesPerDay: 100, bytesPerDay: 100_000, maxConcurrentTasks: 2),
            activeUntil: Int64(Date().timeIntervalSince1970) + days * 86_400,
            identity: owner)
    }

    @Test func importValid_persistsNodeShape_removeRevokes() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.dir) }
        let owner = try PQRCIdentity(seed: Data(repeating: 0x61, count: 32))
        let ownerHex = owner.publicKeyData.hexString
        let peer = String(repeating: "ab", count: 32)
        let grant = try mintGrant(owner: owner, peer: peer)

        let model = TownGrantsModel(grantsPath: paths.grants, peersPath: paths.peers)
        model.importText = String(
            decoding: try JSONEncoder().encode(grant), as: UTF8.self)
        model.importGrant(ownerHex: ownerHex)

        #expect(model.grants.count == 1)
        #expect(model.grants.first?.problem == nil, "an owner-signed grant is VALID")
        #expect(model.grants.first?.peerHex == peer)

        // The file on disk is EXACTLY the node's shape: {"grants":[...]} whose element
        // decodes back to the same signed grant.
        struct NodeShape: Codable { let grants: [StandingGrant] }
        let onDisk = try JSONDecoder().decode(
            NodeShape.self, from: Data(contentsOf: URL(fileURLWithPath: paths.grants)))
        #expect(onDisk.grants == [grant], "byte-faithful round-trip into the node's format")

        // Remove = revocation: the entry leaves the file.
        model.removeGrant(grantID: grant.grantID, ownerHex: ownerHex)
        #expect(model.grants.isEmpty)
        let after = try JSONDecoder().decode(
            NodeShape.self, from: Data(contentsOf: URL(fileURLWithPath: paths.grants)))
        #expect(after.grants.isEmpty, "removal persists — the node denies on its next read")
    }

    @Test func tamperedAndForeignGrants_refusedOnImport_labeledOnLoad() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.dir) }
        let owner = try PQRCIdentity(seed: Data(repeating: 0x62, count: 32))
        let foreign = try PQRCIdentity(seed: Data(repeating: 0x63, count: 32))
        let ownerHex = owner.publicKeyData.hexString
        let peer = String(repeating: "cd", count: 32)

        let model = TownGrantsModel(grantsPath: paths.grants, peersPath: paths.peers)

        // Foreign-signed: import refused outright.
        let foreignGrant = try mintGrant(owner: foreign, peer: peer, grantID: "foreign")
        model.importText = String(decoding: try JSONEncoder().encode(foreignGrant), as: UTF8.self)
        model.importGrant(ownerHex: ownerHex)
        #expect(model.grants.isEmpty, "a foreign-signed grant must not be staged")
        #expect(model.importStatus?.contains("FOREIGN") == true)

        // Tampered (re-scoped without re-signing): import refused.
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try mintGrant(owner: owner, peer: peer, grantID: "t")))
            as! [String: Any]
        json["active_until"] = Int64(Date().timeIntervalSince1970) + 30 * 86_400
        model.importText = String(
            decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        model.importGrant(ownerHex: ownerHex)
        #expect(model.grants.isEmpty, "a tampered grant must not be staged")

        // An INVALID entry already IN the file (edited by hand) is shown + labeled,
        // never silently hidden — this panel is the file's editor, not its consumer.
        let fileJSON = try JSONSerialization.data(
            withJSONObject: ["grants": [json]], options: [])
        try fileJSON.write(to: URL(fileURLWithPath: paths.grants))
        model.reload(ownerHex: ownerHex)
        #expect(model.grants.count == 1)
        #expect(model.grants.first?.problem?.contains("INVALID") == true)
    }

    @Test func peersRoster_roundTripsInTheNodeShape() async throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(atPath: paths.dir) }
        let model = TownGrantsModel(grantsPath: paths.grants, peersPath: paths.peers)
        let entry = TownPeerEntry(
            identityHex: String(repeating: "ef", count: 32), townID: "acme-town", label: "Acme")
        model.addPeer(entry, ownerHex: nil)
        #expect(model.peers == [entry])

        // Field names are the node's wire format — pin them literally so a rename on
        // either side fails THIS test instead of silently orphaning the roster.
        let raw = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: paths.peers))) as! [[String: Any]]
        #expect(raw.first?.keys.sorted() == ["identityHex", "label", "townID"])

        model.removePeer(identityHex: entry.identityHex, ownerHex: nil)
        #expect(model.peers.isEmpty)
    }
}
