import AppKit
import SwiftUI

/// First-run wizard: configure the LLM, test it, install the binary + launcher,
/// show how to register it in Xcode, and hand off to the test chat.
struct SetupWizardView: View {
    let onFinish: () -> Void

    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var health: LLMHealthChecker
    @EnvironmentObject private var installer: InstallerService

    @State private var step = 0
    @State private var installing = false
    @State private var installError: String?
    @State private var xcodeOpenError: String?

    private let lastStep = 4

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { stepBody.padding(24).frame(maxWidth: 560) }
                .frame(maxWidth: .infinity)
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Set up Eldr ACP").font(.title2.weight(.semibold))
            Text("Step \(step + 1) of \(lastStep + 1)").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(step), total: Double(lastStep))
                .frame(maxWidth: 280)
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0: llmStep
        case 1: testStep
        case 2: installStep
        case 3: xcodeStep
        default: doneStep
        }
    }

    // MARK: Step 0 — LLM
    private var llmStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your local LLM").font(.headline)
            Text("Point the agent at any OpenAI-compatible server (LM Studio, Ollama, vLLM…).")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("LM Studio") { store.llmURL = "http://127.0.0.1:1234/v1" }
                Button("Ollama") { store.llmURL = "http://127.0.0.1:11434/v1" }
            }
            .controlSize(.small)
            LabeledContent("Server URL") {
                TextField("http://127.0.0.1:1337/v1", text: $store.llmURL).textFieldStyle(.roundedBorder)
            }
            LabeledContent("API token") {
                SecureField("(usually blank)", text: $store.llmToken).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Model") {
                TextField("local-model", text: $store.llmModel).textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: Step 1 — Test
    private var testStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Test the connection").font(.headline)
            Button("Test connection") { Task { await health.checkNow() } }
            switch health.result {
            case .checking: ProgressView().controlSize(.small)
            case .reachable(let models):
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if models.isEmpty {
                    Text("No models reported, but the server answered.").font(.callout)
                } else {
                    Text("Models: \(models.joined(separator: ", "))").font(.callout)
                }
            case .unreachable(let error):
                Label("Unreachable: \(error)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text("You can still continue and fix this later in Configuration.")
                    .font(.caption).foregroundStyle(.secondary)
            case .unknown:
                Text("Press Test connection.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Step 2 — Install
    private var installStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install the agent").font(.headline)
            Text("Copies eldr-acp to ~/.local/bin and writes the eldr-acp-xcode launcher.")
                .font(.callout).foregroundStyle(.secondary)
            Button(installing ? "Installing…" : "Install now") {
                Task {
                    installing = true
                    installError = nil
                    do { try await installer.install() } catch { installError = installer.lastError ?? error.localizedDescription }
                    installing = false
                }
            }
            .disabled(installing)
            if let installError {
                Label(installError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            switch installer.state {
            case .installed(let v):
                Label("Installed eldr-acp \(v)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                pathRow("Binary", store.paths.installedBinary)
                pathRow("Launcher", store.paths.launcher)
            case .updateAvailable, .notInstalled, .unknown:
                EmptyView()
            }
        }
    }

    // MARK: Step 3 — Xcode
    private var xcodeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register in Xcode 27").font(.headline)
            Text("In Xcode ▸ Settings ▸ Intelligence ▸ add a model provider of type “Agent (ACP)” and set its command to the launcher path:")
                .font(.callout).foregroundStyle(.secondary)
            pathRow("Launcher", store.paths.launcher)
            Button("Open Xcode") { openXcode() }
            if let xcodeOpenError {
                Label(xcodeOpenError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Open the installed Xcode (resolving Xcode-beta too) without relying on the
    /// `xcode://` URL scheme, which beta installs don't register. Falls back to the
    /// generic `/Applications/Xcode.app` path, then surfaces guidance if neither
    /// resolves. No force-unwrap, no crash, no error dialog when Xcode is absent.
    private func openXcode() {
        xcodeOpenError = nil
        let workspace = NSWorkspace.shared
        // 1) Bundle-id lookup resolves Xcode, Xcode-beta, and renamed copies.
        if let appURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // 2) Fall back to the conventional install path if it exists.
        let fallback = URL(fileURLWithPath: "/Applications/Xcode.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            workspace.openApplication(at: fallback, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // 3) Nothing found — guide the user instead of failing silently/crashing.
        xcodeOpenError =
            "Couldn't find Xcode. Open it yourself, then go to Xcode ▸ Settings ▸ Intelligence."
    }

    // MARK: Step 4 — Done
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You're ready", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
            Text("Try the agent right now in the Test Chat tab, watch it work in Logs, and fine-tune anything in Configuration.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func pathRow(_ label: String, _ path: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Footer
    private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            if step < lastStep {
                Button("Next") { step += 1 }.keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { onFinish() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
