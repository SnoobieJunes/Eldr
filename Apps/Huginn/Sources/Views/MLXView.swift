import AppKit
import SwiftUI

/// The MLX tab: a full GUI over the `mlx_lm` CLI surface — environment
/// install, OpenAI-compatible server (wired into the Eldr LLM seam with one
/// click), Hugging Face model manager, convert/quantize, a one-shot generate
/// playground, and LoRA fine-tune + fuse. Everything runs through `MLXService`;
/// long operations are exclusive "jobs" whose terminal output renders inline in
/// the section that started them.
struct MLXView: View {
    @EnvironmentObject private var store: ConfigurationStore
    /// The ONE app-wide MLX engine (owns the server child, jobs, and the log tail).
    /// Deliberately not a `@StateObject`: a recreated tab view must observe the same
    /// instance, not spawn a second service that lost the running server.
    @ObservedObject private var service = MLXService.shared

    // Server "Advanced" numeric fields are optionals in the config; SwiftUI's
    // numeric TextFields fight mid-typing round-trips, so these are seeded once
    // and written through on change.
    @State private var advMaxTokens = ""
    @State private var advTemperature = ""
    @State private var advTopP = ""
    @State private var seeded = false

    // Models
    @State private var searchQuery = ""
    @State private var searchPublisher = "mlx-community"
    @State private var searchMLXOnly = true
    @State private var searchSort = "downloads"
    @State private var deleteCandidate: MLXCachedModel?

    // Convert
    @State private var convertConfig = MLXConvertConfig()

    // Playground
    @State private var playModel = ""
    @State private var playPrompt = ""
    @State private var playMaxTokens = 512
    @State private var playTemperature = ""
    @State private var playTopP = ""
    @State private var playAdapter = ""

    // Fine-tune / fuse
    @State private var fineTuneConfig = MLXFineTuneConfig()
    @State private var fuseModel = ""
    @State private var fuseAdapters = ""
    @State private var fuseSavePath = ""

    /// Confirmation caption captured at click time (so later config edits can't
    /// make it claim something that wasn't written).
    @State private var backendNote: String?

    private var jobRunning: Bool { service.activeJob != nil }

    var body: some View {
        Form {
            environmentSection
            serverSection
            modelsSection
            convertSection
            playgroundSection
            fineTuneSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: 1100, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            if !seeded {
                seeded = true
                advMaxTokens = service.serverConfig.maxTokens.map(String.init) ?? ""
                advTemperature = service.serverConfig.temperature.map(MLXCommand.formatNumber) ?? ""
                advTopP = service.serverConfig.topP.map(MLXCommand.formatNumber) ?? ""
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

    // MARK: - Environment

    private var environmentSection: some View {
        Section("MLX environment") {
            HStack(spacing: 8) {
                Circle().fill(envColor).frame(width: 8, height: 8)
                Text(envText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check") { Task { await service.refreshEnvironment() } }
                    .controlSize(.small)
            }
            Text(
                "A private Python environment (uv preferred, python3 fallback) with the mlx-lm toolkit, installed under \(service.mlxDir). Everything in this tab runs through it; your system Python is untouched."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(installButtonTitle) { service.installEnvironment() }
                    .disabled(jobRunning || !installAvailable)
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: service.mlxDir)])
                }
            }
            jobPane([.installEnvironment])
        }
    }

    private var installAvailable: Bool {
        if case .unsupported = service.envState { return false }
        return true
    }

    private var installButtonTitle: String {
        switch service.envState {
        case .ready: return "Update mlx-lm"
        case .broken: return "Repair install"
        default: return "Install mlx-lm"
        }
    }

    private var envColor: Color {
        switch service.envState {
        case .ready: return .green
        case .notInstalled: return .orange
        case .broken, .unsupported: return .red
        case .unknown: return .secondary
        }
    }

    private var envText: String {
        switch service.envState {
        case .ready(let version): return "mlx-lm \(version) — ready"
        case .notInstalled: return "Not installed yet"
        case .broken(let why): return why
        case .unsupported(let why): return why
        case .unknown: return "Checking…"
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        Section("Server (OpenAI-compatible, mlx_lm.server)") {
            LabeledContent("Model") {
                HStack(spacing: 6) {
                    TextField("mlx-community/… or /path/to/model", text: $service.serverConfig.model)
                        .textFieldStyle(.roundedBorder)
                    if !service.cachedModels.isEmpty {
                        Menu("Cached") {
                            ForEach(service.cachedModels) { model in
                                Button(model.repoID) { service.serverConfig.model = model.repoID }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Browse…") { pickFolder { service.serverConfig.model = $0 } }
                }
            }
            LabeledContent("Host") {
                TextField("127.0.0.1", text: $service.serverConfig.host)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
            }
            LabeledContent("Port") {
                TextField("8080", value: $service.serverConfig.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 90)
            }

            DisclosureGroup("Advanced") {
                LabeledContent("Default max tokens") {
                    TextField("server default", text: $advMaxTokens)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                        .onChange(of: advMaxTokens) { _, new in
                            service.serverConfig.maxTokens = Int(new.trimmingCharacters(in: .whitespaces))
                        }
                }
                LabeledContent("Default temperature") {
                    TextField("unset", text: $advTemperature)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                        .onChange(of: advTemperature) { _, new in
                            service.serverConfig.temperature = Self.parseDouble(new)
                        }
                }
                LabeledContent("Default top-p") {
                    TextField("unset", text: $advTopP)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 120)
                        .onChange(of: advTopP) { _, new in
                            service.serverConfig.topP = Self.parseDouble(new)
                        }
                }
                Text(
                    "Sampling defaults need a recent mlx-lm. Leave blank to omit the flags — an older server rejects them with an argparse error (visible in the log)."
                )
                .font(.caption).foregroundStyle(.secondary)
                Toggle("Trust remote code (--trust-remote-code)", isOn: $service.serverConfig.trustRemoteCode)
                Toggle("Use the tokenizer's default chat template", isOn: $service.serverConfig.useDefaultChatTemplate)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat template override (Jinja, passed verbatim to --chat-template)")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $service.serverConfig.chatTemplate)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 40)
                        .border(.quaternary)
                }
                LabeledContent("Adapter path") {
                    HStack {
                        TextField("(none)", text: $service.serverConfig.adapterPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { pickFolder { service.serverConfig.adapterPath = $0 } }
                    }
                }
                LabeledContent("Extra arguments") {
                    TextField("--log-level DEBUG", text: $service.serverConfig.extraArguments)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Extra arguments are whitespace-split — no shell quoting.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            serverStatusRow

            if let warning = service.serverWarning {
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
                    .disabled(!service.envState.isReady || service.serverConfig.model.isEmpty)
                Button("Stop") { service.stopServer() }
                    .disabled(!serverStoppable)
                Spacer()
                Button("Use as Eldr LLM backend") {
                    service.useAsEldrBackend(store: store)
                    backendNote =
                        "Configuration ▸ Local LLM now points at \(service.serverConfig.baseURL) (\(service.serverConfig.model))."
                }
                .disabled(service.serverConfig.model.isEmpty)
            }
            if let backendNote {
                Label(backendNote, systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }

            Toggle("Start at login (launchd)", isOn: autostartBinding)
            Text(
                autostartEnabledNow
                    ? "launchd owns the server process: Start/Restart rewrites the LaunchAgent and relaunches it; Stop sends SIGTERM through launchctl."
                    : "Off: the server runs as a child of this app and stops when Huginn quits."
            )
            .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Server log (\(service.serverLogPath))")
                    .font(.caption).foregroundStyle(.secondary)
                logPane(
                    service.serverLog.lines.suffix(Self.logPaneMaxLines)
                        .map { LogRow(id: $0.id, text: $0.text) })
            }
        }
    }

    private var autostartEnabledNow: Bool { service.autostartEnabled }

    private var autostartBinding: Binding<Bool> {
        Binding(
            get: { service.autostartEnabled },
            set: { on in Task { await service.setAutostart(on) } })
    }

    private var startButtonTitle: String {
        if service.autostartEnabled { return "Start / Restart (launchd)" }
        if case .stopped = service.serverState { return "Start" }
        if case .failed = service.serverState { return "Start" }
        return "Restart"
    }

    private var serverStoppable: Bool {
        if service.autostartEnabled { return true }
        switch service.serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var restartHintVisible: Bool {
        guard let launched = service.launchedServerConfig else { return false }
        guard launched != service.serverConfig else { return false }
        if service.autostartEnabled { return true }
        switch service.serverState {
        case .starting, .running: return true
        default: return false
        }
    }

    private var serverStatusRow: some View {
        HStack(spacing: 8) {
            Circle().fill(serverColor).frame(width: 8, height: 8)
            Text(serverText).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var serverColor: Color {
        if service.autostartEnabled {
            return service.probeStatus.isReachable ? .green : .orange
        }
        switch service.serverState {
        case .running(let healthy): return healthy ? .green : .orange
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var serverText: String {
        if service.autostartEnabled {
            return service.probeStatus.isReachable
                ? "Running (launchd) — answering on \(service.serverConfig.baseURL)"
                : "launchd-managed — not answering on \(service.serverConfig.baseURL) yet"
        }
        switch service.serverState {
        case .stopped: return "Stopped"
        case .starting: return "Starting — waiting for \(service.serverConfig.baseURL)/models…"
        case .running(true): return "Running — answering on \(service.serverConfig.baseURL)"
        case .running(false): return "Process alive but not answering — see the log"
        case .failed(let why): return why
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        Section("Models — Hugging Face cache") {
            HStack {
                Text("\(service.cachedModels.count) cached — \(totalCacheLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { service.refreshCachedModels() }.controlSize(.small)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: service.cacheDir)])
                }
                .controlSize(.small)
            }
            Text(service.cacheDir)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            ForEach(service.cachedModels) { model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.repoID).font(.callout)
                        Text(model.sizeBytes.formatted(.byteCount(style: .file)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Serve") { service.serverConfig.model = model.repoID }
                        .controlSize(.small)
                    Button("Try") { playModel = model.repoID }
                        .controlSize(.small)
                    Button(role: .destructive) {
                        deleteCandidate = model
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Delete \(model.repoID)")
                }
            }
            if service.cachedModels.isEmpty {
                Text("No models cached yet — search below and download one (small 4-bit instruct models from mlx-community are a good start).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                TextField("Search Hugging Face models…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }.disabled(service.isSearching)
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
            if service.isSearching {
                HStack { ProgressView().controlSize(.small); Text("Searching…").font(.caption) }
            }
            if let error = service.modelsError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(service.searchResults) { result in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(result.id).font(.callout)
                            if let quant = result.quantLabel {
                                Text(quant)
                                    .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            if !result.isMLX && searchMLXOnly == false {
                                Text("not MLX")
                                    .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(.orange.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(searchResultCaption(result)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let page = URL(string: "https://huggingface.co/\(result.id)") {
                        Link(destination: page) { Image(systemName: "safari") }
                            .controlSize(.small)
                            .accessibilityLabel("Open \(result.id) on Hugging Face")
                    }
                    Button("Download") { service.downloadModel(result.id) }
                        .controlSize(.small)
                        .disabled(jobRunning)
                }
            }
            jobPane([.download])
        }
    }

    /// Re-run the current search when a filter changes and results are showing (the
    /// LM Studio behavior — filters act on the live list, not just the next search).
    private func refreshSearchIfActive() {
        if !service.searchResults.isEmpty || !searchQuery.isEmpty { runSearch() }
    }

    private var totalCacheLabel: String {
        service.cachedModels.map(\.sizeBytes).reduce(0, +)
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

    // MARK: - Convert

    private var convertSection: some View {
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
                    .disabled(jobRunning || !service.envState.isReady)
                Spacer()
            }
            jobPane([.convert])
        }
    }

    private var suggestedConvertFolderName: String {
        let base = (convertConfig.hfPath as NSString).lastPathComponent
        let name = base.isEmpty ? "model" : base
        return convertConfig.quantize ? "\(name)-\(convertConfig.qBits)bit-mlx" : "\(name)-mlx"
    }

    // MARK: - Playground

    private var playgroundSection: some View {
        Section("Playground (one-shot mlx_lm.generate)") {
            LabeledContent("Model") {
                HStack {
                    TextField("mlx-community/… or /path/to/model", text: $playModel)
                        .textFieldStyle(.roundedBorder)
                    Button("Use server model") { playModel = service.serverConfig.model }
                        .disabled(service.serverConfig.model.isEmpty)
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
            HStack {
                Button("Generate") {
                    service.runGenerate(
                        MLXGenerateConfig(
                            model: playModel.trimmingCharacters(in: .whitespacesAndNewlines),
                            prompt: playPrompt,
                            maxTokens: max(1, playMaxTokens),
                            temperature: Self.parseDouble(playTemperature),
                            topP: Self.parseDouble(playTopP),
                            adapterPath: playAdapter.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                .disabled(jobRunning || !service.envState.isReady)
                Spacer()
                Text("Exercises a model directly — no server, no agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            jobPane([.generate])
        }
    }

    // MARK: - Fine-tune / fuse

    private var fineTuneSection: some View {
        Section("Fine-tune (mlx_lm.lora) + fuse") {
            LabeledContent("Base model") {
                HStack {
                    TextField("mlx-community/… or /path/to/model", text: $fineTuneConfig.model)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { fineTuneConfig.model = $0 } }
                }
            }
            LabeledContent("Data folder") {
                HStack {
                    TextField("folder with train.jsonl + valid.jsonl", text: $fineTuneConfig.dataDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { fineTuneConfig.dataDir = $0 } }
                }
            }
            if let status = dataDirStatus {
                Label(status.text, systemImage: status.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(status.ok ? Color.green : Color.orange)
            }
            LabeledContent("Adapter output") {
                HStack {
                    TextField("(auto — under the MLX folder)", text: $fineTuneConfig.adapterPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        pickSaveLocation(defaultName: "adapters") { fineTuneConfig.adapterPath = $0 }
                    }
                }
            }
            Picker("Type", selection: $fineTuneConfig.fineTuneType) {
                Text("LoRA").tag("lora")
                Text("DoRA").tag("dora")
                Text("Full").tag("full")
            }
            .pickerStyle(.segmented).frame(maxWidth: 240)
            HStack(spacing: 16) {
                Stepper("Layers: \(fineTuneConfig.numLayers)", value: $fineTuneConfig.numLayers, in: 1...128)
                Stepper("Batch: \(fineTuneConfig.batchSize)", value: $fineTuneConfig.batchSize, in: 1...32)
            }
            HStack(spacing: 16) {
                LabeledContent("Iterations") {
                    TextField("600", value: $fineTuneConfig.iters, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                }
                LabeledContent("Learning rate") {
                    TextField("1e-5", value: $fineTuneConfig.learningRate, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            if fineTuneConfig.fineTuneType != "full" {
                HStack(spacing: 16) {
                    LabeledContent("Rank") {
                        TextField("8", value: $fineTuneConfig.loraRank, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    LabeledContent("Scale") {
                        TextField("20", value: $fineTuneConfig.loraScale, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                    LabeledContent("Dropout") {
                        TextField("0", value: $fineTuneConfig.loraDropout, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 60)
                    }
                }
            }
            HStack {
                Button("Start fine-tune") { service.startFineTune(fineTuneConfig) }
                    .disabled(jobRunning || !service.envState.isReady)
                Spacer()
                Text("Live train/val loss streams below; Cancel stops the run (adapters checkpoint as they go).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            jobPane([.finetune])

            Divider()

            Text("Fuse — bake trained adapters into a standalone model (usable in the sections above).")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Model") {
                HStack {
                    TextField("base model", text: $fuseModel).textFieldStyle(.roundedBorder)
                    Button("From fine-tune") {
                        fuseModel = fineTuneConfig.model
                        fuseAdapters = fineTuneConfig.adapterPath
                    }
                    .disabled(fineTuneConfig.model.isEmpty)
                }
            }
            LabeledContent("Adapters") {
                HStack {
                    TextField("adapter folder", text: $fuseAdapters).textFieldStyle(.roundedBorder)
                    Button("Browse…") { pickFolder { fuseAdapters = $0 } }
                }
            }
            LabeledContent("Save to") {
                HStack {
                    TextField("new folder for the fused model", text: $fuseSavePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        pickSaveLocation(defaultName: "fused-model") { fuseSavePath = $0 }
                    }
                }
            }
            HStack {
                Button("Fuse") {
                    service.startFuse(model: fuseModel, adapterPath: fuseAdapters, savePath: fuseSavePath)
                }
                .disabled(jobRunning || !service.envState.isReady)
                Spacer()
            }
            jobPane([.fuse])
        }
    }

    private var dataDirStatus: (ok: Bool, text: String)? {
        let dir = fineTuneConfig.dataDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return nil }
        let fm = FileManager.default
        let train = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("train.jsonl"))
        let valid = fm.fileExists(atPath: (dir as NSString).appendingPathComponent("valid.jsonl"))
        if train && valid { return (true, "train.jsonl and valid.jsonl found") }
        var missing: [String] = []
        if !train { missing.append("train.jsonl") }
        if !valid { missing.append("valid.jsonl") }
        return (false, "Missing \(missing.joined(separator: " and ")) in that folder")
    }

    // MARK: - Shared pieces

    /// The inline job card: progress + cancel while a matching job runs, its
    /// result label afterwards, and the terminal output whenever the buffer
    /// belongs to one of `kinds`.
    @ViewBuilder
    private func jobPane(_ kinds: Set<MLXService.JobKind>) -> some View {
        if let job = service.activeJob, kinds.contains(job.kind) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job.title).font(.caption)
                Text(job.startedAt, style: .timer)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { service.cancelActiveJob() }.controlSize(.small)
            }
        } else if let result = service.lastJobResult, kinds.contains(result.kind) {
            Label(
                result.message,
                systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(result.success ? Color.green : Color.orange)
        }
        if let kind = service.jobLogKind, kinds.contains(kind), !service.jobLog.isEmpty {
            let lines = service.jobLog.lines
            let base = max(0, lines.count - Self.logPaneMaxLines)
            logPane(lines.suffix(Self.logPaneMaxLines).enumerated().map {
                LogRow(id: base + $0.offset, text: $0.element)
            })
        }
    }

    /// Rows kept in a log pane. Bounded because SwiftUI must diff/lay out every row
    /// on each append; the old single-`Text`-with-the-whole-log rendering re-laid-out
    /// hundreds of KB per update and visibly froze the app every few seconds while
    /// the server was writing (health-poll lines land every ~5 s).
    private static let logPaneMaxLines = 300

    /// One rendered log line (a struct because ForEach needs Identifiable and Swift
    /// key paths can't point at tuple elements).
    private struct LogRow: Identifiable {
        let id: Int
        let text: String
    }

    /// Terminal-style pane: one `Text` PER LINE in a `LazyVStack`, ids stable across
    /// appends so unchanged rows aren't re-laid-out.
    private func logPane(_ allLines: [LogRow]) -> some View {
        let visible = allLines.suffix(Self.logPaneMaxLines)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if visible.isEmpty {
                    Text("(no output yet)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visible) { line in
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

    private static func parseDouble(_ raw: String) -> Double? {
        Double(raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private func pickFolder(_ assign: @escaping (String) -> Void) {
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
    private func pickSaveLocation(defaultName: String, _ assign: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
    }
}
