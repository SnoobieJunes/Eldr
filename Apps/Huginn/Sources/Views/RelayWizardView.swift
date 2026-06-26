import AppKit
import SwiftUI

/// Relay-provisioning wizard. Collects khatru relay config and GENERATES paste-able
/// install/update/stop/uninstall scripts the user runs in their OWN host shell. The
/// Configurator never connects out — there is no SSH/remote-exec surface here.
///
/// Secret tokens are entered only so the UI can tell the user which host env vars the
/// script expects; the VALUES are NOT copied into the generated text (the script reads
/// them from the host env or prompts with `read -s`). Secret fields are marked and the
/// view warns about it.
struct RelayWizardView: View {
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
                relayForm
                allowlistBox
                secretsBox
                scriptsBox
                Text("Generator only: the Mac builds scripts you run yourself. It never connects to your host — no SSH, no remote execution.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
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
