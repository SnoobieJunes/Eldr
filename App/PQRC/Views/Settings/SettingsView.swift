import CoreImage.CIFilterBuiltins
import PQRCCore
import SwiftUI

/// Settings (APP-SPEC §10).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @State private var wipeConfirmStage = 0
    @AppStorage("aiProvider") private var aiProvider = "ondevice"
    @AppStorage("ephemeralReceivingKeys") private var ephemeralKeys = false
    @AppStorage("localLinkEnabled") private var localLinkEnabled = AppSession.localLinkEnabled
    @State private var showRemoteConsent = false
    @State private var relayURLs: [String] = AppSession.configuredRelayURLs
    @State private var newRelayURL = ""
    @State private var relayError: String?
    @State private var needsReconnect = false
    @State private var myAlias = ""
    @State private var anthropicKey = ""
    @State private var openInboxUntil: Int64?
    @State private var now = Int64(Date().timeIntervalSince1970)

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let keychain = KeychainStore(service: "chat.pqrc.keys")

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
                if let keyData = keychain.loadIfPresent(account: "anthropic-api-key") {
                    anthropicKey = String(decoding: keyData, as: UTF8.self)
                }
                Task { openInboxUntil = await model.runtime.openInboxActiveUntil() }
            }
            .onReceive(ticker) { _ in
                now = Int64(Date().timeIntervalSince1970)
            }
            .alert("Send conversations to a remote API?", isPresented: $showRemoteConsent) {
                Button("Enable remote AI", role: .destructive) {
                    Task { await session.applyAIProvider() }
                }
                Button("Cancel", role: .cancel) {
                    aiProvider = "ondevice"
                }
            } message: {
                Text(
                    "Decrypted conversation context will be sent to a remote API for inference. Your signing keys never leave this device, but message content does. This trades privacy for capability."
                )
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
                Text("Sent only over your encrypted conversations — people you haven't connected with never see it.")
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
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.green)
                        .accessibilityLabel("Configured")
                }
                .font(.callout)
            }
            .onDelete { offsets in
                relayURLs.remove(atOffsets: offsets)
                saveRelays()
            }
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
            Picker("Provider", selection: $aiProvider) {
                Text("On-device (FoundationModels)").tag("ondevice")
                Text("Mock (deterministic)").tag("mock")
                Text("Anthropic API (remote)").tag("remote")
            }
            .onChange(of: aiProvider) { _, newValue in
                if newValue == "remote" {
                    showRemoteConsent = true
                } else {
                    Task { await session.applyAIProvider() }
                }
            }
            if aiProvider == "remote" {
                SecureField("Anthropic API key (sk-ant-…)", text: $anthropicKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("anthropic-key-field")
                    // Persist on every change, not just on Return — typing or
                    // pasting and tapping away must still save the key (and
                    // re-resolve the provider), or it silently stays on Mock.
                    .onChange(of: anthropicKey) { _, _ in saveAnthropicKey() }
                    .onSubmit { saveAnthropicKey() }
                Text("Stored in the device Keychain, never synced or exported. Drafts show an error here if the key is rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Outside an active window or thread invite, your AI only drafts privately for you. It never sends on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveAnthropicKey() {
        let trimmed = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: "anthropic-api-key")
        } else {
            try? keychain.save(Data(trimmed.utf8), account: "anthropic-api-key")
        }
        Task { await session.applyAIProvider() }
    }

    // MARK: Prekeys / privacy / data / about

    private var prekeysSection: some View {
        Section("Prekeys") {
            LabeledContent("One-time prekeys", value: "\(model.prekeyCount)")
            Button("Republish bundle") {
                Task {
                    try? await model.runtime.republishBundle(
                        relayURLs: AppSession.configuredRelayURLs)
                    model.prekeyCount = await model.runtime.oneTimePrekeyCount()
                }
            }
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
                        session.mode = .onboarding
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
