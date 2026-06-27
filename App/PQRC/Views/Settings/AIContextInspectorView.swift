import PQRCCore
import SwiftUI

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

    @State private var selectedConversation: String?
    @State private var inspection: PersonaRuntime.AIContextInspection?
    @State private var loading = false

    var body: some View {
        Group {
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

            if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if let inspection {
                inspectionBody(inspection)
            }
        }
        .task {
            if selectedConversation == nil { selectedConversation = model.conversations.first?.id }
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
