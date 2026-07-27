// SPDX-License-Identifier: Apache-2.0
import PQRCNostr
import SwiftUI

/// WS-BM3 — join a Buzz workspace from an invite link.
///
/// The whole on-ramp is one paste. `POST /api/invites/claim` is exempt from
/// Buzz's relay-membership gate by design, so a NIP-98 signature from a
/// freshly-minted key is the entire credential — no operator action, no
/// allowlist row, nothing to negotiate.
struct BuzzJoinWorkspaceView: View {
    let workspaces: BuzzWorkspaceModel
    var onJoined: (BuzzWorkspaceRecord) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    @State private var name = ""
    @State private var ageConfirmed = false
    @State private var joining = false
    @State private var error: String?

    private var parsed: BuzzInviteLink? { BuzzInviteLink.parse(linkText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/invite/… or buzz://join?…", text: $linkText, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("buzz-invite-field")
                    if let parsed {
                        LabeledContent("Workspace", value: parsed.relayURL)
                            .font(.footnote)
                    } else if !linkText.isEmpty {
                        Text("That doesn't look like a Buzz invite link.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Invite link")
                } footer: {
                    Text("Paste the invite someone sent you. Nothing is sent until you tap Join.")
                }

                Section {
                    TextField("Name it (optional)", text: $name)
                        .accessibilityIdentifier("buzz-name-field")
                }

                Section {
                    Toggle("I meet this workspace's age requirement", isOn: $ageConfirmed)
                        .accessibilityIdentifier("buzz-age-toggle")
                } footer: {
                    Text("Only needed if the workspace's operator requires it.")
                }

                Section {
                    Label(BuzzWorkspaceModel.disclosure, systemImage: "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Before you join")
                }

                // The privacy property that is easy to miss and impossible to
                // undo later, so it is stated up front rather than buried.
                Section {
                    Label(
                        "Eldr creates a separate identity for each workspace, so joining doesn't link this workspace to your Eldr identity or to any other workspace.",
                        systemImage: "person.badge.shield.checkmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("buzz-join-error")
                    }
                }
            }
            .navigationTitle("Join a workspace")
            #if !os(macOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(joining ? "Joining…" : "Join", action: join)
                        .disabled(parsed == nil || joining)
                        .accessibilityIdentifier("buzz-join-button")
                }
            }
        }
    }

    private func join() {
        guard let link = parsed else { return }
        joining = true
        error = nil
        Task {
            do {
                let record = try await workspaces.join(
                    link: link,
                    name: name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name,
                    ageConfirmed: ageConfirmed)
                joining = false
                onJoined(record)
                dismiss()
            } catch {
                joining = false
                self.error = BuzzWorkspaceModel.describe(error)
            }
        }
    }
}

/// The sidebar section listing joined workspaces and their channels.
struct BuzzWorkspacesSection: View {
    let workspaces: BuzzWorkspaceModel
    @Binding var showJoin: Bool

    var body: some View {
        Section {
            ForEach(workspaces.workspaces) { workspace in
                DisclosureGroup {
                    let channels = workspaces.channels[workspace.id] ?? []
                    if channels.isEmpty {
                        Text(statusText(for: workspace))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(channels) { channel in
                        Label(channel.name, systemImage: channel.isHidden ? "person.2" : "number")
                            .tag(BuzzRoute.selection(workspace: workspace.id, channel: channel.id))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "building.2")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workspace.name)
                            Text(workspace.host)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .task { await workspaces.connect(workspace) }
                .contextMenu {
                    Button(role: .destructive) {
                        workspaces.forget(workspace)
                    } label: {
                        Label("Leave workspace", systemImage: "trash")
                    }
                }
            }
            Button {
                showJoin = true
            } label: {
                Label("Join a workspace…", systemImage: "plus.circle")
            }
            .accessibilityIdentifier("buzz-join-workspace")
        } header: {
            Text("Workspaces")
                .helpInfo(
                    "Buzz workspaces you've joined. Messages in a workspace are readable by whoever runs it — unlike your Eldr chats, they are not end-to-end encrypted. Eldr uses a separate identity in each workspace.")
        }
    }

    private func statusText(for workspace: BuzzWorkspaceRecord) -> String {
        switch workspaces.connectionState(workspace.id) {
        case .connecting: return "Connecting…"
        case .connected: return "No channels you can see yet."
        case .failed(let reason): return reason
        case .idle: return "Not connected."
        }
    }
}

/// Encodes a workspace channel as a sidebar selection value.
///
/// `MainView`'s selection is a plain `String?` conversation id; rather than
/// widen that type (and touch every call site), a workspace channel is carried
/// as a prefixed route. The prefix is one Eldr conversation ids can never
/// collide with — they are identity hex or group ids, never `buzz:`-prefixed.
enum BuzzRoute {
    static let prefix = "buzz:"

    static func selection(workspace: String, channel: String) -> String {
        "\(prefix)\(workspace)/\(channel)"
    }

    /// Decode a selection back into its parts, or nil if it is an ordinary
    /// conversation id.
    static func parse(_ selection: String) -> (workspace: String, channel: String)? {
        guard selection.hasPrefix(prefix) else { return nil }
        let body = selection.dropFirst(prefix.count)
        guard let slash = body.firstIndex(of: "/") else { return nil }
        let workspace = String(body[body.startIndex..<slash])
        let channel = String(body[body.index(after: slash)...])
        guard !workspace.isEmpty, !channel.isEmpty else { return nil }
        return (workspace, channel)
    }
}
