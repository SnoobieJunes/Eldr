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
    @State private var aiDraft: String?
    @State private var showDraftSheet = false
    @State private var showWindowPicker = false
    @State private var showThreadSheet = false
    @State private var showDetails = false
    /// Multi-select mode for batch "Add to AI Context" (Feature 3).
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// The "AI here" toolbar chip's sheet.
    @State private var showAIHere = false
    /// Read-only summary of the primary AI's effective mode for THIS conversation,
    /// driving the glance chip. Re-read on appear and whenever the override sheet
    /// changes it (it lives in UserDefaults, not @Observable state).
    @State private var aiSummary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)

    private var conversationScope: AIContextGrant.Scope { .conversation(conversationID) }

    /// Whether this conversation is a paired coding-agent node (drives the plan
    /// checklist's visibility). Reads the same local tag the wrench icon uses.
    private var isCodingAgent: Bool {
        model.conversations.first { $0.id == conversationID }?.isCodingAgent ?? false
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
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--uitest-bigpaste"), largePaste == nil {
                largePaste = String(repeating: "PQRC large paste demo line.\n", count: 8000)
            }
            aiSummary = model.primaryAIContextSummary(conversationID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                aiHereChip
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    selecting.toggle()
                    selection = []
                } label: {
                    Image(systemName: selecting ? "checkmark.circle" : "checklist")
                }
                .accessibilityLabel(selecting ? "Done selecting" : "Select messages")
                .accessibilityIdentifier("select-messages-button")
                .help("Select several messages at once to add them to your AI's context.")
                Button {
                    showThreadSheet = true
                } label: {
                    Image(systemName: "text.bubble")
                }
                .accessibilityLabel("Start AI thread")
                .accessibilityIdentifier("thread-create-button")
                .help("Start a thread where each person's AI can join and collaborate — everything they say is recorded right there.")
                Button {
                    showWindowPicker = true
                } label: {
                    Image(systemName: "sparkles")
                }
                .accessibilityLabel("AI options")
                .accessibilityIdentifier("ai-window-button")
                .help("AI options: draft a reply privately, turn your AI on for everyone for a set time, or share AI context.")
                Button {
                    showDetails = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .accessibilityLabel("Conversation details")
                .help("Verify this contact's safety code, set a local name, control AI here, or block.")
            }
        }
        .confirmationDialog("Always-on AI", isPresented: $showWindowPicker) {
            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                Button("My AI responds for \(minutes) min") {
                    Task { await model.startWindow(conversationID: conversationID, minutes: minutes) }
                }
            }
            Button("Draft a reply privately") {
                Task {
                    aiDraft = await model.draft(conversationID: conversationID)
                    showDraftSheet = aiDraft != nil
                }
            }
            // One-shot read at presentation time (no per-second tick needed in
            // this body): the grant's live/expired state when the sheet opens.
            if model.iGrantedContext(
                scope: conversationScope, now: Int64(Date().timeIntervalSince1970))
            {
                Button("Stop sharing AI context", role: .destructive) {
                    Task { await model.withdrawContextSharing(scope: conversationScope) }
                }
            } else {
                Button("Share AI context (30 min)") {
                    Task {
                        await model.grantContextSharing(
                            scope: conversationScope, minutes: 30, conversationID: conversationID)
                    }
                }
            }
        } message: {
            Text("Everyone in the conversation will see that your AI is active.")
        }
        .sheet(isPresented: $showDraftSheet) {
            DraftSheet(model: model, conversationID: conversationID, draft: aiDraft ?? "")
        }
        .sheet(isPresented: $showThreadSheet) {
            ThreadCreateSheet(model: model, conversationID: conversationID)
        }
        .sheet(isPresented: $showDetails) {
            ConversationDetailsView(model: model, conversationID: conversationID)
        }
        .sheet(isPresented: $showAIHere, onDismiss: {
            // The override lives in UserDefaults; refresh the glance chip on close.
            aiSummary = model.primaryAIContextSummary(conversationID)
        }) {
            AIHereSheet(model: model, conversationID: conversationID)
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
                if aiSummary.mode != "off" && aiSummary.isRemote {
                    Image(systemName: aiSummary.firewallOn ? "lock.shield" : "lock.open")
                        .foregroundStyle(aiSummary.firewallOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
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
        let bubble = MessageBubble(
            message: message,
            isMine: isMine,
            senderName: model.contactNames[message.senderIdentity] ?? "Contact",
            agentName: message.agentName ?? model.aiNames[message.senderIdentity],
            palette: PartyColor.palette(forIdentity: message.senderIdentity, isSelf: isMine),
            onToggleAIContext: selecting
                ? nil
                : {
                    Task {
                        await model.markAIContext(
                            messageIDs: [message.id], value: !message.aiContext,
                            conversationID: conversationID)
                    }
                },
            onFullScreen: selecting ? nil : { fullScreenContent = FullScreenContent(text: $0) },
            onRetry: selecting ? nil : { Task { await model.retry(message) } },
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

    private var composer: some View {
        VStack(spacing: 6) {
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
                Button {
                    let outgoing = largePaste ?? draftText
                    largePaste = nil
                    draftText = ""
                    Task { await model.send(outgoing, conversationID: conversationID) }
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
        VStack(spacing: 0) {
            if let banner = model.activeWindowBanner(conversationID: conversationID, now: now) {
                AIWindowBanner(name: banner.name, until: banner.until, now: now)
            }
            if model.iGrantedContext(scope: scope, now: now) {
                Label("AI context sharing is on", systemImage: "brain.head.profile")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.purple.opacity(0.12))
                    .accessibilityIdentifier("context-sharing-banner")
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
                Label("Draft from your AI", systemImage: "sparkles")
                    .font(.headline)
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
                            _ = await model.createThread(conversationID: conversationID, title: title)
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

/// Tap-target of the in-chat "AI here" chip: the per-conversation AI context
/// override, surfaced in the chat itself (the SAME control as
/// ConversationDetailsView's "AI context here"). Writes/reads the SAME
/// `AppSession.conversationContextMode`, so chip · this sheet · Details stay in
/// sync, and the engine reads it every turn (changes apply in real time).
struct AIHereSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    /// "default" | "off" | "marked" | "full".
    @State private var aiContextMode = "default"
    @State private var summary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)

    var body: some View {
        NavigationStack {
            Form {
                Section {
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
                    AIContextEcho(summary: summary)
                    if summary.mode != "off" && summary.isRemote {
                        RemoteAIFirewallRow(firewallOn: summary.firewallOn)
                    }
                } header: {
                    Text("AI in this conversation — overrides your AI's default (now: \(AIContextVocab.glance(summary)))")
                } footer: {
                    Text("Overrides your AIs' own context setting, just here. \"Off\" keeps every AI from gathering anything from this conversation. Applies in real time. Set per-AI defaults and the egress firewall in Settings ▸ AI.")
                }
            }
            .navigationTitle("AI here")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                aiContextMode =
                    AppSession.conversationContextMode(conversationID, siloID: model.siloID) ?? "default"
                summary = model.primaryAIContextSummary(conversationID)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
