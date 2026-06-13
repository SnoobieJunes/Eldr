import PQRCCore
import PQRCNostr
import SwiftUI
import UIKit

/// The address book: every verified contact, keyed by identity pubkey.
/// Names are local-first (D11): your rename wins, then the alias the contact
/// chose for themselves, then their key. Each row lets you flip the displayed
/// identifier between the name and the key, copy the key, or open a chat.
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
                ContactRow(model: model, contact: contact) {
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
    @Bindable var model: AppModel
    let contact: ContactRecord
    let onRename: () -> Void

    /// Name ⇄ key are interchangeable: tap the identifier to flip.
    @State private var showKey = false
    @State private var justCopied = false

    /// The shareable key: the contact's npub (what you add/verify people by).
    private var npub: String { Bech32.npub(contact.binding.nostrPubkey.hexString) }

    var body: some View {
        HStack(spacing: 12) {
            IdenticonView(seed: contact.identityHex, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                // Interchangeable identifier — tap to flip name ⇄ key.
                Button {
                    withAnimation(.snappy) { showKey.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if showKey {
                            Text(npub)
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                        } else {
                            Text(contact.displayName)
                                .font(.headline)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                        }
                        if contact.verified {
                            Image(systemName: "shield.checkered")
                                .font(.caption).foregroundStyle(.green)
                                .accessibilityLabel("Verified")
                        }
                        if contact.blocked {
                            Image(systemName: "hand.raised.fill")
                                .font(.caption).foregroundStyle(.red)
                                .accessibilityLabel("Blocked")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Tap to show \(showKey ? "name" : "key")")
                Text(showKey ? "Tap to show name" : "Tap to show key")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            // Copy the key (npub).
            Button {
                UIPasteboard.general.string = npub
                withAnimation { justCopied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation { justCopied = false }
                }
            } label: {
                Image(systemName: justCopied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(justCopied ? .green : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(justCopied ? "Key copied" : "Copy \(contact.displayName)'s key")
            // Send a message — opens the chat (pushed within this nav stack).
            NavigationLink {
                ConversationView(model: model, conversationID: contact.identityHex)
            } label: {
                Image(systemName: "message")
            }
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Message \(contact.displayName)")
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = npub
            } label: {
                Label("Copy key (npub)", systemImage: "doc.on.doc")
            }
            Button {
                UIPasteboard.general.string = contact.identityHex
            } label: {
                Label("Copy identity key (hex)", systemImage: "key")
            }
            Button {
                onRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        .privacySensitive()
        .accessibilityIdentifier("contact-row-\(contact.displayName)")
    }
}
