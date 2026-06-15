import CoreImage.CIFilterBuiltins
import PQRCCore
import PQRCNostr
import SwiftUI

/// Settings (APP-SPEC §10).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @State private var wipeConfirmStage = 0
    @AppStorage("ephemeralReceivingKeys") private var ephemeralKeys = false
    @AppStorage("localLinkEnabled") private var localLinkEnabled = AppSession.localLinkEnabled
    @State private var relayURLs: [String] = AppSession.configuredRelayURLs
    @State private var newRelayURL = ""
    @State private var relayError: String?
    @State private var needsReconnect = false
    @State private var myAlias = ""
    @State private var openInboxUntil: Int64?
    @State private var checkingRelays = false
    @State private var republishingPrekeys = false
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
                myAlias = UserDefaults.standard.string(forKey: "displayName") ?? ""
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
        UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: "displayName")
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
                LabeledContent(url == "local" ? "Built-in local relay" : url) {
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
            Text("Messages are gift-wrapped: servers see only that an encrypted envelope exists for a recipient — never the sender or content. Enter `local` for the built-in offline relay.")
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

    private func addRelay() {
        let trimmed = newRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLocal = trimmed == "local"
        let url = URL(string: trimmed)
        guard isLocal || (url != nil && (url?.scheme == "ws" || url?.scheme == "wss")) else {
            relayError = "Server URLs must start with wss:// (or ws:// for local testing)."
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
        UserDefaults.standard.set(relayURLs, forKey: "relayURLs")
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
                        relayURLs: AppSession.configuredRelayURLs)
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

    private var accountSection: some View {
        Section {
            Toggle("Unlock with Face ID / Touch ID", isOn: Binding(
                get: { session.hasBiometricUnlock },
                set: { on in
                    if on { session.enableBiometricUnlock() } else { session.disableBiometricUnlock() }
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
