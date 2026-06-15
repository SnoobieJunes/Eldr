import PQRCAgent
import PQRCCore
import SwiftUI

/// Multi-AI configuration (APP-SPEC §9, extended): a person can tether one or
/// more AIs at once — on-device Core AI, a token API, or the Demo stub — name
/// each one, and see exactly what context they receive. Your AIs reply to you
/// by default (in a solo chat); a window or thread invite lets them engage
/// others. Token APIs send decrypted context off-device, gated behind consent.
struct AISettingsView: View {
    @Bindable var model: AppModel
    @Environment(AppSession.self) private var session

    @State private var ais: [ConfiguredAI] = []
    @State private var aiTesting = false
    @State private var aiTestResult: String?
    /// The AI (by id) awaiting remote-consent confirmation.
    @State private var pendingRemote: ConfiguredAI?
    /// Egress firewall: ON by default. Disabling is gated behind a warning.
    @AppStorage("egressFirewallEnabled") private var firewallEnabled = true
    @State private var showFirewallWarning = false

    /// AI config + API keys are scoped to the unlocked silo, so accounts never
    /// share AI setup or credentials.
    private var siloID: String { session.activeSiloID ?? "" }
    private var keychain: KeychainStore { KeychainStore(service: AppSession.siloService(siloID)) }

    var body: some View {
        Form {
            Section {
                ForEach($ais) { $ai in
                    aiRow($ai)
                }
                .onDelete { offsets in
                    ais.remove(atOffsets: offsets)
                    persist()
                }
                Button {
                    ais.append(
                        ConfiguredAI(
                            id: UUID().uuidString,
                            name: FriendlyName.local(seed: UUID().uuidString),
                            kind: "ondevice"))
                    persist()
                } label: {
                    Label("Add an AI", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("add-ai")
            } header: {
                Text("Tethered AIs")
            } footer: {
                Text("Add several to let them share context with each other in a chat or thread. Each gets a local, private name you can edit; names are never broadcast.")
            }

            Section {
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
                        Label("Test primary AI now", systemImage: "stethoscope")
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
            } footer: {
                Text("Runs the first AI against a sample so you see a real reply or the exact failure reason.")
            }

            Section {
                // Custom binding (NOT onChange): flipping OFF just opens the
                // confirmation — it does NOT set the value, so the toggle stays
                // visually ON until the user confirms. The alert is what actually
                // sets it false. (The old onChange re-armed it on every change,
                // so confirming re-triggered the re-arm and it could never turn
                // off — the "can't disable the firewall" bug.)
                Toggle("Egress firewall", isOn: Binding(
                    get: { firewallEnabled },
                    set: { newValue in
                        if newValue {
                            firewallEnabled = true
                            Task { await session.applyAIProvider() }
                        } else {
                            showFirewallWarning = true
                        }
                    }))
                    .accessibilityIdentifier("egress-firewall-toggle")
            } header: {
                Text("Egress firewall")
            } footer: {
                Text("On by default. When on, anything sent to a REMOTE AI is stripped of real names (replaced with your private codenames) and trimmed to a safe size before it leaves your device. On-device AI is never affected. Disabling it is not recommended.")
            }

            Section("What your AI sees") {
                NavigationLink {
                    AIContextView(model: model)
                } label: {
                    Label("View tethered LLM context", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("view-ai-context")
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .task { ais = AppSession.loadConfiguredAIs(siloID: siloID) }
        .alert("Turn off the egress firewall?", isPresented: $showFirewallWarning) {
            Button("Turn off — send raw context", role: .destructive) {
                firewallEnabled = false
                Task { await session.applyAIProvider() }
            }
            Button("Keep it on", role: .cancel) {}
        } message: {
            Text("With the firewall off, a remote AI provider will receive your contacts' real names and your full recent conversation, unredacted and unbounded. On-device AI is unaffected either way. Only do this if you fully trust that provider.")
        }
        .alert("Send conversations to a remote API?", isPresented: showConsent) {
            Button("Enable remote AI", role: .destructive) {
                pendingRemote = nil
                persist()
            }
            Button("Cancel", role: .cancel) {
                // Revert the just-changed AI back to on-device.
                if let pending = pendingRemote,
                    let idx = ais.firstIndex(where: { $0.id == pending.id })
                {
                    ais[idx].kind = "ondevice"
                }
                pendingRemote = nil
                persist()
            }
        } message: {
            Text("Decrypted conversation context will be sent to a remote API for inference. Your signing keys never leave this device, but message content does. This trades privacy for capability.")
        }
    }

    private var showConsent: Binding<Bool> {
        Binding(get: { pendingRemote != nil }, set: { if !$0 { pendingRemote = nil } })
    }

    @ViewBuilder private func aiRow(_ ai: Binding<ConfiguredAI>) -> some View {
        let currentKind = ai.kind.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: ai.name)
                .font(.headline)
                .onSubmit { persist() }
                .accessibilityIdentifier("ai-name")
            Picker("Backend", selection: ai.kind) {
                ForEach(ConfiguredAI.kinds, id: \.tag) { kind in
                    Text(kind.label).tag(kind.tag)
                }
            }
            .onChange(of: ai.kind.wrappedValue) { _, newKind in
                if ConfiguredAI.isRemote(newKind) {
                    pendingRemote = ai.wrappedValue  // gate behind consent
                } else {
                    persist()
                }
            }

            // Self-hosted / custom: an OpenAI-compatible server URL (key optional).
            if ConfiguredAI.needsBaseURL(currentKind) {
                TextField("http://192.168.1.20:11434/v1", text: optionalBinding(ai.baseURL))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-base-url")
                Text("A machine on your network running Ollama or LM Studio (OpenAI-compatible). Same Wi-Fi, no cloud — turn on its network server and use its LAN address.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if ConfiguredAI.supportsModelField(currentKind) {
                TextField(modelPlaceholder(currentKind), text: optionalBinding(ai.model))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-model")
            }

            if ConfiguredAI.isRemote(currentKind),
                let account = ConfiguredAI.keyAccount(for: currentKind)
            {
                SecureField(
                    ConfiguredAI.keyOptional(currentKind) ? "API key (optional)" : "API key",
                    text: keyBinding(account: account))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("api-key-field")
                Text("Stored in the device Keychain, never synced or exported.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            DisclosureGroup("Context & behavior") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instructions (custom persona)")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField(
                            "e.g. You're my terse scheduling assistant; never speculate.",
                            text: optionalBinding(ai.instructions), axis: .vertical)
                            .lineLimit(1...4)
                            .accessibilityIdentifier("ai-instructions")
                    }
                    Picker("Gathers", selection: policyBinding(ai)) {
                        ForEach(ConfiguredAI.policies, id: \.tag) { Text($0.label).tag($0.tag) }
                    }
                    .accessibilityIdentifier("ai-policy")
                    Picker("Does", selection: outputBinding(ai)) {
                        ForEach(ConfiguredAI.outputModes, id: \.tag) { Text($0.label).tag($0.tag) }
                    }
                    .accessibilityIdentifier("ai-output")
                    Stepper(
                        "Context depth: \(ai.wrappedValue.effectiveDepth) messages",
                        value: depthBinding(ai), in: 1...100)
                        .accessibilityIdentifier("ai-depth")
                }
                .padding(.vertical, 2)
            }

            Text(statusLine(for: ai.wrappedValue))
                .font(.caption2)
                .foregroundStyle(statusOK(for: ai.wrappedValue) ? .green : .orange)
        }
        .padding(.vertical, 2)
    }

    private func modelPlaceholder(_ kind: String) -> String {
        switch kind {
        case "groq": return "Model (default: llama-3.1-8b-instant)"
        case "openrouter": return "Model (default: openai/gpt-4o-mini)"
        case "custom": return "Model (e.g. llama3.2 — needed for Ollama)"
        default: return "Model"
        }
    }

    private func optionalBinding(_ source: Binding<String?>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0; persist() })
    }
    private func policyBinding(_ ai: Binding<ConfiguredAI>) -> Binding<String> {
        Binding(
            get: { ai.wrappedValue.effectivePolicy },
            set: { ai.wrappedValue.contextPolicy = $0; persist() })
    }
    private func outputBinding(_ ai: Binding<ConfiguredAI>) -> Binding<String> {
        Binding(
            get: { ai.wrappedValue.effectiveOutputMode },
            set: { ai.wrappedValue.outputMode = $0; persist() })
    }
    private func depthBinding(_ ai: Binding<ConfiguredAI>) -> Binding<Int> {
        Binding(
            get: { ai.wrappedValue.effectiveDepth },
            set: { ai.wrappedValue.contextDepth = $0; persist() })
    }

    /// What this AI will actually use, surfacing the Demo fallback.
    private func statusLine(for ai: ConfiguredAI) -> String {
        if ai.kind == "custom" {
            let base = (ai.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty
                ? "Add a server URL to use this self-hosted AI (Demo stub until then)."
                : "Active: self-hosted at \(base)"
        }
        if ConfiguredAI.isRemote(ai.kind) {
            return hasKey(for: ai.kind)
                ? "Active: \(ConfiguredAI.label(for: ai.kind))"
                : "No API key yet — replies use the Demo stub until you add one."
        }
        if ai.kind == "demo" {
            return "Demo — simulated replies that echo the conversation, no real AI."
        }
        if let reason = FoundationModelsAgentProvider.availabilityReason {
            return "\(reason) Until then replies use the Demo stub."
        }
        return "Active: on-device Core AI."
    }

    private func statusOK(for ai: ConfiguredAI) -> Bool {
        if ai.kind == "custom" {
            return !(ai.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if ConfiguredAI.isRemote(ai.kind) { return hasKey(for: ai.kind) }
        if ai.kind == "demo" { return false }
        return FoundationModelsAgentProvider.availabilityReason == nil
    }

    private func hasKey(for kind: String) -> Bool {
        guard let account = ConfiguredAI.keyAccount(for: kind) else { return false }
        return !loadKey(account).isEmpty
    }

    private func keyBinding(account: String) -> Binding<String> {
        Binding(
            get: { loadKey(account) },
            set: { saveKey(account: account, value: $0) })
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

    /// Persist the configured AIs and re-resolve the live providers.
    private func persist() {
        AppSession.saveConfiguredAIs(ais, siloID: siloID)
        Task { await session.applyAIProvider() }
    }
}

/// Read-only view of the exact context the tethered LLM(s) receive — so the
/// user can see what their AI sees (transparency; SPEC §0). Nothing here is
/// editable or sent anywhere.
struct AIContextView: View {
    @Bindable var model: AppModel

    @State private var aiNames: [String] = []
    @State private var selectedConversation: String?
    @State private var lines: [ContextPreviewLine] = []

    var body: some View {
        List {
            Section("Tethered AIs") {
                if aiNames.isEmpty {
                    Text("None configured.").foregroundStyle(.secondary)
                }
                ForEach(aiNames, id: \.self) { name in
                    Label(name, systemImage: "sparkles")
                }
            }

            Section("Conversation") {
                if model.conversations.isEmpty {
                    Text("Start a conversation to see its context.")
                        .foregroundStyle(.secondary)
                }
                Picker("Conversation", selection: $selectedConversation) {
                    ForEach(model.conversations) { conversation in
                        Text(conversation.title).tag(Optional(conversation.id))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedConversation) { _, _ in Task { await reload() } }
            }

            Section {
                if lines.isEmpty {
                    Text("No context yet — the AI sees nothing for this conversation.")
                        .foregroundStyle(.secondary)
                }
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(line.role)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if line.shared {
                                Text("shared context")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }
                        }
                        Text(line.text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            } header: {
                Text("What the AI receives")
            } footer: {
                Text("By default your AI only sees messages you long-press and \"Add to AI Context\" — not the whole chat. It sees the full recent conversation only while it's active (an AI window/invite is on, or it's your solo AI chat). A peer's marked messages appear only when you've both turned on context sharing.")
            }
        }
        .navigationTitle("AI Context")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            aiNames = await model.tetheredAINames()
            if selectedConversation == nil { selectedConversation = model.conversations.first?.id }
            await reload()
        }
    }

    private func reload() async {
        guard let id = selectedConversation else { lines = []; return }
        lines = await model.contextPreview(conversationID: id)
    }
}
