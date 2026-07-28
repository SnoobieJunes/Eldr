// SPDX-License-Identifier: AGPL-3.0-only
import PQRCAgent
import PQRCCore
import SwiftUI

// WS-D1a — "World" on the phone: every network this identity is attached to, in one place.
//
// **This view is deliberately WEAKER than Huginn's, and that is the point.** The phone
// cannot observe whether a town is actually connected — `lastSeen` lives in the running
// node's memory on the Mac, and there is no node→phone status channel (by choice: it
// would mean a new frame class, a push cadence, and peer identity moving over the wire
// for a convenience). So the phone reports only what it can verify FIRST-HAND: what this
// device authorized, what it joined, and what it tethered.
//
// A town therefore renders as `authorized` / `expiring` / `expired` and NEVER as
// "connected". Showing a green connected lamp here would be the app asserting a fact it
// has no way to know — and the one time it mattered (a peer silently unreachable) it
// would be confidently wrong. The Mac's World tab is where liveness is answerable.

/// Sidebar route for the World screen — same shape as `BuzzRoute`, so a selection can
/// never be mistaken for a conversation id.
enum WorldRoute {
    static let id = "world:home"
    static func isWorld(_ selection: String) -> Bool { selection == id }
}

/// What the PHONE can say about a town. Note the absence of a `connected` case: it is
/// unrepresentable here rather than merely unused, so no future edit can quietly add it.
enum PhoneGrantStatus: Equatable {
    case authorized(until: Int64)
    case expiringSoon(until: Int64)
    case expired

    var label: String {
        switch self {
        case .authorized: return "authorized"
        case .expiringSoon: return "expiring soon"
        case .expired: return "expired"
        }
    }

    var symbol: String {
        switch self {
        case .authorized: return "checkmark.shield"
        case .expiringSoon: return "clock.badge.exclamationmark"
        case .expired: return "xmark.shield"
        }
    }

    var tint: Color {
        switch self {
        case .authorized: return .blue
        case .expiringSoon: return .orange
        case .expired: return .secondary
        }
    }
}

/// One authorized town, as the phone knows it.
struct PhoneTownRow: Identifiable, Equatable {
    let id: String
    /// Short peer prefix — the full 64-char hex is never a useful thing to read.
    let title: String
    /// The planes this peer is authorized on, joined.
    let subtitle: String
    let status: PhoneGrantStatus
}

/// Pure derivation: no clock, no I/O, not `@MainActor` — so it is directly table-testable
/// (the pattern `AppModel.townGrantBanner` established).
enum PhoneWorldDerivation {

    /// How close to expiry a grant starts reading as "expiring soon". A day: long enough
    /// that the owner can act before a demo dies mid-sentence.
    static let expiringWindowSeconds: Int64 = 86_400

    static func status(activeUntil: Int64, now: Int64) -> PhoneGrantStatus {
        if activeUntil <= now { return .expired }
        if activeUntil - now <= expiringWindowSeconds { return .expiringSoon(until: activeUntil) }
        return .authorized(until: activeUntil)
    }

    /// Collapse per-PLANE grant statuses into one row per PEER.
    ///
    /// The engine reports a `StandingGrantStatus` per plane, so a peer granted both wall
    /// and delegate arrives as two entries. Rendering those as two rows would read as two
    /// towns — the horizon shown is the LATEST expiry, matching the node's own
    /// `grantExpiry` semantics so the two dashboards agree.
    static func townRows(_ grants: [AgentEngine.StandingGrantStatus], now: Int64)
        -> [PhoneTownRow]
    {
        let byPeer = Dictionary(grouping: grants, by: \.peerIdentityHex)
        return byPeer.keys.sorted().map { peer in
            let entries = byPeer[peer] ?? []
            let horizon = entries.map(\.activeUntil).max() ?? 0
            let planes = Set(entries.map { $0.plane.rawValue }).sorted()
            return PhoneTownRow(
                id: "town:\(peer)",
                title: String(peer.prefix(12)) + "…",
                subtitle: planes.isEmpty ? "no planes" : planes.joined(separator: " + "),
                status: status(activeUntil: horizon, now: now))
        }
    }
}

/// List or map — a second rendering of the same rows, never a replacement. The list
/// stays the fully navigable surface, which is also what keeps the map accessible.
enum PhoneWorldPresentation: String, CaseIterable, Identifiable {
    case list, map
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Map" }
}

struct WorldView: View {
    @Bindable var model: AppModel
    /// Joined Buzz workspaces, when the workspace model is live for this silo.
    var workspaces: BuzzWorkspaceModel?
    @State private var presentation: PhoneWorldPresentation = .list

    private var now: Int64 { Int64(Date().timeIntervalSince1970) }

    var body: some View {
        List {
            townsSection
            workspacesSection
            aisSection
        }
        .navigationTitle("World")
        .task { await model.refreshTownGrants() }
        .refreshable { await model.refreshTownGrants() }
    }

    private var townsSection: some View {
        Section {
            let rows = PhoneWorldDerivation.townRows(model.myTownGrants, now: now)
            if rows.isEmpty {
                Text("You haven't granted any town access yet. Open a conversation ▸ AI ▸ Grant town access… to mint one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !rows.isEmpty {
                Picker("View", selection: $presentation) {
                    ForEach(PhoneWorldPresentation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if presentation == .map, !rows.isEmpty {
                PhoneWorldMapView(rows: rows)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.status.symbol)
                            .foregroundStyle(row.status.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.monospaced())
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.status.label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(row.status.tint)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Towns you've authorized")
        } footer: {
            // The honest-status rule, stated to the user rather than only in code.
            Text("This is what you granted from this phone. Whether a town is actually connected right now is visible on your Mac — this device can't observe it.")
                .font(.caption)
        }
    }

    @ViewBuilder private var workspacesSection: some View {
        Section {
            let joined = workspaces?.workspaces ?? []
            if joined.isEmpty {
                Text("No workspaces joined.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(joined) { workspace in
                HStack(spacing: 10) {
                    Image(systemName: "building.2").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.name)
                        Text(workspace.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Buzz workspaces")
        } footer: {
            Text("Workspace messages are readable by the workspace's operator. Eldr conversations are not.")
                .font(.caption)
        }
    }

    private var aisSection: some View {
        Section("Your AIs") {
            let ais = model.tetheredAIList()
            if ais.isEmpty {
                Text("No AIs tethered yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(ais, id: \.id) { ai in
                HStack(spacing: 10) {
                    Image(systemName: "brain").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ai.name)
                        Text(ai.kind).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ai.enabled == false {
                        Text("off").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The sidebar entry that reaches the World screen — a peer of conversations and
/// workspaces, never mixed into the conversation list.
struct WorldSidebarSection: View {
    var body: some View {
        Section {
            Label("World", systemImage: "globe")
                .tag(WorldRoute.id)
                .accessibilityIdentifier("world-entry")
        }
    }
}
