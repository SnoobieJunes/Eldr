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
    /// Per-row test state, keyed by ConfiguredAI.id, so each tethered AI can be
    /// tested independently (not just the primary one).
    @State private var rowTesting: Set<String> = []
    @State private var rowTestResult: [String: String] = [:]
    /// The AI (by id) awaiting remote-consent confirmation.
    @State private var pendingRemote: ConfiguredAI?
    /// Egress firewall: ON by default. Disabling is gated behind a warning.
    @AppStorage("egressFirewallEnabled") private var firewallEnabled = true
    @State private var showFirewallWarning = false
    /// The asymmetry knob for shared-thread agent skills (what THIS device brings).
    /// Loaded per-silo in `.task` (can't read `siloID` in a property initializer).
    @State private var contextDomain = ""

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
                    .helpInfo("Bring your own AI into your chats — openly and on your terms. Pick on-device Core AI (nothing leaves your phone), a cloud provider via your own API key, or a model on your own machine. Add several and they can collaborate. No one ever talks to an AI without seeing it.")
            } footer: {
                Text("Add several to let them share context with each other in a chat or thread. Each gets a local, private name you can edit; names are never broadcast. Use each AI's “Test” button to check it against a sample.")
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
                    .helpInfo("Your privacy guard for remote AI. Before anything reaches a cloud provider it swaps every real name for your private codename and trims the context to a safe size. On-device AI never leaves your phone, so it's untouched. On by default — turning it off is not recommended.")
            } footer: {
                Text("On by default. When on, anything sent to a REMOTE AI is stripped of real names (replaced with your private codenames) and trimmed to a safe size before it leaves your device. On-device AI is never affected. Disabling it is not recommended.")
            }

            Section {
                TextField("e.g. iOS / Xcode", text: $contextDomain)
                    .autocorrectionDisabled()
                    .onChange(of: contextDomain) { _, value in
                        AppSession.setAIContextDomain(value, siloID: siloID)
                    }
                    .accessibilityIdentifier("ai-context-domain")
            } header: {
                Text("This workstation's context domain")
            } footer: {
                Text("A short label of what THIS device brings to a shared AI thread (e.g. \"iOS / Xcode\" or \"backend / staging\"). Each person's AI advertises its domain so two of them divide work without dumping full context. Optional — used by the thread Skills feature.")
            }

            Section {
                NavigationLink {
                    AIContextInspectorView(model: model)
                } label: {
                    Label("Context inspector", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("ai-context-inspector")
                NavigationLink {
                    AIContextView(model: model)
                } label: {
                    Label("Quick view (read-only)", systemImage: "eye")
                }
                .accessibilityIdentifier("view-ai-context")
            } header: {
                Text("What your AI sees")
                    .helpInfo("Transparency first, with control. The Context inspector shows EXACTLY what each AI receives for a conversation — its instructions, how much it gathers, and every message — and lets you adjust the depth and include/exclude individual messages, live. The quick view is the same context, read-only. A remote AI always sees your private codenames, never real names.")
            } footer: {
                Text("The inspector's edits map to real, saved controls (per-AI depth and the per-message \"Add to AI Context\" marker) — not a separate copy.")
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ais = AppSession.loadConfiguredAIs(siloID: siloID)
            contextDomain = AppSession.aiContextDomain(siloID: siloID)
        }
        .alert("Turn off the egress firewall?", isPresented: $showFirewallWarning) {
            Button("Turn off — send raw context", role: .destructive) {
                firewallEnabled = false
                Task { await session.applyAIProvider() }
            }
            Button("Keep it on", role: .cancel) {}
        } message: {
            Text("With the firewall off, a remote AI provider will receive your contacts' real names and your full recent conversation, unredacted and unbounded. On-device AI is unaffected either way. Only do this if you fully trust that provider.")
        }
        .alert("Send conversation content off this device?", isPresented: showConsent) {
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
            Text("Decrypted message content is sent off this device for inference — to a cloud provider, or, for the Nearby host's AI, to that nearby device. Your signing keys never leave this device, but your words do (contact names are replaced with codenames while the egress firewall is on). This trades privacy for capability.")
        }
    }

    private var showConsent: Binding<Bool> {
        Binding(get: { pendingRemote != nil }, set: { if !$0 { pendingRemote = nil } })
    }

    @ViewBuilder private func aiRow(_ ai: Binding<ConfiguredAI>) -> some View {
        let currentKind = ai.kind.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: ai.name)
                    .font(.headline)
                    .onSubmit { persist() }
                    .accessibilityIdentifier("ai-name")
                Spacer()
                // Independent on/off — toggle each model without deleting it.
                Toggle("Enabled", isOn: enabledBinding(ai))
                    .labelsHidden()
                    .accessibilityIdentifier("ai-enabled")
            }
            .opacity(ai.wrappedValue.isEnabled ? 1 : 0.6)
            Picker("Backend", selection: ai.kind) {
                ForEach(ConfiguredAI.kinds, id: \.tag) { kind in
                    Text(kind.label).tag(kind.tag)
                }
            }
            .onChange(of: ai.kind.wrappedValue) { _, newKind in
                if ConfiguredAI.requiresConsent(newKind) {
                    pendingRemote = ai.wrappedValue  // gate cloud backends behind consent
                } else {
                    persist()
                }
            }

            // Self-hosted / custom: an OpenAI-compatible server URL (key optional).
            // The field is a normal, editable, clearable TextField bound to the
            // AI's stored baseURL. The placeholder is phrased as an instruction
            // (not a ready-made URL) so a realistic-looking address isn't mistaken
            // for prefilled, locked-in text — the example LAN address lives in the
            // caption below instead.
            if ConfiguredAI.needsBaseURL(currentKind) {
                TextField("Server URL (e.g. http://192.168.1.20:11434/v1)", text: optionalBinding(ai.baseURL))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-base-url")
                Text("A machine on your network running Ollama or LM Studio (OpenAI-compatible). Same Wi-Fi, no cloud — turn on its network server and use its LAN address (e.g. http://192.168.1.20:11434/v1).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if ConfiguredAI.supportsModelField(currentKind) {
                TextField(modelPlaceholder(currentKind), text: optionalBinding(ai.model))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ai-model")
            }

            // Apple Private Cloud Compute: reasoning depth (PCC-only capability).
            if currentKind == "pcc" {
                Picker("Reasoning depth", selection: reasoningBinding(ai)) {
                    ForEach(ConfiguredAI.reasoningLevels, id: \.tag) { Text($0.label).tag($0.tag) }
                }
                .accessibilityIdentifier("ai-reasoning")
                Text("Runs on Apple's Private Cloud Compute — attested and stores no prompts. Deeper reasoning is more thorough but uses more of your daily PCC quota.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if ConfiguredAI.isRemote(currentKind), let account = ai.wrappedValue.apiKeyAccount {
                SecureField(
                    ConfiguredAI.keyOptional(currentKind) ? "API key (optional)" : "API key",
                    text: keyBinding(account: account, legacyKind: currentKind))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("api-key-field")
                Text("Stored in the device Keychain, never synced or exported.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            // Context & behavior — shown EXPANDED by default (was a collapsed
            // DisclosureGroup, so almost nobody found the gather policy / depth).
            // A labeled, always-visible group surfaces these for every AI.
            VStack(alignment: .leading, spacing: 8) {
                Label("Context & behavior", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("ai-context-behavior-header")
                    .helpInfo("Three knobs per AI. Instructions give it a persona. Gathers sets what it can read: the live conversation while it's active, only messages you add to context, or nothing. Does sets whether it participates, drafts for your approval, or just summarizes. Depth is how many recent messages it sees.")
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
            .padding(.top, 4)

            Text(statusLine(for: ai.wrappedValue))
                .font(.caption2)
                .foregroundStyle(statusOK(for: ai.wrappedValue) ? .green : .orange)

            // Per-AI connection test — runs THIS AI against a sample so you see a
            // real reply or its exact failure, independent of the other AIs.
            let aiID = ai.wrappedValue.id
            HStack(spacing: 8) {
                Button {
                    let cfg = ai.wrappedValue
                    rowTesting.insert(cfg.id)
                    rowTestResult[cfg.id] = nil
                    Task {
                        let result = await session.testProvider(for: cfg)
                        rowTestResult[cfg.id] = result
                        rowTesting.remove(cfg.id)
                    }
                } label: {
                    Label("Test", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(rowTesting.contains(aiID))
                .accessibilityIdentifier("test-ai-row")
                if rowTesting.contains(aiID) { ProgressView().controlSize(.small) }
            }
            if let result = rowTestResult[aiID] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("⚠️") ? .orange : .secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("test-ai-row-result")
            }
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
    private func reasoningBinding(_ ai: Binding<ConfiguredAI>) -> Binding<String> {
        Binding(
            get: { ai.wrappedValue.effectiveReasoning },
            set: { ai.wrappedValue.reasoningLevel = $0; persist() })
    }

    /// What this AI will actually use, surfacing the Demo fallback.
    private func statusLine(for ai: ConfiguredAI) -> String {
        if ai.kind == "hub" {
            return AppSession.configuredRelayURLs(siloID: siloID).contains("nearby")
                ? "Uses a nearby host's AI over Multipeer — stay near the host."
                : "Set this device's relay to `nearby` (Settings ▸ Servers) to use a host's shared AI."
        }
        if ai.kind == "custom" {
            let base = (ai.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty
                ? "Add a server URL to use this self-hosted AI (Demo stub until then)."
                : "Active: self-hosted at \(base)"
        }
        if ai.kind == "pcc" {
            if let reason = PCCFoundationModelsProvider.availabilityReason {
                return "\(reason)"
            }
            return "Active: Apple Private Cloud Compute (\(ai.effectiveReasoning) reasoning)."
        }
        if ConfiguredAI.isRemote(ai.kind) {
            return hasKey(for: ai)
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
        if ai.kind == "hub" { return AppSession.configuredRelayURLs(siloID: siloID).contains("nearby") }
        if ai.kind == "custom" {
            return !(ai.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if ai.kind == "pcc" { return PCCFoundationModelsProvider.availabilityReason == nil }
        if ConfiguredAI.isRemote(ai.kind) { return hasKey(for: ai) }
        if ai.kind == "demo" { return false }
        return FoundationModelsAgentProvider.availabilityReason == nil
    }

    private func hasKey(for ai: ConfiguredAI) -> Bool {
        if let account = ai.apiKeyAccount, !loadKey(account).isEmpty { return true }
        // Fall back to a key saved by an older build under the shared account.
        if let legacy = ConfiguredAI.keyAccount(for: ai.kind), !loadKey(legacy).isEmpty { return true }
        return false
    }

    private func enabledBinding(_ ai: Binding<ConfiguredAI>) -> Binding<Bool> {
        Binding(
            get: { ai.wrappedValue.isEnabled },
            set: { ai.wrappedValue.enabled = $0; persist() })
    }

    private func keyBinding(account: String, legacyKind: String) -> Binding<String> {
        Binding(
            get: {
                let perAI = loadKey(account)
                if !perAI.isEmpty { return perAI }
                // Show a key saved by an older build (shared per-provider account)
                // so it's not lost; editing saves it to THIS AI's own account.
                return ConfiguredAI.keyAccount(for: legacyKind).map { loadKey($0) } ?? ""
            },
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
