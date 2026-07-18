import AppKit
import PQRCNostr
import SwiftUI

/// Relay-provisioning wizard. Collects khatru relay config and GENERATES paste-able
/// install/update/stop/uninstall scripts the user runs in their OWN host shell. The
/// Configurator never connects out — there is no SSH/remote-exec surface here.
///
/// Secret tokens are entered only so the UI can tell the user which host env vars the
/// script expects; the VALUES are NOT copied into the generated text (the script reads
/// them from the host env or prompts with `read -s`). Secret fields are marked and the
/// view warns about it.
///
/// WS-B2 added the "This node's relay" section: unlike the generator below (which is
/// about STANDING UP your own relay server), this section controls which relay THIS
/// Mac's own live PQRC node (`ACPBridgeService`, shared with the Bridge (phone tether)
/// tab) actually dials — including debugging/observing that connection live.
struct RelayWizardView: View {
    @EnvironmentObject private var bridge: ACPBridgeService
    @State private var relayURLField = ""
    @State private var didLoadRelayField = false

    // Non-secret config, edited live.
    @State private var domain = ""
    @State private var port = 7777
    @State private var relayName = "Eldr Relay"
    @State private var relayDescription = "Private PQRC relay (NIP-42 AUTH-gated)."
    @State private var tlsMode: RelayProvisioner.TLSMode = .cloudflare
    @State private var maxContentKB = 256
    @State private var pubkeysText = ""

    // Secret fields — for guidance only; their values never enter a generated script.
    @State private var cloudflareToken = ""
    @State private var adminToken = ""

    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                connectionBox
                Divider()
                relayForm
                allowlistBox
                secretsBox
                scriptsBox
                Text("Generator only: the Mac builds scripts you run yourself. It never connects to your host — no SSH, no remote execution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            guard !didLoadRelayField else { return }
            didLoadRelayField = true
            relayURLField = bridge.relayURLOverride
        }
    }

    // MARK: WS-B2 — this node's relay connection

    private var connectionBox: some View {
        GroupBox("This node's relay") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Which relay THIS Mac's node (the Bridge (phone tether) tab) connects to — separate from the relay-setup generator below. Defaults to \(ACPBridgeService.defaultRelayURL)."
                )
                .font(.caption).foregroundStyle(.secondary)

                LabeledContent("Relay URL") {
                    TextField(
                        ACPBridgeService.defaultRelayURL, text: $relayURLField
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .onChange(of: relayURLField) { _, newValue in
                        bridge.setRelayURLOverride(newValue)
                    }
                }

                if let error = relayURLValidationMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }

                HStack {
                    Button("Reconnect") { bridge.reconnectToConfiguredRelay() }
                        .controlSize(.small)
                    Button("Use default relay") {
                        relayURLField = ""
                        bridge.setRelayURLOverride("")
                        bridge.reconnectToConfiguredRelay()
                    }
                    .controlSize(.small)
                    .disabled(relayURLField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Connect local relay") {
                        relayURLField = ACPBridgeService.localRelayURL
                        bridge.connectToLocalRelay()
                    }
                    .controlSize(.small)
                    .help("Points at ws://127.0.0.1:7777 — run `swift run pqrc-relay` in Packages/PQRCNostr first.")
                }

                if !bridge.relayConnections.isEmpty {
                    Divider()
                    ForEach(bridge.relayConnections) { relayRow($0) }
                }
            }
            .padding(4)
        }
    }

    private var relayURLValidationMessage: String? {
        switch ConfigurationStore.validateRelayOverride(relayURLField) {
        case .success: return nil
        case .failure(.invalidURL): return "Not a valid URL."
        case .failure(.unsupportedScheme): return "Use wss:// (or ws:// for a loopback host only)."
        case .failure(.plaintextOffLoopback):
            return "ws:// is plaintext — only allowed for a loopback host (127.0.0.1/localhost). Use wss:// for anything else."
        }
    }

    private func relayRow(_ info: ACPBridgeService.RelayConnectionInfo) -> some View {
        HStack(spacing: 8) {
            Circle().fill(relayStatusColor(info.status)).frame(width: 8, height: 8)
            Text(info.url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            if info.eoseSeen {
                Label("EOSE", systemImage: "checkmark.circle").font(.caption2).foregroundStyle(.secondary)
            }
            authStateLabel(info.authState)
            if let lastEventAt = info.lastEventAt {
                Text(lastEventAt, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func authStateLabel(_ state: ACPBridgeService.RelayConnectionInfo.AuthState) -> some View {
        switch state {
        case .none: EmptyView()
        case .challengeReceived:
            Label("AUTH…", systemImage: "key").font(.caption2).foregroundStyle(.orange)
        case .authenticated:
            Label("AUTH", systemImage: "key.fill").font(.caption2).foregroundStyle(.green)
        case .failed:
            Label("AUTH failed", systemImage: "key.slash").font(.caption2).foregroundStyle(.red)
        }
    }

    private func relayStatusColor(_ status: RelayStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Relay setup", systemImage: "server.rack")
                .font(.title3.weight(.semibold))
            Text("Generate a khatru relay your conversations route through. Fill in the relay's details, then copy the install script into your Linux host's shell. The relay is NIP-42 AUTH-gated — only the pubkeys you allowlist can read or write.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Non-secret config

    private var relayForm: some View {
        GroupBox("Relay details") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Domain") {
                    TextField("relay.example.com", text: $domain)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
                LabeledContent("Host port") {
                    HStack {
                        TextField("7777", value: $port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Stepper("", value: $port, in: 1...65_535).labelsHidden()
                        Spacer()
                    }
                }
                LabeledContent("Relay name") {
                    TextField("Eldr Relay", text: $relayName).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Description") {
                    TextField("Private PQRC relay…", text: $relayDescription)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("TLS") {
                    Picker("", selection: $tlsMode) {
                        ForEach(RelayProvisioner.TLSMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                }
                Stepper(
                    "Max event size: \(maxContentKB) KB",
                    value: $maxContentKB, in: 1...1024, step: 16)
                Text("256 KB is the tuned default — large messages chunk to fixed padding buckets, so a bigger cap doesn't help.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    // MARK: AUTH allowlist

    private var allowlistBox: some View {
        GroupBox("NIP-42 AUTH allowlist") {
            VStack(alignment: .leading, spacing: 6) {
                Text("64-hex x-only pubkeys, one per line. Only these identities can connect.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $pubkeysText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 70)
                    .border(.quaternary)
                    .autocorrectionDisabled()
                if pubkeyCountValid > 0 {
                    Text("\(pubkeyCountValid) valid key(s).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: Secrets (guidance only)

    private var secretsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Secrets stay out of the script", systemImage: "lock.shield")
                    .font(.callout.weight(.medium))
                Text("These tokens are NOT copied into the generated script — that would leak them through shell history or a screen-share. Instead the script reads them from your host's environment, or prompts for them with hidden input. Enter them here only if you'd like the copy button to remind you which variables to set.")
                    .font(.caption).foregroundStyle(.secondary)

                if tlsMode == .cloudflare {
                    secretField(
                        "Cloudflare API token", env: RelayProvisioner.SecretVar.cloudflareToken.rawValue,
                        text: $cloudflareToken)
                }
                secretField(
                    "Relay admin token", env: RelayProvisioner.SecretVar.adminToken.rawValue,
                    text: $adminToken)

                Button {
                    copyToClipboard(envExportReminder(), tag: "env")
                } label: {
                    Label(
                        copied == "env" ? "Copied env reminder" : "Copy env-var names (no values)",
                        systemImage: copied == "env" ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(4)
        }
    }

    private func secretField(_ label: String, env: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(.orange).font(.caption)
                Text(label).font(.caption)
                Text("→ $\(env)").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            SecureField("(kept on your host, never in the copied script)", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Scripts

    private var scriptsBox: some View {
        GroupBox("Generated scripts") {
            VStack(alignment: .leading, spacing: 10) {
                let errors = provisioner.validate()
                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors.indices, id: \.self) { i in
                            Label(errors[i].message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                } else if let bundle = try? provisioner.generateBundle() {
                    Text("Run the install script in your host shell. Update/stop/uninstall manage it afterwards.")
                        .font(.caption).foregroundStyle(.secondary)
                    scriptRow("Install", script: bundle.install, tag: "install", primary: true)
                    scriptRow("Update", script: bundle.update, tag: "update")
                    scriptRow("Stop", script: bundle.stop, tag: "stop")
                    scriptRow("Uninstall", script: bundle.uninstall, tag: "uninstall")
                }
            }
            .padding(4)
        }
    }

    private func scriptRow(_ label: String, script: String, tag: String, primary: Bool = false) -> some View {
        HStack {
            Text(label).font(.callout.weight(primary ? .semibold : .regular))
            Spacer()
            Button {
                copyToClipboard(RelayProvisioner.clipboardText(script), tag: tag)
            } label: {
                Label(
                    copied == tag ? "Copied" : "Copy",
                    systemImage: copied == tag ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
        }
    }

    // MARK: Derived

    private var provisioner: RelayProvisioner {
        RelayProvisioner(config: currentConfig)
    }

    private var currentConfig: RelayProvisioner.Config {
        RelayProvisioner.Config(
            domain: domain,
            httpPort: port,
            allowedPubkeys: pubkeyLines,
            relayName: relayName,
            relayDescription: relayDescription,
            tlsMode: tlsMode,
            maxContentLength: maxContentKB * 1024)
    }

    private var pubkeyLines: [String] {
        pubkeysText.split(whereSeparator: \.isNewline).map { String($0) }
    }

    private var pubkeyCountValid: Int {
        RelayProvisioner.normalizedPubkeys(pubkeyLines)
            .filter(RelayProvisioner.isValidPubkey).count
    }

    /// A copy-able reminder of the secret env vars to set — NAMES only, never values.
    private func envExportReminder() -> String {
        var vars = [RelayProvisioner.SecretVar.adminToken.rawValue]
        if tlsMode == .cloudflare { vars.insert(RelayProvisioner.SecretVar.cloudflareToken.rawValue, at: 0) }
        let assignments = vars.map { "\($0)=…" }.joined(separator: " ")
        return "# Set these on your host before (or while) running the install script:\n"
            + "\(assignments) bash install-eldr-relay.sh"
    }

    private func copyToClipboard(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
    }
}
