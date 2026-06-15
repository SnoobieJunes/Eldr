import CoreImage.CIFilterBuiltins
import PQRCCore
import PQRCNostr
import SwiftUI
import UIKit

/// Settings (APP-SPEC §10).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    /// Relaunch the first-run "explore a new planet" tour (provided by RootView).
    @Environment(TourCoordinator.self) private var tour
    @State private var wipeConfirmStage = 0
    @AppStorage("ephemeralReceivingKeys") private var ephemeralKeys = false
    @AppStorage("localLinkEnabled") private var localLinkEnabled = AppSession.localLinkEnabled
    @State private var relayURLs: [String] = []
    @State private var newRelayURL = ""
    @State private var relayError: String?
    @State private var needsReconnect = false
    @State private var myAlias = ""
    @State private var openInboxUntil: Int64?
    @State private var checkingRelays = false
    @State private var republishingPrekeys = false
    /// Mirrors `session.hasBiometricUnlock` (a Keychain read, which @Observable
    /// can't track) so the Face ID toggle actually re-renders when flipped.
    @State private var biometricOn = false
    /// Local agent access (in-process MCP server) toggle state. Mirrors the live
    /// server, OFF by default; flipping it starts/stops the loopback server.
    @State private var localMCPOn = false
    @State private var now = Int64(Date().timeIntervalSince1970)

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                contactsSection
                serversSection
                nearbySection
                reachabilitySection
                aiSection
                prekeysSection
                privacySection
                localAgentSection
                accountSection
                dataSection
                aboutSection
                #if DEBUG
                    Section("Demo") {
                        Button("Try the demo (Local Universe)") {
                            Task { await session.bootUniverse(runScript: true) }
                        }
                        .accessibilityIdentifier("try-demo")
                    }
                #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                relayURLs = AppSession.configuredRelayURLs(siloID: model.siloID)
                myAlias =
                    UserDefaults.standard.string(forKey: AppSession.displayNameKey(model.siloID)) ?? ""
                biometricOn = session.hasBiometricUnlock
                localMCPOn = session.isLocalMCPRunning
                Task {
                    openInboxUntil = await model.runtime.openInboxActiveUntil()
                    // Refresh the live prekey count so the Prekeys section isn't
                    // showing a stale number from launch.
                    model.prekeyCount = await model.runtime.oneTimePrekeyCount()
                }
            }
            // Server status is checked once at app launch and only re-checked
            // when the user taps "Check connection" — re-pinging on every
            // Settings open was getting the client throttled by the relay.
            .onReceive(ticker) { _ in
                now = Int64(Date().timeIntervalSince1970)
            }
        }
    }

    // MARK: Identity

    private var identitySection: some View {
        Section("Identity") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.myNpub)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("my-npub")
                // The QR is a pqrc: deep link, so scanning it with the system
                // Camera opens THIS app on New Conversation — not a browser.
                QRView(content: "pqrc:add?npub=\(model.myNpub)")
                    .frame(width: 160, height: 160)
                    .accessibilityLabel("QR code of your address")
                ShareLink(item: "pqrc:add?npub=\(model.myNpub)") {
                    Label("Share my address", systemImage: "square.and.arrow.up")
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Alias shown to your contacts", text: $myAlias)
                    .accessibilityIdentifier("my-alias")
                    .onSubmit { saveAlias() }
                Text("Sent only over your encrypted conversations — people you haven't connected with never see it. If you've turned on a remote AI, your alias is also included in prompts sent to that provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Key export", value: "Not possible — by design")
                .foregroundStyle(.secondary)
        }
    }

    private func saveAlias() {
        let trimmed = myAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        // Per-silo, matching the key `bootSilo` reads — a flat `displayName` write
        // was both dead (never read at boot) and a cross-account leak (A33).
        UserDefaults.standard.set(
            trimmed.isEmpty ? nil : trimmed, forKey: AppSession.displayNameKey(model.siloID))
        Task { await model.setMyAlias(trimmed.isEmpty ? nil : trimmed) }
    }

    private var contactsSection: some View {
        Section {
            NavigationLink {
                ContactsView(model: model)
            } label: {
                Label("Contacts", systemImage: "person.crop.circle")
            }
            .accessibilityIdentifier("contacts-link")
        }
    }

    // MARK: Servers

    private var serversSection: some View {
        Section {
            ForEach(relayURLs, id: \.self) { url in
                LabeledContent(relayDisplayName(url)) {
                    relayIndicator(for: url)
                }
                .font(.callout)
            }
            .onDelete { offsets in
                relayURLs.remove(atOffsets: offsets)
                saveRelays()
            }
            LabeledContent("My keys on relay") { keyPublishIndicator }
                .font(.callout)
                .accessibilityIdentifier("key-publish-status")
            HStack {
                TextField("wss://your.relay.example", text: $newRelayURL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .accessibilityIdentifier("add-relay-field")
                Button {
                    addRelay()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .disabled(newRelayURL.isEmpty)
                .accessibilityLabel("Add server")
                .accessibilityIdentifier("add-relay-button")
            }
            if let relayError {
                Text(relayError).font(.caption).foregroundStyle(.red)
            }
            Button {
                checkingRelays = true
                Task {
                    await model.checkRelaysNow()
                    checkingRelays = false
                }
            } label: {
                HStack {
                    Label("Check connection", systemImage: "antenna.radiowaves.left.and.right")
                    if checkingRelays { Spacer(); ProgressView() }
                }
            }
            .disabled(checkingRelays)
            .accessibilityIdentifier("check-relays-button")
            if relayURLs != [AppSession.defaultRelayURL] {
                Button("Reset to default server") {
                    relayURLs = [AppSession.defaultRelayURL]
                    saveRelays()
                }
            }
            if needsReconnect {
                Button {
                    needsReconnect = false
                    dismiss()
                    Task { await session.rebootSingle() }
                } label: {
                    Label("Apply & reconnect", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("apply-relays")
            }
        } header: {
            Text("Servers")
        } footer: {
            Text("Messages are gift-wrapped: servers see only that an encrypted envelope exists for a recipient — never the sender or content. Keywords instead of a URL: `local` (built-in, offline), `host` (turn THIS device into the relay for nearby companions over Wi-Fi/Bluetooth — no router, great for a train or airport), `nearby` (join a device that's hosting).")
        }
    }

    /// Whether peers can fetch my keys: a successful publish is also the
    /// relay-liveness proof. We never re-publish just to refresh this (that
    /// would be an online-presence beacon — SPEC §0); it updates on launch,
    /// relay change, and prekey replenishment.
    @ViewBuilder private var keyPublishIndicator: some View {
        switch model.keyPublish {
        case .pending:
            HStack(spacing: 6) {
                ProgressView()
                Text("Publishing…").foregroundStyle(.secondary)
            }
        case .published:
            Label("Published", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed:
            Label("Not published", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .labelStyle(.titleAndIcon)
        }
    }

    /// Live connection indicator per relay (Feature 5): green check / red x /
    /// spinner. Status comes from the transports via `AppModel.relayStatuses`.
    @ViewBuilder private func relayIndicator(for url: String) -> some View {
        switch relayStatus(for: url) {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Connected")
        case .failed(let reason):
            HStack(spacing: 4) {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
            .accessibilityLabel("Disconnected: \(reason)")
        case .connecting, .none:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Connecting")
        case .disconnected:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not connected")
        }
    }

    private func relayStatus(for url: String) -> RelayStatus? {
        func norm(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return model.relayStatuses.first { norm($0.url) == norm(url) }?.status
    }

    /// Friendly label for a relay entry, including the offline + Multipeer modes.
    private func relayDisplayName(_ url: String) -> String {
        switch url {
        case "local": return "Built-in local relay (offline)"
        case "host": return "Host a nearby relay · Multipeer"
        case "nearby": return "Join a nearby relay · Multipeer"
        default: return url
        }
    }

    private func addRelay() {
        let trimmed = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords: Set<String> = ["local", "host", "nearby"]
        let url = URL(string: trimmed)
        guard keywords.contains(trimmed)
            || (url != nil && (url?.scheme == "ws" || url?.scheme == "wss"))
        else {
            relayError = "Enter wss://… for a server, or a keyword: local (offline), host (relay for nearby devices), nearby (join one)."
            return
        }
        relayError = nil
        guard !relayURLs.contains(trimmed) else {
            newRelayURL = ""
            return
        }
        relayURLs.append(trimmed)
        newRelayURL = ""
        saveRelays()
    }

    private func saveRelays() {
        AppSession.setRelayURLs(relayURLs, siloID: model.siloID)
        needsReconnect = true
    }

    // MARK: Nearby (S1 Multipeer)

    private var nearbySection: some View {
        Section {
            Toggle(isOn: $localLinkEnabled) {
                Label("Nearby delivery", systemImage: "wave.3.right.circle")
            }
            .accessibilityIdentifier("nearby-toggle")
            .onChange(of: localLinkEnabled) {
                needsReconnect = true
            }
        } header: {
            Text("Nearby")
        } footer: {
            Text("Delivers messages directly to contacts in the same room over Wi-Fi/Bluetooth — no server involved, works offline. Pairing stays automatic for verified contacts; strangers nearby can never read or join anything.")
        }
    }

    // MARK: Reachability (open inbox)

    private var reachabilitySection: some View {
        Section {
            if let until = openInboxUntil, until > now {
                Label(
                    "Open to anyone · \(formatRemaining(until - now)) left",
                    systemImage: "envelope.open")
                .foregroundStyle(.orange)
                Button("Close inbox now") {
                    openInboxUntil = nil
                    Task { await model.runtime.setOpenInbox(until: nil) }
                }
            } else {
                Menu {
                    ForEach([15, 60, 480], id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) minutes" : "\(minutes / 60) hours") {
                            let until = now + Int64(minutes * 60)
                            openInboxUntil = until
                            Task { await model.runtime.setOpenInbox(until: until) }
                        }
                    }
                } label: {
                    Label("Receive from anyone…", systemImage: "envelope.open")
                }
                .accessibilityIdentifier("open-inbox-menu")
            }
        } header: {
            Text("Reachability")
        } footer: {
            Text("Normally, first messages from strangers wait in Message Requests. While the inbox is open, anyone who has your address connects instantly — useful when meeting new people. Closes automatically.")
        }
    }

    private func formatRemaining(_ seconds: Int64) -> String {
        seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: AI

    private var aiSection: some View {
        Section("AI") {
            NavigationLink {
                AISettingsView(model: model)
            } label: {
                Label("AI providers & context", systemImage: "brain")
            }
            .accessibilityIdentifier("ai-settings-link")
            Text("Configure one or more AIs (on-device or API), name them, and see exactly what context they receive. Your AIs reply to you by default; a window or thread invite lets them engage others.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Prekeys / privacy / data / about

    private var prekeysSection: some View {
        Section {
            LabeledContent("Unused one-time prekeys") {
                Text("\(model.prekeyCount)")
                    .foregroundStyle(model.prekeyCount == 0 ? .orange : .primary)
                    .monospacedDigit()
                    .accessibilityIdentifier("prekey-count")
            }
            LabeledContent("Bundle on relay") { keyPublishIndicator }
                .font(.callout)
            Button {
                republishingPrekeys = true
                Task {
                    try? await model.runtime.republishBundle(
                        relayURLs: AppSession.configuredRelayURLs(siloID: model.siloID))
                    model.prekeyCount = await model.runtime.oneTimePrekeyCount()
                    republishingPrekeys = false
                }
            } label: {
                HStack {
                    Label("Replenish & republish bundle", systemImage: "arrow.clockwise")
                    if republishingPrekeys { Spacer(); ProgressView() }
                }
            }
            .disabled(republishingPrekeys)
            .accessibilityIdentifier("republish-prekeys")
        } header: {
            Text("Prekeys")
        } footer: {
            Text("One-time prekeys let new contacts open an encrypted conversation with you even while you're offline — each first handshake uses one up. They refill automatically (back up to 10 whenever they drop to 3 or fewer), so a low number is normal and not a problem. If they ever hit 0, peers fall back to your reusable key — still encrypted, just slightly more linkable. Republish after changing relays so peers can fetch a fresh bundle right away.")
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            Toggle("Ephemeral receiving keys", isOn: $ephemeralKeys)
                .disabled(true)
            Text("Experimental — hides your address from relay observers per conversation. Off in this build; see THREAT_MODEL.md.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Local agent access (in-process MCP server, A35 Phase 2)

    private var localAgentSection: some View {
        Section {
            Toggle("Local agent access (MCP)", isOn: Binding(
                get: { localMCPOn },
                set: { on in
                    localMCPOn = on
                    Task {
                        if on { await session.startLocalMCP() } else { await session.stopLocalMCP() }
                        // Snap back if the server refused to bind.
                        localMCPOn = session.isLocalMCPRunning
                    }
                }))
                .accessibilityIdentifier("local-mcp-toggle")
            if let error = session.localMCPError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("local-mcp-error")
            }
            if localMCPOn, let connection = session.localMCPConnection {
                localMCPInstructions(connection)
            }
        } header: {
            Text("Local agent access")
        } footer: {
            Text("OFF by default. When ON, a local AI agent on THIS machine (Goose, Xcode, Claude, …) can READ your conversations through a loopback-only connection — sender names are local codenames, message text is firewall-redacted and size-capped, and there is NO way for it to send or post anything. Nothing is ever exposed off this device, and the connection needs the one-time pairing token below. Turning this off, or locking, stops it immediately. Only enable it if you want a local agent to see your redacted chat.")
        }
    }

    /// The exact shim command + token + env a user pastes into their MCP client.
    @ViewBuilder
    private func localMCPInstructions(_ connection: LocalMCPConnection) -> some View {
        let block = """
            command: pqrc-mcp-bridge
            env:
              PQRC_MCP_SOCKET=\(connection.socketPath)
              PQRC_MCP_TOKEN=\(connection.token)
            """
        VStack(alignment: .leading, spacing: 6) {
            Text("Point your MCP client at the bridge shim with this env:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(block)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("local-mcp-config")
            Button {
                UIPasteboard.general.string = block
            } label: {
                Label("Copy configuration", systemImage: "doc.on.doc")
            }
            .font(.caption)
            .accessibilityIdentifier("local-mcp-copy")
            Text("`pqrc-mcp-bridge` is built from Packages/PQRCMCP (`swift build`). The socket lives in this app's container and changes each time you turn this on.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSection: some View {
        Section {
            Toggle("Unlock with Face ID / Touch ID", isOn: Binding(
                get: { biometricOn },
                set: { on in
                    if on { session.enableBiometricUnlock() } else { session.disableBiometricUnlock() }
                    // Re-sync from the Keychain: an enable that failed (no device
                    // passcode set) snaps back off and surfaces biometricError.
                    biometricOn = session.hasBiometricUnlock
                }))
                .accessibilityIdentifier("biometric-toggle")
            if let error = session.biometricError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("biometric-error")
            }
            Button {
                dismiss()
                Task { await session.lockSilo() }
            } label: {
                Label("Lock & switch account", systemImage: "lock.rotation")
            }
            .accessibilityIdentifier("lock-switch-account")
        } header: {
            Text("Account")
        } footer: {
            Text("On by default: this account unlocks with Face ID / Touch ID, so you don't type the passphrase every time (it auto-prompts at launch). Turn it OFF for high-security mode — then only your passphrase opens this account. The saved key never syncs or leaves this device, and only this primary account is stored (hidden accounts stay passphrase-only either way). If you lose the passphrase there is no recovery. Lock & switch returns to the passphrase screen, where a different passphrase opens (or creates) a fully separate account.")
        }
    }

    private var dataSection: some View {
        Section("Data") {
            Button(wipeConfirmStage == 0
                    ? "Wipe identity and all data"
                    : "Tap again to permanently destroy everything", role: .destructive) {
                if wipeConfirmStage == 0 {
                    wipeConfirmStage = 1
                } else {
                    Task {
                        try? await model.runtime.wipeIdentity()
                        session.mode = .locked
                    }
                }
            }
            .accessibilityIdentifier("wipe-identity")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Button {
                // Dismiss Settings first; `relaunch()` defers the full-screen tour
                // until this sheet has finished dismissing, so the cover doesn't
                // collide with the sheet's dismissal (which silently dropped it).
                dismiss()
                tour.relaunch()
            } label: {
                Label("Take the tour", systemImage: "sparkles")
            }
            .accessibilityIdentifier("take-the-tour")
            .accessibilityHint("Replays the guided tour of EldrChat's features and privacy.")
            LabeledContent("Protocol", value: "pqrc-v1")
            LabeledContent("License", value: "AGPL-3.0")
            Text("Honest limits: relays can see your IP address and that someone messaged you. They cannot see who sent it or what it says. Messages are not deniable, and this identity lives only on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct QRView: View {
    let content: String

    var body: some View {
        if let image = Self.qrImage(for: content) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    static func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
