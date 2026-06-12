import PQRCCore
import SwiftUI

/// Conversation list + navigation shell (APP-SPEC §6.1).
struct MainView: View {
    @Bindable var model: AppModel
    /// Local Universe persona switcher, shown above the list (demo/debug only).
    var personaSwitcher: PersonaSwitcher?
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if !model.messageRequests.isEmpty {
                    Section("Message Requests") {
                        ForEach(model.messageRequests, id: \.self) { sender in
                            Label(
                                "Request from \(String(sender.prefix(12)))…",
                                systemImage: "envelope.badge")
                            .accessibilityLabel("Pending message request")
                        }
                    }
                }
                Section {
                    ForEach(model.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                        .accessibilityIdentifier("conversation-\(conversation.title)")
                    }
                } header: {
                    if model.conversations.isEmpty {
                        Text("No conversations yet — start one with a contact's npub.")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let personaSwitcher {
                    personaSwitcher
                }
            }
            .navigationTitle("PQRC")
            .navigationDestination(for: String.self) { conversationID in
                ConversationView(model: model, conversationID: conversationID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showNewGroup = true
                    } label: {
                        Image(systemName: "person.3")
                    }
                    .accessibilityLabel("New group")
                    Button {
                        showNewChat = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                    .accessibilityIdentifier("new-chat")
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView(model: model)
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(model: model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: ConversationVM

    var body: some View {
        HStack(spacing: 12) {
            IdenticonView(seed: conversation.id, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.verified {
                        Image(systemName: "shield.checkered")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Verified contact")
                    }
                    if conversation.isGroup {
                        Text("\(conversation.memberCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(conversation.lastMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
    }
}

/// Deterministic identicon from an identity pubkey (APP-SPEC §6.1) — no
/// uploaded avatars, nothing leaves the device.
struct IdenticonView: View {
    let seed: String
    let size: CGFloat

    var body: some View {
        let bytes = Array(sha256(Data(seed.utf8)))
        let hue = Double(bytes[0]) / 255
        Canvas { context, canvasSize in
            let cell = canvasSize.width / 5
            for row in 0..<5 {
                for column in 0..<3 {
                    if bytes[1 + row * 3 + column] % 2 == 0 {
                        let color = Color(hue: hue, saturation: 0.55, brightness: 0.8)
                        let rect = CGRect(
                            x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell)
                        context.fill(Path(rect), with: .color(color))
                        // Mirror for symmetry.
                        let mirrored = CGRect(
                            x: CGFloat(4 - column) * cell, y: CGFloat(row) * cell,
                            width: cell, height: cell)
                        context.fill(Path(mirrored), with: .color(color))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .background(Color(hue: hue, saturation: 0.15, brightness: 0.95))
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

import PQRCNostr

/// New 1:1 conversation: paste an npub (QR scan requests camera just-in-time
/// on hardware; paste is the simulator path).
struct NewChatView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var npub = ""
    @State private var firstMessage = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("npub1…", text: $npub)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("new-chat-npub")
                }
                Section("First message") {
                    TextField("Say hi", text: $firstMessage)
                        .accessibilityIdentifier("new-chat-message")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                Button("Start encrypted conversation") {
                    Task {
                        do {
                            _ = try await model.runtime.startConversation(
                                npub: npub, firstMessage: firstMessage.isEmpty ? "👋" : firstMessage)
                            dismiss()
                        } catch {
                            self.error = "Couldn't verify this contact's PQRC setup. They may not have published keys yet."
                        }
                    }
                }
                .disabled(npub.isEmpty)
                .accessibilityIdentifier("new-chat-start")
            }
            .navigationTitle("New Conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct NewGroupView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    private var candidates: [(id: String, name: String)] {
        model.conversations.filter { !$0.isGroup }.map { ($0.id, $0.title) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("group-name")
                }
                Section("Members") {
                    ForEach(candidates, id: \.id) { candidate in
                        Button {
                            if selected.contains(candidate.id) {
                                selected.remove(candidate.id)
                            } else {
                                selected.insert(candidate.id)
                            }
                        } label: {
                            HStack {
                                Text(candidate.name)
                                Spacer()
                                if selected.contains(candidate.id) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .accessibilityIdentifier("group-member-\(candidate.name)")
                    }
                }
                Button("Create group") {
                    Task {
                        _ = await model.createGroup(name: name, members: Array(selected))
                        dismiss()
                    }
                }
                .disabled(name.isEmpty || selected.isEmpty)
                .accessibilityIdentifier("group-create")
            }
            .navigationTitle("New Group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
