import PQRCCore
import SwiftUI

/// The per-AI hub (features 4, 5 + the D2 two-axis grants) — opened from the in-chat
/// AI chip. One place to control, for THIS chat: which of your AIs take part, in what
/// reply order, whether they reply in ordered critique roles, and what they may read
/// from other people (their words vs. their AIs, the 2-step). "Edit where you
/// inspect": this is the consolidated home that replaces the old per-conversation AI
/// sheet. Per-message, per-AI context marks live in the per-AI inspector
/// (Settings ▸ AI), linked at the bottom.
struct AIHubSheet: View {
    @Bindable var model: AppModel
    let conversationID: String
    /// When opened from a thread, the hub edits the THREAD's roster (the collab
    /// participants); otherwise the conversation roster.
    var threadID: String? = nil
    @Environment(\.dismiss) private var dismiss
    /// Re-resolve providers when enabling coding tools auto-adds the Mac-Tethered-AI (matches
    /// `ConversationDetailsView`). Optional — a no-op if absent; `refreshACPBindings` still binds.
    @Environment(AppSession.self) private var session: AppSession?

    private var scopeID: String { threadID ?? conversationID }

    @State private var allAIs: [ConfiguredAI] = []
    /// Display order of all AIs; the participating subset, in THIS order, is the
    /// stored roster (membership + reply order, features 4 & 5).
    @State private var order: [String] = []
    @State private var participating: Set<String> = []
    @State private var orderedCritique = false
    @State private var editMode: EditMode = .inactive
    @State private var now = Int64(Date().timeIntervalSince1970)
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // "My AI responds" (ported from the retired AIHereSheet): window (responds-in-chat)
    // vs private drafting, for THIS conversation.
    @State private var aiRespondsMode: AIRespondsMode = .draftsPrivately
    @State private var aiRespondsHours = 1
    @State private var aiRespondsDraft: String?
    @State private var showRespondsDraft = false
    // Part 5 — the paired coding node's full-tool capability, surfaced here so it's reachable
    // from "My AI". Targets the paired NODE (not this hub's conversationID); nil when none paired.
    @State private var codingNode: (identityHex: String, name: String)?
    @State private var codingEnabled = false
    @State private var codingAutonomy = false

    private var humanScope: AIContextGrant.Scope {
        threadID.map { .thread($0, axis: AIContextGrant.Scope.humanAxis) }
            ?? .conversation(conversationID, axis: AIContextGrant.Scope.humanAxis)
    }
    private var aiScope: AIContextGrant.Scope {
        threadID.map { .thread($0, axis: AIContextGrant.Scope.aiAxis) }
            ?? .conversation(conversationID, axis: AIContextGrant.Scope.aiAxis)
    }

    var body: some View {
        NavigationStack {
            List {
                modeSection
                respondsSection
                rosterSection
                codingSection
                if order.count > 1 { orderSection }
                othersSection
                inspectorLink
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("AI in this chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if order.count > 1 {
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                }
            }
            .task { load(); await loadCodingNode() }
            .onReceive(ticker) { now = Int64($0.timeIntervalSince1970) }
            .sheet(isPresented: $showRespondsDraft) {
                DraftSheet(model: model, conversationID: conversationID, draft: aiRespondsDraft ?? "")
            }
            .accessibilityIdentifier("ai-hub-sheet")
        }
    }

    // MARK: My AI responds (window vs private draft) — ported from AIHereSheet

    private var respondsSection: some View {
        Section {
            Picker("Mode", selection: $aiRespondsMode) {
                Text("Drafts privately").tag(AIRespondsMode.draftsPrivately)
                Text("Responds in chat").tag(AIRespondsMode.respondsInChat)
            }
            .accessibilityIdentifier("ai-responds-mode")
            Picker("For", selection: $aiRespondsHours) {
                Text("1 hour").tag(1)
                Text("8 hours").tag(8)
                Text("24 hours").tag(24)
            }
            .accessibilityIdentifier("ai-responds-duration")
            if aiRespondsMode == .respondsInChat {
                Button {
                    Task {
                        // A prior "Off here" override would silently neuter the window.
                        if model.conversationContextMode(conversationID) == "off" {
                            model.setConversationContextMode(nil, conversationID: conversationID)
                        }
                        // Same failure in a second guise: an EMPTY roster (every AI deselected =
                        // "AIs off here") means the window opens — visible, signed — yet no AI is
                        // eligible to reply. Clear it (nil = all my enabled AIs, config order) so
                        // "Turn on" actually produces replies, then refresh the sheet's roster.
                        if model.conversationAIRoster(conversationID)?.isEmpty == true {
                            model.setConversationAIRoster(nil, scopeID: conversationID)
                            load()
                        }
                        await model.startWindow(
                            conversationID: conversationID, minutes: aiRespondsHours * 60)
                        await model.grantContextSharing(
                            scope: .conversation(conversationID), minutes: aiRespondsHours * 60,
                            conversationID: conversationID)
                    }
                } label: {
                    Label(
                        "Turn on for \(aiRespondsHours == 1 ? "1 hour" : "\(aiRespondsHours) hours")",
                        systemImage: "sparkles")
                }
                .accessibilityIdentifier("ai-responds-turn-on")
            } else {
                Button {
                    Task {
                        aiRespondsDraft = await model.draft(conversationID: conversationID)
                        showRespondsDraft = aiRespondsDraft != nil
                    }
                } label: {
                    Label("Draft a reply now", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("ai-responds-draft-now")
            }
            if model.aiActiveHere(conversationID: conversationID, now: now) {
                Button("Stop my AI replying here", role: .destructive) {
                    Task { await model.stopAIHere(conversationID: conversationID) }
                }
                .accessibilityIdentifier("ai-responds-stop")
            }
        } header: {
            Text("My AI responds")
        } footer: {
            Text("\"Responds in chat\" opens a visible, time-bounded AI window and shares context for that period; \"Drafts privately\" only suggests to you. Off by default.")
        }
    }

    // MARK: Gather mode (per-conversation override)

    private var modeSection: some View {
        Section {
            Picker("AI context here", selection: Binding(
                get: { model.conversationContextMode(conversationID) ?? "default" },
                set: { model.setConversationContextMode($0 == "default" ? nil : $0, conversationID: conversationID) }
            )) {
                Text("Follow each AI's setting").tag("default")
                Text("Live — full conversation while active").tag("full")
                Text("Marked only — messages I add").tag("marked")
                Text("Off — no AI gathers or replies here").tag("off")
            }
            .accessibilityIdentifier("ai-hub-context-mode")
        } footer: {
            Text("Overrides every AI's own setting, just here. \"Off\" silences all AIs in this chat. Each chat is separate — your AI never carries context from one into another.")
        }
    }

    // MARK: Roster (features 4 & 5)

    private var rosterSection: some View {
        Section {
            ForEach(order, id: \.self) { id in
                if let ai = allAIs.first(where: { $0.id == id }) {
                    Button {
                        toggle(id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: participating.contains(id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(participating.contains(id) ? Color.accentColor : .secondary)
                            let badge = AITypeIcon.badge(kind: ai.kind, model: ai.model, name: ai.name)
                            AITypeBadgeView(symbol: badge.symbol, glyph: badge.glyph, size: 14)
                                .frame(width: 18)
                            Text(ai.name).foregroundStyle(.primary)
                            if ai.kind == "acp" {
                                // Part 5: signal at a glance whether this Mac AI can act, or is
                                // read-only. `codingEnabled` = the paired node's dev-control consent.
                                Text(codingEnabled ? "runs commands" : "read-only")
                                    .font(.caption2)
                                    .foregroundStyle(codingEnabled ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            }
                            Spacer()
                            if participating.contains(id),
                                let n = participatingIndex(id), order.count > 1 {
                                Text("\(n)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("reply order \(n)")
                            }
                        }
                    }
                    .accessibilityIdentifier("ai-hub-row-\(ai.kind)")
                }
            }
            .onMove { from, to in
                order.move(fromOffsets: from, toOffset: to)
                writeRoster()
            }
        } header: {
            Text("Replies in this chat")
        } footer: {
            Text(
                participating.count <= 1
                    ? "Pick which of your AIs take part here. Each sees your messages and its own — never another AI's reply, unless you add it."
                    : "Drag to set the order they reply in. Because you grouped them here, each one sees the previous AIs' replies and builds on them.")
        }
    }

    // MARK: Coding & tools (Part 5 — the paired Mac agent's full-tool capability)

    /// Surfaces the full-tool coding path from "My AI": whether the paired Mac agent may run
    /// commands / edit files (dev-control consent), and whether it may do so without asking each
    /// time (autonomous-changes consent). Both target the paired NODE and write the SAME per-node
    /// `AppSession` keys `ConversationDetailsView` does, so the two surfaces stay in sync. Shown
    /// only when a coding node is paired. The read-only chat path (CR-1) is never changed here.
    @ViewBuilder private var codingSection: some View {
        if let node = codingNode {
            Section {
                Toggle("Let this AI run commands & edit files", isOn: Binding(
                    get: { codingEnabled },
                    set: { on in
                        codingEnabled = on
                        if model.setCodingToolsEnabled(on, nodeHex: node.identityHex) {
                            Task { await session?.applyAIProvider() }
                        }
                        if !on { codingAutonomy = false }
                        load()  // the acp AI (+ its capability badge) just appeared / changed
                    }))
                    .accessibilityIdentifier("hub-coding-enable")

                Toggle("Allow changes without asking each time", isOn: Binding(
                    get: { codingAutonomy },
                    set: { on in
                        codingAutonomy = on
                        model.setCodingAutonomy(on, nodeHex: node.identityHex)
                    }))
                    .disabled(!codingEnabled)
                    .accessibilityIdentifier("hub-coding-autonomy")

                Label(
                    codingEnabled
                        ? (codingAutonomy
                            ? "ON — this AI runs commands & edits files on your Mac without asking. Stop a live terminal from its Stop button."
                            : "When this AI wants to run a command or change a file, you'll get an Allow / Deny card here. Reading files never asks.")
                        : "Read-only for now — this AI can look at files for context but can't run commands or change anything.",
                    systemImage: codingEnabled
                        ? (codingAutonomy ? "lock.open.trianglebadge.exclamationmark" : "lock.shield")
                        : "eye")
                    .font(.caption)
                    .foregroundStyle(codingEnabled && codingAutonomy ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityIdentifier("hub-coding-status")
            } header: {
                Text("Coding & tools · \(node.name)")
            } footer: {
                Text("Your paired Mac agent. Enabling lets it act on your Mac when it answers here as your AI — each change is approved on this phone unless you allow autonomy. Your read-only chats are unaffected.")
            }
        }
    }

    private var orderSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { orderedCritique },
                set: { orderedCritique = $0; model.setOrderedCritique($0, conversationID: conversationID) }
            )) {
                Text("Reply as a critique panel")
            }
            .accessibilityIdentifier("ai-hub-ordered-critique")
        } footer: {
            Text("The first AI answers, the next review and critique it, and the last merges them into one result.")
        }
    }

    // MARK: Others' context (D2 — the two-axis 2-step)

    private var othersSection: some View {
        Section {
            Toggle(isOn: grantBinding(humanScope)) {
                Label("Read other people's messages", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("ai-hub-grant-human")
            Toggle(isOn: grantBinding(aiScope)) {
                Label("Read other people's AIs", systemImage: "sparkles")
            }
            .accessibilityIdentifier("ai-hub-grant-ai")
        } header: {
            Text("What your AIs may read from others")
        } footer: {
            Text("Two separate switches: let your AIs read what other people SAY, and — separately — what their AIs say. Both also require the other person to share back. Off by default.")
        }
    }

    private var inspectorLink: some View {
        Section {
            Label(
                "Add or remove specific messages per AI from a message's long-press menu, or in Settings ▸ AI.",
                systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: State

    private func load() {
        allAIs = model.tetheredAIList().filter(\.isEnabled)
        let allIDs = allAIs.map(\.id)
        if let roster = model.conversationAIRoster(scopeID) {
            // Stored: participating = the roster set; order = roster first, then the rest.
            participating = Set(roster)
            order = roster.filter { allIDs.contains($0) } + allIDs.filter { !roster.contains($0) }
        } else {
            // No roster yet — all participate, in config order (today's default).
            order = allIDs
            participating = Set(allIDs)
        }
        orderedCritique = model.isOrderedCritique(conversationID)
    }

    /// Part 5: the paired coding node + its current capability state. Separate from `load()`
    /// because `pairedCodingAgentNode()` reads the runtime actor (async); the consent reads are
    /// synchronous `AppSession` lookups.
    private func loadCodingNode() async {
        let node = await model.pairedCodingAgentNode()
        codingNode = node
        if let hex = node?.identityHex {
            codingEnabled = model.codingToolsEnabled(nodeHex: hex)
            codingAutonomy = model.codingAutonomy(nodeHex: hex)
        }
    }

    private func toggle(_ id: String) {
        if participating.contains(id) { participating.remove(id) } else { participating.insert(id) }
        writeRoster()
    }

    /// Position (1-based) of a participating AI in the reply order.
    private func participatingIndex(_ id: String) -> Int? {
        let participatingOrder = order.filter { participating.contains($0) }
        return participatingOrder.firstIndex(of: id).map { $0 + 1 }
    }

    /// Persist the participating subset, in display order, as the roster. Always an
    /// explicit array once the user has touched the hub (an explicit roster is also
    /// the consent to chain among my own AIs — open decision #1).
    private func writeRoster() {
        let roster = order.filter { participating.contains($0) }
        model.setConversationAIRoster(roster, scopeID: scopeID)
    }

    private func grantBinding(_ scope: AIContextGrant.Scope) -> Binding<Bool> {
        Binding(
            get: { model.iGrantedContext(scope: scope, now: now) },
            set: { on in
                Task {
                    if on {
                        await model.grantContextSharing(
                            scope: scope, minutes: 8 * 60,
                            conversationID: conversationID, threadID: threadID)
                    } else {
                        await model.withdrawContextSharing(scope: scope)
                    }
                }
            })
    }
}
