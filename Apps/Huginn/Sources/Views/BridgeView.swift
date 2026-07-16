import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PQRCACP
import SwiftUI

/// EldrChat bridge: pair the Configurator's coding agent into EldrChat conversations
/// so a group (your phone, teammates) sees the agent's activity over the existing
/// PQRC E2EE stack. Agent messages always render as AI-authored (invariant 8).
struct BridgeView: View {
    @EnvironmentObject private var store: ConfigurationStore
    @StateObject private var bridge = ACPBridgeService()
    @StateObject private var a2aHost = A2AServerHost()
    @State private var copied = false
    @State private var manualOwnerHex = ""
    @State private var a2aBearerField = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("EldrChat Bridge", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.title3.weight(.semibold))

                Text("Add the coding agent to an EldrChat conversation as a first-class participant. The activity you opt into is delivered over the same post-quantum, end-to-end-encrypted PQRC channel EldrChat already uses — no server required to start.")
                    .foregroundStyle(.secondary)

                stateBox
                if case .advertising = bridge.bridgeState { pairingBox }
                if !bridge.activeConversations.isEmpty { conversationsBox }
                if !bridge.activeConversations.isEmpty || bridge.ownerIdentityHex != nil {
                    ownerBox
                }
                projectDirBox
                togglesBox
                controls

                Text("Privacy: nothing is shared until you pair, pick a conversation, and enable a message type. The agent never self-activates — you are sharing your own coding session.")
                    .font(.caption).foregroundStyle(.secondary)

                a2aServingBox
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            // Wire the A2A server's dependencies to this Bridge's live selections — same
            // backend the phone's remote-drive session uses (WS3c), so serving one agent
            // over A2A answers with whatever the operator has configured here.
            a2aHost.descriptorProvider = {
                ConfigurationStore.resolvedHarnessDescriptor(id: bridge.relayHarnessID) ?? .builtIn
            }
            a2aHost.llmProvider = {
                let config = ACPBridgeService.relayHostLLMConfig()
                return InspectingLLMClient(
                    wrapping: OpenAICompatibleLLMClient(config: config), model: config.model)
            }
            a2aHost.toolEnvironmentProvider = {
                ToolEnvironment(
                    workdir: bridge.agentWorkdir, baseEnvironment: ProcessInfo.processInfo.environment)
            }
            // Always `.default` here, deliberately NOT the operator's tuned `store.agentConfig`
            // (which may carry `allowUngatedTools: true`): a remote HTTP caller's tasks stay
            // fail-closed regardless of that Mac-local convenience toggle — the ONLY thing that
            // authorizes a mutating tool on this surface is the per-task "allow tool use"
            // checkbox in the approval UI (default off).
            a2aHost.agentConfigProvider = { .default }
        }
    }

    // MARK: - A2A serving (surface b — this Mac serves an A2A endpoint other clients call)

    private var a2aServingBox: some View {
        GroupBox("A2A serving") {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Expose this Mac's coding agent as an Agent2Agent (A2A) v1.0 endpoint other tools can call. Off by default — every submitted task still needs your explicit approval below before it runs."
                )
                .font(.caption).foregroundStyle(.secondary)

                Toggle(
                    "Serve A2A",
                    isOn: Binding(
                        get: { a2aHost.isServing },
                        set: { newValue in Task { newValue ? await a2aHost.start() : await a2aHost.stop() } }
                    ))

                LabeledContent("Port") {
                    TextField(
                        "port", value: $a2aHost.port, format: .number.grouping(.never)
                    )
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .disabled(a2aHost.isServing)
                }

                HStack {
                    Text("Token").font(.caption.weight(.medium))
                    Text(a2aHost.bearerToken).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(a2aHost.bearerToken, forType: .string)
                    }.controlSize(.small)
                    Button("Regenerate") { a2aHost.regenerateToken() }.controlSize(.small)
                }

                if a2aHost.isServing {
                    Label(
                        "Serving on http://127.0.0.1:\(a2aHost.port)/a2a",
                        systemImage: "checkmark.circle.fill"
                    ).font(.caption).foregroundStyle(.green)
                }
                if let error = a2aHost.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                if !a2aHost.pendingApprovals.isEmpty {
                    Divider()
                    Text("Pending task approvals").font(.caption.weight(.medium))
                    ForEach(a2aHost.pendingApprovals) { item in
                        pendingApprovalRow(item)
                    }
                }

                Divider()
                Text("Caution: anyone on this Mac who has the token can submit tasks to this agent.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            .padding(4)
        }
    }

    private func pendingApprovalRow(_ item: InboundTaskGate.PendingApproval) -> some View {
        PendingApprovalRow(item: item, a2aHost: a2aHost)
    }

    private var stateBox: some View {
        GroupBox {
            HStack(spacing: 10) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                Text(stateText).font(.callout.weight(.medium))
                Spacer()
            }
            .padding(4)
        }
    }

    private var pairingBox: some View {
        GroupBox("Pair with EldrChat") {
            HStack(alignment: .top, spacing: 14) {
                if let link = bridge.pairingLink, let image = Self.qrImage(link) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                        .background(Color.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("On another device: open EldrChat ▸ New conversation ▸ Scan and point it at this code. The agent pairs as a contact you can add to any conversation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("On this Mac, EldrChat can't scan its own screen — copy the link or open it directly:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button {
                            guard let link = bridge.pairingLink else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                            copied = true
                        } label: {
                            Label(
                                copied ? "Copied" : "Copy pairing link",
                                systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Button {
                            guard let link = bridge.pairingLink, let url = URL(string: link) else {
                                return
                            }
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in EldrChat", systemImage: "arrow.up.forward.app")
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(4)
        }
        .onChange(of: bridge.pairingLink) { _, _ in copied = false }
    }

    private var conversationsBox: some View {
        GroupBox("Conversations") {
            ForEach($bridge.activeConversations) { $conversation in
                Toggle(conversation.name, isOn: $conversation.enabled)
            }
            .padding(4)
        }
    }

    /// Path 2 §7 — designate the device whose owner controls this agent. The owner sees
    /// the agent's RAW answers (incl. secrets it reads); every other participant sees the
    /// redacted copy. No owner pinned ⇒ the agent stays silent (fails closed).
    private var ownerBox: some View {
        GroupBox("Owner device") {
            VStack(alignment: .leading, spacing: 8) {
                Text("This agent acts only while the owner's AI is active. The owner sees raw answers; everyone else sees secrets redacted.")
                    .font(.caption).foregroundStyle(.secondary)

                if let owner = bridge.ownerIdentityHex {
                    HStack(spacing: 8) {
                        Image(systemName: "person.badge.shield.checkmark.fill")
                            .foregroundStyle(.green)
                        Text("Owner: \(ownerLabel(owner))").font(.callout.weight(.medium))
                        Spacer()
                        Button("Re-assign") { bridge.setOwnerIdentity(nil) }
                            .controlSize(.small)
                    }
                } else {
                    Label(
                        "No owner pinned — the agent stays silent (fails closed).",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.callout).foregroundStyle(.orange)
                }

                if !bridge.activeConversations.isEmpty {
                    Divider()
                    Text("Choose from paired devices:").font(.caption).foregroundStyle(.secondary)
                    ForEach(bridge.activeConversations) { convo in
                        HStack(spacing: 8) {
                            Button {
                                bridge.setOwnerIdentity(convo.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(
                                        systemName: bridge.ownerIdentityHex == convo.id
                                            ? "largecircle.fill.circle" : "circle"
                                    )
                                    .foregroundStyle(bridge.ownerIdentityHex == convo.id ? .green : .secondary)
                                    Text(convo.name)
                                    Text(Self.shortHex(convo.id))
                                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            // Delete a paired device (clears the owner if it was pinned —
                            // fail-closed). It can re-pair later.
                            Button(role: .destructive) {
                                bridge.removePairedConversation(identityHex: convo.id)
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this paired device")
                        }
                    }
                }

                Divider()
                // Advanced/dev escape hatch: pin the owner by raw identity hex
                // before they appear in the paired-devices list. Tucked behind a
                // collapsed disclosure so the clean path stays QR + the list above.
                DisclosureGroup("Advanced — pin by identity hex") {
                    HStack {
                        TextField("owner identity hex", text: $manualOwnerHex)
                            .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                        Button("Pin") {
                            bridge.setOwnerIdentity(manualOwnerHex)
                            manualOwnerHex = ""
                        }
                        .controlSize(.small)
                        .disabled(manualOwnerHex.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }
                .font(.caption)

                Divider()
                Picker("Watch-along mode", selection: $bridge.watchAlongMode) {
                    Text("Endpoint (hardened)").tag(ACPBridgeService.WatchAlongMode.endpoint)
                    Text("Direct (fallback)").tag(ACPBridgeService.WatchAlongMode.direct)
                }
                .pickerStyle(.segmented)
                Text(
                    bridge.watchAlongMode == .endpoint
                        ? "Endpoint: the Mac drafts to your phone; your phone redacts + voices to the group as your signed agent. The raw secret never reaches anyone but you."
                        : "Direct: the Mac voices to the group itself (owner raw, others redacted). Verified fallback."
                )
                .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Picker("Mac-side responder", selection: $bridge.responder) {
                    Text("eldr-acp (our agent)").tag(ACPBridgeService.Responder.eldrAcp)
                    Text("sybilclaw assistant").tag(ACPBridgeService.Responder.sybilclaw)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("bridge-responder")
                Text(
                    bridge.responder == .sybilclaw
                        ? "Chat to sybilclaw: the owner's messages are forwarded to sybilclaw's OWN assistant (its model, persona, memory, tools) over its local Gateway (default :18789), and the reply comes back over the relay. eldr-acp's LLM isn't used — needs sybilclaw running on this Mac."
                        : "eldr-acp: the owner drives our agent (its own configured LLM) — works even without sybilclaw."
                )
                .font(.caption2).foregroundStyle(.secondary)

                Divider()
                // WS3c — DISTINCT from "Mac-side responder" above: this picks what
                // answers the phone's REMOTE-drive session (full tool-calling ACP,
                // permission cards and all), not what drafts into the watch-along mirror.
                Picker("Cloud coding agent", selection: $bridge.relayHarnessID) {
                    ForEach(HarnessRegistry.all) { descriptor in
                        Text(descriptor.displayName).tag(descriptor.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("bridge-relay-harness")
                Text(relayHarnessCaption)
                    .font(.caption2).foregroundStyle(.secondary)

                if let selected = HarnessRegistry.descriptor(id: bridge.relayHarnessID),
                    selected.kind == .a2aRemote
                {
                    LabeledContent("Bearer token (optional)") {
                        SecureField("(leave blank if the agent needs no auth)", text: $a2aBearerField)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: a2aBearerField) { _, newValue in
                                store.setA2ABearerToken(newValue, for: selected.id)
                            }
                    }
                    .task(id: selected.id) { a2aBearerField = store.a2aBearerToken(for: selected.id) }
                    Text(
                        "Sent as `Authorization: Bearer …` to \(selected.a2aCardURL ?? "the agent's card URL"). Stored in the Keychain, never this app's environment."
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var relayHarnessCaption: String {
        guard let selected = HarnessRegistry.descriptor(id: bridge.relayHarnessID) else { return "" }
        switch selected.kind {
        case .builtIn:
            return "The phone's remote-drive session (full tool access, every action a permission card) runs our built-in agent."
        case .a2aRemote:
            return "Bridges to a remote Agent2Agent (A2A) v1.0 agent over HTTPS JSON-RPC — no subprocess. Every action it takes still surfaces as a permission card on your phone."
        case .stdioSpawn:
            return "Spawns the installed CLI directly (must be on THIS app's PATH). Its vendor key (Settings ▸ Cloud coding agents) is injected ONLY into that process, never this app's shell. Its every file/shell action still surfaces as a permission card on your phone."
        }
    }

    private func ownerLabel(_ hex: String) -> String {
        if let convo = bridge.activeConversations.first(where: { $0.id == hex }) {
            return "\(convo.name) (\(Self.shortHex(hex)))"
        }
        return Self.shortHex(hex)
    }

    static func shortHex(_ hex: String) -> String {
        hex.count > 18 ? "\(hex.prefix(8))…\(hex.suffix(8))" : hex
    }

    /// The project folder the agent's tools (read_file, run_shell, xcodebuild) operate
    /// in. Without it the agent runs in an undefined dir and real tasks fail — so this
    /// is load-bearing for anything beyond "what can you do?".
    private var projectDirBox: some View {
        GroupBox("Agent project folder") {
            VStack(alignment: .leading, spacing: 6) {
                if let dir = bridge.agentWorkdir {
                    Text(dir)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Label(
                        "Not set — the agent has no project to read or build. Pick the folder it should work in.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Choose project folder…") { chooseProjectFolder() }
                        .controlSize(.small)
                    if bridge.agentWorkdir != nil {
                        Button("Clear") { bridge.setAgentWorkdir(nil) }
                            .controlSize(.small)
                    }
                }
            }
            .padding(4)
        }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        panel.message = "Choose the project the coding agent should operate in."
        if panel.runModal() == .OK, let url = panel.url {
            bridge.setAgentWorkdir(url.path)
        }
    }

    private var togglesBox: some View {
        GroupBox("Share from your coding session") {
            VStack(alignment: .leading) {
                Toggle("Tool calls", isOn: $bridge.shareToolCalls)
                Toggle("Build results", isOn: $bridge.shareBuildResults)
                Toggle("File diffs", isOn: $bridge.shareFileDiffs)
                Toggle("Session summary", isOn: $bridge.shareSessionSummary)
            }
            .padding(4)
        }
    }

    private var controls: some View {
        HStack {
            switch bridge.bridgeState {
            case .unpaired, .error:
                Button("Enable bridge") { bridge.enable() }
            default:
                Button("Stop advertising") { bridge.disable() }
                Button(role: .destructive) { Task { await bridge.unpair() } } label: { Text("Unpair") }
            }
        }
    }

    private var stateColor: Color {
        switch bridge.bridgeState {
        case .paired: return .green
        case .advertising: return .yellow
        case .error: return .red
        case .unpaired: return .secondary
        }
    }

    private var stateText: String {
        switch bridge.bridgeState {
        case .unpaired: return "Not paired"
        case .advertising: return "Advertising — waiting for EldrChat to pair"
        case .paired(let name): return "Paired with \(name)"
        case .error(let message): return "Error: \(message)"
        }
    }

    private struct PendingApprovalRow: View {
        let item: InboundTaskGate.PendingApproval
        @ObservedObject var a2aHost: A2AServerHost
        @State private var allowToolUse = false

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.summary).font(.caption.monospaced()).lineLimit(3)
                Text("from \(item.peer)").font(.caption2).foregroundStyle(.secondary)
                Toggle("Allow this task to use tools (write/edit/shell)", isOn: $allowToolUse)
                    .font(.caption2)
                HStack {
                    Button("Deny", role: .destructive) {
                        Task { await a2aHost.deny(item) }
                    }.controlSize(.small)
                    Button("Approve") {
                        Task { await a2aHost.approve(item, allowToolUse: allowToolUse) }
                    }.controlSize(.small).keyboardShortcut(.defaultAction)
                }
            }
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Render the `pqrc:add?npub=…` pairing link as a QR code.
    static func qrImage(_ string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 140, height: 140))
    }
}
