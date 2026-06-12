import CoreImage.CIFilterBuiltins
import PQRCCore
import SwiftUI

/// Settings (APP-SPEC §10).
struct SettingsView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @State private var wipeConfirmStage = 0
    @AppStorage("aiProvider") private var aiProvider = "ondevice"
    @AppStorage("ephemeralReceivingKeys") private var ephemeralKeys = false
    @State private var showRemoteConsent = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.myNpub)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("my-npub")
                        QRView(content: model.myNpub)
                            .frame(width: 160, height: 160)
                            .accessibilityLabel("QR code of your address")
                    }
                    LabeledContent("Key export", value: "Not possible — by design")
                        .foregroundStyle(.secondary)
                }
                Section("Relays") {
                    LabeledContent("local://relay", value: "AUTH ✓")
                    Text("v1 runs against the built-in local relay. The real Nostr network arrives behind the same transport seam.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Prekeys") {
                    LabeledContent("One-time prekeys", value: "\(model.prekeyCount)")
                    Button("Republish bundle") {
                        Task {
                            model.prekeyCount = await model.runtime.oneTimePrekeyCount()
                        }
                    }
                }
                Section("AI") {
                    Picker("Provider", selection: $aiProvider) {
                        Text("On-device (FoundationModels)").tag("ondevice")
                        Text("Mock (deterministic)").tag("mock")
                        Text("Anthropic API (remote)").tag("remote")
                    }
                    .onChange(of: aiProvider) { _, newValue in
                        if newValue == "remote" {
                            showRemoteConsent = true
                        }
                    }
                    Text("Outside an active window or thread invite, your AI only drafts privately for you. It never sends on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Toggle("Ephemeral receiving keys", isOn: $ephemeralKeys)
                        .disabled(true)
                    Text("Experimental — hides your address from relay observers per conversation. Off in this build; see THREAT_MODEL.md.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Data") {
                    Button(wipeConfirmStage == 0
                            ? "Wipe identity and all data"
                            : "Tap again to permanently destroy everything", role: .destructive) {
                        if wipeConfirmStage == 0 {
                            wipeConfirmStage = 1
                        } else {
                            Task {
                                try? await model.runtime.wipeIdentity()
                                session.mode = .onboarding
                            }
                        }
                    }
                    .accessibilityIdentifier("wipe-identity")
                }
                Section("About") {
                    LabeledContent("Protocol", value: "pqrc-v1")
                    LabeledContent("License", value: "AGPL-3.0")
                    Text("Honest limits: relays can see your IP address and that someone messaged you. They cannot see who sent it or what it says. Messages are not deniable, and this identity lives only on this device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #if DEBUG
                    Section("Demo") {
                        Button("Try the demo (Local Universe)") {
                            Task { await session.bootUniverse(runScript: true) }
                        }
                        .accessibilityIdentifier("try-demo")
                    }
                #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Send conversations to a remote API?", isPresented: $showRemoteConsent) {
                Button("Enable remote AI", role: .destructive) {}
                Button("Cancel", role: .cancel) {
                    aiProvider = "ondevice"
                }
            } message: {
                Text(
                    "Decrypted conversation context will be sent to a remote API for inference. Your signing keys never leave this device, but message content does. This trades privacy for capability."
                )
            }
        }
    }
}

struct QRView: View {
    let content: String

    var body: some View {
        if let image = Self.qrImage(for: content) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        }
    }

    static func qrImage(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
