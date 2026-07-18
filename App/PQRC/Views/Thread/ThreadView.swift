import PQRCAgent
import PQRCCore
import SwiftUI
import UIKit

/// Full-screen embedded AI thread (APP-SPEC §8): pinned header with live AI
/// status per human, invite/withdraw control with bounded durations, loop
/// guard state, and the recorded agent exchange.
struct ThreadView: View {
    @Bindable var model: AppModel
    let thread: ThreadVM

    @State private var draftText = ""
    @State private var showInvitePicker = false
    @State private var showSkills = false
    @State private var showTurnLimit = false
    @State private var pinnedSkillCount = 0
    /// C6: true when this is a "My AI" per-AI sub-thread — hides the invite/countdown.
    @State private var isSoloThread = false
    /// Off by default (user request): when on, the header shows a small live
    /// counter of how many AI replies have run in a row. Replaces the removed
    /// auto-pause — informational only, never stops the thread. Per-silo+thread.
    @State private var showCounter = false
    /// Markdown/HTML message currently open in the full-screen reader.
    @State private var fullScreenContent: FullScreenContent?

    var body: some View {
        VStack(spacing: 0) {
            // The header carries the live per-AI invite countdowns; it owns its
            // own 1 Hz clock (ThreadHeader) so the per-second tick re-evaluates
            // only the header — NOT this body, and therefore not the thread
            // message `ForEach`/`ScrollView` below.
            ThreadHeader(
                model: model, thread: thread,
                showInvitePicker: $showInvitePicker, showCounter: showCounter,
                isSoloThread: isSoloThread)
            messageList
                // Composer as a bottom safe-area inset (not a VStack sibling): the
                // anchored scroll keeps the last bubble above it instead of being
                // occluded in place (which also reads as a contrast-audit failure, A7).
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composer
                }
        }
        .navigationTitle("✳︎ \(thread.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // AI-turn counter toggle (off by default). AI threads don't
                // auto-pause; this lets a human opt THIS thread into a live tally
                // of AI replies-in-a-row for situational awareness.
                Button {
                    showCounter.toggle()
                    AppSession.setShowThreadCounter(
                        showCounter, threadID: thread.id, siloID: model.siloID)
                } label: {
                    Label(
                        showCounter ? "Hide AI turn counter" : "Show AI turn counter",
                        systemImage: showCounter ? "number.square.fill" : "number.square")
                }
                .accessibilityIdentifier("thread-counter-toggle")
                .help("Show a live count of how many AI replies have run in a row in this thread. AI threads no longer pause on their own — this is just so you can keep an eye on a long AI exchange.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSkills = true
                } label: {
                    Label(
                        pinnedSkillCount == 0 ? "Skills" : "Skills · \(pinnedSkillCount)",
                        systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("thread-skills")
                .help("Pin shared skills — a common vocabulary (plan-sync, tech-spec, code-debug…) so each person's AI can hand off work the other can act on, instead of free-form chatter.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTurnLimit = true
                } label: {
                    Label("AI turn limit", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .accessibilityIdentifier("thread-turn-limit")
                .help("Cap how many AI replies can run in a row in this thread before it pauses for a human. 0 = unlimited; default 50.")
            }
        }
        .sheet(isPresented: $showTurnLimit) {
            ThreadTurnLimitView(model: model, threadID: thread.id)
        }
        .sheet(isPresented: $showSkills) {
            ThreadSkillsView(threadID: thread.id, siloID: model.siloID)
                .onDisappear {
                    pinnedSkillCount = AppSession.threadSkills(thread.id, siloID: model.siloID).count
                }
        }
        .task {
            pinnedSkillCount = AppSession.threadSkills(thread.id, siloID: model.siloID).count
            showCounter = AppSession.showThreadCounter(thread.id, siloID: model.siloID)
            isSoloThread = await model.isSoloThread(thread.id)
        }
        .fullScreenCover(item: $fullScreenContent) { content in
            FullScreenReaderView(text: content.text)
        }
        .confirmationDialog("Invite my AI", isPresented: $showInvitePicker) {
            ForEach([15, 30, 60, 120], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    Task { await model.inviteAI(threadID: thread.id, minutes: minutes) }
                }
            }
        } message: {
            Text("Your AI will converse in this thread only. Everything it says or shares is recorded here.")
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.threadMessages(thread.id, conversationID: thread.conversationID)) { message in
                        MessageBubble(
                            message: message,
                            isMine: message.senderIdentity == model.myIdentityHex,
                            senderName: model.contactNames[message.senderIdentity] ?? "Contact",
                            agentName: message.agentName ?? model.aiNames[message.senderIdentity],
                            // Same audited party palette as ConversationView. The
                            // nil-palette purple/accent fallback fails the WCAG
                            // contrast audit (white on the accent gradient for my
                            // own bubbles), so threads color by party too.
                            palette: PartyColor.palette(
                                forIdentity: message.senderIdentity,
                                isSelf: message.senderIdentity == model.myIdentityHex),
                            typeSymbol: model.aiTypeBadge(
                                agentName: message.agentName,
                                isMine: message.senderIdentity == model.myIdentityHex)?.symbol,
                            typeGlyph: model.aiTypeBadge(
                                agentName: message.agentName,
                                isMine: message.senderIdentity == model.myIdentityHex)?.glyph,
                            onToggleAIContext: {
                                Task {
                                    await model.markAIContext(
                                        messageIDs: [message.id], value: !message.aiContext,
                                        conversationID: thread.conversationID)
                                }
                            },
                            onFullScreen: { fullScreenContent = FullScreenContent(text: $0) },
                            onRetry: { Task { await model.retry(message) } },
                            // "Bring the answer back" (D4): copy this thread message
                            // into the parent conversation as a co-authored message.
                            onPromoteToMain: {
                                Task { await model.promoteThreadMessage(messageID: message.id) }
                            },
                            myAIs: model.tetheredAIList().filter(\.isEnabled).map { ($0.id, $0.name) },
                            onMarkForAI: { aiID, value in
                                Task {
                                    await model.markAIContext(
                                        messageIDs: [message.id], aiID: aiID, value: value)
                                }
                            },
                            // Strip the AgentSkills ⟡⟡ envelope from agent bubbles
                            // unless the per-silo "Show agent protocol envelope"
                            // toggle is on (default off). Display-only — the
                            // stored record keeps the raw bytes (§23). Thread
                            // bubbles are where the envelope shows up most.
                            showEnvelope: AppSession.showAgentEnvelope(siloID: model.siloID))
                    }
                }
                .padding()
            }
            // Explicit scroll-to-last (same as ConversationView): the lazy
            // stack's estimated height defeats defaultScrollAnchor alone, and
            // a last bubble left under the loop-guard band also reads as a
            // contrast-audit failure (A7).
            .onAppear {
                if let last = model.threadMessages(thread.id, conversationID: thread.conversationID).last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: model.threadMessages(thread.id, conversationID: thread.conversationID).count) {
                if let last = model.threadMessages(thread.id, conversationID: thread.conversationID).last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        // Hard bottom edge: the soft scroll-edge blur leaves bubbles near the
        // loop-guard/composer bars without a determinable background, which
        // the contrast auditor hard-fails (A7).
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        // Open at the latest message (same as conversations, A8). Also
        // audit-load-bearing: an unanchored list can leave the last bubble
        // clipped mid-text under the loop-guard band, which reads as a
        // contrast failure.
        .defaultScrollAnchor(.bottom)
        .accessibilityIdentifier("thread-message-list")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message the thread", text: $draftText, axis: .vertical)
                .lineLimit(1...4)
                // Same treatment as the main composer — the bare rounded-border
                // field measures under the 44 pt minimum hit target and hard-fails
                // the accessibility audit.
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("thread-composer-field")
                // Explicit Paste for iPad/Mac (right-click / long-press) — the
                // main composer has the same affordance.
                .contextMenu {
                    Button {
                        if let clip = UIPasteboard.general.string { draftText += clip }
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                    }
                }
                #if os(macOS) || targetEnvironment(macCatalyst)
                    // Mac: Return sends, Shift+Return inserts a newline (matches the
                    // main composer + the terminal stdin).
                    .onKeyPress { press in
                        guard press.key == .return, !press.modifiers.contains(.shift),
                            !draftText.isEmpty
                        else { return .ignored }
                        let text = draftText
                        draftText = ""
                        Task {
                            await model.send(
                                text, conversationID: thread.conversationID, threadID: thread.id)
                        }
                        return .handled
                    }
                #endif
            Button {
                let text = draftText
                draftText = ""
                Task {
                    await model.send(text, conversationID: thread.conversationID, threadID: thread.id)
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(draftText.isEmpty)
            .accessibilityLabel("Send to thread")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Pinned thread header (APP-SPEC §8): live per-human AI-invite status with a
/// per-minute countdown, the invite/withdraw control, and the context-sharing
/// control. Isolated from `ThreadView` so its OWN 1 Hz clock (`now`) re-renders
/// only this card on each tick — never the parent body or the thread message
/// `ForEach`. Reads the same `@Observable` model state as before; `now` only
/// affects which invites are still "active" and the displayed minutes, so the
/// visible content is identical to the inline version.
/// Per-thread "max AI turns" editor (plan C1): how many AI replies may run in a
/// row before the thread pauses for a human. 0 = unlimited; default 50.
struct ThreadTurnLimitView: View {
    @Bindable var model: AppModel
    let threadID: String
    @State private var limitText = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Max AI turns", text: $limitText)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("thread-turn-limit-field")
                } footer: {
                    Text("How many AI replies can run in a row in this thread before it pauses for a human turn. Enter 0–9999; 0 = unlimited. Default 50.")
                }
            }
            .navigationTitle("AI turn limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = max(
                            0, min(9999, Int(limitText) ?? AppSession.defaultThreadLoopGuardLimit))
                        Task { await model.setThreadLoopGuardLimit(value, threadID: threadID) }
                        dismiss()
                    }
                    .accessibilityIdentifier("thread-turn-limit-save")
                }
            }
            .task {
                limitText = String(AppSession.threadLoopGuardLimit(threadID, siloID: model.siloID))
            }
        }
        .presentationDetents([.medium])
    }
}

private struct ThreadHeader: View {
    let model: AppModel
    let thread: ThreadVM
    @Binding var showInvitePicker: Bool
    /// Off by default (user request). When on, shows the AI-replies-in-a-row tally.
    var showCounter: Bool = false
    /// C6: a My-AI per-AI sub-thread — hide the invite/withdraw/context controls and
    /// the per-AI countdown (the pinned AI is always on; there's no peer or timer).
    var isSoloThread: Bool = false
    @State private var now = Int64(Date().timeIntervalSince1970)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var myInviteUntil: Int64? {
        guard let until = model.aiInvites[thread.id]?[model.myIdentityHex], until > now else {
            return nil
        }
        return until
    }

    private var threadScope: AIContextGrant.Scope { .thread(thread.id) }

    /// How many AI replies have run consecutively since the last human message —
    /// the run length the removed auto-pause used to cap. Counts every party's AI
    /// (resets on any human message), computed from the visible thread so it needs
    /// no engine round-trip and updates as messages arrive.
    private var aiTurnsInARow: Int {
        var n = 0
        for message in model.threadMessages(thread.id, conversationID: thread.conversationID).reversed() {
            guard message.participantType == .agent else { break }
            n += 1
        }
        return n
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showCounter {
                let n = aiTurnsInARow
                Label(
                    "\(n) AI repl\(n == 1 ? "y" : "ies") in a row",
                    systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("thread-counter")
                .accessibilityLabel(
                    "\(n) AI repl\(n == 1 ? "y" : "ies") in a row since the last person spoke")
            }
            if !isSoloThread {
            ForEach(Array((model.aiInvites[thread.id] ?? [:]).keys.sorted()), id: \.self) { identityHex in
                if let until = model.aiInvites[thread.id]?[identityHex], until > now {
                    Label(
                        "\(model.contactNames[identityHex] ?? "Contact")'s AI active · \((until - now) / 60)m left",
                        systemImage: "sparkles")
                    .font(.caption)
                    .accessibilityIdentifier("thread-ai-status")
                }
            }
            HStack {
                if myInviteUntil != nil {
                    Button("Withdraw my AI") {
                        Task { await model.withdrawAI(threadID: thread.id) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("withdraw-ai")
                } else {
                    Button {
                        showInvitePicker = true
                    } label: {
                        Label("Invite my AI", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("invite-ai")
                    .help("Let your AI converse in this thread for a set time. Everything it says is recorded here; it can never join on its own.")
                }
                if model.iGrantedContext(scope: threadScope, now: now) {
                    Button("Stop sharing context") {
                        Task { await model.withdrawContextSharing(scope: threadScope) }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("withdraw-context")
                } else {
                    Button {
                        Task {
                            await model.grantContextSharing(
                                scope: threadScope, minutes: 30,
                                conversationID: thread.conversationID, threadID: thread.id)
                        }
                    } label: {
                        Label("Share context", systemImage: "brain")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("grant-context")
                }
            }
            }  // end if !isSoloThread (C6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        // Opaque card, not .glassEffect(): the glass shadow/blur spills over
        // the first scroll rows and leaves the contrast auditor with an
        // indeterminate background for anything near it (A7).
        .background(Color(.secondarySystemGroupedBackground))
        .onReceive(ticker) { _ in
            now = Int64(Date().timeIntervalSince1970)
        }
    }
}

/// Pin agent-to-agent **skills** to a thread (docs/eldrchat-agent-skills.md):
/// a shared vocabulary so two people's AIs hand off work cleanly. Pinned skills
/// are appended to every AI's thread-turn prompt; the AIs use whichever fits.
/// The picker shows the 20 fixed built-ins (`AgentSkills.catalog`, the package's
/// source of truth) plus this account's custom skills (the app-layer overlay,
/// `AppSession.loadCustomSkills`) — both pin and inject identically.
struct ThreadSkillsView: View {
    let threadID: String
    /// The unlocked silo, so pinned skills AND custom skills are stored per-account (A33).
    let siloID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var customSkills: [CustomSkill] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Pin shared **skills** for this thread — a common vocabulary (plan-sync, tech-spec, code-debug, context-export, …) so each person's AI can hand off work the other can parse and act on. Every AI in the thread already follows the same scope, context-boundary, and recording rules; skills add the format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !customSkills.isEmpty {
                    Section("Your custom skills") {
                        ForEach(customSkills) { skill in
                            skillRow(skill.asAgentSkill)
                        }
                    }
                }

                Section(customSkills.isEmpty ? "Skills" : "Built-in skills") {
                    ForEach(AgentSkills.catalog) { skill in
                        skillRow(skill)
                    }
                }

                Section {
                    NavigationLink {
                        CustomSkillsManagerView(siloID: siloID) {
                            customSkills = AppSession.loadCustomSkills(siloID: siloID)
                        }
                    } label: {
                        Label("Manage custom skills + export", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("manage-custom-skills")
                } footer: {
                    Text("Create your own handoff formats, or export the whole catalog (built-in + custom) to share.")
                }
            }
            .navigationTitle("Thread skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                selected = Set(AppSession.threadSkills(threadID, siloID: siloID))
                customSkills = AppSession.loadCustomSkills(siloID: siloID)
            }
        }
    }

    @ViewBuilder private func skillRow(_ skill: AgentSkill) -> some View {
        Button {
            if selected.contains(skill.id) {
                selected.remove(skill.id)
            } else {
                selected.insert(skill.id)
            }
            AppSession.setThreadSkills(Array(selected), threadID: threadID, siloID: siloID)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: selected.contains(skill.id)
                        ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(skill.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name).font(.headline)
                    Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .accessibilityIdentifier("skill-\(skill.id)")
    }
}
