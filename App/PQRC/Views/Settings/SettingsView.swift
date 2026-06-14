import CoreImage.CIFilterBuiltins
import PQRCAgent
import PQRCCore
import PQRCNostr
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
    @State private var openaiKey = ""
    @State private var geminiKey = ""
    @State private var openInboxUntil: Int64?
    @State private var aiTesting = false
    @State private var aiTestResult: String?
    @State private var checkingRelays = false
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
                // Migrate the pre-multi-provider tags so the picker selection
                // still resolves ("remote" → Claude, "mock" → Demo).
                if aiProvider == "remote" { aiProvider = "claude" }
                if aiProvider == "mock" { aiProvider = "demo" }
                anthropicKey = loadKey("anthropic-api-key")
                openaiKey = loadKey("openai-api-key")
                geminiKey = loadKey("gemini-api-key")
                Task { openInboxUntil = await model.runtime.openInboxActiveUntil() }
            }
            // Server status is checked once at app launch and only re-checked
            // when the user taps "Check connection" — re-pinging on every
            // Settings open was getting the client throttled by the relay.
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

    /// Picker options. `remote` providers send decrypted context to a third
    /// party, so selecting one runs the consent gate first.
    private static let aiProviders: [(tag: String, label: String, remote: Bool)] = [
        ("ondevice", "On-device (Core AI)", false),
        ("claude", "Claude (Anthropic API)", true),
        ("openai", "OpenAI API", true),
        ("gemini", "Gemini API", true),
        ("demo", "Demo (simulated)", false),
    ]

    private func isRemoteProvider(_ tag: String) -> Bool {
        Self.aiProviders.first { $0.tag == tag }?.remote ?? false
    }

    /// Keychain account, field placeholder and bound state for the selected
    /// token-based provider's API key (nil for on-device / demo).
    private var remoteKeyConfig: (account: String, placeholder: String, key: Binding<String>)? {
        switch aiProvider {
        case "claude": return ("anthropic-api-key", "Anthropic API key (sk-ant-…)", $anthropicKey)
        case "openai": return ("openai-api-key", "OpenAI API key (sk-…)", $openaiKey)
        case "gemini": return ("gemini-api-key", "Gemini API key (AIza…)", $geminiKey)
        default: return nil
        }
    }

    private var aiSection: some View {
        Section("AI") {
            Picker("Provider", selection: $aiProvider) {
                ForEach(Self.aiProviders, id: \.tag) { provider in
                    Text(provider.label).tag(provider.tag)
                }
            }
            .onChange(of: aiProvider) { _, newValue in
                // Token APIs send conversation content off-device: gate behind
                // explicit consent. Local options apply immediately.
                if isRemoteProvider(newValue) {
                    showRemoteConsent = true
                } else {
                    Task { await session.applyAIProvider() }
                }
            }
            // Make the Demo fallback visible: if the chosen provider isn't
            // actually usable, replies come from the simulated Demo provider
            // that only echoes context. This row says which brain is live.
            Label(activeProviderStatus.text,
                systemImage: activeProviderStatus.ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(activeProviderStatus.ok ? .green : .orange)
                .accessibilityIdentifier("ai-provider-status")
            if let config = remoteKeyConfig {
                SecureField(config.placeholder, text: config.key)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("api-key-field")
                    // Persist on every change, not just on Return — typing or
                    // pasting and tapping away must still save the key (and
                    // re-resolve the provider), or it silently stays on Demo.
                    .onChange(of: config.key.wrappedValue) { _, newValue in
                        saveKey(account: config.account, value: newValue)
                    }
                    .onSubmit { saveKey(account: config.account, value: config.key.wrappedValue) }
                Text("Stored in the device Keychain, never synced or exported. Drafts show an error here if the key is rejected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                aiTesting = true
                aiTestResult = nil
                Task {
                    let result = await model.testAI()
                    aiTestResult = result
                    aiTesting = false
                }
            } label: {
                HStack {
                    Label("Test AI now", systemImage: "stethoscope")
                    if aiTesting { Spacer(); ProgressView() }
                }
            }
            .disabled(aiTesting)
            .accessibilityIdentifier("test-ai-button")
            if let aiTestResult {
                Text(aiTestResult)
                    .font(.caption)
                    .foregroundStyle(aiTestResult.hasPrefix("⚠️") ? .orange : .primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("test-ai-result")
            }
            Text("Outside an active window or thread invite, your AI only drafts privately for you. It never sends on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// What the AI engine will *actually* use — exposes the Demo fallback
    /// (simulated replies that only echo the chat, no real inference).
    private var activeProviderStatus: (text: String, ok: Bool) {
        if let config = remoteKeyConfig {
            let name = Self.aiProviders.first { $0.tag == aiProvider }?.label ?? "Remote API"
            let hasKey = !config.key.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasKey
                ? ("Active: \(name) — reads your conversation and replies.", true)
                : ("No API key yet — replies use the simulated Demo provider until you add one.", false)
        }
        switch aiProvider {
        case "demo":
            return ("Demo provider — simulated replies that echo the conversation, no real AI.", false)
        default:
            if let reason = FoundationModelsAgentProvider.availabilityReason {
                // Surface the SPECIFIC reason (not enabled / downloading / not
                // eligible) so the user can fix it, instead of a silent stub.
                return ("\(reason) Until then replies use the simulated Demo provider — or pick a token-based API.", false)
            }
            return ("Active: on-device Core AI — reads your conversation.", true)
        }
    }

    private func loadKey(_ account: String) -> String {
        keychain.loadIfPresent(account: account)
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func saveKey(account: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete(account: account)
        } else {
            try? keychain.save(Data(trimmed.utf8), account: account)
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
