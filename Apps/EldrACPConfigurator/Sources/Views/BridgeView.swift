import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// EldrChat bridge: pair the Configurator's coding agent into EldrChat conversations
/// so a group (your phone, teammates) sees the agent's activity over the existing
/// PQRC E2EE stack. Agent messages always render as AI-authored (invariant 8).
struct BridgeView: View {
    @StateObject private var bridge = ACPBridgeService()
    @State private var copied = false
    @State private var manualOwnerHex = ""

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
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
                    }
                }

                Divider()
                Text("Or pin by identity hex (beta — before the owner appears above):")
                    .font(.caption).foregroundStyle(.secondary)
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
            }
            .padding(4)
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
                Button(role: .destructive) { bridge.unpair() } label: { Text("Unpair") }
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
