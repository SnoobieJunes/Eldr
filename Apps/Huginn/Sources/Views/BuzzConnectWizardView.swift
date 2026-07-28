// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import PQRCNostr
import SwiftUI

// WS-I7 Path A, the five-step sheet: "Connect an AI to a workspace".
//
// Modeled on `RelayWizardView`/`SetupWizardView` (numbered steps, one Form, a
// Back/Next footer). The order is the order the user actually decides things:
// which workspace → which model → who the agent is → what crossing this boundary
// costs → connect.

/// Everything the sheet is editing, plus the two async results it collects. Kept
/// as one observable object so each step is a plain sub-view.
@MainActor
final class BuzzConnectDraft: ObservableObject {
    @Published var relayURL = ""
    @Published var channelsText = ""
    @Published var displayName = "Eldr"
    @Published var about = BuzzConnection.defaultAbout
    @Published var pictureURL = ""
    @Published var systemPrompt = BuzzConnection.defaultSystemPrompt
    @Published var mentionsOnly = true
    @Published var redactOutbound = true
    @Published var disclosureAcknowledged = false
    /// Which membership path (plan §2 Step 1).
    @Published var isWorkspaceOwner = true
    /// One-time owner key: used to sign the NIP-OA attestation and then dropped.
    @Published var ownerPrivateKey = ""
    /// Empty ⇒ follow Huginn's current backend.
    @Published var model = ""
    @Published var providerURL = ""

    @Published var probing = false
    @Published var probeResult: BuzzRelayProbeResult?
    @Published var error: String?

    var channels: [String] { BuzzConnectionStore.parseChannelList(channelsText) }

    /// The record this draft would create (agent key filled in by the store).
    func connection() -> BuzzConnection {
        BuzzConnection(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            about: about,
            pictureURL: pictureURL.trimmingCharacters(in: .whitespacesAndNewlines),
            relayURL: relayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            channelIds: channels,
            systemPrompt: systemPrompt,
            respondToMentionsOnly: mentionsOnly,
            redactOutbound: redactOutbound,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            providerURL: providerURL.trimmingCharacters(in: .whitespacesAndNewlines),
            disclosureAcknowledged: disclosureAcknowledged)
    }
}

struct BuzzConnectWizardView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @ObservedObject private var mlx = MLXService.shared
    @StateObject private var draft = BuzzConnectDraft()
    @Environment(\.dismiss) private var dismiss

    /// Called with the created connection so the caller can start it.
    let onConnect: (BuzzConnection) -> Void
    let connections: BuzzConnectionStore

    @State private var step = 1
    private static let lastStep = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                switch step {
                case 1: workspaceStep
                case 2: modelStep
                case 3: identityStep
                case 4: disclosureStep
                default: connectStep
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect an AI to a workspace").font(.title3.weight(.semibold))
            Text("Step \(step) of \(Self.lastStep) — \(stepTitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var stepTitle: String {
        switch step {
        case 1: return "Which workspace?"
        case 2: return "Which model?"
        case 3: return "Agent identity & behavior"
        case 4: return "What crossing this boundary means"
        default: return "Connect"
        }
    }

    // MARK: Step 1 — workspace

    @ViewBuilder private var workspaceStep: some View {
        Section {
            TextField("wss://you.communities.buzz.xyz", text: $draft.relayURL)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            HStack {
                Button("Test connection") {
                    Task {
                        draft.probing = true
                        draft.probeResult = await BuzzRelayProbe.probe(urlString: draft.relayURL)
                        draft.probing = false
                    }
                }
                .disabled(draft.probing || draft.relayURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if draft.probing { ProgressView().controlSize(.small) }
                if let result = draft.probeResult {
                    Label(
                        result.relayName.map { "\($0) — \(result.detail)" } ?? result.detail,
                        systemImage: result.reachable ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(result.reachable ? .green : .red)
                }
            }
        } header: {
            Text("Workspace relay")
        } footer: {
            Text(
                "This is the workspace's own relay — the same URL Buzz Desktop connects to. Plaintext ws:// is refused unless the relay runs on this machine."
            )
            .font(.caption)
        }

        Section("Membership") {
            Picker("", selection: $draft.isWorkspaceOwner) {
                Text("I own or admin this workspace").tag(true)
                Text("I was invited").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if draft.isWorkspaceOwner {
                SecureField("Owner key (nsec1… or 64 hex) — used once, never stored", text: $draft.ownerPrivateKey)
                    .textFieldStyle(.roundedBorder)
                Text(
                    "Huginn signs a NIP-OA attestation with this key so the workspace's relay accepts your agent, then discards it. Only the signature and your public key are saved."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "Huginn will mint this agent's key now and show you its public key. Send that to the workspace's admin; they return a NIP-OA attestation tag, which you paste into the connection's Edit ▸ Attestation. Until then the agent can only join channels whose relay admits its own key."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "An attestation signs one specific agent key, so it can't be issued before that key exists — which is why this is a second step, not a field here."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 2 — model

    @ViewBuilder private var modelStep: some View {
        Section {
            LabeledContent("Currently serving") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.llmURL.isEmpty ? "not set" : store.llmURL)
                        .font(.caption.monospaced())
                    Text(store.llmModel.isEmpty ? "no model" : store.llmModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            TextField("Model (leave empty to follow Huginn's current model)", text: $draft.model)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            TextField(
                "Endpoint (leave empty to follow Huginn's current endpoint)",
                text: $draft.providerURL
            )
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
        } header: {
            Text("The brain")
        } footer: {
            Text(
                "Left empty, this agent always uses whatever model Huginn is serving — swap the brain in the MLX tab and the workspace agent follows. Pin a model here to keep this workspace on one model."
            )
            .font(.caption)
        }

        if case .working(let model, let phase) = mlx.brainSwap {
            Section {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(model): \(phase)").font(.caption)
                }
            }
        } else if case .failed(let why) = mlx.brainSwap {
            Section {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }

        if !mlx.cachedModels.isEmpty {
            Section("Downloaded models") {
                ForEach(mlx.cachedModels.prefix(12), id: \.repoID) { model in
                    HStack {
                        Text(model.repoID).font(.caption.monospaced())
                        Spacer()
                        if draft.model == model.repoID {
                            Label("pinned", systemImage: "pin.fill").font(.caption2)
                        } else {
                            Button("Pin this") { draft.model = model.repoID }
                                .font(.caption)
                        }
                        // The plan's "let the user Start one inline": this is the
                        // same one-click brain swap the MLX tab's rows use, so the
                        // model the agent will ask for is actually being served.
                        Button("Serve it") {
                            Task { await mlx.makeBrain(model: model.repoID, store: store) }
                        }
                        .font(.caption)
                        .disabled(mlx.brainSwap.isWorking || store.llmModel == model.repoID)
                    }
                }
            }
        }
    }

    // MARK: Step 3 — identity & behavior

    @ViewBuilder private var identityStep: some View {
        Section("Identity") {
            TextField("Display name (what people @mention)", text: $draft.displayName)
                .textFieldStyle(.roundedBorder)
            TextField("About", text: $draft.about, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            TextField("Avatar image URL (optional)", text: $draft.pictureURL)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
            Text(
                "Published as the agent's kind:0 picture, so workspace members see a face. A URL, not an uploaded file — Eldr stores nothing for you."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Section {
            TextField("Channel ids, comma-separated", text: $draft.channelsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(2...5)
            if !draft.channelsText.isEmpty && draft.channels.allSatisfy({ BuzzConnectionStore.isChannelID($0) }) {
                Text("\(draft.channels.count) channel(s) look valid.")
                    .font(.caption).foregroundStyle(.green)
            }
        } header: {
            Text("Channels")
        } footer: {
            Text(
                "In Buzz, open the channel and copy its id. The agent listens only in the channels you list here, and an admin still has to let it into private channels."
            )
            .font(.caption)
        }
        Section("Behavior") {
            Toggle("Only answer when @mentioned", isOn: $draft.mentionsOnly)
            Toggle("Redact secrets from anything it posts", isOn: $draft.redactOutbound)
            Text(
                "The redaction filter scrubs key-shaped and password-shaped text out of replies before they leave this Mac. Leave it on unless this workspace is fully private to you."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("Persona / system prompt", text: $draft.systemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .lineLimit(4...10)
        }
    }

    // MARK: Step 4 — the honest disclosure

    @ViewBuilder private var disclosureStep: some View {
        Section {
            BuzzDisclosureBanner()
            Toggle(
                "I understand: what my AI posts in this workspace is not end-to-end encrypted.",
                isOn: $draft.disclosureAcknowledged)
        } footer: {
            Text(
                "Your Eldr↔Eldr chats are unaffected — they stay end-to-end encrypted and post-quantum ratcheted. This applies only to what this agent says inside this Buzz workspace."
            )
            .font(.caption)
        }
    }

    // MARK: Step 5 — connect

    @ViewBuilder private var connectStep: some View {
        Section("Summary") {
            LabeledContent("Agent", value: draft.displayName)
            LabeledContent("Workspace", value: draft.relayURL)
            LabeledContent("Channels", value: draft.channels.joined(separator: ", "))
            LabeledContent(
                "Model", value: draft.model.isEmpty ? "follows Huginn (\(store.llmModel))" : draft.model)
            LabeledContent(
                "Membership",
                value: draft.isWorkspaceOwner
                    ? "owner-attested (NIP-OA)"
                    : "invited — attest it after connecting (Edit ▸ Attestation)")
            LabeledContent("Answers", value: draft.mentionsOnly ? "only when @mentioned" : "every message")
            LabeledContent("Egress filter", value: draft.redactOutbound ? "on" : "off")
        }
        if let error = draft.error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        Section {
            Text(
                "Connecting mints a brand-new key for this agent (stored in this Mac's Keychain, never synced), attests it, and starts the gateway. You can pause or remove it at any time."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if step > 1 {
                Button("Back") { step -= 1 }
            }
            if step < Self.lastStep {
                Button("Next") { step += 1 }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            } else {
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(12)
    }

    private var canAdvance: Bool {
        switch step {
        case 1:
            return ConfigurationStore.effectiveRelayURL(draft.relayURL) != nil
                && !draft.relayURL.trimmingCharacters(in: .whitespaces).isEmpty
        case 3:
            return !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                && !draft.channels.isEmpty
                && draft.channels.allSatisfy { BuzzConnectionStore.isChannelID($0) }
        case 4:
            return draft.disclosureAcknowledged
        default:
            return true
        }
    }

    private var canConnect: Bool {
        canAdvance && draft.disclosureAcknowledged
            && (!draft.isWorkspaceOwner || !draft.ownerPrivateKey.isEmpty)
    }

    private func connect() {
        draft.error = nil
        do {
            let created = try connections.create(
                draft.connection(),
                ownerPrivateKey: draft.isWorkspaceOwner ? draft.ownerPrivateKey : nil)
            // The owner key has done its one job — drop it from memory now rather
            // than letting it live as long as the sheet does.
            draft.ownerPrivateKey = ""
            onConnect(created)
            dismiss()
        } catch {
            draft.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// The E2EE-termination notice — a banner, not a footnote (plan §2 Step 4). Shown
/// in the wizard AND on the Connections tab, so it can't be acknowledged once and
/// then forgotten.
struct BuzzDisclosureBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye.trianglebadge.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("End-to-end encryption stops here.")
                    .font(.callout.weight(.semibold))
                Text(
                    "Messages your AI posts into a Buzz workspace are readable by whoever runs that workspace's relay. Buzz channels are signed, but not end-to-end encrypted. Run this only in workspaces you trust with what your AI will say."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}
