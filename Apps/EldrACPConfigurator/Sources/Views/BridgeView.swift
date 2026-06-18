import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// EldrChat bridge: pair the Configurator's coding agent into EldrChat conversations
/// so a group (your phone, teammates) sees the agent's activity over the existing
/// PQRC E2EE stack. Agent messages always render as AI-authored (invariant 8).
struct BridgeView: View {
    @StateObject private var bridge = ACPBridgeService()
    @State private var copied = false

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
