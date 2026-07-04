import AppKit
import SwiftUI

/// Configuration UI for the `contextgraph` integration (graph-based context
/// manager). Toggles the agent-side route (env flags via `ConfigurationStore`),
/// lets the user install/start the local service from a checkout, and shows a
/// live health dot. The OpenClaw plugin route is wired separately, in the
/// OpenClaw registration step.
struct ContextGraphSection: View {
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var service = ContextGraphService()
    /// Debounces the live health probe so editing the endpoint doesn't fire a
    /// (4s-timeout) request on every keystroke.
    @State private var healthProbe: Task<Void, Never>?

    var body: some View {
        Section("ContextGraph (smart context)") {
            Toggle(
                "Assemble context via contextgraph (graph + tag retrieval)",
                isOn: $store.contextGraphEnabled)
            Text(
                "When on, the eldr agent asks contextgraph to assemble relevant prior context each turn (and learns each turn), instead of a plain recent-window. Falls back automatically if the service is down."
            )
            .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Endpoint") {
                TextField("http://localhost:8302", text: $store.contextGraphURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onChange(of: store.contextGraphURL) { _, newValue in
                        // Live feedback: re-probe shortly after the user stops typing
                        // so the dot reflects the endpoint they're actually editing,
                        // not the one from when the section first appeared.
                        service.endpoint = newValue
                        healthProbe?.cancel()
                        healthProbe = Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            if Task.isCancelled { return }
                            await service.refreshHealth()
                        }
                    }
            }

            LabeledContent("Channel label") {
                TextField("(auto — derived from each project)", text: $store.contextGraphAgentName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            Text("Keeps separate projects' graphs from mixing. Leave blank to derive one per project folder.")
                .font(.caption).foregroundStyle(.secondary)

            healthRow

            if store.contextGraphEnabled, case .down = service.state {
                Text(
                    "Not answering yet. Pick your contextgraph checkout and press “Install & start service,” or point Endpoint at an already-running instance. The agent falls back to a plain recent-window until it's reachable."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            LabeledContent("contextgraph checkout") {
                HStack {
                    Text(service.repoDir.isEmpty ? "Not selected" : service.repoDir)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(service.repoDir.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseRepo() }
                }
            }

            HStack {
                Button {
                    Task {
                        service.endpoint = store.contextGraphURL
                        try? await service.installAndStart()
                    }
                } label: {
                    if service.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Install & start service")
                    }
                }
                .disabled(service.isWorking || service.repoDir.isEmpty)
                Spacer()
            }

            if let error = service.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !service.setupLog.isEmpty {
                ScrollView {
                    Text(service.setupLog)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 100)
                .border(.quaternary)
            }
        }
        .task {
            service.endpoint = store.contextGraphURL
            await service.refreshHealth()
        }
    }

    private var healthRow: some View {
        HStack(spacing: 8) {
            Circle().fill(healthColor).frame(width: 8, height: 8)
            Text(healthText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Check") {
                Task {
                    service.endpoint = store.contextGraphURL
                    await service.refreshHealth()
                }
            }
            .controlSize(.small)
        }
    }

    private var healthColor: Color {
        switch service.state {
        case .up: return .green
        case .down: return .orange
        case .unknown: return .secondary
        }
    }

    private var healthText: String {
        switch service.state {
        case .up(let n): return "Running — \(n) messages stored"
        case .down: return "Not reachable at \(store.contextGraphURL)"
        case .unknown: return "Status unknown — Check to probe"
        }
    }

    private func chooseRepo() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose your contextgraph checkout folder"
        if panel.runModal() == .OK, let url = panel.url {
            service.repoDir = url.path
        }
    }
}
