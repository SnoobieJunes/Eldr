import PQRCAgent
import SwiftUI
import UniformTypeIdentifiers

/// A user-authored agent skill — the app-layer overlay on top of the fixed
/// `AgentSkills.catalog` (the package stays the source of truth for built-ins).
/// A person writes a name + one-line summary + the injected instruction text;
/// the skill then appears in the Thread Skills picker beside the built-ins and,
/// when pinned, its `instruction` is appended to that thread's AI-turn prompt
/// exactly like a built-in's `fragment` (see `PersonaRuntime.customSkillFragments`).
///
/// Stored per-silo (UserDefaults via `AppSession.loadCustomSkills`) so accounts
/// never share or accumulate each other's skills (deniability — A33). Nothing
/// here touches the wire: a skill is just prompt text, recorded in the thread
/// like any other agent message (the recording guarantee).
struct CustomSkill: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var summary: String
    /// The instruction text injected into the thread-turn prompt when pinned —
    /// the user's own TRIGGER / PRODUCE / CONSUME contract (free-form).
    var instruction: String

    init(id: String = "custom-" + UUID().uuidString, name: String, summary: String, instruction: String) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instruction = instruction
    }

    /// Bridge to the package type so a custom skill renders in the picker with the
    /// same shape as a built-in. The overlay id is preserved, so thread pins and
    /// injection resolve back to the right custom skill.
    var asAgentSkill: AgentSkill {
        AgentSkill(id: id, name: name, summary: summary, fragment: instruction, tags: ["custom"])
    }
}

/// The shareable export shape: the catalog version + the built-ins (by id, so an
/// importer can tell which were customized) + the full custom skills. JSON is the
/// canonical, re-importable form; a Markdown rendering is offered for humans.
struct SkillExport: Codable, Sendable {
    var format = "eldrchat.skills.v1"
    var exportedAt: Int64
    var builtInSkillIDs: [String]
    var customSkills: [CustomSkill]

    init(customSkills: [CustomSkill]) {
        self.exportedAt = Int64(Date().timeIntervalSince1970)
        self.builtInSkillIDs = AgentSkills.catalog.map(\.id)
        self.customSkills = customSkills
    }

    var jsonData: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Human-readable catalog: every built-in (name + summary + the TRIGGER/
    /// PRODUCE/CONSUME fragment) plus every custom skill, as Markdown.
    static func markdown(customSkills: [CustomSkill]) -> String {
        var out = "# EldrChat agent skills\n\n"
        out += "_A shared vocabulary so two people's AIs can hand off work cleanly in a thread._\n\n"
        out += "## Built-in skills (\(AgentSkills.catalog.count))\n\n"
        for skill in AgentSkills.catalog {
            out += "### \(skill.name) `\(skill.id)`\n\n\(skill.summary)\n\n```\n\(skill.fragment)\n```\n\n"
        }
        if !customSkills.isEmpty {
            out += "## Custom skills (\(customSkills.count))\n\n"
            for skill in customSkills {
                out +=
                    "### \(skill.name) `\(skill.id)`\n\n\(skill.summary)\n\n```\n\(skill.instruction)\n```\n\n"
            }
        }
        return out
    }

    /// Markdown for a single skill (built-in or custom), for the per-skill share.
    static func markdown(skill: AgentSkill) -> String {
        "# \(skill.name)\n\n`\(skill.id)`\n\n\(skill.summary)\n\n```\n\(skill.fragment)\n```\n"
    }
}

/// A `Transferable` file wrapper so `ShareLink` produces a properly-named file
/// (not just a pasteboard string). Carries the bytes + a base filename; the type
/// (JSON or Markdown) is chosen at the call site.
struct SkillsFile: Transferable {
    let data: Data
    let filename: String
    let utType: UTType

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName { $0.filename }
            .exportingCondition { $0.utType == .json }
        DataRepresentation(exportedContentType: .plainText) { $0.data }
            .suggestedFileName { $0.filename }
            .exportingCondition { $0.utType != .json }
    }
}

/// Create / edit one custom skill (name + summary + injected instruction). On
/// save it's written to the silo's overlay; the new skill then shows up in the
/// Thread Skills picker beside the built-ins.
struct CustomSkillEditor: View {
    let siloID: String
    /// nil = creating a new skill; non-nil = editing an existing one in place.
    var existing: CustomSkill?
    var onSave: (CustomSkill) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var summary = ""
    @State private var instruction = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !trimmedName.isEmpty
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Release notes)", text: $name)
                        .accessibilityIdentifier("custom-skill-name")
                    TextField("One-line summary", text: $summary, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("custom-skill-summary")
                } header: {
                    Text("Skill")
                        .helpInfo("A custom skill is your own shared format for AI-to-AI handoff in a thread. Give it a short name and summary so it reads cleanly in the picker beside the built-ins.")
                } footer: {
                    Text("Appears in a thread's Skills picker alongside the 20 built-ins, for this account only.")
                }
                Section {
                    TextField(
                        "TRIGGER: …\nPRODUCE: …\nCONSUME: …",
                        text: $instruction, axis: .vertical)
                        .lineLimit(4...16)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("custom-skill-instruction")
                } header: {
                    Text("Injected instruction")
                        .helpInfo("This exact text is appended to your AI's thread-turn prompt when the skill is pinned — the same way a built-in skill's contract is. Describe when to use it (TRIGGER), what to output (PRODUCE), and how to react to the peer (CONSUME). It is recorded in the thread like any AI message; never put secrets here.")
                } footer: {
                    Text("This text is added to your AI's prompt for the thread, verbatim. Remote AIs still receive your private codenames, never real names.")
                }
            }
            .navigationTitle(existing == nil ? "New skill" : "Edit skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var skill = existing ?? CustomSkill(name: "", summary: "", instruction: "")
                        skill.name = trimmedName
                        skill.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                        skill.instruction = instruction
                        onSave(skill)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("custom-skill-save")
                }
            }
            .task {
                if let existing {
                    name = existing.name
                    summary = existing.summary
                    instruction = existing.instruction
                }
            }
        }
    }
}

/// Manage custom skills (create / edit / delete) and export the catalog. Opened
/// from the Thread Skills picker. The built-in catalog is read-only here (it's
/// the package's source of truth); only the overlay is editable.
struct CustomSkillsManagerView: View {
    let siloID: String
    /// Called whenever the overlay changes, so the picker can refresh.
    var onChange: () -> Void = {}

    @State private var skills: [CustomSkill] = []
    @State private var editing: CustomSkill?
    @State private var creating = false

    private var exportJSON: SkillsFile {
        SkillsFile(
            data: SkillExport(customSkills: skills).jsonData,
            filename: "eldrchat-skills.json", utType: .json)
    }
    private var exportMarkdown: SkillsFile {
        SkillsFile(
            data: Data(SkillExport.markdown(customSkills: skills).utf8),
            filename: "eldrchat-skills.md", utType: .plainText)
    }

    var body: some View {
        List {
            Section {
                Button {
                    creating = true
                } label: {
                    Label("Create a custom skill", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("create-custom-skill")
            } header: {
                Text("Custom skills")
                    .helpInfo("Build your own AI-to-AI handoff formats. A custom skill is a name, a summary, and the instruction text injected into your AI's thread prompt. Stored only for this account, never broadcast.")
            } footer: {
                if skills.isEmpty {
                    Text("No custom skills yet. Create one and it joins the 20 built-ins in every thread's Skills picker.")
                }
            }

            if !skills.isEmpty {
                Section("Your skills") {
                    ForEach(skills) { skill in
                        Button {
                            editing = skill
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).font(.headline).foregroundStyle(.primary)
                                if !skill.summary.isEmpty {
                                    Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("custom-skill-row")
                        .swipeActions {
                            ShareLink(
                                item: SkillsFile(
                                    data: Data(SkillExport.markdown(skill: skill.asAgentSkill).utf8),
                                    filename: "\(skill.id).md", utType: .plainText),
                                preview: SharePreview(skill.name))
                            {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                    .onDelete { offsets in
                        skills.remove(atOffsets: offsets)
                        persist()
                    }
                }
            }

            Section {
                ShareLink(item: exportJSON, preview: SharePreview("EldrChat skills (JSON)")) {
                    Label("Export all skills (JSON)", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("export-skills-json")
                ShareLink(item: exportMarkdown, preview: SharePreview("EldrChat skills (Markdown)")) {
                    Label("Export all skills (Markdown)", systemImage: "doc.richtext")
                }
                .accessibilityIdentifier("export-skills-markdown")
            } header: {
                Text("Export")
                    .helpInfo("Share the whole catalog — the 20 built-ins plus your custom skills — as a file. JSON re-imports into another account or device; Markdown is for reading. A single skill exports from its swipe action.")
            } footer: {
                Text("Exports the built-in catalog and your custom skills. The JSON file can be re-imported.")
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .task { skills = AppSession.loadCustomSkills(siloID: siloID) }
        .sheet(isPresented: $creating) {
            CustomSkillEditor(siloID: siloID, existing: nil) { skill in
                skills.append(skill)
                persist()
            }
        }
        .sheet(item: $editing) { skill in
            CustomSkillEditor(siloID: siloID, existing: skill) { updated in
                if let idx = skills.firstIndex(where: { $0.id == updated.id }) {
                    skills[idx] = updated
                } else {
                    skills.append(updated)
                }
                persist()
            }
        }
    }

    private func persist() {
        AppSession.saveCustomSkills(skills, siloID: siloID)
        onChange()
    }
}
