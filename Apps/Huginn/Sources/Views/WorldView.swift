// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftUI

// WS-D2h — "World": one answer to "who is this Mac actually connected to?".
//
// Before this, the answer was split across two tabs that could not see each other and a
// running node that neither could see at all: Town Grants read `town-grants.json` while
// the node read a DIFFERENT file, so the panel could truthfully show "None" while the
// node was live and serving a granted town. This view consolidates the three families —
// towns, Buzz workspaces, the phone tether — and gets town state from the NODE ITSELF
// (`world/status`) rather than from a file that may not be the one the node loaded.
//
// **The honest-status rule.** A row may only claim what this app can verify first-hand.
// `authorized` (a live grant exists) and `live` (the node has actually seen traffic) are
// different facts and are never collapsed: a grant is permission, not a connection. Every
// row carries when it was confirmed, so nothing implies freshness it does not have.
//
// The two prior tabs are NOT deleted — `TownGrantsView` and `BuzzConnectionsView` are
// reachable from their sections here, so every edit/import/revoke path is unchanged.

/// What one connection's state is, in the only vocabulary this app can honestly use.
enum WorldStatus: Equatable {
    /// The node has seen traffic from this peer at `lastSeen` (unix seconds).
    case live(lastSeen: Int64)
    /// A live grant covers it, but no traffic observed. Permission ≠ connection.
    case authorized(until: Int64?)
    /// Paired/known, but nothing authorizes it right now.
    case notAuthorized
    /// Reachability was tested and failed.
    case unreachable(String)
    /// We could not establish the fact at all (node down, not configured).
    case unknown(String)

    var label: String {
        switch self {
        case .live: return "connected"
        case .authorized: return "authorized"
        case .notAuthorized: return "not authorized"
        case .unreachable: return "unreachable"
        case .unknown: return "unknown"
        }
    }

    var symbol: String {
        switch self {
        case .live: return "checkmark.circle.fill"
        case .authorized: return "checkmark.shield"
        case .notAuthorized: return "slash.circle"
        case .unreachable: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .live: return .green
        case .authorized: return .blue
        case .notAuthorized: return .secondary
        case .unreachable: return .orange
        case .unknown: return .secondary
        }
    }
}

/// One row, whatever family it came from.
struct WorldRow: Identifiable, Equatable {
    enum Family: String, Equatable { case town, buzz, tether }
    let id: String
    let family: Family
    let title: String
    let subtitle: String
    let status: WorldStatus
    /// When the underlying fact was established. Rendered as "confirmed Ns ago".
    let confirmedAt: Int64
}

/// Pure derivation — no I/O, no clock of its own — so every row of the status table is
/// table-testable. Kept `enum` (namespace only) deliberately.
enum WorldStatusDerivation {

    /// How recently the node must have seen a peer for it to read as `live` rather than
    /// merely authorized. Five minutes: long enough that a quiet-but-connected town does
    /// not flap, short enough that "connected" still means something.
    static let liveWindowSeconds: Int64 = 300

    /// A town's status, from the node's snapshot.
    ///
    /// Order matters: authorization is checked FIRST, so a peer whose grant lapsed can
    /// never read as `live` off a stale `lastSeen` — losing the grant is exactly when a
    /// dashboard must stop saying "connected".
    static func townStatus(
        _ town: TownStatusWire.Town, now: Int64, liveWindow: Int64 = liveWindowSeconds
    ) -> WorldStatus {
        guard town.wallGranted || town.delegateGranted else { return .notAuthorized }
        if town.lastSeen > 0 && now - town.lastSeen <= liveWindow {
            return .live(lastSeen: town.lastSeen)
        }
        return .authorized(until: town.grantExpiry)
    }

    static func townRows(_ snapshot: TownStatusWire, now: Int64) -> [WorldRow] {
        snapshot.towns.map { town in
            let planes = [
                town.wallGranted ? "wall" : nil, town.delegateGranted ? "delegate" : nil,
            ].compactMap { $0 }
            return WorldRow(
                id: "town:\(town.townID)", family: .town,
                title: town.label.isEmpty ? town.townID : town.label,
                subtitle: planes.isEmpty
                    ? "\(town.townID) · no live grant"
                    : "\(town.townID) · \(planes.joined(separator: " + "))",
                status: townStatus(town, now: now),
                confirmedAt: snapshot.generatedAt)
        }
    }

    /// A Buzz workspace's status. A paused connection is deliberately NOT "unreachable" —
    /// the owner turned it off, which is a different fact from the relay being down.
    static func buzzStatus(paused: Bool, probe: BuzzRelayProbeResult?) -> WorldStatus {
        if paused { return .notAuthorized }
        guard let probe else { return .unknown("not probed yet") }
        return probe.reachable ? .live(lastSeen: 0) : .unreachable(probe.detail)
    }
}

// MARK: - Model

@MainActor
final class WorldModel: ObservableObject {
    @Published private(set) var townRows: [WorldRow] = []
    /// The raw snapshot towns, kept alongside the derived rows so the MAP can draw
    /// grant-lifetime rings (which need `grantExpiry` even for a live edge, a fact the
    /// derived `WorldRow.status` deliberately does not carry).
    @Published private(set) var townsRaw: [TownStatusWire.Town] = []
    @Published private(set) var nodeTownID: String = ""
    @Published private(set) var townsProblem: String?
    @Published private(set) var buzzProbes: [String: BuzzRelayProbeResult] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var nodeSummary: String?

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    /// Refresh town state from the node. Buzz probes are NOT run here — they hit the
    /// network, so they stay on an explicit per-row action.
    func refreshTowns(paths: ConfigPaths = .standard) async {
        refreshing = true
        defer { refreshing = false }
        do {
            let snapshot = try await WorldStatusClient.fetch(paths: paths)
            townRows = WorldStatusDerivation.townRows(snapshot, now: now)
            townsRaw = snapshot.towns
            nodeTownID = snapshot.nodeTownID
            townsProblem = nil
            nodeSummary =
                "node town “\(snapshot.nodeTownID)” as \(snapshot.localAgentID)"
                + (snapshot.droppedInboundCount > 0
                    ? " · \(snapshot.droppedInboundCount) inbound dropped" : "")
        } catch WorldStatusError.notConfigured {
            townRows = []
            townsRaw = []
            nodeSummary = nil
            townsProblem =
                "No town socket configured on this Mac. Set ELDR_GOOSEWORLD_SOCKET and "
                + "ELDR_GOOSEWORLD_TOKEN (the same values the node is launched with)."
        } catch WorldStatusError.nodeUnreachable(let why) {
            // The COMMON case. Never an empty list, which would read as "no towns".
            townRows = []
            townsRaw = []
            nodeSummary = nil
            townsProblem = "The node isn't answering (\(why)). Start eldr-node to see live towns."
        } catch {
            townRows = []
            townsRaw = []
            nodeSummary = nil
            townsProblem = "Could not read the node's status: \(error)"
        }
    }

    func probeBuzz(_ connection: BuzzConnection) async {
        let result = await BuzzRelayProbe.probe(urlString: connection.relayURL)
        buzzProbes[connection.id] = result
    }
}

// MARK: - View

/// List or map. The toggle never HIDES information — the map is a second rendering of
/// the same rows, and the list stays the fully navigable (and accessible) surface.
enum WorldPresentation: String, CaseIterable, Identifiable {
    case list, map
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Map" }
}

struct WorldView: View {
    @StateObject private var model = WorldModel()
    @ObservedObject private var buzz = BuzzGatewayService.shared.store
    @State private var presentation: WorldPresentation = .list

    var body: some View {
        NavigationStack {
            List {
                townsSection
                buzzSection
                tetherSection
            }
            .navigationTitle("World")
            .toolbar {
                Button {
                    Task { await model.refreshTowns() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.refreshing)
            }
            .task { await model.refreshTowns() }
        }
    }

    private var townsSection: some View {
        Section {
            if let problem = model.townsProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Picker("View", selection: $presentation) {
                ForEach(WorldPresentation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if presentation == .map {
                WorldMapView(nodeTownID: model.nodeTownID, towns: model.townsRaw)
            } else {
                ForEach(model.townRows) { row in
                    WorldRowView(row: row)
                }
            }
            NavigationLink {
                TownGrantsView()
            } label: {
                Label("Manage town grants…", systemImage: "signpost.right.and.left")
            }
        } header: {
            HStack {
                Text("Towns")
                Spacer()
                if let summary = model.nodeSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(
                "“authorized” means a live owner-signed grant covers this town. "
                    + "“connected” means the node has actually seen its traffic. A grant is "
                    + "permission, not a connection."
            )
            .font(.caption)
        }
    }

    private var buzzSection: some View {
        Section("Buzz workspaces") {
            if buzz.connections.isEmpty {
                Text("No workspace connections yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(buzz.connections) { connection in
                let status = WorldStatusDerivation.buzzStatus(
                    paused: connection.paused, probe: model.buzzProbes[connection.id])
                WorldRowView(
                    row: WorldRow(
                        id: "buzz:\(connection.id)", family: .buzz,
                        title: connection.displayName.isEmpty
                            ? connection.relayHost : connection.displayName,
                        subtitle: connection.relayHost, status: status,
                        confirmedAt: Int64(Date().timeIntervalSince1970))
                ) {
                    Button("Check") { Task { await model.probeBuzz(connection) } }
                        .buttonStyle(.borderless)
                }
            }
            NavigationLink {
                BuzzConnectionsView()
            } label: {
                Label("Manage workspace connections…", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
    }

    private var tetherSection: some View {
        Section("Phone tether") {
            NavigationLink {
                BridgeView()
            } label: {
                Label("Pairing & remote-drive session", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

/// One row: title, subtitle, status chip, and when it was confirmed.
struct WorldRowView<Accessory: View>: View {
    let row: WorldRow
    @ViewBuilder var accessory: Accessory

    init(row: WorldRow, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.row = row
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.status.symbol)
                .foregroundStyle(row.status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(row.status.tint)
                Text(Self.detail(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            accessory
        }
    }

    /// The per-status detail line — an expiry, a last-seen, or a reason.
    static func detail(_ row: WorldRow) -> String {
        switch row.status {
        case .live(let lastSeen):
            return lastSeen > 0 ? "seen \(relative(lastSeen))" : "reachable"
        case .authorized(let until):
            guard let until else { return "no expiry" }
            return "until \(Date(timeIntervalSince1970: TimeInterval(until)).formatted(.dateTime.month().day().hour().minute()))"
        case .notAuthorized:
            return ""
        case .unreachable(let why):
            return why
        case .unknown(let why):
            return why
        }
    }

    private static func relative(_ unix: Int64) -> String {
        let delta = Int64(Date().timeIntervalSince1970) - unix
        if delta < 60 { return "\(max(0, delta))s ago" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        return "\(delta / 3600)h ago"
    }
}
