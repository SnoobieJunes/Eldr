import PQRCCore
import SwiftUI

/// The Context inspector (SPEC §0 transparency, taken further than the read-only
/// `AIContextView`): for each tethered AI, show EXACTLY what context is assembled
/// and sent for a conversation — the system/instructions prompt, the gather
/// policy + depth, and the actual transcript entries — and make the safely-editable
/// parts editable.
///
/// What's editable, and how it maps to REAL persisted controls (no parallel store):
///  - **Depth** writes the AI's `ConfiguredAI.contextDepth` and re-applies the
///    live providers (`AppSession.applyAIProvider`), so the next turn uses it.
///  - **Include/exclude a message** flips its `aiContext` marker via the same
///    `markAsAIContext` path the long-press menu uses (persisted, and mirrored to
///    the peer for my own messages). In "Marked only" mode that directly controls
///    inclusion; in "Live" mode it pins a message so it survives the depth cutoff.
///
/// Privacy posture is preserved: a REMOTE AI's transcript is shown codename-
/// redacted (real names → "you" / a contact's local codename), exactly as it
/// leaves the device; on-device AIs show real names. The effect is live — every
/// edit re-runs the same assembly the engine runs.
struct AIContextInspectorView: View {
    @Bindable var model: AppModel
    @Environment(AppSession.self) private var session

    @State private var selectedConversation: String?
    @State private var inspections: [PersonaRuntime.AIContextInspection] = []
    @State private var loading = false

    private var siloID: String { model.siloID }

    var body: some View {
        List {
            Section {
                if model.conversations.isEmpty {
                    Text("Start a conversation to inspect its AI context.")
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
                Text("Conversation")
                    .helpInfo("Pick a conversation to see precisely what each of your tethered AIs would receive for it right now — the instructions, how much it gathers, and every message in the window. Edits take effect immediately.")
            }

            if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }

            ForEach(inspections) { inspection in
                inspectorSections(inspection)
            }

            if !inspections.isEmpty {
                Section {
                    EmptyView()
                } footer: {
                    Text("This is the exact context assembled on-device. For a remote AI the egress firewall replaces real names with your private codenames and bounds the size before anything leaves your device; on-device AI sees real names and never leaves your phone. AI messages always stay labeled as AI.")
                }
            }
        }
        .navigationTitle("Context inspector")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if selectedConversation == nil { selectedConversation = model.conversations.first?.id }
            await reload()
        }
    }

    @ViewBuilder private func inspectorSections(
        _ inspection: PersonaRuntime.AIContextInspection
    ) -> some View {
        // Header: which AI, remote/firewall posture, the effective policy.
        Section {
            HStack {
                Label(inspection.aiName, systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if inspection.isRemote {
                    Label(
                        inspection.firewallOn ? "Remote · firewall on" : "Remote · firewall OFF",
                        systemImage: inspection.firewallOn ? "lock.shield" : "lock.open")
                        .font(.caption2)
                        .foregroundStyle(inspection.firewallOn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                        .labelStyle(.titleAndIcon)
                } else {
                    Label("On-device", systemImage: "iphone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(policyExplanation(inspection.effectivePolicy))
                .font(.caption)
                .foregroundStyle(.secondary)
            if inspection.effectivePolicy != "off" {
                Stepper(
                    "Context depth: \(inspection.depth) messages",
                    value: depthBinding(for: inspection), in: 1...100)
                    .accessibilityIdentifier("inspector-depth-\(inspection.id)")
            }
        } header: {
            Text(inspection.aiName)
        }

        // The system / instructions prompt — collapsible, selectable, verbatim.
        Section {
            DisclosureGroup {
                Text(inspection.systemPrompt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("inspector-system-prompt-\(inspection.id)")
            } label: {
                Label("System & instructions", systemImage: "text.alignleft")
                    .font(.callout)
            }
        } header: {
            Text("Instructions sent")
                .helpInfo("The exact system prompt this AI receives — its persona/instructions plus, in a shared thread, the EldrChat guardrails and any pinned skills. Word for word, read-only.")
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
                .helpInfo("Every message in the window this AI sees. Toggle a message off to exclude it: in \"Marked only\" mode the toggle is what includes a message; in \"Live\" mode it pins a message so it isn't dropped by the depth limit. Changes are saved and take effect on the next turn.")
        } footer: {
            Text("Toggling reuses the same \"Add to AI Context\" marker as the chat's long-press menu — it's a real, saved control, mirrored to the other person for your own messages.")
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

    /// Depth → the AI's `ConfiguredAI.contextDepth`, then re-apply providers so the
    /// runtime's `TetheredAI.contextDepth` updates, then re-assemble live.
    private func depthBinding(for inspection: PersonaRuntime.AIContextInspection) -> Binding<Int> {
        Binding(
            get: { inspection.depth },
            set: { newValue in
                var list = AppSession.loadConfiguredAIs(siloID: siloID)
                guard let idx = list.firstIndex(where: { $0.id == inspection.id }) else { return }
                list[idx].contextDepth = max(1, newValue)
                AppSession.saveConfiguredAIs(list, siloID: siloID)
                Task {
                    await session.applyAIProvider()
                    await reload()
                }
            })
    }

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
                // Flipping the toggle sets the marker. In live mode un-marking a
                // policy-included message won't drop it from the live window (the
                // policy still includes it) — but it's the only safe, real control,
                // so we keep the marker authoritative and re-assemble to show truth.
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
        guard let id = selectedConversation else { inspections = []; return }
        loading = true
        inspections = await model.contextInspections(conversationID: id)
        loading = false
    }
}
