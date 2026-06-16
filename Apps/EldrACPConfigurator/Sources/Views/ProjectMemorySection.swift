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
        .sheet(item: $viewing) { project in
            ProjectMemoryDetail(
                title: (project.cwd as NSString).lastPathComponent,
                text: learner.memoryText(project))
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
        .frame(width: 560, height: 420)
    }
}
