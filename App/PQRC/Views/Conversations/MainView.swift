import PQRCCore
import PQRCNostr
import SwiftUI
import UIKit  // UIPasteboard (Copy npub) — available on iOS + Mac Catalyst.

/// Conversation list + navigation shell (APP-SPEC §6.1).
struct MainView: View {
    @Bindable var model: AppModel
    /// Local Universe persona switcher, shown above the list (demo/debug only).
    var personaSwitcher: PersonaSwitcher?
    @Environment(AppSession.self) private var session
    @Environment(AppCommands.self) private var commands
    @State private var showNewChat = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var deepLinkNpub: String?
    /// Conversation-list search text (⌘F on Mac). Filters the list by title.
    @State private var searchText = ""
    /// Bound to `.searchable`'s focus so ⌘F can pop the cursor into it on Mac.
    @FocusState private var searchFocused: Bool
    /// Per-silo "muted" conversations: their unread badge is suppressed in the
    /// list. A pure UI preference (the app has no push notifications), kept here
    /// so muting needs no engine change. Persisted per-silo so accounts don't
    /// share the set (matches AppSession.siloDefaultsKey namespacing).
    @State private var mutes = MutedConversations()
    /// Selected conversation drives the detail pane on wide screens (iPad/Mac/
    /// landscape) and pushes on compact widths (iPhone portrait) — one binding,
    /// both layouts, via NavigationSplitView (CLAUDE.md responsive roadmap).
    @State private var selection: String?
    // Show the conversation list by default on wide screens (the list is the
    // home of the app); .automatic hid it in iPad portrait until the user found
    // "Show Sidebar". Ignored on compact iPhone widths (which stack).
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Conversations after applying the search filter (Mac ⌘F).
    private var visibleConversations: [ConversationVM] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.conversations }
        return model.conversations.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                // A draggable, collapsible sidebar like every native Mac app —
                // bounded so it can't be dragged uselessly narrow or hog a 27"
                // display. iOS uses its own fixed column metrics, so this is a
                // no-op there.
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            // Each conversation gets its own stack so threads/details push within
            // the detail pane on wide screens; rebuilds per selection so state
            // (composer, scroll) doesn't bleed between conversations.
            NavigationStack {
                if let selection {
                    ConversationView(model: model, conversationID: selection)
                        .id(selection)
                        .onAppear { model.markRead(selection) }
                } else {
                    ContentUnavailableView(
                        "No conversation selected",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Pick a conversation, or start a new one. The brain icon opens a private chat with just you and your AI."))
                }
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
        .onAppear { mutes.load(siloID: session.activeSiloID ?? "") }
        .onChange(of: session.pendingNpub) { _, npub in
            // QR deep link (pqrc:add?npub=…): open New Conversation
            // prefilled with the scanned address.
            guard let npub else { return }
            deepLinkNpub = npub
            session.pendingNpub = nil
            showNewChat = true
        }
        // Menu-bar commands (Mac). Each is a counter the command bumps; reacting
        // to the change keeps the action one-shot. No-ops on iPhone/iPad, where
        // nothing ever bumps them.
        .onChange(of: commands.newConversationTick) { _, _ in showNewChat = true }
        .onChange(of: commands.newGroupTick) { _, _ in showNewGroup = true }
        .onChange(of: commands.newAIChatTick) { _, _ in
            Task { if let id = await model.createSelfChat() { selection = id } }
        }
        .onChange(of: commands.openSettingsTick) { _, _ in showSettings = true }
        .onChange(of: commands.findTick) { _, _ in searchFocused = true }
        .onChange(of: commands.toggleSidebarTick) { _, _ in
            withAnimation { columnVisibility = columnVisibility == .all ? .detailOnly : .all }
        }
    }

    /// Conversation list — the sidebar on wide screens, the root on iPhone.
    private var sidebar: some View {
        List(selection: $selection) {
            if !model.messageRequests.isEmpty {
                Section {
                    ForEach(model.messageRequests, id: \.self) { sender in
                        MessageRequestRow(model: model, sender: sender) { conversationID in
                            selection = conversationID
                        }
                    }
                } header: {
                    Text("Message Requests")
                        .helpInfo("First messages from people you haven't talked to wait here — nothing is shown until you Accept. Decline to ignore them. Their identity is only confirmed after you accept and verify their safety code.")
                }
            }
            Section {
                ForEach(visibleConversations) { conversation in
                    ConversationRow(conversation: conversation, muted: mutes.contains(conversation.id))
                        .tag(conversation.id)
                        // Combine the identicon + text into ONE accessibility
                        // element so the WHOLE row is the identified, hittable
                        // target. After the NavigationSplitView migration the id
                        // landed on the inner identicon (44×44, reported as "not
                        // hittable"), and the timestamp text became its own
                        // too-small audit-flagged element. Combining fixes both.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("conversation-\(conversation.title)")
                        .accessibilityAddTraits(.isButton)
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
                        // Secondary-click (right-click) menu on every list row —
                        // the core Mac affordance. Also long-press on iPhone/iPad,
                        // so it's a pure addition everywhere.
                        .contextMenu {
                            conversationMenu(conversation)
                        }
                }
            } header: {
                if model.conversations.isEmpty {
                    Text("No conversations yet — start one with a contact's npub.")
                } else if visibleConversations.isEmpty {
                    Text("No conversations match “\(searchText)”.")
                }
            }
        }
        // ⌘F-focusable, type-to-filter conversation search. On iPhone/iPad it's
        // the familiar pull-to-reveal search bar; on Mac it's always visible in
        // the sidebar and the menu-bar Find command jumps the cursor here.
        .searchable(
            text: $searchText, placement: .sidebar, prompt: "Search conversations"
        )
        .searchFocused($searchFocused)
        .safeAreaInset(edge: .top) {
            if let personaSwitcher {
                personaSwitcher
            }
        }
        .navigationTitle("PQRC")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
                .help("Settings (⌘,)")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        if let id = await model.createSelfChat() { selection = id }
                    }
                } label: {
                    Image(systemName: "brain")
                }
                .accessibilityLabel("New AI chat")
                .accessibilityIdentifier("new-ai-chat")
                .help("Open a private solo chat with just you and your AI(s) — a staging ground to brainstorm or draft. Add people later to make it a real conversation. (⌥⌘N)")
                Button {
                    showNewGroup = true
                } label: {
                    Image(systemName: "person.3")
                }
                .accessibilityLabel("New group")
                .help("New group (⇧⌘N)")
                Button {
                    showNewChat = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New conversation")
                .accessibilityIdentifier("new-chat")
                .help("New conversation (⌘N)")
            }
        }
    }

    /// Right-click / long-press actions for a conversation list row. Open, pin,
    /// mute (suppress its unread badge), copy npub (1:1 only), block (1:1 only),
    /// delete — the standard Messages/Mail set.
    @ViewBuilder
    private func conversationMenu(_ conversation: ConversationVM) -> some View {
        Button {
            selection = conversation.id
        } label: {
            Label("Open", systemImage: "bubble.left.and.bubble.right")
        }
        Button {
            Task { await model.togglePinned(conversation.id) }
        } label: {
            Label(
                conversation.pinned ? "Unpin" : "Pin",
                systemImage: conversation.pinned ? "pin.slash" : "pin")
        }
        Button {
            mutes.toggle(conversation.id, siloID: session.activeSiloID ?? "")
        } label: {
            Label(
                mutes.contains(conversation.id) ? "Unmute" : "Mute",
                systemImage: mutes.contains(conversation.id) ? "bell" : "bell.slash")
        }
        // npub / block only make sense for a 1:1 contact (a group's id is not an
        // identity key). For 1:1 chats the conversation id IS the contact's
        // identity-key hex, so it npub-encodes directly.
        if !conversation.isGroup {
            Button {
                UIPasteboard.general.string = Bech32.npub(conversation.id)
            } label: {
                Label("Copy npub", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.block(conversation.id) }
            } label: {
                Label("Block", systemImage: "hand.raised")
            }
        } else {
            Divider()
        }
        Button(role: .destructive) {
            Task { await model.deleteConversation(conversation.id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

/// Per-silo set of muted conversation ids, persisted in UserDefaults under the
/// same silo namespace the rest of the app uses. A muted conversation simply
/// hides its unread badge in the list — a UI-only preference (there are no push
/// notifications to silence), which is why it lives in the View layer and needs
/// no engine/runtime change. Hidden silos keep their own set, so muting one
/// account never reveals or affects another (deniability — A33).
@Observable
final class MutedConversations {
    private var ids: Set<String> = []
    private var loadedSiloID: String?

    private static func key(_ siloID: String) -> String {
        AppSession.siloDefaultsKey("mutedConversations", siloID)
    }

    func load(siloID: String) {
        guard loadedSiloID != siloID else { return }
        loadedSiloID = siloID
        ids = Set(UserDefaults.standard.stringArray(forKey: Self.key(siloID)) ?? [])
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String, siloID: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(Array(ids), forKey: Self.key(siloID))
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
    /// When muted, the unread badge is suppressed and a bell-slash is shown.
    var muted = false
    /// Pointer hover (Mac / iPad trackpad). Drives a subtle row tint so the list
    /// feels alive under a mouse; `false` and inert on touch-only iPhone.
    @State private var hovering = false

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
                    if muted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Muted")
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
                    if conversation.unread > 0, !muted {
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
        // Subtle hover highlight for pointer devices (Mac / iPad trackpad). The
        // overlay is transparent until the pointer is over the row; on touch-only
        // iPhone `onHover` never fires, so the row looks exactly as before.
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                .padding(.vertical, -4)
                .padding(.horizontal, -8)
                .allowsHitTesting(false))
        .onHover { hovering = $0 }
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
    /// Shown when the contact simply hasn't joined yet — offer to invite them.
    @State private var offerInvite = false

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
                    if offerInvite {
                        ShareLink(
                            item:
                                "Let's talk privately on PQRC — end-to-end encrypted. Open the app, then add me: \(model.myNpub)"
                        ) {
                            Label("Invite them to PQRC", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Button("Start encrypted conversation") {
                    offerInvite = false
                    Task {
                        do {
                            _ = try await model.runtime.startConversation(
                                npub: npub, firstMessage: firstMessage.isEmpty ? "👋" : firstMessage)
                            dismiss()
                        } catch PQRCError.relayUnreachable {
                            self.error = "Can't reach your relay right now. Check your connection or your relay in Settings — or use Nearby below to connect in person, no server needed."
                        } catch PQRCError.peerKeysNotPublished {
                            self.error = "You're connected, but this contact hasn't opened PQRC on this relay yet, so their keys aren't here to start the encrypted chat. Ask them to open the app on the same relay, then try again — or use Nearby below if you're together."
                            offerInvite = true
                        } catch {
                            self.error = "Couldn't start the conversation. If you're together in person, use Nearby below — no server needed."
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
                Section {
                    if candidates.isEmpty {
                        Text("No contacts yet. Leave this empty to make a private group with just you and your AIs — add people later from the group.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                } header: {
                    Text("Members")
                } footer: {
                    Text("Optional. With no one else selected this is a solo group — just you and your tethered AIs, where they reply to you and to each other. Add people anytime.")
                }
                Button(selected.isEmpty ? "Create solo AI group" : "Create group") {
                    Task {
                        _ = await model.createGroup(name: name, members: Array(selected))
                        dismiss()
                    }
                }
                .disabled(name.isEmpty)
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
