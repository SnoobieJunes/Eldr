// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import PQRCCore
import SwiftUI

// WS-G5 Phase-2 gate — the Huginn TOWN GRANTS panel: the human-visible surface over
// the two files an `eldr-node` town plane consumes:
//
//   town-grants.json  {"grants":[ <StandingGrant>… ]}   (FileStandingGrantStore)
//   town-peers.json   [ {identityHex, townID, label}… ]
//
// Huginn VERIFIES and STAGES; it never signs. Grants are minted on the PHONE (the human
// identity key lives there — the app's "Grant town access…" flow copies the export
// JSON) and pasted here; each entry is re-verified (structure, signature, granter ==
// the pinned owner) and labeled honestly — an entry the node would drop is shown as
// INVALID here rather than hidden, because this panel is the EDITOR for the file, not
// its consumer. Removing an entry IS the node-side revocation (DEVIATIONS AC143): the
// node re-reads the file on change, so removal bites on the peer's next frame.

/// One roster entry — field names MUST match `EldrNodeGooseworld.TownWallHost.TownPeer`
/// exactly (this file is that type's wire format; Huginn deliberately does not link
/// EldrNode, so the shape is pinned here and by `TownGrantsModelTests`).
struct TownPeerEntry: Codable, Equatable, Identifiable {
    var id: String { identityHex }
    var identityHex: String
    var townID: String
    var label: String
}

/// The panel's model: file I/O + per-entry verification, paths injectable so tests run
/// in a temp dir with no app state (the zero-subprocess Huginn test rule).
@MainActor
final class TownGrantsModel: ObservableObject {
    struct GrantRow: Identifiable, Equatable {
        var id: String { grantID }
        let grantID: String
        let peerHex: String
        let planes: [String]
        let activeUntil: Int64
        /// nil = verifies against the pinned owner; else the human-readable problem.
        let problem: String?
    }

    @Published private(set) var grants: [GrantRow] = []
    @Published private(set) var peers: [TownPeerEntry] = []
    @Published var importText = ""
    @Published private(set) var importStatus: String?

    let grantsPath: String
    let peersPath: String

    init(grantsPath: String, peersPath: String) {
        self.grantsPath = grantsPath
        self.peersPath = peersPath
    }

    private struct GrantFile: Codable {
        var grants: [StandingGrant]
    }

    // MARK: - Load + verify

    /// (Re)read both files, verifying every grant against `ownerHex` (nil = phone not
    /// yet paired → verification can check the signature but not WHO signed; stated).
    func reload(ownerHex: String?, now: Int64 = Int64(Date().timeIntervalSince1970)) {
        let owner = ownerHex?.lowercased()
        var rows: [GrantRow] = []
        if let data = FileManager.default.contents(atPath: grantsPath),
            let file = try? JSONDecoder().decode(GrantFile.self, from: data)
        {
            for grant in file.grants {
                rows.append(Self.row(for: grant, owner: owner, now: now))
            }
        }
        grants = rows
        if let data = FileManager.default.contents(atPath: peersPath),
            let decoded = try? JSONDecoder().decode([TownPeerEntry].self, from: data)
        {
            peers = decoded
        } else {
            peers = []
        }
    }

    nonisolated static func row(for grant: StandingGrant, owner: String?, now: Int64) -> GrantRow {
        let problem: String?
        if (try? grant.validateStructure()) == nil {
            problem = "INVALID structure — the node will drop it"
        } else if !grant.hasValidSignature() {
            problem = "INVALID signature — tampered or corrupted; the node will drop it"
        } else if let owner, grant.enabledBy.hexString != owner {
            problem = "FOREIGN signer — not the paired owner; the node will drop it"
        } else if grant.activeUntil <= now {
            problem = "EXPIRED"
        } else if owner == nil {
            problem = "signature OK — pair the phone to pin WHO signed"
        } else {
            problem = nil
        }
        return GrantRow(
            grantID: grant.grantID, peerHex: grant.peer, planes: grant.planes,
            activeUntil: grant.activeUntil, problem: problem)
    }

    // MARK: - Mutations (each rewrites the file; the node re-reads on change)

    /// Import one pasted grant JSON (the phone's export). Refused unless it decodes,
    /// validates, and — when an owner is pinned — was signed by that owner. A grant
    /// with a duplicate grantID replaces the existing entry (re-issue/top-up).
    func importGrant(ownerHex: String?, now: Int64 = Int64(Date().timeIntervalSince1970)) {
        guard let data = importText.data(using: .utf8),
            let grant = try? JSONDecoder().decode(StandingGrant.self, from: data)
        else {
            importStatus = "Not a grant: paste the exact JSON the phone's “Copy grant for the node” produced."
            return
        }
        let row = Self.row(for: grant, owner: ownerHex?.lowercased(), now: now)
        if let problem = row.problem, problem != "signature OK — pair the phone to pin WHO signed" {
            importStatus = "Refused: \(problem)"
            return
        }
        var file = loadFile()
        file.grants.removeAll { $0.grantID == grant.grantID }
        file.grants.append(grant)
        importStatus = save(file) ? "Imported \(grant.grantID) — the node honors it on the next frame." : "Write failed."
        importText = ""
        reload(ownerHex: ownerHex, now: now)
    }

    /// Remove = the node-side revocation (the store's documented contract).
    func removeGrant(grantID: String, ownerHex: String?) {
        var file = loadFile()
        file.grants.removeAll { $0.grantID == grantID }
        _ = save(file)
        reload(ownerHex: ownerHex)
    }

    func addPeer(_ entry: TownPeerEntry, ownerHex: String?) {
        var current = peers.filter { $0.identityHex != entry.identityHex }
        current.append(entry)
        _ = savePeers(current)
        reload(ownerHex: ownerHex)
    }

    func removePeer(identityHex: String, ownerHex: String?) {
        _ = savePeers(peers.filter { $0.identityHex != identityHex })
        reload(ownerHex: ownerHex)
    }

    // MARK: - File I/O (atomic-write, 0600 — same posture as every node data file)

    private func loadFile() -> GrantFile {
        guard let data = FileManager.default.contents(atPath: grantsPath),
            let file = try? JSONDecoder().decode(GrantFile.self, from: data)
        else { return GrantFile(grants: []) }
        return file
    }

    private func save(_ file: GrantFile) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return false }
        return Self.write(data, to: grantsPath)
    }

    private func savePeers(_ entries: [TownPeerEntry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        return Self.write(data, to: peersPath)
    }

    nonisolated private static func write(_ data: Data, to path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}

struct TownGrantsView: View {
    @EnvironmentObject private var bridge: ACPBridgeService
    @StateObject private var model = TownGrantsModel(
        grantsPath: ConfigPaths.standard.townGrantsFile,
        peersPath: ConfigPaths.standard.townPeersFile)
    @State private var newPeerHex = ""
    @State private var newPeerTown = ""
    @State private var newPeerLabel = ""

    var body: some View {
        Form {
            Section {
                if let owner = bridge.ownerIdentityHex {
                    Label("Verifying against the paired owner \(String(owner.prefix(12)))…", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No owner paired yet — signatures verify, but WHO signed can't be pinned until the phone pairs (Bridge tab).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Standing grants (\(model.grantsPath))") {
                if model.grants.isEmpty {
                    Text("None. Mint one on the phone (conversation ▸ AI ▸ Grant town access…), copy it, and paste it below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.grants) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.planes.joined(separator: " + ")) → \(String(row.peerHex.prefix(12)))…")
                                .font(.callout.monospaced())
                            if let problem = row.problem {
                                Text(problem).font(.caption2).foregroundStyle(.orange)
                            } else {
                                Text("valid · until \(Date(timeIntervalSince1970: TimeInterval(row.activeUntil)).formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove (revoke)", role: .destructive) {
                            model.removeGrant(grantID: row.grantID, ownerHex: bridge.ownerIdentityHex)
                        }
                        .font(.caption)
                    }
                }
            }
            Section("Import a phone-minted grant") {
                TextEditor(text: $model.importText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 70)
                HStack {
                    Button("Import") {
                        model.importGrant(ownerHex: bridge.ownerIdentityHex)
                    }
                    .disabled(model.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let status = model.importStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Paired towns (\(model.peersPath))") {
                ForEach(model.peers) { peer in
                    HStack {
                        Text("\(peer.townID) — \(peer.label)  \(String(peer.identityHex.prefix(12)))…")
                            .font(.callout)
                        Spacer()
                        Button("Remove", role: .destructive) {
                            model.removePeer(identityHex: peer.identityHex, ownerHex: bridge.ownerIdentityHex)
                        }
                        .font(.caption)
                    }
                }
                HStack {
                    TextField("peer identity hex", text: $newPeerHex).font(.caption.monospaced())
                    TextField("town id", text: $newPeerTown).frame(width: 110)
                    TextField("label", text: $newPeerLabel).frame(width: 110)
                    Button("Add") {
                        model.addPeer(
                            TownPeerEntry(
                                identityHex: newPeerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                                townID: newPeerTown, label: newPeerLabel),
                            ownerHex: bridge.ownerIdentityHex)
                        newPeerHex = ""
                        newPeerTown = ""
                        newPeerLabel = ""
                    }
                    .disabled(newPeerHex.trimmingCharacters(in: .whitespacesAndNewlines).count != 64)
                }
            }
            Section {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: model.grantsPath)])
                }
            } footer: {
                Text("The node re-reads these files on change: importing takes effect on the peer's next frame, and removing an entry is that file's revocation. Grants are day-bounded and signed by the phone; Huginn only verifies and stages them.")
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .onAppear { model.reload(ownerHex: bridge.ownerIdentityHex) }
    }
}
