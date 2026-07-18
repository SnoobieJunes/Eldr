import AppKit
import Combine
import Foundation
import PQRCACP
import os

/// The MLX tab's engine: one place that runs every `mlx_lm` subprocess (env
/// install, model download, server, convert, fine-tune, fuse, generate) against
/// a private Python environment under `<configDir>/mlx/venv`, so nothing touches
/// the user's system Python. Pattern follows `ContextGraphService` (guided
/// install + health), scaled up: long "jobs" stream their merged stdout/stderr
/// into a published terminal buffer and are cancellable; the server is a managed
/// long-running child (or a launchd agent when login autostart is on) logging to
/// a file the UI tails.
///
/// Concurrency: the class is @MainActor for SwiftUI; children run detached and
/// stream back via `appendJobOutput`. Jobs are serialized — ONE at a time — both
/// to keep the UI honest and because two simultaneous model loads can OOM a
/// machine. The server is independent of jobs.
@MainActor
final class MLXService: ObservableObject {

    /// ONE app-wide instance. The MLX tab used to create its own `@StateObject`, so a
    /// torn-down/recreated tab view spawned a second service that had lost track of the
    /// first one's running server child (stale "Stopped" UI, port-bind failures on the
    /// next Start). The server is a machine-wide resource; its owner must be too.
    static let shared = MLXService()

    // MARK: - Environment

    enum EnvironmentState: Equatable {
        case unknown
        case unsupported(String)
        case notInstalled
        /// venv exists but `import mlx_lm` fails — reinstall repairs it.
        case broken(String)
        case ready(version: String)

        var isReady: Bool { if case .ready = self { return true }; return false }
    }

    @Published private(set) var envState: EnvironmentState = .unknown

    // MARK: - Server

    enum ServerState: Equatable {
        case stopped
        /// Process launched; waiting for `/v1/models` to answer.
        case starting
        case running(healthy: Bool)
        case failed(String)
    }

    @Published private(set) var serverState: ServerState = .stopped
    /// Latest health-probe result (child AND launchd mode; `.unknown` when idle).
    @Published private(set) var probeStatus: LLMHealthChecker.HealthResult = .unknown
    /// A model-load failure spotted in the server's own log AFTER our launch. The
    /// health probe can't see this: `mlx_lm.server`'s load thread can die while
    /// `/v1/models` keeps answering 200, leaving a "healthy" server whose chats hang.
    @Published private(set) var serverWarning: String?
    /// The config the running server was actually launched with — UI shows a
    /// "restart to apply" hint when it drifts from the edited `serverConfig`.
    @Published private(set) var launchedServerConfig: MLXServerConfig?
    /// True when the LaunchAgent plist exists (launchd owns the server process;
    /// in-app start/stop route through launchctl instead of a child process).
    @Published private(set) var autostartEnabled: Bool

    @Published var serverConfig: MLXServerConfig {
        didSet { persistServerConfig() }
    }

    // MARK: - Jobs (one at a time)

    enum JobKind: String, Sendable {
        case installEnvironment = "install"
        case download
        case convert
        case finetune = "fine-tune"
        case fuse
        case generate
    }

    struct Job: Identifiable {
        let id = UUID()
        let kind: JobKind
        let title: String
        let startedAt = Date()
    }

    struct JobResult: Equatable {
        let kind: JobKind
        let success: Bool
        let message: String
    }

    @Published private(set) var activeJob: Job?
    /// Terminal-style output of the current/most recent job (`jobLogKind` says
    /// which section it belongs to).
    @Published private(set) var jobLog = TerminalLineBuffer()
    @Published private(set) var jobLogKind: JobKind?
    @Published private(set) var lastJobResult: JobResult?

    // MARK: - Models

    @Published private(set) var cachedModels: [MLXCachedModel] = []
    @Published private(set) var searchResults: [MLXHubModel] = []
    @Published private(set) var isSearching = false
    @Published private(set) var modelsError: String?

    // MARK: - Paths / plumbing

    nonisolated let mlxDir: String
    nonisolated let venvDir: String
    nonisolated let venvPython: String
    nonisolated let serverLogPath: String
    nonisolated let cacheDir: String
    private nonisolated let launchAgentPlistPath: String

    private let defaults: UserDefaults
    private let diagnostics = DiagnosticsLog.shared
    private static let log = Logger(subsystem: "chat.eldr.huginn", category: "mlx")
    private static let serverConfigKey = "mlx.serverConfig"

    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var expectingServerStop = false
    private var pendingRestart = false
    private var monitorTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?

    /// The server log's live tail — owned HERE (not by the view) so (a) exactly one
    /// tailer exists no matter how often the tab view is rebuilt, and (b) the service
    /// can scan newly-appended lines for load failures (`serverWarning`).
    let serverLog: LogTailer
    private var logScanCancellable: AnyCancellable?
    /// Only log lines with ids beyond this belong to OUR current launch; older ones
    /// are a previous run's history and must not raise a warning for this one.
    private var logScanBaselineID = Int.max

    static func serverLogPath(paths: ConfigPaths) -> String {
        ((paths.mlxDir as NSString).appendingPathComponent("mlx-server.log"))
    }

    init(
        paths: ConfigPaths = .standard,
        defaults: UserDefaults = .standard,
        launchAgentsDir: String? = nil
    ) {
        self.defaults = defaults
        mlxDir = paths.mlxDir
        venvDir = (paths.mlxDir as NSString).appendingPathComponent("venv")
        venvPython = ((paths.mlxDir as NSString).appendingPathComponent("venv") as NSString)
            .appendingPathComponent("bin/python3")
        serverLogPath = Self.serverLogPath(paths: paths)
        cacheDir = HFCache.defaultCacheDir()
        let agentsDir =
            launchAgentsDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        launchAgentPlistPath = (agentsDir as NSString)
            .appendingPathComponent(MLXCommand.launchdLabel + ".plist")

        serverConfig =
            defaults.data(forKey: Self.serverConfigKey)
            .flatMap { try? JSONDecoder().decode(MLXServerConfig.self, from: $0) }
            ?? MLXServerConfig()
        autostartEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)
        serverLog = LogTailer(path: Self.serverLogPath(paths: paths))

        try? FileManager.default.createDirectory(
            atPath: paths.mlxDir, withIntermediateDirectories: true)
        // The HF hub cache must exist BEFORE the server serves: huggingface_hub's
        // scan_cache_dir() raises CacheNotFound on a missing directory, which made
        // every /v1/models request die with a traceback until the first download
        // created it (observed live in mlx-server.log).
        try? FileManager.default.createDirectory(
            atPath: cacheDir, withIntermediateDirectories: true)
        startMonitor()
        serverLog.start()
        logScanCancellable = serverLog.$lines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in self?.scanServerLog(lines) }
        // A child server must not outlive the app (the UI promises "stops when
        // Huginn quits", and an orphan would hold the port hostage for the next
        // session). launchd-managed servers deliberately DO survive quit. The
        // registration is intentionally never removed: the service lives for the
        // app's lifetime, the token can't be touched from a Swift 6 deinit
        // (non-Sendable), and the weak capture makes a dangling block a no-op.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appWillTerminate() }
        }
    }

    deinit {
        monitorTask?.cancel()
        jobTask?.cancel()
    }

    /// Best-effort synchronous teardown: SIGTERM the child server and cancel the
    /// active job (its cancellation handler SIGTERMs the job's child immediately).
    private func appWillTerminate() {
        jobTask?.cancel()
        if let process = serverProcess, process.isRunning {
            process.terminate()
        }
    }

    private func persistServerConfig() {
        if let data = try? JSONEncoder().encode(serverConfig) {
            defaults.set(data, forKey: Self.serverConfigKey)
        }
    }

    // MARK: - Environment install / probe

    /// Import-probe the venv: exit 0 + a version proves it actually works.
    func refreshEnvironment() async {
        #if arch(arm64)
            guard FileManager.default.isExecutableFile(atPath: venvPython) else {
                envState = .notInstalled
                return
            }
            let result = await ProcessRunner.run(venvPython, MLXCommand.versionProbeArguments)
            let version = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exit == 0, !version.isEmpty {
                envState = .ready(version: version)
            } else {
                envState = .broken(
                    "mlx-lm is installed but failed to import (exit \(result.exit)). Run Install / update to repair it."
                )
            }
        #else
            envState = .unsupported("MLX runs on Apple silicon only.")
        #endif
    }

    /// Create the venv (uv preferred — it can fetch a managed Python; plain
    /// `python3 -m venv` fallback) and install/upgrade mlx-lm into it. The same
    /// action serves install, upgrade, and repair.
    func installEnvironment() {
        #if arch(arm64)
            let venvDir = self.venvDir
            let venvPython = self.venvPython
            startJob(
                .installEnvironment, "Install / update mlx-lm",
                onFinish: { [weak self] _ in
                    Task { await self?.refreshEnvironment() }
                }
            ) { [self] in
                let hasVenv = FileManager.default.isExecutableFile(atPath: venvPython)
                if let uv = MLXCommand.findExecutable(named: "uv") {
                    if !hasVenv {
                        try await runJobStep(uv, ["venv", venvDir, "--python", "3.12"])
                    }
                    try await runJobStep(
                        uv, ["pip", "install", "--python", venvPython, "--upgrade", "mlx-lm"])
                } else if let python3 = MLXCommand.findExecutable(named: "python3") {
                    if !hasVenv {
                        try await runJobStep(python3, ["-m", "venv", venvDir])
                    }
                    try await runJobStep(
                        venvPython, ["-m", "pip", "install", "--upgrade", "pip", "mlx-lm"])
                } else {
                    throw MLXError.message(
                        "Neither `uv` nor `python3` was found. Install uv (https://docs.astral.sh/uv) or the Xcode Command Line Tools, then retry."
                    )
                }
            }
        #else
            envState = .unsupported("MLX runs on Apple silicon only.")
        #endif
    }

    // MARK: - Server lifecycle

    /// Start — or restart, if running — the server with the CURRENT config.
    /// In autostart mode the plist is rewritten and launchd relaunches it.
    func startServer() {
        guard envState.isReady else {
            serverState = .failed("Install the MLX environment first.")
            return
        }
        if let problem = MLXCommand.validateServerModel(serverConfig.model) {
            serverState = .failed(problem)
            return
        }
        if autostartEnabled {
            Task { await restartLaunchdServer() }
            return
        }
        if let process = serverProcess, process.isRunning {
            pendingRestart = true
            expectingServerStop = true
            terminateServerProcess(process)
            return
        }
        launchServerProcess()
    }

    func stopServer() {
        if autostartEnabled {
            Task { await stopLaunchdServer() }
            return
        }
        guard let process = serverProcess else {
            serverState = .stopped
            return
        }
        expectingServerStop = true
        terminateServerProcess(process)
    }

    private func launchServerProcess() {
        var config = serverConfig
        // A "~/…" model is legal in the UI but not to Python: expand it here (the
        // validator already did, for its checks).
        if config.model.hasPrefix("~") {
            config.model = (config.model as NSString).expandingTildeInPath
        }
        let arguments = MLXCommand.serverArguments(config)

        guard let logHandle = openServerLogHandle() else {
            serverState = .failed("Couldn't open the server log at \(serverLogPath).")
            return
        }
        let header =
            "\n===== \(Date().ISO8601Format()) mlx_lm.server starting: "
            + Self.commandDisplay(venvPython, arguments) + " =====\n"
        try? logHandle.write(contentsOf: Data(header.utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: venvPython)
        process.arguments = arguments
        // tqdm redraws are unreadable in a log file; models should be pre-pulled
        // via the Models section (which shows live progress) anyway.
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        // Explicitly @Sendable: a bare closure literal here would inherit this
        // method's @MainActor isolation, and Foundation fires terminationHandler
        // on an arbitrary queue — Swift 6's dynamic isolation check would SIGTRAP
        // exactly like the LogTailer crash (see LogTailerTests).
        let onExit: @Sendable (Process) -> Void = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in self?.serverProcessExited(status) }
        }
        process.terminationHandler = onExit

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            serverState = .failed("Couldn't launch the server: \(error.localizedDescription)")
            return
        }
        serverProcess = process
        serverLogHandle = logHandle
        launchedServerConfig = config
        serverState = .starting
        beginLogScanForThisLaunch()
        Self.log.info("mlx server starting on port \(config.port, privacy: .public)")
        diagnostics.record(.mlx, .info, "MLX server starting", "\(config.model) on \(config.baseURL)")
    }

    /// SIGTERM now; SIGKILL 5 s later if it lingers (kill of an already-dead pid
    /// is a harmless ESRCH; the 5 s window is far too short for pid reuse).
    private func terminateServerProcess(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            kill(pid, SIGKILL)
        }
    }

    private func serverProcessExited(_ status: Int32) {
        serverProcess = nil
        try? serverLogHandle?.close()
        serverLogHandle = nil
        launchedServerConfig = nil
        probeStatus = .unknown
        if pendingRestart {
            pendingRestart = false
            expectingServerStop = false
            launchServerProcess()
            return
        }
        if expectingServerStop {
            expectingServerStop = false
            serverState = .stopped
            serverWarning = nil
            diagnostics.record(.mlx, .info, "MLX server stopped")
        } else {
            serverState = .failed(
                "The server exited unexpectedly (\(Self.describeExit(status))). See the log below.")
            diagnostics.record(.mlx, .error, "MLX server exited", "status \(status)")
            Self.log.error("mlx server exited status \(status, privacy: .public)")
        }
    }

    private func openServerLogHandle() -> FileHandle? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: serverLogPath) {
            fm.createFile(atPath: serverLogPath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: serverLogPath) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    private static func describeExit(_ status: Int32) -> String {
        status == 15 ? "terminated" : "status \(status)"
    }

    // MARK: - Server-log failure scan

    /// Reset the warning + move the scan baseline to "now": only lines appended
    /// after this launch can raise a warning for it.
    private func beginLogScanForThisLaunch() {
        serverWarning = nil
        logScanBaselineID = serverLog.lines.last.map { $0.id + 1 } ?? 0
    }

    /// Watch the server's own log for a dead model-load thread. Triggered on every
    /// tail update; only lines newer than the launch baseline count, and only while
    /// a server we manage should be up.
    private func scanServerLog(_ lines: [LogLine]) {
        guard serverWarning == nil, serverProcess != nil || autostartEnabled else { return }
        let markers = [
            "HFValidationError", "CacheNotFound", "Exception in thread",
            "Traceback (most recent call last)",
        ]
        for line in lines where line.id >= logScanBaselineID {
            if markers.contains(where: { line.text.contains($0) }) {
                serverWarning =
                    "The server hit an error while loading the model — chats will hang even though the health check answers. Check the model id/path (log below)."
                diagnostics.record(.mlx, .error, "MLX model load failed", "see mlx-server.log")
                return
            }
        }
    }

    // MARK: - Health monitor

    /// Polls `/v1/models` every 3 s while the server should be up (child alive or
    /// launchd-managed), via the same probe the Configuration tab's LLM row uses.
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.autostartEnabled || self.serverProcess != nil {
                    let config = self.serverConfig
                    let result = await LLMHealthChecker.probe(
                        LLMConfig(
                            url: config.baseURL, token: "", model: config.model,
                            requestTimeoutSeconds: 4))
                    self.applyProbe(result)
                } else if self.probeStatus != .unknown {
                    self.probeStatus = .unknown
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func applyProbe(_ result: LLMHealthChecker.HealthResult) {
        probeStatus = result
        let healthy = result.isReachable
        switch serverState {
        case .starting where healthy:
            serverState = .running(healthy: true)
            diagnostics.record(.mlx, .success, "MLX server is answering", serverConfig.baseURL)
        case .running(let wasHealthy) where wasHealthy != healthy:
            serverState = .running(healthy: healthy)
        default:
            break
        }
    }

    // MARK: - launchd autostart

    /// Toggle login autostart. ON: hand the server to launchd (stopping any
    /// in-app child first — exactly one owner of the port). OFF: bootout + remove
    /// the plist; in-app control resumes.
    func setAutostart(_ enabled: Bool) async {
        if enabled {
            guard envState.isReady else {
                serverState = .failed("Install the MLX environment first.")
                return
            }
            if let problem = MLXCommand.validateServerModel(serverConfig.model) {
                serverState = .failed(problem)
                return
            }
            if let process = serverProcess, process.isRunning {
                expectingServerStop = true
                terminateServerProcess(process)
            }
            // Wait (bounded) for the child to actually exit and release the port —
            // otherwise the launchd copy loses the bind race, exits, and (KeepAlive
            // false) stays down while the toggle claims it's managed. The exit
            // handler runs on this actor, so sleeping here lets it land.
            for _ in 0..<140 where serverProcess != nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            do {
                try writeLaunchAgentPlist()
            } catch {
                serverState = .failed(
                    "Couldn't write the LaunchAgent: \(error.localizedDescription)")
                return
            }
            _ = await Self.captureProcess("/bin/launchctl", ["bootout", launchdServiceTarget])
            let result = await Self.captureProcess(
                "/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentPlistPath])
            guard result.status == 0 else {
                serverState = .failed(
                    "launchctl bootstrap failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
                return
            }
            autostartEnabled = true
            serverState = .stopped
            launchedServerConfig = serverConfig
            diagnostics.record(.mlx, .info, "MLX server autostart enabled (launchd)")
        } else {
            _ = await Self.captureProcess("/bin/launchctl", ["bootout", launchdServiceTarget])
            try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
            autostartEnabled = false
            launchedServerConfig = nil
            probeStatus = .unknown
            diagnostics.record(.mlx, .info, "MLX server autostart disabled")
        }
    }

    private var launchdServiceTarget: String {
        "gui/\(getuid())/\(MLXCommand.launchdLabel)"
    }

    private func writeLaunchAgentPlist() throws {
        let data = try MLXCommand.launchdPlist(
            pythonPath: venvPython,
            serverArguments: MLXCommand.serverArguments(serverConfig),
            logPath: serverLogPath)
        try FileManager.default.createDirectory(
            atPath: (launchAgentPlistPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: launchAgentPlistPath), options: .atomic)
    }

    private func restartLaunchdServer() async {
        do {
            try writeLaunchAgentPlist()
        } catch {
            serverState = .failed("Couldn't write the LaunchAgent: \(error.localizedDescription)")
            return
        }
        _ = await Self.captureProcess("/bin/launchctl", ["bootout", launchdServiceTarget])
        let result = await Self.captureProcess(
            "/bin/launchctl", ["bootstrap", "gui/\(getuid())", launchAgentPlistPath])
        if result.status == 0 {
            launchedServerConfig = serverConfig
            beginLogScanForThisLaunch()
            diagnostics.record(.mlx, .info, "MLX server (launchd) restarted")
        } else {
            serverState = .failed(
                "launchctl bootstrap failed (\(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    private func stopLaunchdServer() async {
        _ = await Self.captureProcess(
            "/bin/launchctl", ["kill", "SIGTERM", launchdServiceTarget])
        probeStatus = .unknown
        serverWarning = nil
        diagnostics.record(.mlx, .info, "MLX server (launchd) sent SIGTERM")
    }

    // MARK: - Backend wiring

    /// Point the whole Eldr stack (eldr-acp, test chat, health row) at this
    /// server — writes the existing Configuration ▸ Local LLM fields through the
    /// standard `LLMClient` seam; no new abstraction.
    func useAsEldrBackend(store: ConfigurationStore) {
        store.llmURL = serverConfig.baseURL
        store.llmModel = serverConfig.model
        diagnostics.record(
            .mlx, .success, "Eldr LLM backend set to the MLX server", serverConfig.baseURL)
        Self.log.info("Eldr backend switched to the MLX server")
    }

    // MARK: - Models

    func refreshCachedModels() {
        let dir = cacheDir
        Task { [weak self] in
            let models = await Task.detached { HFCache.scanModels(cacheDir: dir) }.value
            self?.cachedModels = models
        }
    }

    /// Delete = move the `models--…` folder to the Trash (recoverable; same
    /// directory `mlx_lm.manage --delete` would remove, without its interactive
    /// y/N prompt that would hang a GUI-driven subprocess).
    func deleteCachedModel(_ model: MLXCachedModel) {
        modelsError = nil
        let url = URL(fileURLWithPath: model.path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            diagnostics.record(.mlx, .info, "Moved \(model.repoID) to the Trash")
        } catch {
            do {
                try FileManager.default.removeItem(at: url)
                diagnostics.record(.mlx, .info, "Deleted \(model.repoID)")
            } catch {
                modelsError = "Couldn't delete \(model.repoID): \(error.localizedDescription)"
            }
        }
        refreshCachedModels()
    }

    func searchHub(query: String, author: String?, mlxOnly: Bool, sort: String) async {
        guard
            let url = MLXCommand.searchURL(
                query: query, author: author, mlxOnly: mlxOnly, sort: sort)
        else { return }
        isSearching = true
        modelsError = nil
        defer { isSearching = false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw MLXError.message("Hugging Face returned HTTP \(http.statusCode).")
            }
            searchResults = try JSONDecoder().decode([MLXHubModel].self, from: data)
        } catch {
            searchResults = []
            modelsError =
                "Search failed: \((error as? MLXError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    /// Pre-download (warm the HF cache) so server startup / playground runs don't
    /// block on a silent multi-GB fetch.
    func downloadModel(_ repoID: String) {
        let trimmed = repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MLXCommand.isValidRepoID(trimmed) else {
            modelsError = "\u{201C}\(trimmed)\u{201D} isn't a valid Hugging Face model id (owner/name)."
            return
        }
        guard envState.isReady else {
            modelsError = "Install the MLX environment first — downloads run through its huggingface_hub."
            return
        }
        let python = venvPython
        startJob(
            .download, "Download \(trimmed)",
            onFinish: { [weak self] _ in self?.refreshCachedModels() }
        ) { [self] in
            try await runJobStep(python, MLXCommand.downloadArguments(repoID: trimmed))
        }
    }

    // MARK: - Convert / quantize

    func startConvert(_ config: MLXConvertConfig) {
        guard envState.isReady else {
            reportImmediateFailure(.convert, "Install the MLX environment first.")
            return
        }
        var cfg = config
        cfg.hfPath = cfg.hfPath.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.mlxPath = cfg.mlxPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cfg.hfPath.isEmpty, !cfg.mlxPath.isEmpty else {
            reportImmediateFailure(.convert, "Source model and output folder are both required.")
            return
        }
        guard !FileManager.default.fileExists(atPath: cfg.mlxPath) else {
            reportImmediateFailure(
                .convert,
                "The output folder already exists — mlx_lm.convert refuses to overwrite. Pick a fresh path."
            )
            return
        }
        let python = venvPython
        let resolved = cfg
        startJob(
            .convert, "Convert \(resolved.hfPath)",
            onFinish: { [weak self] ok in if ok { self?.refreshCachedModels() } }
        ) { [self] in
            try await runJobStep(python, MLXCommand.convertArguments(resolved))
        }
    }

    // MARK: - Playground

    func runGenerate(_ config: MLXGenerateConfig) {
        guard envState.isReady else {
            reportImmediateFailure(.generate, "Install the MLX environment first.")
            return
        }
        guard !config.model.isEmpty, !config.prompt.isEmpty else {
            reportImmediateFailure(.generate, "Model and prompt are both required.")
            return
        }
        let python = venvPython
        startJob(.generate, "Generate") { [self] in
            try await runJobStep(python, MLXCommand.generateArguments(config))
        }
    }

    // MARK: - Fine-tune / fuse

    func startFineTune(_ config: MLXFineTuneConfig) {
        guard envState.isReady else {
            reportImmediateFailure(.finetune, "Install the MLX environment first.")
            return
        }
        var cfg = config
        cfg.model = cfg.model.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.dataDir = cfg.dataDir.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.adapterPath = cfg.adapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cfg.model.isEmpty else {
            reportImmediateFailure(.finetune, "Base model is required.")
            return
        }
        let fm = FileManager.default
        guard
            fm.fileExists(atPath: (cfg.dataDir as NSString).appendingPathComponent("train.jsonl")),
            fm.fileExists(atPath: (cfg.dataDir as NSString).appendingPathComponent("valid.jsonl"))
        else {
            reportImmediateFailure(
                .finetune,
                "The data folder must contain train.jsonl and valid.jsonl (mlx_lm.lora's expected layout)."
            )
            return
        }
        if cfg.adapterPath.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            cfg.adapterPath = (mlxDir as NSString).appendingPathComponent("adapters-\(stamp)")
        }
        let configPath = (mlxDir as NSString)
            .appendingPathComponent("finetune-\(UUID().uuidString).yaml")
        let yaml = MLXCommand.loraConfigYAML(cfg)
        let python = venvPython
        let adapterPath = cfg.adapterPath
        startJob(.finetune, "Fine-tune \(cfg.model)") { [self] in
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
            await appendJobOutput("config: \(configPath)\nadapters: \(adapterPath)\n")
            try await runJobStep(python, MLXCommand.loraArguments(configPath: configPath))
        }
    }

    func startFuse(model: String, adapterPath: String, savePath: String) {
        guard envState.isReady else {
            reportImmediateFailure(.fuse, "Install the MLX environment first.")
            return
        }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let adapters = adapterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let save = savePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !adapters.isEmpty, !save.isEmpty else {
            reportImmediateFailure(.fuse, "Model, adapter path, and save path are all required.")
            return
        }
        let python = venvPython
        startJob(.fuse, "Fuse adapters into \(model)") { [self] in
            try await runJobStep(
                python, MLXCommand.fuseArguments(model: model, adapterPath: adapters, savePath: save))
        }
    }

    // MARK: - Job engine

    func cancelActiveJob() {
        jobTask?.cancel()
    }

    private func reportImmediateFailure(_ kind: JobKind, _ message: String) {
        lastJobResult = JobResult(kind: kind, success: false, message: message)
    }

    private func startJob(
        _ kind: JobKind, _ title: String,
        onFinish: (@MainActor (Bool) -> Void)? = nil,
        body: @escaping @Sendable () async throws -> Void
    ) {
        guard activeJob == nil else {
            lastJobResult = JobResult(
                kind: kind, success: false,
                message: "Another MLX task is still running — wait for it or cancel it first.")
            return
        }
        let job = Job(kind: kind, title: title)
        activeJob = job
        jobLog = TerminalLineBuffer()
        jobLogKind = kind
        lastJobResult = nil
        Self.log.info("MLX job started: \(kind.rawValue, privacy: .public)")
        diagnostics.record(.mlx, .info, "\(title) started")
        jobTask = Task { [weak self] in
            do {
                try await body()
                self?.finishJob(job, error: nil, onFinish: onFinish)
            } catch {
                self?.finishJob(job, error: error, onFinish: onFinish)
            }
        }
    }

    private func finishJob(_ job: Job, error: Error?, onFinish: (@MainActor (Bool) -> Void)?) {
        guard activeJob?.id == job.id else { return }
        activeJob = nil
        jobTask = nil
        let result: JobResult
        if let error {
            if error is CancellationError {
                result = JobResult(kind: job.kind, success: false, message: "Cancelled.")
                diagnostics.record(.mlx, .warn, "\(job.title) cancelled")
            } else {
                let message = (error as? MLXError)?.errorDescription ?? error.localizedDescription
                result = JobResult(kind: job.kind, success: false, message: message)
                diagnostics.record(.mlx, .error, "\(job.title) failed", message)
            }
        } else {
            result = JobResult(kind: job.kind, success: true, message: "\(job.title) — done.")
            diagnostics.record(.mlx, .success, "\(job.title) finished")
        }
        lastJobResult = result
        appendJobOutput("\n[\(result.message)]\n")
        Self.log.info(
            "MLX job finished: \(job.kind.rawValue, privacy: .public) success=\(error == nil)")
        onFinish?(error == nil)
    }

    func appendJobOutput(_ chunk: String) {
        jobLog.feed(chunk)
    }

    /// Run one child process as part of the active job, streaming its merged
    /// output into the job log; throws on nonzero exit.
    private nonisolated func runJobStep(
        _ launchPath: String, _ arguments: [String], environment: [String: String]? = nil
    ) async throws {
        let display = Self.commandDisplay(launchPath, arguments)
        await appendJobOutput("$ \(display)\n")
        let status = try await Self.streamProcess(
            launchPath, arguments, environment: environment
        ) { [weak self] chunk in
            await self?.appendJobOutput(chunk)
        }
        guard status == 0 else {
            throw MLXError.stepFailed(command: display, status: status)
        }
    }

    private nonisolated static func commandDisplay(
        _ launchPath: String, _ arguments: [String]
    ) -> String {
        let name = (launchPath as NSString).lastPathComponent
        let joined = ([name] + arguments).joined(separator: " ")
        return joined.count > 400 ? String(joined.prefix(400)) + " …" : joined
    }

    // MARK: - Subprocess plumbing

    /// Spawn a child with merged stdout+stderr streamed to `onChunk`, flushed at
    /// line boundaries (`\n` AND `\r`, so tqdm progress redraws arrive live).
    /// Cancellation SIGTERMs the child (SIGKILL 3 s later if it ignores that) and
    /// rethrows CancellationError after reaping. Never hangs: EOF is guaranteed
    /// once the child dies, and the reap loop escalates to SIGKILL itself.
    nonisolated static func streamProcess(
        _ launchPath: String, _ arguments: [String],
        environment: [String: String]?,
        onChunk: @escaping @Sendable (String) async -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier

        return try await withTaskCancellationHandler {
            var readError: Error?
            do {
                var buffer: [UInt8] = []
                buffer.reserveCapacity(4096)
                for try await byte in pipe.fileHandleForReading.bytes {
                    buffer.append(byte)
                    if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
                        || buffer.count >= 4096
                    {
                        await onChunk(String(decoding: buffer, as: UTF8.self))
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty { await onChunk(String(decoding: buffer, as: UTF8.self)) }
            } catch {
                readError = error
            }
            // Reap. EOF normally means the child exited; a cancelled read means we
            // SIGTERMed it and EOF is on its way. Bounded: escalate to SIGKILL at
            // 3 s, give up (still reporting) at 8 s.
            var waitedMilliseconds = 0
            while process.isRunning {
                await uncancellableSleep(milliseconds: 50)
                waitedMilliseconds += 50
                if waitedMilliseconds == 3_000 { kill(pid, SIGKILL) }
                if waitedMilliseconds >= 8_000 { break }
            }
            if Task.isCancelled { throw CancellationError() }
            if let readError { throw readError }
            guard !process.isRunning else {
                throw MLXError.message("The child process did not exit even after SIGKILL.")
            }
            return process.terminationStatus
        } onCancel: {
            kill(pid, SIGTERM)
            // Guarantee the read loop's EOF even if the child ignores SIGTERM.
            Task.detached {
                try? await Task.sleep(for: .seconds(3))
                kill(pid, SIGKILL)
            }
        }
    }

    /// Short-lived helper runs (launchctl) where we want merged output back as a
    /// string rather than a stream.
    nonisolated static func captureProcess(
        _ launchPath: String, _ arguments: [String]
    ) async -> (output: String, status: Int32) {
        let buffer = OSAllocatedUnfairLock(initialState: "")
        let status =
            (try? await streamProcess(launchPath, arguments, environment: nil) { chunk in
                buffer.withLock { $0 += chunk }
            }) ?? -1
        return (buffer.withLock { $0 }, status)
    }

    /// Sleep that ignores task cancellation — the reap loop must keep polling
    /// after the job is cancelled (a cancelled `Task.sleep` returns immediately,
    /// which would spin the loop).
    private nonisolated static func uncancellableSleep(milliseconds: Int) async {
        await Task.detached {
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }.value
    }
}

enum MLXError: LocalizedError, Equatable {
    case message(String)
    case stepFailed(command: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .stepFailed(let command, let status):
            let short = command.count > 80 ? String(command.prefix(80)) + " …" : command
            return "`\(short)` failed (exit \(status)). See the log for details."
        }
    }
}
