import AppKit
import SwiftUI

/// The "Project Memory" section of the Configuration form: the global learning
/// toggle plus a live list of projects with an accumulated `eldr.md`.
struct ProjectMemorySection: View {
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var learner = ContextLearner()
    @State private var viewing: ContextLearner.ProjectMemory?

    var body: some View {
        Section("Project Memory") {
            Toggle("Self-learning (record events, build per-project eldr.md)", isOn: $store.learningEnabled)
            Text("The agent appends events as it works; the learner distills them into a per-project eldr.md it reads back next session. Turn off to stop recording.")
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Project context file") {
                HStack {
                    TextField("(auto — per-project eldr.md)", text: $store.contextFilePath)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…") { chooseContextFile() }
                    if !store.contextFilePath.isEmpty {
                        Button("Clear") { store.contextFilePath = "" }
                    }
                }
            }
            Text("Optional: force a specific eldr.md to prepend to every session. Leave blank to auto-discover one per project.")
                .font(.caption).foregroundStyle(.secondary)

            if learner.activeProjects.isEmpty {
                Text("No project memory yet.").foregroundStyle(.secondary)
            } else {
                ForEach(learner.activeProjects) { project in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((project.cwd as NSString).lastPathComponent)
                                .font(.callout.weight(.medium))
                            Text(project.preview)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("View") { viewing = project }
                            .controlSize(.small)
                        Button(role: .destructive) { learner.clear(project) } label: { Text("Clear") }
                            .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { learner.start() }
        .onDisappear { learner.stop() }
        .task {
            // B2: hand the learner the at-rest metadata key derived from the SAME
            // Secure-Enclave-wrapped master key the agent + transcript use, so it
            // reads/writes events.jsonl + eldr.md SEALED (not cleartext). Keychain
            // unavailable / no master key ⇒ nil ⇒ cleartext fallback (today's behavior).
            let transcripts = URL(
                fileURLWithPath: ConfigPaths.standard.configDir, isDirectory: true
            ).appendingPathComponent("transcripts", isDirectory: true)
            // `…IfProvisioned` (load-only): this is a SECOND ConversationMemory instance, so it must
            // never CREATE the master key — only the bridge's instance does — or the two would
            // diverge on a first-launch race and the learner couldn't read the agent's sealed files.
            let key = await ConversationMemory(directory: transcripts).metadataKeyIfProvisioned()
            learner.setMetadataKey(key)
        }
        .sheet(item: $viewing) { project in
            ProjectMemoryDetail(
                title: (project.cwd as NSString).lastPathComponent,
                text: learner.memoryText(project))
        }
    }

    private func chooseContextFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose an eldr.md (or any text file) to prepend to every session"
        if panel.runModal() == .OK, let url = panel.url {
            store.contextFilePath = url.path
        }
    }
}

private struct ProjectMemoryDetail: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        // Resizable instead of hard-fixed: long eldr.md content no longer clips, and the
        // user can drag the sheet larger. min keeps it readable; ideal is the old size.
        .frame(
            minWidth: 480, idealWidth: 680, maxWidth: .infinity,
            minHeight: 360, idealHeight: 600, maxHeight: .infinity)
    }
}
