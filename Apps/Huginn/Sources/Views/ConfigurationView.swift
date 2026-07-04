import SwiftUI

/// The live configuration form. Every control is bound to a `ConfigurationStore`
/// `@Published` property, which debounces a write to the on-disk files the CLI reads.
struct ConfigurationView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var health: LLMHealthChecker
    @StateObject private var connections = ConnectionStatusProbe()
    @State private var acpxRegistered = false
    @State private var sybilclawRegistered = false
    @State private var showTour = false

    var body: some View {
        Form {
            Section {
                Button {
                    showTour = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.title3)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Why Eldr for teams").font(.headline)
                            Text("A 2-minute tour: zero-trust agent collaboration, sovereign self-hosted AI, post-quantum encryption.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("enterprise-tour-launch")
            }

            Section("Local LLM") {
                LabeledContent("Server URL") {
                    TextField("http://127.0.0.1:1337/v1", text: $store.llmURL)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("API token") {
                    SecureField("(usually blank for local servers)", text: $store.llmToken)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Model") {
                    TextField("local-model", text: $store.llmModel)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Allow image input (vision models only)", isOn: $store.visionEnabled)
                Text(
                    "Only turn on if your model can read images. Most local text-only models will choke on image input."
                )
                .font(.caption).foregroundStyle(.secondary)
                healthRow
            }

            connectionsSection

            Section("Context budget") {
                Stepper(
                    "Max tool-result bytes: \(byteLabel(store.maxToolResultBytes))",
                    value: $store.maxToolResultBytes, in: 0...262_144, step: 1024)
                Stepper(
                    "Max file read: \(mbLabel(store.maxReadFileBytes))",
                    value: $store.maxReadFileBytes, in: 0...(50 * 1_048_576), step: 1_048_576)
                Stepper(
                    "Max history turns: \(store.maxHistoryTurns)",
                    value: $store.maxHistoryTurns, in: 0...64)
                Stepper(
                    "Max context chars: \(store.maxContextChars)",
                    value: $store.maxContextChars, in: 0...262_144, step: 4096)
                Text(
                    "0 means unbounded. Smaller models need tighter budgets so a big file read can't flood the window. \"Max file read\" stops a huge file from running the agent out of memory before it's even trimmed."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Agent limits") {
                Stepper(
                    "Max agent steps: \(limitLabel(store.maxAgentSteps))",
                    value: $store.maxAgentSteps, in: 0...500)
                Stepper(
                    "LLM request timeout: \(secondsLabel(store.llmTimeoutSeconds))",
                    value: $store.llmTimeoutSeconds, in: 0...600, step: 5)
                Stepper(
                    "Shell command timeout: \(secondsLabel(store.shellTimeoutSeconds))",
                    value: $store.shellTimeoutSeconds, in: 0...600, step: 5)
                Stepper(
                    "Permission prompt timeout: \(secondsLabel(store.permissionTimeoutSeconds))",
                    value: $store.permissionTimeoutSeconds, in: 0...600, step: 10)
                Text(
                    "0 = unlimited. \"Max agent steps\" caps the tool-call loop (set it to 0 if a turn ends too early with \"reached the tool-call limit\"). The timeouts kill a stalled LLM request or shell command; the permission timeout denies a tool change you don't answer in time."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Security") {
                Toggle("Run tools without asking permission", isOn: $store.allowUngatedTools)
                if store.allowUngatedTools {
                    Label(
                        "The agent will create/modify files and run shell commands with NO prompt. Only enable on a machine you fully trust and isolate.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.red)
                } else {
                    Text(
                        "Off (recommended): every file or shell change asks you first, and the permission timeout above denies an unanswered prompt."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }

            ContextGraphSection()

            Section("Tools") {
                ForEach(ConfigurationStore.allToolNames, id: \.self) { name in
                    Toggle(
                        name,
                        isOn: Binding(
                            get: { store.enabledTools.contains(name) },
                            set: { on in
                                if on { store.enabledTools.insert(name) }
                                else { store.enabledTools.remove(name) }
                            }))
                }
            }

            Section("Skills") {
                Toggle("Advertise built-in skills", isOn: $store.skillsEnabled)
                if store.skillsEnabled {
                    ForEach(ConfigurationStore.allSkillNames, id: \.self) { name in
                        Toggle(
                            "/\(name)",
                            isOn: Binding(
                                get: { store.enabledSkills.contains(name) },
                                set: { on in
                                    if on { store.enabledSkills.insert(name) }
                                    else { store.enabledSkills.remove(name) }
                                })
                        )
                        .padding(.leading, 12)
                    }
                    Text("Turn off a skill to stop advertising that slash-command to the model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Prompt tuning") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt preamble (appended to the built-in system prompt)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.promptPreamble)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                        .border(.quaternary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("System prompt override (replaces the built-in prompt entirely; {cwd} is substituted)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.systemPromptOverride)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 60)
                        .border(.quaternary)
                }
            }

            ProjectMemorySection()
        }
        .formStyle(.grouped)
        // Cap the reading width (CLAUDE.md: don't let forms sprawl edge-to-edge on a
        // big display) but fill the rest of the window so the form uses the full height
        // and stays top-aligned instead of clustering at its natural size. Matches the
        // BridgeView/TestChatView/RelayWizardView pattern.
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showTour) {
            EnterpriseTourView { showTour = false }
        }
    }

    private var healthRow: some View {
        HStack(spacing: 8) {
            Circle().fill(healthColor).frame(width: 8, height: 8)
            Text(healthText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Test") { Task { await health.checkNow() } }
                .controlSize(.small)
        }
    }

    private var healthColor: Color {
        switch health.result {
        case .reachable: return .green
        case .unreachable: return .red
        default: return .yellow
        }
    }
    private var healthText: String {
        switch health.result {
        case .reachable(let m): return m.isEmpty ? "Reachable" : "Reachable — \(m.joined(separator: ", "))"
        case .unreachable(let e): return e
        case .checking: return "Checking…"
        case .unknown: return "Not checked"
        }
    }

    private func byteLabel(_ bytes: Int) -> String {
        bytes == 0 ? "unbounded" : "\(bytes / 1024) KB"
    }

    private func mbLabel(_ bytes: Int) -> String {
        bytes == 0 ? "unbounded" : "\(bytes / 1_048_576) MB"
    }

    private func limitLabel(_ value: Int) -> String {
        value == 0 ? "unlimited" : "\(value)"
    }

    private func secondsLabel(_ seconds: Int) -> String {
        seconds == 0 ? "unlimited" : "\(seconds)s"
    }

    // MARK: - Connections (answers "is the daemon running?" and "what port?")

    private var connectionsSection: some View {
        Section("Connections") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
                    Text("eldr-acp agent")
                    Spacer()
                    Text("Spawned on demand").font(.caption).foregroundStyle(.secondary)
                }
                Text(agentActivityText).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Circle().fill(gatewayColor).frame(width: 8, height: 8)
                Text("sybilclaw gateway")
                Spacer()
                Text(gatewayText).font(.caption).foregroundStyle(.secondary)
                Button("Check") {
                    Task { await connections.probeGateway(port: store.sybilclawGatewayPort) }
                }
                .controlSize(.small)
            }
            LabeledContent("Gateway port") {
                TextField(
                    "18789", value: $store.sybilclawGatewayPort,
                    format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
            }
            LabeledContent("Registered in acpx") { registrationStatus(acpxRegistered) }
            LabeledContent("Registered in sybilclaw") { registrationStatus(sybilclawRegistered) }
            Text(
                "eldr-acp speaks over stdio and has no port of its own — a harness (Xcode, OpenClaw, sybilclaw) launches it per session, so there is no background process of ours to watch. The gateway above is sybilclaw's own daemon (default :18789); the port here only tells this panel where to look. Register or re-register from the setup wizard."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            connections.refreshAgentActivity(logFile: store.paths.logFile)
            acpxRegistered = HarnessRegistration.isRegistered(path: store.paths.acpxGlobalConfig)
            sybilclawRegistered = HarnessRegistration.isRegistered(
                path: store.paths.defaultSybilclawConfig)
            await connections.probeGateway(port: store.sybilclawGatewayPort)
        }
    }

    private var gatewayColor: Color {
        switch connections.gateway {
        case .up: return .green
        case .down: return .orange
        case .checking: return .yellow
        case .unknown: return .secondary
        }
    }

    private var gatewayText: String {
        switch connections.gateway {
        case .up: return "Running on :\(store.sybilclawGatewayPort)"
        case .down(let message): return message
        case .checking: return "Checking…"
        case .unknown: return "Not checked"
        }
    }

    private var agentActivityText: String {
        let base = "Not a background daemon — it runs only while a harness is using it."
        guard let date = connections.lastAgentActivity else {
            return base + " No activity logged yet."
        }
        let formatter = RelativeDateTimeFormatter()
        return base + " Last activity \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    private func registrationStatus(_ on: Bool) -> some View {
        Label(on ? "Yes" : "No", systemImage: on ? "checkmark.circle.fill" : "circle")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(on ? Color.green : Color.secondary)
    }
}
