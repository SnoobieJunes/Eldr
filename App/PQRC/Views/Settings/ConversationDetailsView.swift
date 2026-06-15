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
                    Picker("AI context here", selection: $aiContextMode) {
                        Text("Use each AI's own setting").tag("default")
                        Text("Off in this conversation").tag("off")
                        Text("Only messages I add to context").tag("marked")
                        Text("Full conversation while active").tag("full")
                    }
                    .accessibilityIdentifier("conversation-ai-mode")
                    .onChange(of: aiContextMode) { _, newValue in
                        AppSession.setConversationContextMode(
                            newValue == "default" ? nil : newValue, conversationID: conversationID,
                            siloID: model.siloID)
                    }
                } header: {
                    Text("AI in this conversation")
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
