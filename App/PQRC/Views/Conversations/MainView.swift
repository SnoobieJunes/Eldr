import PQRCCore
import SwiftUI

/// Conversation list + navigation shell (APP-SPEC §6.1).
struct MainView: View {
    @Bindable var model: AppModel
    /// Local Universe persona switcher, shown above the list (demo/debug only).
    var personaSwitcher: PersonaSwitcher?
    @Environment(AppSession.self) private var session
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var deepLinkNpub: String?
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.messageRequests.isEmpty {
                    Section("Message Requests") {
                        ForEach(model.messageRequests, id: \.self) { sender in
                            MessageRequestRow(model: model, sender: sender) { conversationID in
                                path.append(conversationID)
                            }
                        }
                    }
                }
                Section {
                    ForEach(model.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                        .accessibilityIdentifier("conversation-\(conversation.title)")
                        .swipeActions(edge: .leading) {
                            Button {
                                Task { await model.togglePinned(conversation.id) }
                            } label: {
                                Label(
                                    conversation.pinned ? "Unpin" : "Pin",
                                    systemImage: conversation.pinned ? "pin.slash" : "pin")
                            }
                            .tint(.orange)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await model.deleteConversation(conversation.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
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
                    .onAppear { model.markRead(conversationID) }
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
                NewChatView(model: model, prefilledNpub: deepLinkNpub ?? "")
                    .onDisappear { deepLinkNpub = nil }
            }
            .sheet(isPresented: $showNewGroup) {
                NewGroupView(model: model)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(model: model)
            }
            .onChange(of: session.pendingNpub) { _, npub in
                // QR deep link (pqrc:add?npub=…): open New Conversation
                // prefilled with the scanned address.
                guard let npub else { return }
                deepLinkNpub = npub
                session.pendingNpub = nil
                showNewChat = true
            }
        }
    }
}

/// A pending request: explains who is asking (by key — identity is only
/// proven after accept fetches + verifies their binding) and offers
/// Accept / Decline. Accepting opens the conversation ready to type.
struct MessageRequestRow: View {
    @Bindable var model: AppModel
    let sender: String
    let onAccepted: (String) -> Void
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Request from \(String(sender.prefix(12)))…",
                systemImage: "envelope.badge")
            .accessibilityLabel("Pending message request")
            HStack(spacing: 12) {
                Button {
                    working = true
                    Task {
                        if let conversationID = await model.acceptRequest(sender) {
                            onAccepted(conversationID)
                        }
                        working = false
                    }
                } label: {
                    // Semibold body: keeps white-on-accent above the audit's
                    // large-text contrast threshold (A7).
                    Label("Accept", systemImage: "checkmark")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(working)
                .accessibilityIdentifier("accept-request")
                Button(role: .destructive) {
                    Task { await model.declineRequest(sender) }
                } label: {
                    Text("Decline")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
                // Darkened red: plain system red on the bordered fill is
                // ~3.5:1 and fails the contrast audit (A7).
                .tint(Color.red.mix(with: .black, by: 0.35))
                .disabled(working)
                .accessibilityIdentifier("decline-request")
            }
        }
        .padding(.vertical, 4)
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
                    if conversation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                    if conversation.isGroup {
                        Text("\(conversation.memberCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if conversation.lastActivity > 0 {
                        Text(
                            Date(timeIntervalSince1970: TimeInterval(conversation.lastActivity)),
                            format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top) {
                    Text(conversation.lastMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if conversation.unread > 0 {
                        // Darkened accent: white small text on plain system
                        // accent is ~3.5:1 and fails the contrast audit (A7).
                        Text("\(conversation.unread)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                Color.accentColor.mix(with: .black, by: 0.35), in: Capsule())
                            .accessibilityLabel("\(conversation.unread) unread messages")
                    }
                }
            }
        }
        .frame(minHeight: 44)
        .privacySensitive()
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

/// New 1:1 conversation: paste an npub, or arrive prefilled from a scanned
/// `pqrc:add?npub=…` QR (the system Camera deep-links into the app).
struct NewChatView: View {
    @Bindable var model: AppModel
    var prefilledNpub: String = ""
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
                        .onAppear {
                            if npub.isEmpty, !prefilledNpub.isEmpty {
                                npub = prefilledNpub
                            }
                        }
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
                            self.error = "Couldn't reach this contact's keys. Either the relay is unreachable, or they haven't published their PQRC keys to it yet. If you're together in person, use Nearby below — no server needed."
                        }
                    }
                }
                .disabled(npub.isEmpty)
                .accessibilityIdentifier("new-chat-start")

                // Relay-free path: peers verified directly over the local link
                // (SPEC §10). Only shown when the Nearby setting is on.
                if model.localLinkEnabled {
                    Section {
                        if model.nearbyContacts.isEmpty {
                            Text("No one nearby yet. Both devices need Nearby on, foregrounded, and within Wi-Fi/Bluetooth range.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(model.nearbyContacts) { peer in
                            Button {
                                Task {
                                    if (await model.startNearby(peer.identityHex, firstMessage: firstMessage)) != nil {
                                        dismiss()
                                    }
                                }
                            } label: {
                                Label(peer.name, systemImage: "wave.3.right")
                            }
                            .accessibilityIdentifier("nearby-\(peer.name)")
                        }
                    } header: {
                        Text("Nearby · no server")
                    } footer: {
                        Text("Keys are exchanged and verified directly between your devices. Confirm the 60-digit safety code in person afterwards.")
                    }
                }
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
