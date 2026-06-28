import PQRCCore
import SwiftUI
import UIKit

/// The message view (APP-SPEC §6.2): bubbles, agent styling, system rows,
/// ai_window banner, thread chips, composer with the large-paste chip.
struct ConversationView: View {
    @Bindable var model: AppModel
    let conversationID: String

    @State private var draftText = ""
    /// Large-paste state: multi-KB content collapses into a chip (APP-SPEC §6.3).
    @State private var largePaste: String?
    /// Markdown/HTML message currently open in the full-screen reader.
    @State private var fullScreenContent: FullScreenContent?
    /// Set while the AI is drafting a response into the composer.
    @State private var aiDrafting = false
    @State private var showThreadSheet = false
    /// When starting a thread from a specific message (long-press), the source
    /// message id to anchor it to; nil for a thread started from the top menu.
    @State private var threadSourceMessageID: String?
    /// Per-message AI-context visibility for the eye badge (C5), recomputed from
    /// the runtime's inspections. Keyed by message id.
    @State private var aiVisibilityByMessage: [String: AIMessageVisibility] = [:]
    @State private var showDetails = false
    /// Multi-select mode for batch "Add to AI Context" (Feature 3).
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// The "AI here" toolbar chip's sheet.
    @State private var showAIHere = false
    /// In-chat contact rename (1:1 only) — tap the title.
    @State private var showRename = false
    @State private var renameText = ""
    /// "Have my AI answer this" → the drafted reply, shown in a DraftSheet. nil = no sheet.
    @State private var answerDraft: String?
    @State private var answerDrafting = false
    /// Read-only summary of the primary AI's effective mode for THIS conversation,
    /// driving the glance chip. Re-read on appear and whenever the override sheet
    /// changes it (it lives in UserDefaults, not @Observable state).
    @State private var aiSummary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)

    /// @-mention autocomplete (feature 6): all candidates for this chat (my AIs +
    /// people + their AIs), and the filtered subset shown for the active @token.
    @State private var allMentionCandidates: [MentionSuggestionList.MentionSuggestion] = []
    @State private var mentionSuggestions: [MentionSuggestionList.MentionSuggestion] = []
    /// My tethered AIs (id, name) for the per-AI context submenu (feature 7).
    @State private var myAIList: [(id: String, name: String)] = []

    private var conversationScope: AIContextGrant.Scope { .conversation(conversationID) }

    /// Whether this conversation is a paired coding-agent node (drives the plan
    /// checklist's visibility). Reads the same local tag the wrench icon uses.
    private var isCodingAgent: Bool {
        model.conversations.first { $0.id == conversationID }?.isCodingAgent ?? false
    }

    private var isGroup: Bool {
        model.conversations.first { $0.id == conversationID }?.isGroup ?? false
    }
    /// Total participants in this group (INCLUDES me). 0/1 ⇒ a solo "My AI" group.
    private var memberCount: Int {
        model.conversations.first { $0.id == conversationID }?.memberCount ?? 0
    }
    /// Group-header subtitle: the participant count. A member-less solo group reads
    /// as "just you + your AI" rather than "1 person".
    private var groupMemberLabel: String {
        memberCount <= 1 ? "Just you · your AI" : "\(memberCount) people"
    }
    private var currentContactName: String {
        model.contactNames[conversationID] ?? "Conversation"
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.safetyCodeChangedFor.contains(conversationID) {
                // Persistent until re-verified (APP-SPEC §6.2).
                Label(
                    "Safety code changed — verify \(model.contactNames[conversationID] ?? "this contact") again before trusting new messages",
                    systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.red)
                .accessibilityIdentifier("safety-change-banner")
            }
            // The live AI-window countdown + context-sharing indicator are
            // isolated into their own view that owns a 1 Hz clock. This keeps
            // the per-second tick from invalidating THIS body (and therefore
            // the message ForEach below) — only the small header re-evaluates
            // each second. It reads the same @Observable model state, so it
            // updates on banner/grant changes exactly as before.
            ConversationStatusHeader(
                model: model, conversationID: conversationID, scope: conversationScope)
            // The paired coding agent's live plan/TODO checklist (Phase D1), shown
            // only for a coding-agent conversation that currently has a plan. It's
            // node→phone status (not a message), so it sits above the transcript and
            // gets the bubbles' reading-width cap so it doesn't sprawl on iPad/Mac.
            if isCodingAgent, let plan = model.acpPlansByConversation[conversationID], !plan.isEmpty {
                ACPPlanView(entries: plan)
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .frame(maxWidth: 760)
            }
            // Phase D4 — a live INTERACTIVE terminal (PTY) the node is running, with its
            // prominent Stop/Kill control. Shown only for a coding-agent conversation while
            // a terminal is live; same reading-width cap so it doesn't sprawl on iPad/Mac.
            if isCodingAgent, let terminal = model.acpTerminalByConversation[conversationID] {
                ACPTerminalView(
                    model: model, conversationID: conversationID, terminal: terminal)
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .frame(maxWidth: 760)
            }
            ConversationAIBar(model: model, conversationID: conversationID) { showAIHere = true }
            threadChips
            messageList
            if selecting { selectionBar } else { composer }
        }
        // Full-width pane: the message bubbles get the reading-width cap (applied
        // on `messageList` itself), but the banners, status header, thread chips,
        // composer, and selection bar span the whole pane — like iMessage, which
        // caps the bubbles, not the input bar. (Previously the 760pt cap wrapped
        // this whole VStack, so on iPad/Mac the composer + banners floated in a
        // centered column with empty gutters; CLAUDE.md responsive roadmap.)
        .frame(maxWidth: .infinity)
        .navigationTitle(model.contactNames[conversationID] ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        // Opaque bar: the title fails the contrast audit over scrolled content.
        .toolbarBackground(.visible, for: .navigationBar)
        .alert("Rename contact", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await model.renameContact(
                        conversationID, nickname: trimmed.isEmpty ? nil : trimmed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This name is local to your device and never shared.")
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitest-bigpaste"), largePaste == nil {
                largePaste = String(repeating: "PQRC large paste demo line.\n", count: 8000)
            }
            aiSummary = model.primaryAIContextSummary(conversationID)
            // Refresh the agent-bubble type badges in case the AI config changed.
            model.refreshAITypes()
            Task { await refreshAIVisibility() }
            Task { await loadMentionCandidates() }
            myAIList = model.tetheredAIList().filter(\.isEnabled).map { ($0.id, $0.name) }
        }
        .onChange(of: model.messages(for: conversationID).count) { _, _ in
            Task { await refreshAIVisibility() }
        }
        .toolbar {
            // Group header: name + participant count, tappable to open the
            // group-aware Details (roster). 1:1 chats keep the plain navigationTitle.
            // Without this there was NO way to see who/how many were in a group.
            if isGroup {
                ToolbarItem(placement: .principal) {
                    Button {
                        showDetails = true
                    } label: {
                        VStack(spacing: 1) {
                            Text(currentContactName)
                                .font(.headline)
                                .lineLimit(1)
                            Text(groupMemberLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("group-header")
                    .accessibilityLabel(
                        "\(currentContactName), \(groupMemberLabel). Opens group details.")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                aiHereChip
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selecting {
                    // In multi-select, a single explicit Done — no crowded bar.
                    Button("Done") {
                        selecting = false
                        selection = []
                    }
                    .accessibilityIdentifier("select-messages-button")
                } else {
                    // One real "•••" menu (the auto-overflow one didn't respond) holding
                    // every conversation action — including the in-chat rename — so the
                    // nav bar stays just the AI:live chip + this menu, not cramped.
                    Menu {
                        if !isGroup {
                            Button {
                                renameText = currentContactName
                                showRename = true
                            } label: {
                                Label("Rename contact", systemImage: "pencil")
                            }
                        }
                        Button {
                            selecting = true
                            selection = []
                        } label: {
                            Label("Select messages", systemImage: "checklist")
                        }
                        .accessibilityIdentifier("select-messages-menu-item")
                        Button {
                            threadSourceMessageID = nil
                            showThreadSheet = true
                        } label: {
                            Label("Start AI thread", systemImage: "text.bubble")
                        }
                        .accessibilityIdentifier("thread-create-button")
                        Button {
                            showDetails = true
                        } label: {
                            Label("Conversation details", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("conversation-details-item")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("conversation-more-menu")
                }
            }
        }
        .sheet(isPresented: $showThreadSheet) {
            ThreadCreateSheet(
                model: model, conversationID: conversationID,
                sourceMessageID: threadSourceMessageID)
        }
        .sheet(isPresented: $showDetails) {
            ConversationDetailsView(model: model, conversationID: conversationID)
        }
        .sheet(isPresented: $showAIHere, onDismiss: {
            // The override lives in UserDefaults; refresh the glance chip on close.
            aiSummary = model.primaryAIContextSummary(conversationID)
            Task { await refreshAIVisibility() }
        }) {
            AIHubSheet(model: model, conversationID: conversationID)
        }
        // "Have my AI answer this" (long-press a guest message) → preview the drafted
        // reply, then "Send as my AI" or "Edit & send as me" — the same DraftSheet the
        // private-draft path uses.
        .sheet(
            isPresented: Binding(
                get: { answerDraft != nil }, set: { if !$0 { answerDraft = nil } })
        ) {
            DraftSheet(model: model, conversationID: conversationID, draft: answerDraft ?? "")
        }
        .fullScreenCover(item: $fullScreenContent) { content in
            FullScreenReaderView(text: content.text)
        }
        .alert(
            "AI couldn't respond",
            isPresented: Binding(
                get: { model.agentError != nil },
                set: { if !$0 { model.agentError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.agentError ?? "")
        }
        // Feature 6 / decision #5: a single @-mention of one of my AIs when it isn't
        // live here — choose draft-privately vs. open-a-window-and-post (never a
        // silent autonomous send to the other people).
        .confirmationDialog(
            "\(model.pendingAIMentionChoice?.aiName ?? "Your AI") isn't live in this chat",
            isPresented: Binding(
                get: { model.pendingAIMentionChoice != nil },
                set: { if !$0 { model.pendingAIMentionChoice = nil } }),
            titleVisibility: .visible
        ) {
            Button("Draft privately") { Task { await model.resolveAIMentionChoice(draft: true) } }
            Button("Open window & post") { Task { await model.resolveAIMentionChoice(draft: false) } }
            Button("Cancel", role: .cancel) { model.pendingAIMentionChoice = nil }
        } message: {
            Text("Draft a reply only you can send, or open a brief AI window for just this AI and let it post in the chat.")
        }
        // "Draft privately" hands the text back to the composer for you to edit + send.
        .onChange(of: model.mentionDraft) { _, draft in
            if let draft {
                if draftText.isEmpty { draftText = draft }
                else { draftText += (draftText.hasSuffix("\n") ? "" : "\n") + draft }
                model.mentionDraft = nil
            }
        }
    }

    /// Toolbar status chip: the AI's EFFECTIVE gather mode for THIS conversation
    /// at a glance, with a firewall glyph when a remote AI is active. Tap opens
    /// the per-conversation override sheet. Reuses the Capsule chip style of
    /// `threadChips` (opaque fill — no `.glassEffect()` over scroll content).
    private var aiHereChip: some View {
        Button {
            showAIHere = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(AIContextVocab.glance(aiSummary))
                // Remote AI: the egress-firewall state is always visible (privacy
                // cardinal rule) — shielded when on, an orange open lock when off.
                // Every chat is E2EE, so the lock is ALWAYS shown (it used to vanish
                // whenever no remote AI was active — the "lost lock"). It sharpens to a
                // shield when a remote AI's egress firewall is on, or an orange OPEN
                // lock when a remote AI is active with the firewall OFF — that downgrade
                // must stay visible (privacy cardinal rule).
                Image(systemName: lockGlyph)
                    .foregroundStyle(lockTint)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // Opaque fill: translucent materials fail the contrast audit under
            // busy content (matches threadChips).
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
        .accessibilityIdentifier("ai-here-chip")
        .accessibilityLabel(
            "AI in this conversation: \(AIContextVocab.glance(aiSummary))"
                + (aiSummary.mode != "off" && aiSummary.isRemote
                    ? (aiSummary.firewallOn ? ", egress firewall on" : ", egress firewall off")
                    : ""))
        // What this chip means, at a glance on Mac (tap opens the same control on
        // iOS). The shield/open-lock glyph reflects the egress firewall for a
        // remote AI — shielded when on, an orange open lock when off.
        .help("What your AI sees in this chat, at a glance. Tap to change it just here. The shield shows the egress firewall is on for a remote AI; an orange open lock means it's off.")
    }

    /// The AI:live lock, ALWAYS present (every chat is E2EE): a plain closed lock by
    /// default, a shield when a remote AI's egress firewall is on, an open lock when a
    /// remote AI is active with the firewall off.
    private var lockGlyph: String {
        guard aiSummary.mode != "off", aiSummary.isRemote else { return "lock" }
        return aiSummary.firewallOn ? "lock.shield" : "lock.open"
    }
    private var lockTint: AnyShapeStyle {
        (aiSummary.mode != "off" && aiSummary.isRemote && !aiSummary.firewallOn)
            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
    }

    private var threadChips: some View {
        Group {
            if let threads = model.threadsByConversation[conversationID], !threads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(threads) { thread in
                            NavigationLink {
                                ThreadView(model: model, thread: thread)
                            } label: {
                                Label(
                                    "✳︎ \(thread.title) · \(thread.messageCount)",
                                    systemImage: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                // Opaque fill: translucent materials fail the
                                // contrast audit under busy content.
                                .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                            .accessibilityLabel("AI thread \(thread.title), \(thread.messageCount) messages")
                            .accessibilityIdentifier("thread-chip-\(thread.title)")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.messages(for: conversationID)) { message in
                        messageRow(message)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("message-list")
            // Hard bottom edge near the composer — soft-blur zones fail the
            // contrast audit (see ThreadView).
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            // Conversations open at the latest message (iMessage behavior).
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages(for: conversationID).count) {
                if let last = model.messages(for: conversationID).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        // Reading-width cap on the BUBBLES only (iMessage caps the bubble column,
        // not the input bar): keep the message list from sprawling edge-to-edge on
        // iPad/Mac/landscape detail panes, centered in the pane. The composer +
        // full-width banners live outside this and still span the whole width.
        // No effect on compact iPhone widths (already < 760).
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func messageRow(_ message: StoredMessage) -> some View {
        let isMine = message.senderIdentity == model.myIdentityHex
        // Party color (APP-SPEC §6.2): an AI's OWNER is its sender identity, so
        // BOTH human and agent messages key off `senderIdentity` — my AIs map to
        // me (the accent), a peer's AI maps to that peer's deterministic color.
        // The agent bubble then renders the matched tint+outline; color is never
        // the sole AI signal (the sparkles glyph + outline always carry it).
        // Backend-type badge (Apple / phone / Mac-Tethered-AI / 🦞 / …) for MY OWN
        // AI bubbles, matching the Settings AI row. nil for a peer's AI.
        let typeBadge = model.aiTypeBadge(agentName: message.agentName, isMine: isMine)
        let bubble = MessageBubble(
            message: message,
            isMine: isMine,
            senderName: model.contactNames[message.senderIdentity] ?? "Contact",
            agentName: message.agentName ?? model.aiNames[message.senderIdentity],
            palette: PartyColor.palette(forIdentity: message.senderIdentity, isSelf: isMine),
            typeSymbol: typeBadge?.symbol,
            typeGlyph: typeBadge?.glyph,
            onToggleAIContext: selecting
                ? nil
                : {
                    Task {
                        await model.markAIContext(
                            messageIDs: [message.id], value: !message.aiContext,
                            conversationID: conversationID)
                        await refreshAIVisibility()
                    }
                },
            onFullScreen: selecting ? nil : { fullScreenContent = FullScreenContent(text: $0) },
            onRetry: selecting ? nil : { Task { await model.retry(message) } },
            // Guest messages only: have my AI draft a reply to THIS message → a preview
            // sheet (Send as my AI / Edit & send as me). User-initiated, so no ai_window
            // is needed (the §13 gate stops UNBIDDEN agent sends; this is bidden).
            onAnswerWithAI: (selecting || isMine || message.participantType == .agent)
                ? nil
                : {
                    guard !answerDrafting else { return }
                    answerDrafting = true
                    Task {
                        let text = await model.draft(
                            conversationID: conversationID, focus: message.text)
                        answerDrafting = false
                        if let text { answerDraft = text }
                    }
                },
            // Start a focused AI thread anchored to this message (long-press).
            onStartThread: selecting
                ? nil
                : {
                    threadSourceMessageID = message.id
                    showThreadSheet = true
                },
            // Per-AI context submenu (feature 7): add/remove THIS message from a
            // specific one of my AIs' context. (Declared before `aiVisibility`, so it
            // must precede it here.)
            myAIs: selecting ? [] : myAIList,
            onMarkForAI: selecting
                ? nil
                : { aiID, value in
                    Task {
                        await model.markAIContext(
                            messageIDs: [message.id], aiID: aiID, value: value)
                        await refreshAIVisibility()
                    }
                },
            aiVisibility: aiVisibilityByMessage[message.id],
            // Strip the AgentSkills ⟡⟡ envelope from agent bubbles unless the
            // per-silo "Show agent protocol envelope" toggle is on (default off).
            // Display-only — the stored record keeps the raw bytes (§23).
            showEnvelope: AppSession.showAgentEnvelope(siloID: model.siloID))
        if selecting {
            HStack(spacing: 8) {
                Image(systemName: selection.contains(message.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(message.id) ? .purple : .secondary)
                bubble
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selection.contains(message.id) { selection.remove(message.id) } else {
                    selection.insert(message.id)
                }
            }
        } else {
            bubble
        }
    }

    /// Recompute per-message AI-context visibility (C5) from the runtime's
    /// inspections — once per call (expensive), cached in `aiVisibilityByMessage`.
    /// A message is "seen" by an AI when that AI's inspection includes its id; a
    /// firewalled remote AI marks the entry redacted.
    private func refreshAIVisibility() async {
        let inspections = await model.contextInspections(conversationID: conversationID)
        var map: [String: AIMessageVisibility] = [:]
        for insp in inspections {
            let redactedHere = insp.isRemote && insp.firewallOn
            for entry in insp.entries {
                let prev = map[entry.id]
                map[entry.id] = AIMessageVisibility(
                    count: (prev?.count ?? 0) + 1,
                    redacted: (prev?.redacted ?? false) || redactedHere)
            }
        }
        aiVisibilityByMessage = map
    }

    /// Bottom action bar shown while multi-selecting.
    private var selectionBar: some View {
        HStack {
            Button("Cancel") {
                selecting = false
                selection = []
            }
            Spacer()
            Button {
                let ids = Array(selection)
                Task {
                    await model.markAIContext(messageIDs: ids, value: true, conversationID: conversationID)
                }
                selecting = false
                selection = []
            } label: {
                Label("Add \(selection.count) to AI Context", systemImage: "brain")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Send whatever's in the composer (a large paste or the typed text), then clear it.
    /// Factored out so the Send button and the macOS Return key share one path.
    private func sendCurrent() {
        let outgoing = largePaste ?? draftText
        guard !outgoing.isEmpty else { return }
        largePaste = nil
        draftText = ""
        mentionSuggestions = []
        Task { await model.send(outgoing, conversationID: conversationID) }
    }

    // MARK: @-mention autocomplete (feature 6)

    /// The trailing "@token" the user is composing, if any (the @ must start the text
    /// or follow whitespace, and only token chars may follow it to the end).
    private func activeMentionRange(_ text: String) -> (range: Range<String.Index>, query: String)? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let after = text[text.index(after: atIndex)...]
        guard after.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        if atIndex > text.startIndex {
            guard text[text.index(before: atIndex)].isWhitespace else { return nil }
        }
        return (atIndex..<text.endIndex, String(after))
    }

    private func updateMentionSuggestions(_ text: String) {
        guard let (_, query) = activeMentionRange(text) else {
            mentionSuggestions = []
            return
        }
        let q = query.lowercased()
        mentionSuggestions = Array(
            allMentionCandidates
                .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
                .prefix(8))
    }

    private func applyMention(_ pick: MentionSuggestionList.MentionSuggestion) {
        if let (range, _) = activeMentionRange(draftText) {
            draftText.replaceSubrange(range, with: "@\(pick.name) ")
        }
        mentionSuggestions = []
    }

    private func loadMentionCandidates() async {
        allMentionCandidates = await model.mentionCandidates(conversationID: conversationID)
            .map { MentionSuggestionList.MentionSuggestion(name: $0.name, kind: $0.kind) }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            MentionSuggestionList(suggestions: mentionSuggestions) { applyMention($0) }
            if let paste = largePaste {
                // The chip: the field never visibly chokes on a 200 KB paste.
                // Large text rides the relay as ordered, ratcheted chunks
                // (reassembled on the far side); smaller pastes go in a single
                // padded envelope. Either way it's end-to-end encrypted text —
                // no blob server involved.
                HStack {
                    Label(
                        paste.utf8.count > PQRCConstants.maxChunkTextBytes
                            ? "Large text · \(paste.utf8.count / 1024) KB · sends in encrypted chunks"
                            : "Large text · \(paste.utf8.count / 1024) KB · sends padded inline",
                        systemImage: "doc.zipper")
                    .font(.caption)
                    .lineLimit(1)
                    Spacer()
                    Button {
                        largePaste = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Remove large text attachment")
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("large-paste-chip")
            }
            HStack(alignment: .bottom, spacing: 8) {
                // Draft with AI: pulls the conversation + your "AI context"
                // messages and drops an editable reply into the box (not sent).
                Button {
                    draftWithAI()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(aiDrafting ? AnyShapeStyle(.secondary) : AnyShapeStyle(.purple))
                        .overlay { if aiDrafting { ProgressView().controlSize(.small) } }
                }
                .frame(minWidth: 40, minHeight: 44)
                .disabled(aiDrafting)
                .accessibilityLabel("Draft with AI")
                .accessibilityIdentifier("composer-draft-ai")
                TextField("Message", text: $draftText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityIdentifier("composer-field")
                    .onChange(of: draftText) { oldValue, newValue in
                        // Collapse big PASTES into the chip — detected as a large
                        // jump in a single change — so the keyboard's QuickType
                        // engine doesn't thrash on a big block left live in the
                        // field. Gradual typing never triggers this, so a long
                        // message you're writing is never ejected mid-sentence.
                        // A very large total is a backstop for incremental paste.
                        let delta = newValue.utf8.count - oldValue.utf8.count
                        if delta > 4096 || newValue.utf8.count > 16384 {
                            largePaste = newValue
                            draftText = ""
                        }
                        updateMentionSuggestions(draftText)
                    }
                    // Long-press the empty box: "Draft with AI" beside Paste.
                    .contextMenu {
                        Button {
                            if let clip = UIPasteboard.general.string { insertIntoComposer(clip) }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                        Button {
                            draftWithAI()
                        } label: {
                            Label("Draft with AI", systemImage: "sparkles")
                        }
                        .disabled(aiDrafting)
                    }
                    #if os(macOS) || targetEnvironment(macCatalyst)
                        // Mac: Return sends, Shift+Return inserts a newline for multi-line
                        // blocks. (The all-keys overload — `.onKeyPress(.return)` doesn't
                        // surface the press for a TextField.) iOS/iPadOS are untouched.
                        .onKeyPress { press in
                            guard press.key == .return, !press.modifiers.contains(.shift)
                            else { return .ignored }
                            sendCurrent()
                            return .handled
                        }
                    #endif
                Button {
                    sendCurrent()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(draftText.isEmpty && largePaste == nil)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("composer-send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Ask the AI to draft a reply from the conversation + "AI context" messages
    /// and inject it into the composer (editable, NOT sent). Errors surface via
    /// the existing `agentError` alert.
    private enum DraftOutcome { case text(String), failed, timedOut }

    private func draftWithAI() {
        guard !aiDrafting else { return }
        aiDrafting = true
        Task {
            // Race the draft against a timeout so the button can't spin forever
            // (a wedged provider / network would otherwise leave it stuck).
            let outcome = await withTaskGroup(of: DraftOutcome.self) { group -> DraftOutcome in
                group.addTask {
                    if let text = await model.draft(conversationID: conversationID) {
                        return .text(text)
                    }
                    return .failed  // model.draft already set agentError
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(25))
                    return .timedOut
                }
                let first = await group.next() ?? .failed
                group.cancelAll()
                return first
            }
            aiDrafting = false
            switch outcome {
            case .text(let drafted): insertIntoComposer(drafted)
            case .failed: break  // the agentError alert already explains why
            case .timedOut:
                model.agentError =
                    "The AI took too long to respond. Check your connection or your AI provider in Settings, then try again."
            }
        }
    }

    /// Appends text to the composer without clobbering what's already typed.
    private func insertIntoComposer(_ text: String) {
        if draftText.isEmpty {
            draftText = text
        } else {
            draftText += (draftText.hasSuffix("\n") ? "" : "\n") + text
        }
    }
}

/// Isolated 1 Hz status strip for a conversation: the active AI-window banner
/// (with its live mm:ss countdown) and the "AI context sharing is on" label.
/// It owns its OWN `now` clock so the per-second tick re-evaluates only this
/// small view — NOT `ConversationView.body`, and therefore not the message
/// `ForEach`/`ScrollView` (the cause of the per-second full re-render). Reads
/// the same `@Observable` model state the parent did, so banner/grant changes
/// still flow through immediately; only the tick is scoped here.
private struct ConversationStatusHeader: View {
    let model: AppModel
    let conversationID: String
    let scope: AIContextGrant.Scope
    @State private var now = Int64(Date().timeIntervalSince1970)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let summary = model.primaryAIContextSummary(conversationID)
        VStack(spacing: 0) {
            if let banner = model.activeWindowBanner(conversationID: conversationID, now: now) {
                AIWindowBanner(name: banner.name, until: banner.until, now: now)
            }
            if model.iGrantedContext(scope: scope, now: now) {
                Label("AI context sharing is on", systemImage: "brain.head.profile")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    // OPAQUE tint, not `Color.purple.opacity(0.12)`: the accessibility
                    // contrast auditor hard-fails a full-width label over a translucent
                    // fill because it can't determine the effective background. The mix is
                    // the same 12%-purple look but opaque, so contrast is computable and
                    // it adapts to light/dark (DEVIATIONS A7 / build-conventions).
                    .background(Color.purple.mix(with: Color(.systemBackground), by: 0.88))
                    .accessibilityIdentifier("context-sharing-banner")
            }
            // Egress-firewall state for this chat. Shown only when a REMOTE AI is here —
            // the only time the firewall does anything (on-device AI never leaves the
            // device). ON is the calm, protected state; OFF is a LOUD warning that real
            // names + full context leave the device unredacted (privacy cardinal rule:
            // the downgrade must stay visible). Opaque tint so the contrast auditor can
            // resolve it (A7).
            if summary.mode != "off", summary.isRemote {
                Label(
                    summary.firewallOn
                        ? "Egress firewall on — names & secrets redacted before this chat reaches your cloud AI"
                        : "Egress firewall OFF — real names & full context leave your device",
                    systemImage: summary.firewallOn ? "lock.shield" : "lock.open")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        summary.firewallOn
                            ? Color.green.mix(with: Color(.systemBackground), by: 0.86)
                            : Color.orange.mix(with: Color(.systemBackground), by: 0.78))
                    .accessibilityIdentifier("conversation-firewall-status")
                    .accessibilityLabel(
                        summary.firewallOn
                            ? "Egress firewall on for this conversation"
                            : "Warning: egress firewall off — full context leaves your device")
            }
        }
        .onReceive(ticker) { _ in
            now = Int64(Date().timeIntervalSince1970)
        }
    }
}

/// "AI is present" reads as a distinct material (APP-SPEC §11).
struct AIWindowBanner: View {
    let name: String
    let until: Int64
    let now: Int64

    var body: some View {
        let remaining = max(0, until - now)
        Label(
            "\(name)'s AI is active · \(remaining / 60)m \(remaining % 60)s left",
            systemImage: "sparkles")
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .glassEffect()
        .accessibilityIdentifier("ai-window-banner")
        .accessibilityLabel("\(name)'s AI is active for \(remaining / 60) more minutes")
    }
}

/// AI draft preview: "Send as my AI" (agent-signed + labeled) or
/// "Edit & send as me" (human message, human-signed) — APP-SPEC §9.
struct DraftSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    @State var draft: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Made with you and your AI", systemImage: "sparkles")
                        .font(.headline)
                    Text("Your AI drafted this from your conversation. Review or edit it, then send as your AI — it'll show as made with you and your AI for everyone in the chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $draft)
                    .frame(minHeight: 120)
                    .padding(4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("draft-editor")
                Button {
                    Task {
                        await model.sendAsAI(draft, conversationID: conversationID)
                        dismiss()
                    }
                } label: {
                    Label("Send as my AI", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("send-as-ai")
                Button {
                    Task {
                        await model.send(draft, conversationID: conversationID)
                        dismiss()
                    }
                } label: {
                    Text("Edit & send as me")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("send-as-me")
                Spacer()
            }
            .padding()
            .navigationTitle("AI Draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ThreadCreateSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    /// Optional source message to anchor the thread to (long-press "Start a thread
    /// from here"); nil when started from the conversation menu.
    var sourceMessageID: String? = nil
    @State private var title = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Thread title", text: $title)
                        .accessibilityIdentifier("thread-title")
                    Button("Create AI thread") {
                        Task {
                            _ = await model.createThread(
                                conversationID: conversationID, title: title,
                                anchorMessageID: sourceMessageID)
                            dismiss()
                        }
                    }
                    .disabled(title.isEmpty)
                    .accessibilityIdentifier("thread-create-confirm")
                } footer: {
                    Text("A thread is a focused space where each person's AI can be invited to collaborate for a set time. Everything the AIs say is recorded right here, and they pause after a few back-to-back turns until a human speaks.")
                }
            }
            .navigationTitle("New AI Thread")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Mode for the "My AI responds" control: drafts privately (default,
/// privacy-first — nothing posted, no context shared) vs responds in chat as the
/// signed agent for a bounded window (announces an active window + shares context).
enum AIRespondsMode: Hashable { case draftsPrivately, respondsInChat }

