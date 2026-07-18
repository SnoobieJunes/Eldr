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
    @State private var harnessKind: HarnessKindUI = .sybilclaw
    @State private var harnessConfigPath = ""
    @State private var harnessStatus: String?
    @State private var harnessError: String?
    /// Set when we refused to hot-edit a RUNNING gateway: the JSON to apply when idle.
    @State private var deferredJSON: String?
    @State private var registering = false
    @StateObject private var connections = ConnectionStatusProbe()

    private let lastStep = 5

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
            Text("Set up your Eldr node").font(.title2.weight(.semibold))
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
        case 4: harnessStep
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
            Label("Optional · for developers using Xcode's coding agent", systemImage: "hammer")
                .font(.caption).foregroundStyle(.secondary)
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

    /// Open Xcode, **preferring Xcode-beta**. Xcode 27's "Agent (ACP)" settings
    /// only exist in the beta, but with both installed the `com.apple.dt.Xcode`
    /// bundle id (and the `xcode://` URL scheme) resolve to whichever is the
    /// LaunchServices default — frequently the stable Xcode, the wrong one. So we
    /// check the conventional beta path FIRST, then fall back to the bundle-id
    /// lookup, then the generic `/Applications/Xcode.app`, then surface guidance.
    /// No force-unwrap, no crash, no error dialog when Xcode is absent.
    private func openXcode() {
        xcodeOpenError = nil
        let workspace = NSWorkspace.shared
        let config = NSWorkspace.OpenConfiguration()
        // 1) Xcode-beta at its conventional path wins over the LaunchServices default.
        let betaPath = "/Applications/Xcode-beta.app"
        if FileManager.default.fileExists(atPath: betaPath) {
            workspace.openApplication(at: URL(fileURLWithPath: betaPath), configuration: config)
            return
        }
        // 2) Bundle-id lookup resolves a single installed Xcode (stable or renamed).
        if let appURL = workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") {
            workspace.openApplication(at: appURL, configuration: config)
            return
        }
        // 3) Fall back to the conventional install path if it exists.
        let fallback = URL(fileURLWithPath: "/Applications/Xcode.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            workspace.openApplication(at: fallback, configuration: config)
            return
        }
        // 4) Nothing found — guide the user instead of failing silently/crashing.
        xcodeOpenError =
            "Couldn't find Xcode. Open it yourself, then go to Xcode ▸ Settings ▸ Intelligence."
    }

    // MARK: Step 4 — Harness (sybilclaw / OpenClaw / acpx)
    private var harnessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Register in your harness").font(.headline)
            Label("Optional · point sybilclaw, OpenClaw, or acpx at the eldr agent", systemImage: "hammer")
                .font(.caption).foregroundStyle(.secondary)
            Text("The agent command is written to acpx's own ~/.acpx/config.json (safe anytime). For a gateway (sybilclaw / OpenClaw) we also enable the acpx plugin and allowlist the agent — but never while the gateway is running, since that restarts it and would kill a live session.")
                .font(.callout).foregroundStyle(.secondary)

            Picker("Harness", selection: $harnessKind) {
                Text("sybilclaw").tag(HarnessKindUI.sybilclaw)
                Text("OpenClaw").tag(HarnessKindUI.openClaw)
                Text("acpx only").tag(HarnessKindUI.acpxOnly)
                Text("Custom…").tag(HarnessKindUI.custom)
            }
            .pickerStyle(.segmented)
            .onChange(of: harnessKind) { _, newKind in
                harnessConfigPath = defaultPath(for: newKind)
                harnessStatus = nil
                harnessError = nil
                deferredJSON = nil
                // WS-B5: sybilclaw/OpenClaw is a GATEWAY VENDOR choice, not just a
                // one-off registration target — persist it as the single `gatewayFlavor`
                // pref the Connections panel's caption/labels also read, so picking it
                // here doesn't get silently forgotten the moment the wizard closes.
                if let flavor = newKind.gatewayFlavor { store.gatewayFlavor = flavor }
            }

            if harnessKind != .acpxOnly {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gateway config file").font(.caption).foregroundStyle(.secondary)
                    TextField("~/.sybilclaw/sybilclaw.json", text: $harnessConfigPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .autocorrectionDisabled()
                        .disabled(harnessKind != .custom)  // fixed paths for known harnesses
                }
            }
            pathRow("Launcher", store.paths.openClawLauncher)

            Button(registering ? "Registering…" : "Register") {
                Task { await registerHarness() }
            }
            .disabled(registering)

            if let harnessStatus {
                Label(harnessStatus, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
            if let harnessError {
                Label(harnessError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let deferredJSON {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Your gateway is running — its config was left untouched", systemImage: "exclamationmark.shield.fill")
                        .font(.caption).foregroundStyle(.orange)
                    Text("Editing it live would restart the gateway and kill the running session. Apply this when you're idle (paste into \(harnessConfigPath); the gateway reloads then):")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(deferredJSON)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140).border(.quaternary)
                    Button("Copy JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(deferredJSON, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            // WS-B5: open on whatever gateway flavor is actually configured (the
            // Connections panel's picker and this one now share ONE persisted pref),
            // instead of always resetting to sybilclaw regardless of a prior choice.
            harnessKind = HarnessKindUI(gatewayFlavor: store.gatewayFlavor)
            if harnessConfigPath.isEmpty { harnessConfigPath = defaultPath(for: harnessKind) }
        }
    }

    /// Register crash-safely: always write the command to acpx-global; for a gateway
    /// target, add the plugin-enable + allowlist only when the gateway is NOT running
    /// (otherwise defer with the exact JSON to apply when idle).
    @MainActor
    private func registerHarness() async {
        registering = true
        defer { registering = false }
        // WS-B6: fires whether this attempt wrote/no-op'd/errored — Configuration's
        // Status tab (`ConfigurationView`) observes this to recompute "Registered in
        // …", which used to only ever get computed on that view's own first
        // appearance and so went stale the moment you registered from here.
        defer { store.noteHarnessRegistrationChanged() }
        harnessError = nil
        harnessStatus = nil
        deferredJSON = nil
        let launcher = store.paths.openClawLauncher
        let cg = store.contextGraphEnabled ? store.contextGraphURL : nil
        var messages: [String] = []
        do {
            // 1) Always register the COMMAND in acpx-global (unwatched → safe anytime).
            let acpxPlan = try HarnessRegistration.plan(target: .acpxGlobal, launcherPath: launcher)
            switch try HarnessRegistration.apply(acpxPlan, gatewayRunning: false) {
            case .wrote(let p, _): messages.append("Wrote the agent command to \(p).")
            case .unchanged(let p): messages.append("\(p) already had the agent.")
            case .deferredGatewayRunning: break  // not applicable to acpx-global
            }

            // 2) For a gateway target, add the plugin enable + allowlist crash-safely.
            if harnessKind != .acpxOnly {
                let path =
                    harnessConfigPath.isEmpty ? defaultPath(for: harnessKind) : harnessConfigPath
                let plan = try HarnessRegistration.plan(
                    target: .gateway(path: path), launcherPath: launcher, contextGraphURL: cg)
                await connections.probeGateway(port: store.sybilclawGatewayPort)
                let running = connections.gateway == .up
                switch try HarnessRegistration.apply(plan, gatewayRunning: running) {
                case .wrote(let p, let backup):
                    messages.append(
                        "Enabled the agent in \(p)"
                            + (backup.map { " (backed up to \($0))" } ?? "") + ".")
                case .unchanged(let p):
                    messages.append("\(p) already had the agent.")
                case .deferredGatewayRunning(_, let json):
                    deferredJSON = json
                }
            }
            harnessStatus =
                messages.isEmpty ? "Nothing to change." : messages.joined(separator: " ")
        } catch {
            harnessError =
                (error as? HarnessRegistration.RegError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func defaultPath(for kind: HarnessKindUI) -> String {
        switch kind {
        case .sybilclaw: return store.paths.defaultGatewayConfig(for: .sybilclaw)
        case .openClaw: return store.paths.defaultGatewayConfig(for: .openClaw)
        case .acpxOnly: return store.paths.acpxGlobalConfig
        case .custom:
            return harnessConfigPath.isEmpty
                ? store.paths.defaultGatewayConfig(for: .sybilclaw) : harnessConfigPath
        }
    }

    // MARK: Step 5 — Done
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

/// The harness choices in the setup wizard's "Register" step.
private enum HarnessKindUI: Hashable {
    case sybilclaw, openClaw, acpxOnly, custom

    /// WS-B5: the subset of these choices that is actually a GATEWAY VENDOR pick
    /// (`ConfigurationStore.GatewayFlavor`) — `.acpxOnly`/`.custom` are registration
    /// TARGETS, not vendors, so they map to nil (leaves the persisted flavor untouched).
    var gatewayFlavor: ConfigurationStore.GatewayFlavor? {
        switch self {
        case .sybilclaw: return .sybilclaw
        case .openClaw: return .openClaw
        case .acpxOnly, .custom: return nil
        }
    }

    init(gatewayFlavor: ConfigurationStore.GatewayFlavor) {
        switch gatewayFlavor {
        case .sybilclaw: self = .sybilclaw
        case .openClaw: self = .openClaw
        }
    }
}
