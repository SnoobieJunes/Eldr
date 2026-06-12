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

    var body: some View {
        NavigationStack {
            Form {
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
