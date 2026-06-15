import PQRCCore
import SwiftUI

/// Per-conversation details: verification (D13), block & report (D8).
struct ConversationDetailsView: View {
    @Bindable var model: AppModel
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var safetyCode = ""
    @State private var verified = false
    @State private var showReport = false
    @State private var blocked = false
    @State private var nickname = ""
    /// Per-conversation AI context override: "default" (use each AI's own
    /// setting) | "off" | "marked" | "full".
    @State private var aiContextMode = "default"
    /// Read-only echo of the primary AI's effective mode / remoteness / firewall
    /// for this conversation, refreshed when the override changes.
    @State private var summary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(
                        "Local name for this contact", text: $nickname,
                        prompt: Text(model.contactNames[conversationID] ?? "Contact"))
                    .accessibilityIdentifier("contact-nickname")
                    .onSubmit {
                        Task {
                            await model.renameContact(
                                conversationID, nickname: nickname.isEmpty ? nil : nickname)
                        }
                    }
                    Text("Only you see this name — local to your device, never broadcast. If you've turned on a remote AI, a name you set here is included in prompts sent to that provider. If they've chosen an alias, it shows when you clear this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Verify \(model.contactNames[conversationID] ?? "contact")") {
                    Text(safetyCode.isEmpty ? "—" : safetyCode)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("safety-code")
                    Text("Compare these 60 digits in person or over a call you trust. They are derived from both of your identity keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    QRView(content: safetyCode)
                        .frame(width: 120, height: 120)
                        .accessibilityLabel("Safety code QR for comparison")
                    Toggle("Mark as verified", isOn: $verified)
                        .accessibilityIdentifier("mark-verified")
                        .onChange(of: verified) { _, newValue in
                            // Persisted (D13): the shield badge survives
                            // relaunch and clears safety-change warnings.
                            Task { await model.setVerified(conversationID, verified: newValue) }
                        }
                }
                Section {
                    // Unified vocabulary (matches the per-AI "Gathers" picker and
                    // the in-chat "AI here" chip): Use default · Off · Marked only
                    // · Live. Tags stay the engine's "default"/"off"/"marked"/
                    // "full" — only the labels are unified.
                    Picker("AI context here", selection: $aiContextMode) {
                        Text("Use default").tag("default")
                        Text("Off in this conversation").tag("off")
                        Text("Marked only — messages I add to context").tag("marked")
                        Text("Live — full conversation while active").tag("full")
                    }
                    .accessibilityIdentifier("conversation-ai-mode")
                    .onChange(of: aiContextMode) { _, newValue in
                        AppSession.setConversationContextMode(
                            newValue == "default" ? nil : newValue, conversationID: conversationID,
                            siloID: model.siloID)
                        summary = model.primaryAIContextSummary(conversationID)
                    }
                    // Live echo of what the AI actually does here + the firewall/
                    // consent indicator whenever a REMOTE AI is active (privacy
                    // cardinal rule: any widening of what a remote AI sees keeps
                    // the firewall state visible).
                    AIContextEcho(summary: summary)
                    if summary.mode != "off" && summary.isRemote {
                        RemoteAIFirewallRow(firewallOn: summary.firewallOn)
                    }
                } header: {
                    Text("AI in this conversation — overrides your AI's default (now: \(AIContextVocab.glance(summary)))")
                } footer: {
                    Text("Overrides your AIs' own context setting, just here. \"Off\" keeps every AI from gathering anything from this conversation.")
                }
                Section("Safety") {
                    Button(blocked ? "Unblock" : "Block", role: .destructive) {
                        blocked.toggle()
                        Task {
                            if blocked {
                                await model.block(conversationID)
                            } else {
                                await model.runtime.setBlocked(conversationID, blocked: false)
                            }
                        }
                    }
                    .accessibilityIdentifier("block-contact")
                    Button("Report a problem") {
                        showReport = true
                    }
                    .accessibilityIdentifier("report-contact")
                }
            }
            .navigationTitle("Details")
            .task {
                safetyCode = await model.runtime.safetyCode(with: conversationID)
                let info = await model.runtime.contactInfo(conversationID)
                verified = info.verified
                blocked = info.blocked
                aiContextMode =
                    AppSession.conversationContextMode(conversationID, siloID: model.siloID) ?? "default"
                summary = model.primaryAIContextSummary(conversationID)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showReport) {
                ReportSheet()
            }
        }
    }
}

/// Shared vocabulary for the AI-context surfaces (Details section, the in-chat
/// "AI here" chip, the chip sheet) so they always read the same. Input is the
/// engine `mode` ("off" | "strict" | "active") from
/// `AppModel.primaryAIContextSummary`; output is the user-facing wording.
enum AIContextVocab {
    /// Compact glance label for a chip / header: "AI off here", "AI: marked",
    /// "AI: live". Mirrors PersonaRuntime's resolution (off / strict / active).
    static func glance(_ summary: (mode: String, isRemote: Bool, firewallOn: Bool)) -> String {
        switch summary.mode {
        case "off": return "AI off here"
        case "strict": return "AI: marked"
        default: return "AI: live"  // "active"
        }
    }

    /// One-line "Your AI sees: …" echo describing what the AI gathers here.
    static func sees(_ summary: (mode: String, isRemote: Bool, firewallOn: Bool)) -> String {
        switch summary.mode {
        case "off": return "Your AI sees: nothing from this conversation."
        case "strict": return "Your AI sees: only messages you add to context."
        default: return "Your AI sees: the full recent conversation while it's active."
        }
    }
}

/// One-line echo of what the AI actually gathers in a conversation. Read-only.
struct AIContextEcho: View {
    let summary: (mode: String, isRemote: Bool, firewallOn: Bool)
    var body: some View {
        Label(AIContextVocab.sees(summary), systemImage: "eye")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("ai-sees-echo")
    }
}

/// Firewall/consent indicator shown whenever a REMOTE AI is active for a
/// conversation — the privacy cardinal rule requires the egress-firewall state
/// stay visible anywhere a remote AI's exposure can widen. Read-only (the toggle
/// itself lives in Settings ▸ AI).
struct RemoteAIFirewallRow: View {
    let firewallOn: Bool
    var body: some View {
        Label(
            firewallOn
                ? "Remote AI · egress firewall ON — names redacted, context bounded before it leaves your device."
                : "Remote AI · egress firewall OFF — real names and full context leave your device unredacted.",
            systemImage: firewallOn ? "lock.shield" : "lock.open")
            .font(.caption)
            .foregroundStyle(firewallOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
            .accessibilityIdentifier("remote-ai-firewall-row")
    }
}

/// Report flow (D8, Guideline 1.2): explains E2EE, nothing is auto-shared;
/// offers a voluntary export the user emails to the maintainer.
struct ReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("Reporting in an E2EE app", systemImage: "hand.raised")
                    .font(.headline)
                Text(
                    "PQRC messages are end-to-end encrypted: nothing is shared automatically with anyone, including the app maintainer. If you want to report abuse, you can voluntarily export selected messages and email them to the maintainer. Blocking the contact stops their messages immediately, on this device, without notifying them."
                )
                .font(.subheadline)
                ShareLink(item: "PQRC report — attach exported messages here.") {
                    Label("Export & report", systemImage: "square.and.arrow.up")
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
