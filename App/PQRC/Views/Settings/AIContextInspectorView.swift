// SPDX-License-Identifier: AGPL-3.0-only
import PQRCAgent  // AgentEngine.StandingGrantStatus (the WS-G4 town-grant rows)
import PQRCCore
import SwiftUI
import UIKit  // UIPasteboard for the grant-export copy affordance

/// Per-AI context inspection (SPEC §0 transparency), embedded in a tethered AI's
/// detail screen (Settings ▸ AI ▸ tap an AI). For the chosen conversation it shows
/// EXACTLY what THIS AI receives — the assembled system/instructions prompt that
/// actually goes out, and every transcript entry in its window — and lets you
/// include or exclude individual messages live.
///
/// Instructions, gather policy, and depth are edited just ABOVE this on the same
/// screen (the config section), so they're not repeated here; this is the "what
/// actually leaves the device" mirror.
///
/// Privacy posture is preserved: a REMOTE AI's transcript is shown codename-
/// redacted (real names → "you" / a contact's local codename), exactly as it
/// leaves the device; on-device AIs show real names. Returns Sections (no `List`
/// wrapper) so it drops straight into the detail `Form`.
struct AIInspectionView: View {
    @Bindable var model: AppModel
    /// The tethered AI this inspection is scoped to (`ConfiguredAI.id`).
    let aiID: String
    /// C6: when embedded in a CONVERSATION surface (Details / the AI hub), the
    /// conversation is fixed — the picker is hidden and this id is inspected.
    var fixedConversationID: String? = nil

    @State private var selectedConversation: String?
    @State private var inspection: PersonaRuntime.AIContextInspection?
    @State private var loading = false

    var body: some View {
        Group {
            if fixedConversationID == nil {
                Section {
                    if model.conversations.isEmpty {
                        Text("Start a conversation to inspect what this AI receives.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Conversation", selection: $selectedConversation) {
                            ForEach(model.conversations) { conversation in
                                Text(conversation.title).tag(Optional(conversation.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("inspector-conversation")
                        .onChange(of: selectedConversation) { _, _ in Task { await reload() } }
                    }
                } header: {
                    Text("What this AI sees")
                        .helpInfo("Pick a conversation to see precisely what THIS AI would receive for it right now — the exact prompt that goes out and every message in its window. Toggling a message is saved and takes effect on the next turn.")
                }
            }

            if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let inspection {
                inspectionBody(inspection)
            }
        }
        .task {
            if let fixed = fixedConversationID {
                selectedConversation = fixed
            } else if selectedConversation == nil {
                selectedConversation = model.conversations.first?.id
            }
            await reload()
        }
    }

    @ViewBuilder private func inspectionBody(
        _ inspection: PersonaRuntime.AIContextInspection
    ) -> some View {
        // Posture + the exact prompt that goes out for this conversation.
        Section {
            HStack {
                if inspection.isRemote {
                    Label(
                        inspection.firewallOn ? "Remote · firewall on" : "Remote · firewall OFF",
                        systemImage: inspection.firewallOn ? "lock.shield" : "lock.open")
                        .foregroundStyle(
                            inspection.firewallOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                } else {
                    Label("On-device", systemImage: "iphone").foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
            Text(policyExplanation(inspection.effectivePolicy))
                .font(.caption)
                .foregroundStyle(.secondary)
            // The verbatim prompt the model receives this turn — your instructions
            // (set above) plus any engine additions (a summarize note here;
            // coordination guardrails + pinned skills in a shared thread).
            DisclosureGroup {
                let prompt = inspection.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                Text(prompt.isEmpty
                    ? "Empty — only the transcript is sent (pure conduit)."
                    : inspection.systemPrompt)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } label: {
                Label("Exactly what's sent", systemImage: "text.alignleft").font(.callout)
            }
            .accessibilityIdentifier("inspector-assembled-prompt-\(inspection.id)")
        } header: {
            Text("Prompt")
        }

        // The transcript — every entry, each with a real include/exclude toggle.
        Section {
            if inspection.entries.isEmpty {
                Text(emptyTranscriptText(inspection.effectivePolicy))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(inspection.entries) { entry in
                entryRow(entry, policy: inspection.effectivePolicy)
            }
        } header: {
            Text("Transcript (\(inspection.entries.count))")
                .helpInfo("Every message in the window this AI sees. Toggle a message off to exclude it: in \"Marked only\" mode the toggle is what includes a message; in \"Live\" mode it pins a message so it isn't dropped by the depth limit. Saved; effective next turn.")
        } footer: {
            Text("For a remote AI the egress firewall replaces real names with your private codenames and bounds the size before anything leaves your device; on-device AI sees real names and never leaves your phone. AI messages always stay labeled as AI.")
        }
    }

    @ViewBuilder private func entryRow(
        _ entry: PersonaRuntime.AIContextInspection.Entry, policy: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.role)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.isAgent ? Color.accentColor : .secondary)
                    if entry.shared {
                        Text("shared context")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    if entry.marked {
                        Image(systemName: "brain.head.profile")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                            .accessibilityLabel("Marked as AI context")
                    }
                }
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            // Include/exclude — maps onto the real aiContext marker. In live mode a
            // policy-included message is "on" by default; toggling it off can only
            // un-mark, so we present marked-state as the toggle and explain the rest.
            Toggle(
                "Included",
                isOn: includeBinding(for: entry, policy: policy))
                .labelsHidden()
                .accessibilityIdentifier("inspector-include-\(entry.id)")
                .accessibilityLabel(entry.marked ? "Marked for AI context" : "Not marked for AI context")
        }
        .padding(.vertical, 1)
    }

    // MARK: - Bindings to real, persisted controls

    /// Include/exclude → the message's `aiContext` marker via the same
    /// `markAsAIContext` path the long-press menu uses (persisted + mirrored).
    private func includeBinding(
        for entry: PersonaRuntime.AIContextInspection.Entry, policy: String
    ) -> Binding<Bool> {
        Binding(
            get: {
                // In "Marked only" mode, inclusion == marked. In "Live" mode a
                // message is in the window by policy OR because it's marked.
                policy == "strict" ? entry.marked : (entry.includedByPolicy || entry.marked)
            },
            set: { newValue in
                guard let conversationID = selectedConversation else { return }
                Task {
                    await model.markAIContext(
                        messageIDs: [entry.id], value: newValue, conversationID: conversationID)
                    await reload()
                }
            })
    }

    private func policyExplanation(_ policy: String) -> String {
        switch policy {
        case "off": return "Gathers nothing from this conversation. Only the instructions are sent."
        case "strict": return "Marked only — sees just the messages you add to context."
        default: return "Live — sees the full recent conversation while it's active (window/invite/solo)."
        }
    }

    private func emptyTranscriptText(_ policy: String) -> String {
        switch policy {
        case "off": return "Nothing — this AI gathers no messages here."
        case "strict": return "No messages added to context yet. Toggle a message on (or long-press it in chat) to include it."
        default: return "No messages in the window yet. The AI sees the conversation from the moment it's turned on."
        }
    }

    private func reload() async {
        guard let id = selectedConversation else { inspection = nil; return }
        loading = true
        inspection = await model.contextInspections(conversationID: id)
            .first(where: { $0.id == aiID })
        loading = false
    }
}

/// C6: THE per-conversation "what your AI sees here" component — one mode picker
/// (the ONLY writer of the per-conversation `conversationContextMode` key), the
/// live effect echo, and a collapsed per-AI inspection (the same `AIInspectionView`
/// Settings ▸ AI uses, conversation fixed). Embedded by BOTH
/// `ConversationDetailsView` and `AIHubSheet`, which previously each had their own
/// picker writing the same key with drifting copy — edit where you inspect, once.
struct ConversationAIContextSection: View {
    @Bindable var model: AppModel
    let conversationID: String
    /// Called after the mode changes, so the embedder can refresh its own summary
    /// state (the Details header / the in-chat glance chip).
    var onChanged: (() -> Void)? = nil

    @State private var mode = "default"
    @State private var summary: (mode: String, isRemote: Bool, firewallOn: Bool) =
        ("active", false, true)
    /// The enabled AI whose view is being inspected (defaults to the first).
    @State private var inspectedAI: String?
    @State private var myAIs: [(id: String, name: String)] = []
    @State private var showInspection = false

    var body: some View {
        Section {
            Picker("AI context here", selection: $mode) {
                Text("Follow each AI's own setting").tag("default")
                Text("Off in this conversation").tag("off")
                Text("Marked only — messages I add to context").tag("marked")
                Text("Live — full conversation while active").tag("full")
            }
            .accessibilityIdentifier("conversation-ai-mode")
            .onAppear(perform: load)
            .onChange(of: mode) { _, newValue in
                model.setConversationContextMode(
                    newValue == "default" ? nil : newValue, conversationID: conversationID)
                summary = model.primaryAIContextSummary(conversationID)
                onChanged?()
            }
            // Live echo of what the AI actually does here + the firewall indicator
            // whenever a REMOTE AI is active (privacy cardinal rule: any widening
            // of what a remote AI sees keeps the firewall state visible).
            AIContextEcho(summary: summary)
            if summary.mode != "off", summary.isRemote {
                RemoteAIFirewallRow(firewallOn: summary.firewallOn)
            }
            // The inspection itself: exactly what a chosen AI receives for THIS
            // conversation — prompt + transcript with real include/exclude
            // toggles. Collapsed by default (it can be long in a sheet).
            if !myAIs.isEmpty {
                DisclosureGroup(isExpanded: $showInspection) {
                    if myAIs.count > 1 {
                        Picker("Inspect", selection: $inspectedAI) {
                            ForEach(myAIs, id: \.id) { ai in
                                Text(ai.name).tag(Optional(ai.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("conversation-inspect-ai")
                    } else {
                        Text("Showing \(myAIs.first?.name ?? "your AI")'s view below.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Label("What your AI sees here", systemImage: "eye")
                        .font(.callout)
                }
                .accessibilityIdentifier("conversation-ai-inspection")
            }
        } header: {
            Text("AI in this conversation (now: \(AIContextVocab.glance(summary)))")
        } footer: {
            Text("Overrides every AI's own setting, just here. \"Off\" silences all AIs in this chat. Each chat is separate — your AI never carries context from one into another.")
        }
        // WS-G4 Phase-2 gate: standing TOWN grants for this 1:1 peer, inside the C6
        // surface (edit-where-you-inspect — no new chrome). Groups have no single
        // peer identity, so the section only renders for 1:1s.
        if model.conversations.first(where: { $0.id == conversationID })?.isGroup != true {
            TownGrantSection(model: model, conversationID: conversationID)
        }
        // The inspection sections render as siblings (AIInspectionView emits
        // Form sections; nesting them inside the DisclosureGroup row would
        // collapse their layout), gated on the disclosure being open.
        if showInspection, let aiID = inspectedAI ?? myAIs.first?.id {
            AIInspectionView(model: model, aiID: aiID, fixedConversationID: conversationID)
                .id("\(aiID)-\(conversationID)")
        }
    }

    private func load() {
        mode = model.conversationContextMode(conversationID) ?? "default"
        summary = model.primaryAIContextSummary(conversationID)
        myAIs = model.tetheredAIList().filter(\.isEnabled).map { ($0.id, $0.name) }
        if inspectedAI == nil { inspectedAI = myAIs.first?.id }
    }
}

/// WS-G4 → the Phase-2 UI gate (invariant 9): standing TOWN grants for this 1:1 peer —
/// the human-signed, day-bounded, revocable authorization for the cross-town wall /
/// delegate planes. Minting happens HERE because the human identity key lives on the
/// phone; the export JSON is how the authorization reaches a headless node's
/// `town-grants.json` (paste into Huginn ▸ Town Grants). Revoking kills the engine-side
/// authorization immediately; the footer says the file entry must go too (that store's
/// removal-is-revocation contract, DEVIATIONS AC143).
struct TownGrantSection: View {
    @Bindable var model: AppModel
    let conversationID: String
    @State private var now = Int64(Date().timeIntervalSince1970)
    @State private var copied = false

    private var grantsHere: [AgentEngine.StandingGrantStatus] {
        model.myTownGrants.filter { $0.peerIdentityHex == conversationID && $0.activeUntil > now }
    }

    var body: some View {
        Section {
            ForEach(grantsHere, id: \.grantID) { grant in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(grant.plane.rawValue) plane · \(townGrantRemaining(until: grant.activeUntil, now: now))")
                            .font(.callout)
                        Text("\(grant.messagesRemaining) msgs · \(grant.bytesRemaining / 1024) KB left today")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        Task { await model.revokeTownGrant(grantID: grant.grantID) }
                    }
                    .font(.caption.weight(.medium))
                    .accessibilityIdentifier("revoke-town-grant-\(grant.grantID)")
                }
            }
            Menu {
                Button("Wall only · 7 days") { mint(planes: [.wall]) }
                Button("Wall + delegate · 7 days") { mint(planes: [.wall, .delegate]) }
            } label: {
                Label("Grant town access…", systemImage: "signpost.right.and.left")
            }
            .accessibilityIdentifier("mint-town-grant")
            if let json = model.lastMintedGrantJSON {
                Button {
                    UIPasteboard.general.string = json
                    copied = true
                } label: {
                    Label(
                        copied ? "Copied — paste into Huginn ▸ Town Grants" : "Copy grant for the node",
                        systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .font(.caption)
                .accessibilityIdentifier("copy-town-grant")
            }
        } header: {
            Text("Standing town grants")
        } footer: {
            Text(
                "Signed by you, day-bounded, revocable. A live grant shows a banner in this chat for its whole lifetime. Revoking ends it everywhere your engine gates — ALSO remove it from the node's town-grants.json (removing the entry is that file's revocation)."
            )
        }
        .task {
            await model.refreshTownGrants()
            now = Int64(Date().timeIntervalSince1970)
        }
    }

    private func mint(planes: [StandingGrant.Plane]) {
        Task {
            _ = await model.startTownGrant(
                peerIdentityHex: conversationID, planes: planes, days: 7)
            copied = false
        }
    }
}
