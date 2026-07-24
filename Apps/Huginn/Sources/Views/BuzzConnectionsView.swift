// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PQRCNostr
import SwiftUI
import UniformTypeIdentifiers

// WS-I7 — the **Connections** tab: "my AI can join a chat workspace like a
// teammate. It runs on MY machine, answers when mentioned, and I can pause or
// remove it any time."
//
// Two paths, both here because they answer two different questions:
//  • Path A (top): Huginn owns the agent — it mints its key, attests it, and
//    supervises the `eldr-buzz-agent` child. This is the Eldr product.
//  • Path B (bottom): Buzz owns the agent — we hand Buzz a snapshot manifest so
//    the agent appears in ITS Agents tab, brained by this Mac's model.
struct BuzzConnectionsView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var installer: InstallerService
    @ObservedObject private var service = BuzzGatewayService.shared
    @ObservedObject private var connections = BuzzGatewayService.shared.store

    @State private var wizardShown = false
    @State private var removing: BuzzConnection?
    @State private var busyMessage: String?
    @State private var noticeMessage: String?
    @State private var rotating: BuzzConnection?
    @State private var rotateOwnerKey = ""
    @State private var editing: BuzzConnection?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                BuzzDisclosureBanner()
            }

            Section("Workspace agents") {
                if connections.connections.isEmpty {
                    Text(
                        "No workspace connections yet. “Connect an AI to a workspace” puts the model this Mac is running into a Buzz workspace as an agent that answers when it's @mentioned."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(connections.connections) { connection in
                    BuzzConnectionRow(
                        connection: connection,
                        state: service.state(of: connection.id),
                        counters: service.counters(of: connection.id),
                        onPauseToggle: { togglePause(connection) },
                        onLogs: { openLogs(connection) },
                        onEdit: { editing = connection },
                        onRotate: { rotating = connection; rotateOwnerKey = "" },
                        onRemove: { removing = connection })
                }
                HStack {
                    Button("Connect an AI to a workspace…") { wizardShown = true }
                        .disabled(service.executablePath == nil)
                    if let notice = noticeMessage {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    if let busy = busyMessage {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            gatewayBinarySection
            pathBSection
        }
        .formStyle(.grouped)
        .padding(12)
        .sheet(isPresented: $wizardShown) {
            BuzzConnectWizardView(
                onConnect: { created in
                    let backend = currentBackend()
                    service.start(
                        created, llmURL: backend.url, llmModel: backend.model,
                        llmToken: backend.token)
                },
                connections: connections
            )
            .environmentObject(store)
        }
        .alert(item: $removing) { connection in
            Alert(
                title: Text("Remove \(connection.displayName)?"),
                message: Text(
                    "Huginn will publish a signed retirement to \(connection.relayHost) — so the workspace's own record shows the agent is gone — and then destroy its key on this Mac. This can't be undone; reconnecting mints a new identity."
                ),
                primaryButton: .destructive(Text("Retire and remove")) { remove(connection) },
                secondaryButton: .cancel())
        }
        .sheet(item: $rotating) { connection in
            rotateSheet(connection)
        }
        .sheet(item: $editing) { connection in
            BuzzConnectionEditView(connection: connection, store: connections) { updated, restart in
                connections.update(updated)
                editing = nil
                guard restart else { return }
                let backend = currentBackend()
                service.start(
                    updated, llmURL: backend.url, llmModel: backend.model,
                    llmToken: backend.token)
            } onCancel: {
                editing = nil
            }
        }
        .onAppear {
            connections.reload()
            service.refreshExecutable()
        }
    }

    // MARK: - Gateway binary

    @ViewBuilder private var gatewayBinarySection: some View {
        Section {
            if let path = service.executablePath {
                LabeledContent("eldr-buzz-agent") {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "The gateway binary isn't installed yet — install it to connect a workspace.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Install the gateway") {
                    do {
                        try installer.installBuzzAgent()
                        service.refreshExecutable()
                        noticeMessage = "Gateway installed."
                    } catch {
                        noticeMessage =
                            "Couldn't install the gateway: \(error.localizedDescription). Build Huginn from the workspace so the binary is bundled."
                    }
                }
            }
        } header: {
            Text("Gateway")
        } footer: {
            Text(
                "Each connection runs as its own supervised process on this Mac. It stops when Huginn quits, and its whole conversation with the relay is in the log."
            )
            .font(.caption)
        }
    }

    // MARK: - Path B (Buzz-managed agent)

    @ViewBuilder private var pathBSection: some View {
        Section("Add this model to Buzz's own Agents tab") {
            Text(
                "The other direction: hand Buzz a snapshot and IT manages the agent (start/stop/persona in its Agents tab), using this Mac's model as the brain. Import the file in Buzz Desktop, then Save."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            LabeledContent("Runtime / provider", value: "goose / lmstudio")
            LabeledContent("Model", value: store.llmModel.isEmpty ? "no model configured" : store.llmModel)

            VStack(alignment: .leading, spacing: 4) {
                Text("Buzz can't carry env vars in a snapshot (it treats them as secrets), so set this once in Buzz ▸ agent ▸ Advanced — or in goose's own config:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(providerHints, id: \.0) { key, value in
                    HStack {
                        Text("\(key)=\(value)").font(.caption.monospaced())
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(key)=\(value)", forType: .string)
                        }
                        .font(.caption)
                    }
                }
            }

            Button("Save agent snapshot…") { saveSnapshot() }
                .disabled(store.llmModel.isEmpty)
        }
    }

    /// The endpoint Buzz's goose agent must be pointed at. Falls back to the
    /// default MLX port rather than rendering `LMSTUDIO_HOST=` with nothing after
    /// it when no backend is configured yet.
    private var providerBaseURL: String {
        store.llmURL.isEmpty ? "http://127.0.0.1:1337/v1" : store.llmURL
    }

    private var providerHints: [(String, String)] {
        BuzzAgentSnapshot.LocalProvider.lmstudio
            .environmentHints(baseURL: providerBaseURL)
            .map { ($0.key, $0.value) }
    }

    private func saveSnapshot() {
        let snapshot = BuzzAgentSnapshot.forLocalModel(
            displayName: "Eldr (local model)",
            systemPrompt: BuzzConnection.defaultSystemPrompt,
            providerBaseURL: providerBaseURL,
            model: store.llmModel,
            provider: .lmstudio,
            about: BuzzConnection.defaultAbout)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Eldr.agent.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Save the Buzz agent snapshot, then import it in Buzz Desktop."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try snapshot.encodedJSON().write(to: url)
            noticeMessage = "Snapshot written — import it in Buzz ▸ Agents."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            noticeMessage = "Couldn't write the snapshot: \(error.localizedDescription)"
        }
    }

    // MARK: - Rotate

    @ViewBuilder private func rotateSheet(_ connection: BuzzConnection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rotate \(connection.displayName)'s key").font(.title3.weight(.semibold))
            Text(
                "Mints a brand-new agent key for this workspace and re-attests it, so the old public key can no longer be used to correlate this agent. The old key is destroyed and the gateway restarts."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Owner key (nsec1… or hex) — used once, never stored", text: $rotateOwnerKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { rotating = nil }
                Spacer()
                Button("Rotate") {
                    rotate(connection)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(connection.ownerPubkeyHex != nil && rotateOwnerKey.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private func rotate(_ connection: BuzzConnection) {
        do {
            let updated = try connections.rotateKey(
                id: connection.id, ownerPrivateKey: rotateOwnerKey.isEmpty ? nil : rotateOwnerKey)
            rotateOwnerKey = ""
            rotating = nil
            let backend = currentBackend()
            service.start(
                updated, llmURL: backend.url, llmModel: backend.model, llmToken: backend.token)
            noticeMessage = "Key rotated — the agent rejoined with a new identity."
        } catch {
            noticeMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            rotating = nil
        }
    }

    // MARK: - Row actions

    private func currentBackend() -> (url: String, model: String, token: String) {
        (store.llmURL, store.llmModel, store.llmToken)
    }

    private func togglePause(_ connection: BuzzConnection) {
        let backend = currentBackend()
        service.setPaused(
            !connection.paused, id: connection.id, llmURL: backend.url, llmModel: backend.model,
            llmToken: backend.token)
    }

    private func openLogs(_ connection: BuzzConnection) {
        openWindow(
            id: LogConsoleView.windowID,
            value: LogConsoleSource.buzzGateway(
                connectionID: connection.id, name: connection.displayName))
    }

    /// Remove = publish the agent-signed retirement, then destroy the key.
    private func remove(_ connection: BuzzConnection) {
        service.stop(id: connection.id)
        busyMessage = "Retiring \(connection.displayName)…"
        let keypair = connections.agentKeypair(id: connection.id)
        Task {
            var outcome = "Key destroyed on this Mac."
            if let keypair {
                outcome = await BuzzRevoker().retire(
                    connection: connection, keypair: keypair,
                    reason:
                        "This Eldr-hosted agent was disconnected by its owner. Its key is destroyed; any later message signed by it is not from this owner."
                )
            }
            connections.remove(id: connection.id)
            busyMessage = nil
            noticeMessage = outcome
        }
    }
}

/// One connection's live status row: the light, who it is, where it is, what it
/// has done, and the four controls (plan §2 "Running state").
private struct BuzzConnectionRow: View {
    let connection: BuzzConnection
    let state: BuzzGatewayService.State
    let counters: BuzzGatewayCounters
    let onPauseToggle: () -> Void
    let onLogs: () -> Void
    let onEdit: () -> Void
    let onRotate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(lightColor)
                    .frame(width: 8, height: 8)
                Text(connection.displayName).font(.callout.weight(.medium))
                Text("· \(connection.relayHost)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if case .failed(let why) = state {
                Text(why).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let failure = counters.lastFailure {
                Text(failure).font(.caption2).foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Text(connection.agentPubkeyHex.isEmpty ? "" : "npub-key \(String(connection.agentPubkeyHex.prefix(12)))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(connection.paused ? "Resume" : "Pause", action: onPauseToggle)
                    .font(.caption)
                Button("View logs", action: onLogs).font(.caption)
                Button("Edit", action: onEdit).font(.caption)
                Button("Rotate key", action: onRotate).font(.caption)
                Button("Remove", role: .destructive, action: onRemove).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var lightColor: Color {
        if connection.paused { return .secondary }
        switch state {
        case .connected: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    /// Honest one-liner: what the agent has actually done, from its own status
    /// lines — never an optimistic "connected" the process can't back up.
    private var summary: String {
        if connection.paused { return "paused" }
        switch state {
        case .stopped: return "stopped"
        case .starting: return "connecting…"
        case .failed: return "failed"
        case .connected:
            let replies = counters.replies == 1 ? "1 reply" : "\(counters.replies) replies"
            let tokens =
                counters.tokens >= 1000
                ? String(format: "%.1fk tokens", Double(counters.tokens) / 1000)
                : "\(counters.tokens) tokens"
            return "\(replies) · \(tokens)"
        }
    }
}

/// Edit an existing connection's persona, channels, and behavior — the plan's
/// "Edit persona" control. The relay and the agent's identity are deliberately
/// NOT editable here: changing either means a different agent in a different
/// workspace, which is a new connection (and a new attested key), not an edit.
private struct BuzzConnectionEditView: View {
    @State private var draft: BuzzConnection
    /// The values that only take effect on the next launch of the child.
    private let original: BuzzConnection
    private let store: BuzzConnectionStore
    let onSave: (BuzzConnection, Bool) -> Void
    let onCancel: () -> Void

    @State private var pastedAuthTag = ""
    @State private var attestationNote: String?

    init(
        connection: BuzzConnection, store: BuzzConnectionStore,
        onSave: @escaping (BuzzConnection, Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: connection)
        original = connection
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
    }

    /// Everything below is read by the gateway at LAUNCH, so a save that touches
    /// any of it needs a restart to take effect — say so rather than letting the
    /// UI and the running agent disagree.
    private var needsRestart: Bool {
        draft.displayName != original.displayName || draft.about != original.about
            || draft.pictureURL != original.pictureURL
            || draft.systemPrompt != original.systemPrompt
            || draft.channelIds != original.channelIds
            || draft.respondToMentionsOnly != original.respondToMentionsOnly
            || draft.redactOutbound != original.redactOutbound || draft.model != original.model
            || draft.providerURL != original.providerURL
    }

    @State private var channelsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit \(original.displayName)").font(.title3.weight(.semibold)).padding(12)
            Divider()
            Form {
                Section {
                    LabeledContent("Workspace", value: original.relayURL)
                    LabeledContent(
                        "Agent key", value: String(original.agentPubkeyHex.prefix(16)) + "…")
                } footer: {
                    Text(
                        "The workspace and the agent's key aren't editable: a different workspace means a different attested identity, which is a new connection."
                    )
                    .font(.caption)
                }
                Section("Identity") {
                    TextField("Display name", text: $draft.displayName)
                    TextField("About", text: $draft.about, axis: .vertical).lineLimit(2...4)
                    TextField("Avatar image URL", text: $draft.pictureURL)
                        .font(.caption.monospaced())
                }
                Section("Channels") {
                    TextField("Channel ids, comma-separated", text: $channelsText, axis: .vertical)
                        .font(.caption.monospaced())
                        .lineLimit(2...5)
                        .onChange(of: channelsText) { _, new in
                            draft.channelIds = BuzzConnectionStore.parseChannelList(new)
                        }
                }
                Section("Behavior") {
                    Toggle("Only answer when @mentioned", isOn: $draft.respondToMentionsOnly)
                    Toggle("Redact secrets from anything it posts", isOn: $draft.redactOutbound)
                    TextField("Persona / system prompt", text: $draft.systemPrompt, axis: .vertical)
                        .font(.caption)
                        .lineLimit(4...12)
                }
                Section {
                    if let owner = draft.ownerPubkeyHex, draft.authTagJSON != nil {
                        Label(
                            "Attested by \(String(owner.prefix(16)))… — the workspace's relay can verify this agent belongs to that owner.",
                            systemImage: "checkmark.seal"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    } else {
                        Text(
                            "Not attested. Send your workspace admin this agent's public key; paste the NIP-OA tag they return below."
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                    HStack {
                        Text(original.agentPubkeyHex).font(.caption2.monospaced()).lineLimit(1)
                        Spacer()
                        Button("Copy key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(original.agentPubkeyHex, forType: .string)
                        }
                        .font(.caption)
                    }
                    TextField("Paste the [\"auth\", …] tag", text: $pastedAuthTag, axis: .vertical)
                        .font(.caption.monospaced())
                        .lineLimit(2...4)
                    HStack {
                        Button("Apply attestation") {
                            do {
                                draft = try store.applyAttestation(
                                    pastedAuthTag, id: original.id)
                                pastedAuthTag = ""
                                attestationNote =
                                    "Attestation verified and saved — reconnect for the relay to see it."
                            } catch {
                                attestationNote =
                                    (error as? LocalizedError)?.errorDescription ?? "\(error)"
                            }
                        }
                        .disabled(pastedAuthTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let note = attestationNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Attestation")
                } footer: {
                    Text(
                        "A NIP-OA tag signs ONE specific agent key, so it can only be issued after this connection exists. A tag that doesn't authorize this key is refused here rather than failing silently at the relay."
                    )
                    .font(.caption)
                }
                Section("Brain") {
                    TextField("Model (empty = follow Huginn)", text: $draft.model)
                        .font(.callout.monospaced())
                    TextField("Endpoint (empty = follow Huginn)", text: $draft.providerURL)
                        .font(.callout.monospaced())
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                if needsRestart {
                    Text("Saving restarts the agent so the change takes effect.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Save") { onSave(draft, needsRestart) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                            || draft.channelIds.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { channelsText = original.channelIds.joined(separator: ", ") }
    }
}
