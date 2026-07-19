import AppKit
import Charts
import SwiftUI

/// The teachable fine-tune surface (WS-M4): Guided (default) or Expert mode, a
/// dataset assistant, a memory preflight, a live Swift-Charts loss curve, and an
/// after-run try/fuse flow. Lives in its own file per the plan; rendered inside
/// `MLXFineTuneSection` (the Equatable Form section). Streaming loss updates only
/// re-render `MLXLossChartView` (its own Equatable child) — the form scaffolding
/// is `@State`-driven and doesn't churn on loss ticks.
struct FineTuneGuideView: View {
    let service: MLXService
    let envReady: Bool
    let jobRunning: Bool
    let fineTunePane: MLXService.JobPaneState
    let fusePane: MLXService.JobPaneState
    let lossHistory: MLXLossHistory
    let cachedModels: [MLXCachedModel]
    /// A Huginn-managed server is running (so "stop it during training" is offered).
    let managedServerRunning: Bool
    let serverMemoryBytes: Int64?
    @Binding var playModel: String
    @Binding var playAdapter: String

    enum Mode: String, CaseIterable, Identifiable {
        case guided = "Guided"
        case expert = "Expert"
        var id: String { rawValue }
    }

    @State private var config = MLXFineTuneConfig()
    @State private var mode: Mode = .guided
    @State private var preset: MLXFineTunePreset = .balanced
    @State private var showTour = false
    @State private var datasetSheet = false
    @State private var datasetReport: MLXDatasetReport?
    @State private var datasetNote: String?
    @State private var memory: MLXMemoryVerdict?

    @State private var fuseModel = ""
    @State private var fuseAdapters = ""
    @State private var fuseSavePath = ""

    // Grouped into a handful of @ViewBuilder blocks so each stays under SwiftUI's
    // 10-child ViewBuilder limit; Group/tuple children still flatten to Form rows.
    var body: some View {
        header
        baseModelStep
        dataStep
        if mode == .guided { presetStep } else { expertKnobs }
        memoryPreflight
        startRow
        runOutput
        fuseBlock
            .sheet(isPresented: $datasetSheet) { datasetAssistant }
    }

    @ViewBuilder
    private var header: some View {
        DisclosureGroup("How fine-tuning works", isExpanded: $showTour) { tourCards }
        Picker("Mode", selection: $mode) {
            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).frame(maxWidth: 240)
        Text(
            mode == .guided
                ? "Guided: base model → data → preset, then Start."
                : "Expert: every knob, explained in place (hover the ⓘ)."
        )
        .font(.caption).foregroundStyle(.secondary)
    }

    private var startRow: some View {
        HStack {
            Button("Start fine-tune") { startFineTune() }
                .disabled(jobRunning || !envReady || !canStart)
            Spacer()
            Text("Cancel stops the run — adapters checkpoint as they go.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var runOutput: some View {
        if fineTunePane.activeJob != nil || !lossHistory.isEmpty {
            lossSection
        }
        MLXJobPane(service: service, state: fineTunePane)
        if fineTunePane.activeJob == nil, fineTunePane.lastResult?.success == true {
            afterRunCard
        }
    }

    @ViewBuilder
    private var fuseBlock: some View {
        Divider()
        fuseSection
    }

    // MARK: Step 1 — base model

    @ViewBuilder
    private var baseModelStep: some View {
        LabeledContent("Base model") {
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
        Text("A small instruct model (e.g. a 4-bit mlx-community build) trains fastest.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Step 2 — data

    @ViewBuilder
    private var dataStep: some View {
        LabeledContent("Data folder") {
            HStack {
                TextField("folder with train.jsonl + valid.jsonl", text: $config.dataDir)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") { pickFolder { config.dataDir = $0 } }
                Button("Dataset help…") { datasetSheet = true }
            }
        }
        if let status = dataDirStatus {
            Label(
                status.text, systemImage: status.ok ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(status.ok ? Color.green : Color.orange)
        }
        if let report = datasetReport {
            datasetReportView(report)
        }
    }

    // MARK: Step 3a — guided preset

    @ViewBuilder
    private var presetStep: some View {
        Picker("Preset", selection: $preset) {
            ForEach(MLXFineTunePreset.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).frame(maxWidth: 360)
        Text(preset.summary).font(.caption).foregroundStyle(.secondary)
        Picker("Method", selection: $config.fineTuneType) {
            Text("LoRA").tag("lora")
            Text("DoRA").tag("dora")
            Text("Full").tag("full")
        }
        .pickerStyle(.segmented).frame(maxWidth: 240)
        .help(MLXCommand.knobHelp("type"))
        let applied = preset.applied(to: config)
        Text(
            "This preset: \(applied.iters) iters · batch \(applied.batchSize) · \(applied.numLayers) layers · lr \(MLXCommand.formatNumber(applied.learningRate)). Switch to Expert to fine-tune every knob."
        )
        .font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Step 3b — expert knobs

    @ViewBuilder
    private var expertKnobs: some View {
        LabeledContent("Adapter output") {
            HStack {
                TextField("(auto — under the MLX folder)", text: $config.adapterPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    pickSaveLocation(defaultName: "adapters") { config.adapterPath = $0 }
                }
            }
        }
        knobRow("Method") {
            Picker("", selection: $config.fineTuneType) {
                Text("LoRA").tag("lora")
                Text("DoRA").tag("dora")
                Text("Full").tag("full")
            }
            .pickerStyle(.segmented).frame(maxWidth: 240).labelsHidden()
        } help: { MLXCommand.knobHelp("type") }

        HStack(spacing: 16) {
            Stepper("Layers: \(config.numLayers)", value: $config.numLayers, in: 1...128)
                .help(MLXCommand.knobHelp("layers"))
            Stepper("Batch: \(config.batchSize)", value: $config.batchSize, in: 1...32)
                .help(MLXCommand.knobHelp("batch"))
        }
        HStack(spacing: 16) {
            numberField("Iterations", value: $config.iters, width: 80, help: MLXCommand.knobHelp("iters"))
            LabeledContent("Learning rate") {
                TextField("1e-5", value: $config.learningRate, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 100)
                    .help(MLXCommand.knobHelp("learningRate"))
            }
        }
        if config.fineTuneType != "full" {
            HStack(spacing: 16) {
                numberField("Rank", value: $config.loraRank, width: 60, help: MLXCommand.knobHelp("rank"))
                LabeledContent("Scale") {
                    TextField("20", value: $config.loraScale, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                        .help(MLXCommand.knobHelp("scale"))
                }
                LabeledContent("Dropout") {
                    TextField("0", value: $config.loraDropout, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 60)
                        .help(MLXCommand.knobHelp("dropout"))
                }
            }
        }
        HStack(spacing: 16) {
            numberField("Save every", value: $config.saveEvery, width: 70,
                help: "Write a checkpoint adapter every N iterations.")
            numberField("Validate every", value: $config.valEvery, width: 70,
                help: "Run the validation set every N iterations (the val curve).")
            numberField("Max seq", value: $config.maxSeqLength, width: 80, help: MLXCommand.knobHelp("maxSeq"))
        }
        Toggle("Gradient checkpointing (less memory, slower)", isOn: $config.gradCheckpoint)
            .help("Recompute activations instead of storing them — a big memory saving at some speed cost. Turn on if training runs out of memory.")
    }

    // MARK: Memory preflight

    @ViewBuilder
    private var memoryPreflight: some View {
        HStack(spacing: 8) {
            Button("Check memory") { refreshMemory() }.controlSize(.small)
            if let memory {
                Image(systemName: memoryIcon(memory.level))
                    .foregroundStyle(memoryColor(memory.level))
            }
            Spacer()
        }
        if let memory {
            Text(memory.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if managedServerRunning {
                HStack(spacing: 8) {
                    Button("Stop the MLX server during training") { service.stopServer() }
                        .controlSize(.small)
                    if let bytes = serverMemoryBytes {
                        Text("frees ≈ \(bytes.formatted(.byteCount(style: .memory)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help("Huginn can only stop the server it manages. Any other model on the machine (e.g. a detached server or LM Studio) shows up as pressure it can't control.")
            }
        }
    }

    // MARK: Loss chart + checkpoints

    @ViewBuilder
    private var lossSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Training loss").font(.caption).foregroundStyle(.secondary)
            MLXLossChartView(history: lossHistory)
            Text(MLXCommand.lossTrend(lossHistory)).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if !lossHistory.checkpoints.isEmpty {
                Text("Checkpoints: \(lossHistory.checkpoints.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.head)
            }
        }
    }

    // MARK: After-run

    @ViewBuilder
    private var afterRunCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fine-tune finished — try the adapter.", systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.green)
            HStack {
                Button("Try with adapter") {
                    playModel = config.model
                    playAdapter = resolvedAdapterPath
                }
                .controlSize(.small)
                .disabled(config.model.isEmpty || resolvedAdapterPath.isEmpty)
                Button("Fuse this adapter") {
                    fuseModel = config.model
                    fuseAdapters = resolvedAdapterPath
                }
                .controlSize(.small)
                .disabled(config.model.isEmpty || resolvedAdapterPath.isEmpty)
                Spacer()
            }
            Text("“Try with adapter” fills the Playground with this base + adapter; clear the adapter there to compare against the base.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Fuse

    @ViewBuilder
    private var fuseSection: some View {
        Text("Fuse — bake trained adapters into a standalone model (usable in the sections above).")
            .font(.caption).foregroundStyle(.secondary)
        LabeledContent("Model") {
            HStack {
                TextField("base model", text: $fuseModel).textFieldStyle(.roundedBorder)
                Button("From fine-tune") {
                    fuseModel = config.model
                    fuseAdapters = resolvedAdapterPath
                }
                .disabled(config.model.isEmpty)
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
            .disabled(jobRunning || !envReady)
            Spacer()
        }
        MLXJobPane(service: service, state: fusePane)
    }

    // MARK: Dataset assistant sheet

    private var datasetAssistant: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dataset assistant").font(.title3).bold()
            Text("mlx_lm accepts JSONL — one record per line — in these shapes (it picks the first that fits: prompt+completion, then messages, then text):")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach([MLXDatasetFormat.completions, .chat, .text], id: \.rawValue) { format in
                VStack(alignment: .leading, spacing: 2) {
                    Text(format.label).font(.caption).bold()
                    Text(MLXCommand.datasetTemplate(format))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Divider()
            Text("Validate a file").font(.caption).bold()
            HStack {
                Button("Validate a .jsonl…") { validatePicked() }
                Button("Import a CSV → train/valid…") { importCSV() }
            }
            if let datasetNote {
                Text(datasetNote).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your data stays on this machine — the assistant never reads chat history or memory, and never logs record contents.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { datasetSheet = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }

    @ViewBuilder
    private func datasetReportView(_ report: MLXDatasetReport) -> some View {
        if report.ok, let format = report.format {
            Label(
                "\(report.recordCount) records checked · \(format.label)",
                systemImage: "checkmark.circle"
            )
            .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    report.format == nil
                        ? "No recognized format in the sample."
                        : "\(report.recordCount) checked · \(report.errors.count) problem(s)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
                ForEach(report.errors.prefix(5), id: \.line) { error in
                    Text("line \(error.line): \(error.kind)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var tourCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            tourCard("1 · Pick a base", "Start from a small instruct model you've already downloaded. Fine-tuning teaches it your style/task on top.")
            tourCard("2 · Bring data", "A folder with train.jsonl + valid.jsonl. Use the Dataset help to see the shapes and validate a file.")
            tourCard("3 · Choose effort", "A preset sets sensible iters/batch/layers. Watch the loss curve: falling = learning.")
            tourCard("4 · Try it", "When it finishes, one tap loads the adapter into the Playground so you can feel the difference — then Fuse to bake it in.")
        }
    }

    private func tourCard(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).bold()
            Text(body).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Small helpers

    private func knobRow<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content, help: () -> String
    ) -> some View {
        LabeledContent(label) { content() }.help(help())
    }

    private func numberField(_ label: String, value: Binding<Int>, width: CGFloat, help: String)
        -> some View
    {
        LabeledContent(label) {
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: width).help(help)
        }
    }

    private func memoryIcon(_ level: MLXMemoryLevel) -> String {
        switch level {
        case .comfortable: return "checkmark.circle.fill"
        case .tight: return "exclamationmark.circle.fill"
        case .risky: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private func memoryColor(_ level: MLXMemoryLevel) -> Color {
        switch level {
        case .comfortable: return .green
        case .tight: return .orange
        case .risky: return .red
        case .unknown: return .secondary
        }
    }

    private var canStart: Bool {
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !config.dataDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The adapter path the run will actually use (explicit, so the after-run flow
    /// and Fuse can point at it).
    private var resolvedAdapterPath: String {
        config.adapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var effectiveConfig: MLXFineTuneConfig {
        mode == .guided ? preset.applied(to: config) : config
    }

    private var baseModelBytes: Int64? {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return cachedModels.first { $0.repoID == model }?.sizeBytes
    }

    private var dataDirStatus: (ok: Bool, text: String)? {
        let dir = config.dataDir.trimmingCharacters(in: .whitespacesAndNewlines)
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

    // MARK: Actions

    private func startFineTune() {
        var run = effectiveConfig
        // Ensure an explicit adapter path so the after-run flow / Fuse can find it
        // (the service would otherwise auto-name a timestamped one we couldn't show).
        if run.adapterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            run.adapterPath = (service.mlxDir as NSString).appendingPathComponent("adapters-\(stamp)")
        }
        config = run  // reflect the resolved knobs/path back into the UI
        service.startFineTune(run)
    }

    private func refreshMemory() {
        let peak = MLXCommand.estimateTrainingPeakBytes(
            baseModelBytes: baseModelBytes, fineTuneType: effectiveConfig.fineTuneType)
        memory = MLXCommand.memoryVerdict(
            availableBytes: MLXService.availableMemoryBytes(), estimatedPeakBytes: peak)
    }

    private func validatePicked() {
        pickFile { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                datasetNote = "Couldn't read that file."
                return
            }
            let report = MLXCommand.validateDataset(data)
            datasetReport = report
            datasetNote =
                report.ok
                ? "The first \(report.recordCount) records validate as \(report.format?.label ?? "") (a sample — large files aren't fully scanned)."
                : "Found \(report.errors.count) problem(s) in the sample — see the report under the Data folder field."
        }
    }

    private func importCSV() {
        pickFile { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                datasetNote = "Couldn't read that file."
                return
            }
            let records = MLXCommand.completionsFromCSV(text)
            guard records.count >= 2 else {
                datasetNote = "Need at least 2 prompt,completion rows to make train + valid."
                return
            }
            let split = MLXCommand.splitJSONL(records)
            pickSaveLocation(defaultName: "dataset") { folder in
                let fm = FileManager.default
                let trainPath = (folder as NSString).appendingPathComponent("train.jsonl")
                let validPath = (folder as NSString).appendingPathComponent("valid.jsonl")
                do {
                    try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    try split.train.joined(separator: "\n").write(
                        toFile: trainPath, atomically: true, encoding: .utf8)
                    try split.valid.joined(separator: "\n").write(
                        toFile: validPath, atomically: true, encoding: .utf8)
                    config.dataDir = folder
                    datasetNote =
                        "Wrote \(split.train.count) train + \(split.valid.count) valid records to that folder."
                } catch {
                    datasetNote = "Couldn't write the dataset files: \(error.localizedDescription)"
                }
            }
        }
    }
}

/// The live loss curve — its own Equatable child so streaming loss points
/// re-render ONLY the chart, not the fine-tune form (WS-M0 discipline).
struct MLXLossChartView: View, Equatable {
    let history: MLXLossHistory

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.history == rhs.history }

    var body: some View {
        Chart {
            ForEach(history.train) { point in
                LineMark(
                    x: .value("Iteration", point.iter),
                    y: .value("Loss", point.loss),
                    series: .value("Series", "train")
                )
                .foregroundStyle(by: .value("Series", "train"))
            }
            ForEach(history.val) { point in
                LineMark(
                    x: .value("Iteration", point.iter),
                    y: .value("Loss", point.loss),
                    series: .value("Series", "validation")
                )
                .foregroundStyle(by: .value("Series", "validation"))
            }
        }
        .chartForegroundStyleScale(domain: ["train", "validation"], range: [Color.blue, Color.orange])
        .chartLegend(.visible)
        .frame(height: 160)
        .overlay {
            if history.train.isEmpty && history.val.isEmpty {
                Text("Loss numbers will plot here as training reports them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
