import PQRCCore
import SwiftUI

/// The address book: every verified contact, keyed by identity pubkey.
/// Names are local-first (D11): your rename wins, then the alias the contact
/// chose for themselves (received over the encrypted channel), then their key.
struct ContactsView: View {
    @Bindable var model: AppModel
    @State private var contacts: [ContactRecord] = []
    @State private var renaming: ContactRecord?
    @State private var renameText = ""

    var body: some View {
        List {
            if contacts.isEmpty {
                ContentUnavailableView(
                    "No contacts yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Start a conversation from an npub or QR code and the verified contact appears here."))
            }
            ForEach(contacts, id: \.identityHex) { contact in
                ContactRow(
                    contact: contact,
                    conversationExists: model.conversations.contains { $0.id == contact.identityHex }
                ) {
                    renameText = contact.localNickname ?? ""
                    renaming = contact
                }
            }
        }
        .navigationTitle("Contacts")
        .task { await reload() }
        .alert("Rename contact", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let contact = renaming {
                    Task {
                        await model.renameContact(
                            contact.identityHex,
                            nickname: renameText.isEmpty ? nil : renameText)
                        await reload()
                    }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Only you see this name. Leave empty to use the name they chose for themselves.")
        }
    }

    private func reload() async {
        contacts = await model.runtime.allContactRecords()
    }
}

private struct ContactRow: View {
    let contact: ContactRecord
    let conversationExists: Bool
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            IdenticonView(seed: contact.identityHex, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(contact.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if contact.verified {
                        Image(systemName: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Verified contact")
                    }
                    if contact.blocked {
                        Image(systemName: "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Blocked")
                    }
                }
                if let peerAlias = contact.peerAlias, contact.localNickname != nil,
                    peerAlias != contact.localNickname
                {
                    Text("Calls themselves “\(peerAlias)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(contact.identityHex.prefix(16) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                onRename()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Rename \(contact.displayName)")
        }
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contact-row-\(contact.displayName)")
    }
}
