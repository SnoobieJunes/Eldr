import SwiftUI

/// The live configuration form. Every control is bound to a `ConfigurationStore`
/// `@Published` property, which debounces a write to the on-disk files the CLI reads.
struct ConfigurationView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var health: LLMHealthChecker

    var body: some View {
        Form {
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
                healthRow
            }

            Section("Context budget") {
                Stepper(
                    "Max tool-result bytes: \(byteLabel(store.maxToolResultBytes))",
                    value: $store.maxToolResultBytes, in: 0...262_144, step: 1024)
                Stepper(
                    "Max history turns: \(store.maxHistoryTurns)",
                    value: $store.maxHistoryTurns, in: 0...64)
                Stepper(
                    "Max context chars: \(store.maxContextChars)",
                    value: $store.maxContextChars, in: 0...262_144, step: 4096)
                Text(
                    "0 means unbounded. Smaller models need tighter budgets so a big file read can't flood the window."
                )
                .font(.caption).foregroundStyle(.secondary)
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
                Toggle("Advertise built-in skills (/spec, /snippet, /html)", isOn: $store.skillsEnabled)
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
}
