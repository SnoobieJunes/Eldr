import AppKit
import SwiftUI

/// The MLX tab: a full GUI over the `mlx_lm` CLI surface — environment
/// install, OpenAI-compatible server (wired into the Eldr LLM seam with one
/// click), Hugging Face model manager, convert/quantize, a one-shot generate
/// playground, and LoRA fine-tune + fuse. Everything runs through `MLXService`;
/// long operations are exclusive "jobs" whose terminal output renders inline in
/// the section that started them.
///
/// WS-M0 layout: each section is its own Equatable child view taking narrow
/// values/bindings, so a (batched) job-log append or probe change re-evaluates
/// only the section it belongs to — not the whole six-section Form, which is
/// what visibly froze the tab. The service rides along as a plain UNOBSERVED
/// reference for actions; everything a section displays arrives as a value its
/// `==` compares.
struct MLXView: View {
    @EnvironmentObject private var store: ConfigurationStore
    /// The ONE app-wide MLX engine (owns the server child, jobs, and the log tail).
    /// Deliberately not a `@StateObject`: a recreated tab view must observe the same
    /// instance, not spawn a second service that lost the running server.
    @ObservedObject private var service = MLXService.shared

    /// Cross-section state: the Models section's "Try" seeds the Playground model.
    @State private var playModel = ""
    @State private var playModelSeeded = false
    /// Cross-section state: the fine-tune after-run "Try with adapter" seeds the
    /// Playground adapter (WS-M4).
    @State private var playAdapter = ""
    /// Cross-section state: rows request deletion; the dialog presents Form-wide.
    @State private var deleteCandidate: MLXCachedModel?

    /// Whether a Huginn-MANAGED server is up (the only server the fine-tune memory
    /// preflight may offer to stop; a detached/foreign server isn't Huginn's).
    private var managedServerRunning: Bool {
        guard service.managesServer else { return false }
        if service.autostartEnabled { return service.probeStatus.isReachable }
        switch service.serverState {
        case .running, .starting: return true
        default: return false
        }
    }

    var body: some View {
        Form {
            MLXBrainCard(
                service: service,
                managed: service.managesServer,
                envState: service.envState,
                mlxDir: service.mlxDir,
                config: service.serverConfig,
                serverState: service.serverState,
                probeStatus: service.probeStatus,
                autostart: service.autostartEnabled,
                startedAt: service.serverStartedAt,
                memoryBytes: service.serverMemoryBytes,
                brainSwap: service.brainSwap,
                portDiagnosis: service.portDiagnosis,
                wiredAsBackend: store.llmURL == service.serverConfig.baseURL,
                backendURL: store.llmURL,
                jobRunning: service.activeJob != nil,
                pane: service.jobPaneState(for: [.installEnvironment]))
            MLXServerSection(
                service: service,
                store: store,
                managed: service.managesServer,
                config: $service.serverConfig,
                serverState: service.serverState,
                probeStatus: service.probeStatus,
                serverWarning: service.serverWarning,
                launchedConfig: service.launchedServerConfig,
                autostart: service.autostartEnabled,
                envReady: service.envState.isReady,
                cachedModels: service.cachedModels)
            MLXModelsSection(
                service: service,
                store: store,
                cachedModels: service.cachedModels,
                searchResults: service.searchResults,
                isSearching: service.isSearching,
                modelsError: service.modelsError,
                cacheDir: service.cacheDir,
                jobRunning: service.activeJob != nil,
                brainSwapAvailable: service.managesServer && service.envState.isReady
                    && !service.brainSwap.isWorking,
                pane: service.jobPaneState(for: [.download]),
                downloadProgress: service.downloadProgress,
                downloadPreflight: service.downloadPreflight,
                playModel: $playModel,
                deleteCandidate: $deleteCandidate)
            MLXConvertSection(
                service: service,
                envReady: service.envState.isReady,
                jobRunning: service.activeJob != nil,
                pane: service.jobPaneState(for: [.convert]))
            MLXPlaygroundSection(
                service: service,
                envReady: service.envState.isReady,
                jobRunning: service.activeJob != nil,
                serverModel: service.serverConfig.model,
                pane: service.jobPaneState(for: [.generate]),
                playModel: $playModel,
                playModelValue: playModel,
                playAdapter: $playAdapter,
                playAdapterValue: playAdapter)
            MLXFineTuneSection(
                service: service,
                envReady: service.envState.isReady,
                jobRunning: service.activeJob != nil,
                fineTunePane: service.jobPaneState(for: [.finetune]),
                fusePane: service.jobPaneState(for: [.fuse]),
                lossHistory: service.lossHistory,
                cachedModels: service.cachedModels,
                managedServerRunning: managedServerRunning,
                serverMemoryBytes: service.serverMemoryBytes,
                playModel: $playModel,
                playAdapter: $playAdapter)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if !playModelSeeded {
                playModelSeeded = true
                playModel = service.serverConfig.model
            }
            service.refreshCachedModels()
            await service.refreshEnvironment()
        }
        .confirmationDialog(
            "Delete model?", isPresented: deleteConfirmationShown, presenting: deleteCandidate
        ) { model in
            Button("Move \(model.repoID) to the Trash", role: .destructive) {
                service.deleteCachedModel(model)
            }
        } message: { model in
            Text(
                "Frees \(model.sizeBytes.formatted(.byteCount(style: .file))) from the Hugging Face cache. The folder is moved to the Trash when possible (deleted permanently if the Trash is unavailable, e.g. on some external volumes)."
            )
        }
    }

    private var deleteConfirmationShown: Binding<Bool> {
        Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } })
    }
}

// MARK: - Brain card (WS-M1)

/// The at-a-glance card at the top of the tab: which model is (or would be) the
/// AI's brain, whether it's answering, uptime / memory / port, whether Eldr is
/// wired to it, brain-swap progress, port-conflict diagnosis — and the MLX
/// environment demoted to a status chip (the full install card only appears
/// while it's actually needed: not ready, or an install job showing output).
private struct MLXBrainCard: View, Equatable {
    let service: MLXService
    let managed: Bool
    let envState: MLXService.EnvironmentState
    let mlxDir: String
    let config: MLXServerConfig
    let serverState: MLXService.ServerState
    let probeStatus: LLMHealthChecker.HealthResult
    let autostart: Bool
    let startedAt: Date?
    let memoryBytes: Int64?
    let brainSwap: MLXService.BrainSwapState
    let portDiagnosis: String?
    let wiredAsBackend: Bool
    let backendURL: String
    let jobRunning: Bool
    let pane: MLXService.JobPaneState

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.managed == rhs.managed && lhs.envState == rhs.envState
            && lhs.config == rhs.config && lhs.serverState == rhs.serverState
            && lhs.probeStatus == rhs.probeStatus && lhs.autostart == rhs.autostart
            && lhs.startedAt == rhs.startedAt && lhs.memoryBytes == rhs.memoryBytes
            && lhs.brainSwap == rhs.brainSwap && lhs.portDiagnosis == rhs.portDiagnosis
            && lhs.wiredAsBackend == rhs.wiredAsBackend && lhs.backendURL == rhs.backendURL
            && lhs.jobRunning == rhs.jobRunning && lhs.pane == rhs.pane
    }

    var body: some View {
        Section("Your AI's brain") {
            HStack(spacing: 10) {
                Circle().fill(stateColor).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelTitle).font(.headline)
                    Text(stateText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if wiredAsBackend {
                    Label("Eldr backend", systemImage: "checkmark.seal.fill")
                        .font(.caption).foregroundStyle(.green)
                        .help(
                            "Configuration ▸ Local LLM points at this server — your AI runs on it."
                        )
                }
            }
            if managed, serverUp {
                HStack(spacing: 16) {
                    if let startedAt {
                        Label {
                            Text("up ") + Text(startedAt, style: .relative)
                        } icon: {
                            Image(systemName: "clock")
                        }
                    }
                    if let memoryBytes {
                        Label(
                            memoryBytes.formatted(.byteCount(style: .memory)),
                            systemImage: "memorychip")
                    }
                    Label("\(config.probeHost):\(String(config.port))", systemImage: "network")
                    Spacer()
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            switch brainSwap {
            case .idle:
                EmptyView()
            case .working(_, let phase):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(phase).font(.caption)
                    Spacer()
                }
            case .done(let model):
                dismissableNote(
                    Label("Your AI now runs on \(model).", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green))
            case .failed(let why):
                dismissableNote(
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange))
            }

            if let portDiagnosis {
                Label(portDiagnosis, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            environmentRow
        }
    }

    private func dismissableNote(_ label: some View) -> some View {
        HStack(spacing: 8) {
            label
            Spacer()
            Button {
                service.clearBrainSwapNote()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Dismiss")
        }
    }

    // MARK: Environment chip / card

    /// Full install card only while it's needed: env not ready, an install
    /// running, or a FAILED install to explain. A successful install collapses
    /// straight to the chip (the fresh version number is the confirmation).
    private var environmentExpanded: Bool {
        !envState.isReady || pane.activeJob != nil
            || pane.lastResult.map { !$0.success } == true
    }

    @ViewBuilder
    private var environmentRow: some View {
        if environmentExpanded {
            Divider()
            HStack(spacing: 8) {
                Circle().fill(envColor).frame(width: 8, height: 8)
                Text(envText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check") { Task { await service.refreshEnvironment() } }
                    .controlSize(.small)
            }
            Text(
                "A private Python environment (uv preferred, python3 fallback) with the mlx-lm toolkit, installed under \(mlxDir). Everything in this tab runs through it; your system Python is untouched."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(installButtonTitle) { service.installEnvironment() }
                    .disabled(jobRunning || !installAvailable)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: mlxDir)])
                }
            }
            MLXJobPane(service: service, state: pane)
        } else {
            HStack(spacing: 6) {
                Circle().fill(envColor).frame(width: 6, height: 6)
                Text(envText).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Check again") { Task { await service.refreshEnvironment() } }
                    Button("Update mlx-lm") { service.installEnvironment() }
                        .disabled(jobRunning)
                    Button("Reveal environment in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: mlxDir)])
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("MLX environment actions")
            }
        }
    }

    private var installAvailable: Bool {
        if case .unsupported = envState { return false }
        return true
    }

    private var installButtonTitle: String {
        switch envState {
        case .ready: return "Update mlx-lm"
        case .broken: return "Repair install"
        default: return "Install mlx-lm"
        }
    }

    private var envColor: Color {
        switch envState {
        case .ready: return .green
        case .notInstalled: return .orange
        case .broken, .unsupported: return .red
        case .unknown: return .secondary
        }
    }

    private var envText: String {
        switch envState {
        case .ready(let version): return "mlx-lm \(version) — ready"
        case .notInstalled: return "Not installed yet"
        case .broken(let why): return why
        case .unsupported(let why): return why
        case .unknown: return "Checking…"
        }
    }

    // MARK: Display state

    private var modelTitle: String {
        guard managed else { return "MLX serving is off" }
        return config.model.isEmpty ? "No model picked yet" : config.model
    }

    private var serverUp: Bool {
        if autostart { return probeStatus.isReachable }
        switch serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var stateColor: Color {
        guard managed else { return .secondary }
        if autostart { return probeStatus.isReachable ? .green : .orange }
        switch serverState {
        case .running(let healthy): return healthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var stateText: String {
        guard managed else {
            return "Eldr talks to \(backendURL.isEmpty ? "no backend yet" : backendURL) — manage that in the Server section below."
        }
        if autostart {
            return probeStatus.isReachable
                ? "Answering (launchd) on \(config.baseURL)"
                : "launchd-managed — not answering on \(config.baseURL) yet"
        }
        switch serverState {
        case .stopped:
            return config.model.isEmpty
                ? "Pick a cached model below and serve it as your AI's brain."
                : "Not running — press Start below, or \u{201C}Serve as my AI's brain\u{201D} on a cached model."
        case .starting: return "Starting — waiting for \(config.baseURL) to answer…"
        case .running(true): return "Answering on \(config.baseURL)"
        case .running(false): return "Process alive but not answering — see the server log"
        case .failed(let why): return why
        }
    }
}

// MARK: - Server

private struct MLXServerSection: View, Equatable {
    let service: MLXService
    /// Observed (not just referenced): the OFF card binds its URL/model fields
    /// straight to the store, so its edits must re-render this section. The store
    /// only publishes on user edits — no periodic churn rides in through it.
    @ObservedObject var store: ConfigurationStore
    let managed: Bool
    @Binding var config: MLXServerConfig
    /// Value copy of `config` taken at construction (same parent-body read that
    /// made the binding): a nonisolated `==` may not read a Binding, and the two
    /// can't diverge — any config change republishes the service and rebuilds
    /// this struct with a fresh copy.
    let currentConfig: MLXServerConfig
    let serverState: MLXService.ServerState
    let probeStatus: LLMHealthChecker.HealthResult
    let serverWarning: String?
    let launchedConfig: MLXServerConfig?
    let autostart: Bool
    let envReady: Bool
    let cachedModels: [MLXCachedModel]

    // Server "Advanced" numeric fields are optionals in the config; SwiftUI's
    // numeric TextFields fight mid-typing round-trips, so these seed once (State
    // initial values latch at first render) and write through on change.
    @State private var advMaxTokens: String
    @State private var advTemperature: String
    @State private var advTopP: String
    @State private var advPromptCacheSize: String
    @State private var advPromptCacheGB: String

    /// Confirmation caption captured at click time (so later config edits can't
    /// make it claim something that wasn't written).
    @State private var backendNote: String?

    init(
        service: MLXService, store: ConfigurationStore, managed: Bool,
        config: Binding<MLXServerConfig>, serverState: MLXService.ServerState,
        probeStatus: LLMHealthChecker.HealthResult, serverWarning: String?,
        launchedConfig: MLXServerConfig?, autostart: Bool, envReady: Bool,
        cachedModels: [MLXCachedModel]
    ) {
        self.service = service
        self.store = store
        self.managed = managed
        self._config = config
        self.currentConfig = config.wrappedValue
        self.serverState = serverState
        self.probeStatus = probeStatus
        self.serverWarning = serverWarning
        self.launchedConfig = launchedConfig
        self.autostart = autostart
        self.envReady = envReady
        self.cachedModels = cachedModels
        _advMaxTokens = State(initialValue: config.wrappedValue.maxTokens.map(String.init) ?? "")
        _advTemperature = State(
            initialValue: config.wrappedValue.temperature.map(MLXCommand.formatNumber) ?? "")
        _advTopP = State(initialValue: config.wrappedValue.topP.map(MLXCommand.formatNumber) ?? "")
        _advPromptCacheSize = State(
            initialValue: config.wrappedValue.promptCacheSize.map(String.init) ?? "")
        _advPromptCacheGB = State(
            initialValue: config.wrappedValue.promptCacheBytes
                .map { MLXCommand.formatNumber(MLXCommand.gigabytes(fromBytes: $0)) } ?? "")
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.managed == rhs.managed && lhs.currentConfig == rhs.currentConfig
            && lhs.serverState == rhs.serverState && lhs.probeStatus == rhs.probeStatus
            && lhs.serverWarning == rhs.serverWarning && lhs.launchedConfig == rhs.launchedConfig
            && lhs.autostart == rhs.autostart && lhs.envReady == rhs.envReady
            && lhs.cachedModels == rhs.cachedModels
    }

    var body: some View {
        Section("Server (OpenAI-compatible, mlx_lm.server)") {
            Toggle("Huginn manages the model server", isOn: managedBinding)
            Text(
                managed
                    ? "On: Huginn runs mlx_lm.server as configured below and can point the whole Eldr stack at it."
                    : "Off: the MLX server is stopped and its health checks and log tail idle. Eldr talks to the external server below instead — turning this back on restores the MLX config and rewires the backend to it."
            )
            .font(.caption).foregroundStyle(.secondary)

            if managed {
                managedContent
            } else {
                unmanagedCard
            }
        }
    }

    private var managedBinding: Binding<Bool> {
        Binding(
            get: { managed },
            set: { on in Task { await service.setManagesServer(on, store: store) } })
    }

    // MARK: Managed (historical) contents

    @ViewBuilder
    private var managedContent: some View {
        LabeledContent("Model") {
            HStack(spacing: 6) {
                TextField("mlx-community/… or /path/to/model", text: $config.model)
                    .textFieldStyle(.roundedBorder)
                if !cachedModels.isEmpty {
                    Menu("Cached") {
                        ForEach(cachedModels) { model in
                            Button(model.repoID) { config.model = model.repoID }
                        }
                    }
                    .fixedSize()
                }
                Button("Browse…") { pickFolder { config.model = $0 } }
            }
        }
        LabeledContent("Host") {
            TextField("127.0.0.1", text: $config.host)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
        }
        LabeledContent("Port") {
            TextField("8080", value: $config.port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
        }

        DisclosureGroup("Advanced") {
            LabeledContent("Default max tokens") {
                TextField("server default", text: $advMaxTokens)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: advMaxTokens) { _, new in
                        config.maxTokens = Int(new.trimmingCharacters(in: .whitespaces))
                    }
            }
            LabeledContent("Default temperature") {
                TextField("unset", text: $advTemperature)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: advTemperature) { _, new in
                        config.temperature = parseDouble(new)
                    }
            }
            LabeledContent("Default top-p") {
                TextField("unset", text: $advTopP)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: advTopP) { _, new in
                        config.topP = parseDouble(new)
                    }
            }
            Text(
                "Sampling defaults need a recent mlx-lm. Leave blank to omit the flags — an older server rejects them with an argparse error (visible in the log)."
            )
            .font(.caption).foregroundStyle(.secondary)
            Picker("Reasoning (thinking mode)", selection: $config.reasoning) {
                Text("Model default").tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
            .help(
                "Passes --chat-template-args {\"enable_thinking\":…} so reasoning models (Qwen3-style) think, or answer directly. \u{201C}Model default\u{201D} omits the flag — required for older mlx-lm servers; models without a thinking mode ignore it."
            )
            LabeledContent("Prompt-cache entries") {
                TextField("server default", text: $advPromptCacheSize)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: advPromptCacheSize) { _, new in
                        config.promptCacheSize = Int(new.trimmingCharacters(in: .whitespaces))
                    }
            }
            .help(
                "--prompt-cache-size — how many distinct conversation prefixes the server keeps ready (its KV prompt cache). More entries = instant re-prompts for more chats, at the cost of memory."
            )
            LabeledContent("Prompt-cache cap (GB)") {
                TextField("unbounded", text: $advPromptCacheGB)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                    .onChange(of: advPromptCacheGB) { _, new in
                        config.promptCacheBytes = parseDouble(new).flatMap(MLXCommand.bytes(fromGB:))
                    }
            }
            .help(
                "--prompt-cache-bytes — hard cap on the KV prompt cache's memory. Set it if the server's RAM keeps growing across long chats; evicted prefixes simply re-prefill (slower first token, identical answers). Needs a recent mlx-lm."
            )
            Toggle("Trust remote code (--trust-remote-code)", isOn: $config.trustRemoteCode)
            Toggle("Use the tokenizer's default chat template", isOn: $config.useDefaultChatTemplate)
            VStack(alignment: .leading, spacing: 4) {
                Text("Chat template override (Jinja, passed verbatim to --chat-template)")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $config.chatTemplate)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 40)
                    .border(.quaternary)
            }
            LabeledContent("Adapter path") {
                HStack {
                    TextField("(none)", text: $config.adapterPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { config.adapterPath = $0 } }
                }
            }
            LabeledContent("Extra arguments") {
                TextField("--log-level DEBUG", text: $config.extraArguments)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Extra arguments are whitespace-split — no shell quoting.")
                .font(.caption).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
            Circle().fill(serverColor).frame(width: 8, height: 8)
            Text(serverText).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }

        if let warning = serverWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        }

        if restartHintVisible {
            Label("Settings changed since launch — press \(startButtonTitle) to apply.",
                systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.orange)
        }

        HStack {
            Button(startButtonTitle) { service.startServer() }
                .disabled(!envReady || config.model.isEmpty)
            Button("Stop") { service.stopServer() }
                .disabled(!serverStoppable)
            Spacer()
            Button("Use as Eldr LLM backend") {
                service.useAsEldrBackend(store: store)
                backendNote =
                    "Configuration ▸ Local LLM now points at \(config.baseURL) (\(config.model))."
            }
            .disabled(config.model.isEmpty)
        }
        if let backendNote {
            Label(backendNote, systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        }

        Toggle("Start at login (launchd)", isOn: autostartBinding)
        Text(
            autostart
                ? "launchd owns the server process: Start/Restart rewrites the LaunchAgent and relaunches it; Stop sends SIGTERM through launchctl."
                : "Off: the server runs as a child of this app and stops when Huginn quits."
        )
        .font(.caption).foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 4) {
            Text("Server log")
                .font(.caption).foregroundStyle(.secondary)
            // WS-M2: the reusable console replaced the read-only MLXLogPane here.
            // It owns its own tailer (visibility-driven), so this section's ==
            // stays free of log churn, and Expand/search/remediation come along.
            LogConsoleView(source: .mlxServer, style: .embedded)
        }
    }

    // MARK: Unmanaged (kill-switch OFF) card

    @ViewBuilder
    private var unmanagedCard: some View {
        Label(
            "MLX is off — Eldr uses \(store.llmURL.isEmpty ? "no backend yet" : store.llmURL)",
            systemImage: "moon.zzz.fill"
        )
        .font(.callout)
        LabeledContent("Backend URL") {
            TextField("http://127.0.0.1:1234/v1", text: $store.llmURL)
                .textFieldStyle(.roundedBorder)
        }
        LabeledContent("Model") {
            TextField("model id, as that server reports it", text: $store.llmModel)
                .textFieldStyle(.roundedBorder)
        }
        Text(
            "Written straight to Configuration ▸ Local LLM — the same seam \u{201C}Use as Eldr LLM backend\u{201D} writes. LM Studio's own server default is http://127.0.0.1:1234/v1; or run its server on port \(String(config.port)) and nothing else needs to change. The model library and downloads below stay usable — they don't need the server."
        )
        .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Derived display state

    private var autostartBinding: Binding<Bool> {
        Binding(
            get: { autostart },
            set: { on in Task { await service.setAutostart(on) } })
    }

    private var startButtonTitle: String {
        if autostart { return "Start / Restart (launchd)" }
        if case .stopped = serverState { return "Start" }
        if case .failed = serverState { return "Start" }
        return "Restart"
    }

    private var serverStoppable: Bool {
        if autostart { return true }
        switch serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var restartHintVisible: Bool {
        guard let launched = launchedConfig else { return false }
        guard launched != config else { return false }
        if autostart { return true }
        switch serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var serverColor: Color {
        if autostart {
            return probeStatus.isReachable ? .green : .orange
        }
        switch serverState {
        case .running(let healthy): return healthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var serverText: String {
        if autostart {
            return probeStatus.isReachable
                ? "Running (launchd) — answering on \(config.baseURL)"
                : "launchd-managed — not answering on \(config.baseURL) yet"
        }
        switch serverState {
        case .stopped: return "Stopped"
        case .starting: return "Starting — waiting for \(config.baseURL)/models…"
        case .running(true): return "Running — answering on \(config.baseURL)"
        case .running(false): return "Process alive but not answering — see the log"
        case .failed(let why): return why
        }
    }
}

// MARK: - Models

private struct MLXModelsSection: View, Equatable {
    let service: MLXService
    /// Unobserved — only passed into `makeBrain` (the swap's backend wiring).
    let store: ConfigurationStore
    let cachedModels: [MLXCachedModel]
    let searchResults: [MLXHubModel]
    let isSearching: Bool
    let modelsError: String?
    let cacheDir: String
    let jobRunning: Bool
    /// Managed + env ready + no swap already running (disables the per-row
    /// "Serve as my AI's brain" buttons).
    let brainSwapAvailable: Bool
    let pane: MLXService.JobPaneState
    /// Live download progress (files-based percent), nil when not downloading.
    let downloadProgress: MLXDownloadProgress?
    /// Non-nil while the pre-download size/disk check runs (disables Download).
    let downloadPreflight: String?
    @Binding var playModel: String
    @Binding var deleteCandidate: MLXCachedModel?

    @State private var searchQuery = ""
    @State private var searchPublisher = "mlx-community"
    @State private var searchMLXOnly = true
    @State private var searchSort = "downloads"
    /// Cache-hygiene ordering; `.largest` first surfaces the models to delete.
    @State private var cacheSort: MLXModelSort = .largest

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cachedModels == rhs.cachedModels && lhs.searchResults == rhs.searchResults
            && lhs.isSearching == rhs.isSearching && lhs.modelsError == rhs.modelsError
            && lhs.jobRunning == rhs.jobRunning && lhs.pane == rhs.pane
            && lhs.brainSwapAvailable == rhs.brainSwapAvailable
            && lhs.downloadProgress == rhs.downloadProgress
            && lhs.downloadPreflight == rhs.downloadPreflight
    }

    var body: some View {
        Section("Models — Hugging Face cache") {
            HStack {
                Text("\(cachedModels.count) cached — \(totalCacheLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { service.refreshCachedModels() }.controlSize(.small)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: cacheDir)])
                }
                .controlSize(.small)
            }
            Text(cacheDir)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            if cachedModels.count > 1 {
                Picker("Sort", selection: $cacheSort) {
                    ForEach(MLXModelSort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                .help(
                    "Largest first is the fastest way to free up space — the biggest models are on top to delete.")
            }

            ForEach(MLXCommand.sortedModels(cachedModels, by: cacheSort)) { model in
                MLXCachedModelRow(
                    model: model,
                    brainSwapAvailable: brainSwapAvailable,
                    onServe: { Task { await service.makeBrain(model: model.repoID, store: store) } },
                    onTry: { playModel = model.repoID },
                    onDelete: { deleteCandidate = model })
            }
            if cachedModels.isEmpty {
                Text("No models cached yet — search below and download one (small 4-bit instruct models from mlx-community are a good start).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                TextField("Search Hugging Face models…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }.disabled(isSearching)
            }
            HStack(spacing: 12) {
                Picker("Source", selection: $searchPublisher) {
                    Text("Any publisher").tag("")
                    ForEach(MLXCommand.searchPublishers.filter { !$0.isEmpty }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .fixedSize()
                Picker("Sort", selection: $searchSort) {
                    ForEach(MLXCommand.searchSorts, id: \.value) { sort in
                        Text(sort.label).tag(sort.value)
                    }
                }
                .fixedSize()
                Toggle("MLX format only", isOn: $searchMLXOnly)
                Spacer()
            }
            .onChange(of: searchPublisher) { _, _ in refreshSearchIfActive() }
            .onChange(of: searchSort) { _, _ in refreshSearchIfActive() }
            .onChange(of: searchMLXOnly) { _, _ in refreshSearchIfActive() }
            Text(
                "Only MLX-format builds run on mlx_lm — keep the filter on unless you plan to Convert. mlx-community, lmstudio-community, and unsloth publish ready-quantized MLX models."
            )
            .font(.caption).foregroundStyle(.secondary)
            if isSearching {
                HStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption) }
            }
            if let error = modelsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(searchResults) { result in
                let format = result.format
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(result.id).font(.callout)
                                if let quant = result.quantLabel {
                                    Text(quant)
                                        .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                if searchMLXOnly == false, let badge = format.badge {
                                    Text(badge)
                                        .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(
                                            (format.isBlocking ? Color.red : Color.orange)
                                                .opacity(0.2), in: Capsule())
                                }
                            }
                            Text(searchResultCaption(result)).font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        if let page = URL(string: "https://huggingface.co/\(result.id)") {
                            Link(destination: page) { Image(systemName: "safari") }
                                .controlSize(.small)
                                .accessibilityLabel("Open \(result.id) on Hugging Face")
                        }
                        Button("Download") { service.downloadModel(result.id) }
                            .controlSize(.small)
                            .disabled(jobRunning || downloadPreflight != nil)
                    }
                    // Format honesty (the NVFP4 lesson): when the MLX filter is off,
                    // spell out what mlx_lm can't load and name the alternative.
                    if searchMLXOnly == false, let advisory = format.advisory {
                        Label(
                            advisory,
                            systemImage: format.isBlocking
                                ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(format.isBlocking ? Color.red : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let downloadPreflight {
                Label(downloadPreflight, systemImage: "externaldrive.badge.questionmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // Determinate download progress (WS-M3): a real ProgressView driven by
            // the tqdm frame in the log. Files-based (per-file byte bars are
            // suppressed off a TTY), captioned in tqdm's own honest wording.
            if pane.activeJob?.kind == .download, let progress = downloadProgress {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: progress.fraction) {
                        Text(progress.caption).font(.caption)
                    }
                    Text("\(Int((progress.fraction * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            MLXJobPane(service: service, state: pane)
        }
    }

    /// Re-run the current search when a filter changes and results are showing (the
    /// LM Studio behavior — filters act on the live list, not just the next search).
    private func refreshSearchIfActive() {
        if !searchResults.isEmpty || !searchQuery.isEmpty { runSearch() }
    }

    private var totalCacheLabel: String {
        cachedModels.map(\.sizeBytes).reduce(0, +)
            .formatted(.byteCount(style: .file))
    }

    private func searchResultCaption(_ result: MLXHubModel) -> String {
        var parts: [String] = []
        if let downloads = result.downloads { parts.append("\(downloads.formatted()) downloads") }
        if let likes = result.likes { parts.append("\(likes.formatted()) likes") }
        if let updated = result.lastModified?.prefix(10) { parts.append("updated \(updated)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func runSearch() {
        Task {
            await service.searchHub(
                query: searchQuery, author: searchPublisher.isEmpty ? nil : searchPublisher,
                mlxOnly: searchMLXOnly, sort: searchSort)
        }
    }
}

/// One cached-model row with an ⓘ detail popover (size / last used / quant / path
/// + Reveal / Serve / Try). Owns its own popover flag so the popover anchors to
/// the row's info button (WS-M3). Actions arrive as closures from the section.
private struct MLXCachedModelRow: View {
    let model: MLXCachedModel
    let brainSwapAvailable: Bool
    let onServe: () -> Void
    let onTry: () -> Void
    let onDelete: () -> Void

    @State private var showDetail = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.repoID).font(.callout)
                HStack(spacing: 6) {
                    Text(model.sizeBytes.formatted(.byteCount(style: .file)))
                    if let quant = model.quant {
                        Text(quant)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showDetail = true } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Details for \(model.repoID)")
            .popover(isPresented: $showDetail, arrowEdge: .top) { detail }
            Button("Serve as my AI's brain") { onServe() }
                .controlSize(.small)
                .disabled(!brainSwapAvailable)
                .help(
                    "One click: start the server on this model, wait until it answers, and wire it as the Eldr backend. Progress shows in the card at the top."
                )
            Button("Try") { onTry() }
                .controlSize(.small)
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .accessibilityLabel("Delete \(model.repoID)")
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.repoID).font(.headline).textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                detailRow("Size", model.sizeBytes.formatted(.byteCount(style: .file)))
                GridRow {
                    Text("Last used").foregroundStyle(.secondary)
                    if let lastUsed = model.lastUsed {
                        Text(lastUsed, format: .relative(presentation: .named))
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                // nil quant means "no quantization tag in config.json" — which is
                // usually a full-precision model but also covers an unreadable
                // config, so show "—" rather than over-claim "full precision".
                detailRow("Quant", model.quant ?? "—")
            }
            .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text("Path").font(.caption).foregroundStyle(.secondary)
                Text(model.path)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
            }
            Divider()
            HStack {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: model.path)])
                    showDetail = false
                }
                Button("Serve") {
                    onServe()
                    showDetail = false
                }
                .disabled(!brainSwapAvailable)
                Button("Try") {
                    onTry()
                    showDetail = false
                }
                Spacer()
            }
            .controlSize(.small)
        }
        .padding()
        .frame(minWidth: 320, maxWidth: 460)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Convert

private struct MLXConvertSection: View, Equatable {
    let service: MLXService
    let envReady: Bool
    let jobRunning: Bool
    let pane: MLXService.JobPaneState

    @State private var convertConfig = MLXConvertConfig()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.envReady == rhs.envReady && lhs.jobRunning == rhs.jobRunning && lhs.pane == rhs.pane
    }

    var body: some View {
        Section("Convert / quantize (mlx_lm.convert)") {
            LabeledContent("Source model") {
                HStack {
                    TextField("HF repo id or local folder", text: $convertConfig.hfPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { convertConfig.hfPath = $0 } }
                }
            }
            LabeledContent("Output folder") {
                HStack {
                    TextField("new folder for the MLX model", text: $convertConfig.mlxPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        pickSaveLocation(defaultName: suggestedConvertFolderName) {
                            convertConfig.mlxPath = $0
                        }
                    }
                }
            }
            Toggle("Quantize", isOn: $convertConfig.quantize)
            if convertConfig.quantize {
                Picker("Bits", selection: $convertConfig.qBits) {
                    Text("4-bit").tag(4)
                    Text("8-bit").tag(8)
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
                Picker("Group size", selection: $convertConfig.qGroupSize) {
                    Text("32").tag(32)
                    Text("64").tag(64)
                    Text("128").tag(128)
                }
                .pickerStyle(.segmented).frame(maxWidth: 240)
            }
            Picker("dtype", selection: $convertConfig.dtype) {
                Text("default").tag("")
                Text("float16").tag("float16")
                Text("bfloat16").tag("bfloat16")
                Text("float32").tag("float32")
            }
            .frame(maxWidth: 240)
            LabeledContent("Upload to HF (optional)") {
                TextField("your-org/your-model", text: $convertConfig.uploadRepo)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Convert") { service.startConvert(convertConfig) }
                    .disabled(jobRunning || !envReady)
                Spacer()
            }
            MLXJobPane(service: service, state: pane)
        }
    }

    private var suggestedConvertFolderName: String {
        let base = (convertConfig.hfPath as NSString).lastPathComponent
        let name = base.isEmpty ? "model" : base
        return convertConfig.quantize ? "\(name)-\(convertConfig.qBits)bit-mlx" : "\(name)-mlx"
    }
}

// MARK: - Playground

private struct MLXPlaygroundSection: View, Equatable {
    let service: MLXService
    let envReady: Bool
    let jobRunning: Bool
    let serverModel: String
    let pane: MLXService.JobPaneState
    @Binding var playModel: String
    /// Value copy of `playModel` for the nonisolated `==` (same rationale as
    /// MLXServerSection.currentConfig) — the field must re-render when the Models
    /// section's "Try" writes the shared state.
    let playModelValue: String
    /// Shared with the fine-tune after-run "Try with adapter" (WS-M4), same pattern
    /// as playModel: a binding to write + a value copy for the nonisolated `==`.
    @Binding var playAdapter: String
    let playAdapterValue: String

    @State private var playPrompt = ""
    @State private var playMaxTokens = 512
    @State private var playTemperature = ""
    @State private var playTopP = ""
    // KV-cache controls (WS-M1): generate is where mlx_lm's quantized-KV flags
    // actually exist (the server has none — verified against 0.31.3).
    @State private var playKVBits: Int?
    @State private var playKVGroup = ""
    @State private var playKVStart = ""
    @State private var playMaxKV = ""

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.envReady == rhs.envReady && lhs.jobRunning == rhs.jobRunning
            && lhs.serverModel == rhs.serverModel && lhs.pane == rhs.pane
            && lhs.playModelValue == rhs.playModelValue
            && lhs.playAdapterValue == rhs.playAdapterValue
    }

    var body: some View {
        Section("Playground (one-shot mlx_lm.generate)") {
            LabeledContent("Model") {
                HStack {
                    TextField("mlx-community/… or /path/to/model", text: $playModel)
                        .textFieldStyle(.roundedBorder)
                    Button("Use server model") { playModel = serverModel }
                        .disabled(serverModel.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $playPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 70)
                    .border(.quaternary)
            }
            HStack(spacing: 16) {
                LabeledContent("Max tokens") {
                    TextField("512", value: $playMaxTokens, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                LabeledContent("Temp") {
                    TextField("default", text: $playTemperature)
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
                LabeledContent("Top-p") {
                    TextField("default", text: $playTopP)
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            LabeledContent("Adapter (optional)") {
                HStack {
                    TextField("LoRA adapter folder", text: $playAdapter)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { playAdapter = $0 } }
                }
            }
            DisclosureGroup("KV cache (advanced)") {
                Picker("KV quantization", selection: $playKVBits) {
                    Text("Off (16-bit)").tag(Int?.none)
                    Text("8-bit").tag(Int?.some(8))
                    Text("4-bit").tag(Int?.some(4))
                }
                .help(
                    "--kv-bits — quantizes the key/value cache while generating: big memory savings on long outputs, slight quality cost. 8-bit is nearly lossless; 4-bit halves that again for a small further cost."
                )
                if playKVBits != nil {
                    LabeledContent("Group size") {
                        TextField("64", text: $playKVGroup)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    .help(
                        "--kv-group-size — how many values share one quantization scale. Smaller groups track the data closer (better quality, slightly more memory). Blank = mlx default (64)."
                    )
                    LabeledContent("Quantize after (tokens)") {
                        TextField("5000", text: $playKVStart)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    .help(
                        "--quantized-kv-start — keep the first N tokens of cache un-quantized (the prompt matters most). Blank = mlx default (5000)."
                    )
                }
                LabeledContent("Max KV size (tokens)") {
                    TextField("unlimited", text: $playMaxKV)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                .help(
                    "--max-kv-size — rotating cap on the cached context. Bounds memory on very long generations; the model gradually forgets the oldest tokens past the cap."
                )
            }
            HStack {
                Button("Generate") {
                    service.runGenerate(
                        MLXGenerateConfig(
                            model: playModel.trimmingCharacters(in: .whitespacesAndNewlines),
                            prompt: playPrompt,
                            maxTokens: max(1, playMaxTokens),
                            temperature: parseDouble(playTemperature),
                            topP: parseDouble(playTopP),
                            adapterPath: playAdapter.trimmingCharacters(in: .whitespacesAndNewlines),
                            kvBits: playKVBits,
                            kvGroupSize: playKVBits != nil
                                ? Int(playKVGroup.trimmingCharacters(in: .whitespaces)) : nil,
                            quantizedKVStart: playKVBits != nil
                                ? Int(playKVStart.trimmingCharacters(in: .whitespaces)) : nil,
                            maxKVSize: Int(playMaxKV.trimmingCharacters(in: .whitespaces))))
                }
                .disabled(jobRunning || !envReady)
                Spacer()
                Text("Exercises a model directly — no server, no agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MLXJobPane(service: service, state: pane)
        }
    }
}

// MARK: - Fine-tune / fuse

private struct MLXFineTuneSection: View, Equatable {
    let service: MLXService
    let envReady: Bool
    let jobRunning: Bool
    let fineTunePane: MLXService.JobPaneState
    let fusePane: MLXService.JobPaneState
    let lossHistory: MLXLossHistory
    let cachedModels: [MLXCachedModel]
    let managedServerRunning: Bool
    let serverMemoryBytes: Int64?
    @Binding var playModel: String
    @Binding var playAdapter: String

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.envReady == rhs.envReady && lhs.jobRunning == rhs.jobRunning
            && lhs.fineTunePane == rhs.fineTunePane && lhs.fusePane == rhs.fusePane
            && lhs.lossHistory == rhs.lossHistory && lhs.cachedModels == rhs.cachedModels
            && lhs.managedServerRunning == rhs.managedServerRunning
            && lhs.serverMemoryBytes == rhs.serverMemoryBytes
    }

    var body: some View {
        Section("Fine-tune (mlx_lm.lora) + fuse") {
            // WS-M4: guided/expert modes, dataset assistant, memory preflight, live
            // loss chart, after-run try/fuse — all in FineTuneGuideView (its own
            // file). This section stays a narrow Equatable wrapper.
            FineTuneGuideView(
                service: service, envReady: envReady, jobRunning: jobRunning,
                fineTunePane: fineTunePane, fusePane: fusePane,
                lossHistory: lossHistory, cachedModels: cachedModels,
                managedServerRunning: managedServerRunning, serverMemoryBytes: serverMemoryBytes,
                playModel: $playModel, playAdapter: $playAdapter)
        }
    }
}

// MARK: - Shared pieces

/// The inline job card: progress + cancel while a matching job runs, its result
/// label afterwards, and the terminal output whenever the (already
/// section-filtered) window is non-empty. Equatable on the pane state alone so a
/// job streaming in one section never re-lays-out the others.
/// Internal so FineTuneGuideView (a separate file) reuses it.
struct MLXJobPane: View, Equatable {
    let service: MLXService
    let state: MLXService.JobPaneState

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var body: some View {
        if let job = state.activeJob {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.title).font(.caption)
                Text(job.startedAt, style: .timer)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { service.cancelActiveJob() }.controlSize(.small)
            }
        } else if let result = state.lastResult {
            Label(
                result.message,
                systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(result.success ? Color.green : Color.orange)
        }
        if !state.logWindow.isEmpty {
            MLXLogPane(rows: state.logWindow)
        }
    }
}

/// Terminal-style pane: one `Text` PER LINE in a `LazyVStack`, ids stable across
/// appends so unchanged rows aren't re-laid-out. Rows arrive precomputed
/// (MLXService's bounded 300-line windows) — no per-body suffix/map here.
private struct MLXLogPane: View, Equatable {
    let rows: [MLXLogRow]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("(no output yet)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(2)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 150)
        .border(.quaternary)
    }
}

private func parseDouble(_ raw: String) -> Double? {
    Double(raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
}

// Internal (not private) so FineTuneGuideView (a separate file) reuses them.
@MainActor
func pickFolder(_ assign: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    // Models overwhelmingly live under DOT-directories (~/.cache/huggingface/hub,
    // ~/.lmstudio, our own ~/.config/eldr-acp/mlx) — an open panel that hides them
    // makes every model folder unreachable without knowing ⌘⇧. .
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    panel.prompt = "Select"
    if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
}

/// Pick a NEW folder location (the mlx tools create it; convert refuses an
/// existing one).
@MainActor
func pickSaveLocation(defaultName: String, _ assign: @escaping (String) -> Void) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    panel.nameFieldStringValue = defaultName
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
}

/// Pick an existing FILE (dataset validation, CSV/text import for the assistant).
@MainActor
func pickFile(_ assign: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.prompt = "Select"
    if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
}
