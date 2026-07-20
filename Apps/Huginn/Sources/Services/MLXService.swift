// SPDX-License-Identifier: AGPL-3.0-only
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

    /// WS-M0 kill-switch: when false, Huginn does NOT manage an MLX server — the
    /// child/launchd server is stopped, the health monitor and server-log tailer
    /// idle (zero MLX-tab churn), and the Eldr backend points at an external
    /// OpenAI-compatible server (LM Studio) instead. Persisted (`mlx.managed`);
    /// default true = the historical behavior. Flip via `setManagesServer`.
    @Published private(set) var managesServer: Bool

    // MARK: - Serve surface (WS-M1)

    /// The one-click "serve this model as my AI's brain" flow, observable so the
    /// brain card and the Models rows can show progress/result.
    enum BrainSwapState: Equatable {
        case idle
        case working(model: String, phase: String)
        case done(model: String)
        case failed(String)

        var isWorking: Bool { if case .working = self { return true }; return false }
    }

    @Published private(set) var brainSwap: BrainSwapState = .idle
    /// When the running server process started — child mode records launch time;
    /// launchd mode derives it from `ps -o etime` (survives Huginn relaunches).
    /// Rendered with `Text(_, style: .relative)`, which self-updates — no
    /// periodic publish needed for a ticking uptime.
    @Published private(set) var serverStartedAt: Date?
    /// Server-process RSS, sampled every ~15 s while up and rounded to 16 MB so
    /// allocator jitter doesn't republish the tab (WS-M0 discipline).
    @Published private(set) var serverMemoryBytes: Int64?
    /// Plain-language port-conflict line ("port 1337 is held by LM Studio …"),
    /// set on bind-failure exits, launchd servers that stay unreachable, and
    /// healthy-but-not-ours imposters; cleared on stop/successful start.
    @Published private(set) var portDiagnosis: String?

    private var statsTick = 0
    private var launchdUnreachableTicks = 0

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

    struct Job: Identifiable, Equatable {
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
    /// which section it belongs to). Fed in batches — see `appendJobOutput`.
    @Published private(set) var jobLog = TerminalLineBuffer()
    @Published private(set) var jobLogKind: JobKind?
    @Published private(set) var lastJobResult: JobResult?

    // MARK: - Precomputed log windows (WS-M0 publish hygiene)

    /// Last `logWindowMaxLines` rows of the job log, recomputed once per
    /// (coalesced) publish. Views render the array as-is — the old per-body
    /// `suffix(300).map` re-projected the window on EVERY Form re-evaluation.
    /// (The server log's window is gone: WS-M2's LogConsoleView tails the file
    /// itself; the service keeps its tailer only for the failure scan.)
    @Published private(set) var jobLogWindow: [MLXLogRow] = []
    static let logWindowMaxLines = 300

    /// Narrow, Equatable snapshot of everything ONE section's inline job pane
    /// shows — nil/empty when the active/last job isn't one of that section's
    /// kinds, so a download job's output invalidates the Models section only,
    /// not all six.
    struct JobPaneState: Equatable {
        var activeJob: Job?
        var lastResult: JobResult?
        var logWindow: [MLXLogRow]
    }

    func jobPaneState(for kinds: Set<JobKind>) -> JobPaneState {
        JobPaneState(
            activeJob: activeJob.flatMap { kinds.contains($0.kind) ? $0 : nil },
            lastResult: lastJobResult.flatMap { kinds.contains($0.kind) ? $0 : nil },
            logWindow: jobLogKind.map { kinds.contains($0) } == true ? jobLogWindow : [])
    }

    // MARK: - Models

    @Published private(set) var cachedModels: [MLXCachedModel] = []
    @Published private(set) var searchResults: [MLXHubModel] = []
    @Published private(set) var isSearching = false
    @Published private(set) var modelsError: String?
    /// WS-M3: the live download-progress frame (files-based percent + caption),
    /// parsed from the tqdm line in the job log while a `.download` job runs.
    /// Dedupe-guarded like all published state — a redraw only on a real change.
    @Published private(set) var downloadProgress: MLXDownloadProgress?
    /// Non-nil while the pre-download size/disk check runs — the HF tree lookup
    /// can take seconds, and without this the button tap looked dead (and a second
    /// tap raced into a confusing "another task is running") (review-pass catch).
    @Published private(set) var downloadPreflight: String?

    /// WS-M4: the fine-tune run's parsed loss curves + checkpoints, rebuilt from
    /// the job log on each coalesced flush and published only when it CHANGES (loss
    /// lines are sparse — every `steps_per_report` iters — so this is far below
    /// 4 Hz in practice).
    @Published private(set) var lossHistory = MLXLossHistory()

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
    static let managedKey = "mlx.managed"
    private static let resumeModeKey = "mlx.resumeMode"
    private static let externalURLKey = "mlx.externalLLMURL"
    private static let externalModelKey = "mlx.externalLLMModel"

    private var serverProcess: Process?
    private var serverLogHandle: FileHandle?
    private var expectingServerStop = false
    private var pendingRestart = false
    private var monitorTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    /// WS-M0: job output accumulates here and lands in `jobLog` in ~4 Hz batches
    /// (a tqdm progress bar redraws dozens of times a second, and publishing per
    /// line invalidated the whole MLX Form each time).
    private var pendingJobLogChunk = ""
    private var jobLogFlushTask: Task<Void, Never>?
    private let jobLogFlushInterval: Duration

    /// True while the 3 s health-monitor loop is alive (idle when the
    /// kill-switch is off) — observable for the WS-M0 toggle tests.
    var isMonitoringHealth: Bool { monitorTask != nil }

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
        launchAgentsDir: String? = nil,
        jobLogFlushInterval: Duration = .milliseconds(250),
        cacheDir: String? = nil
    ) {
        self.defaults = defaults
        self.jobLogFlushInterval = jobLogFlushInterval
        mlxDir = paths.mlxDir
        venvDir = (paths.mlxDir as NSString).appendingPathComponent("venv")
        venvPython = ((paths.mlxDir as NSString).appendingPathComponent("venv") as NSString)
            .appendingPathComponent("bin/python3")
        serverLogPath = Self.serverLogPath(paths: paths)
        // Injectable so a unit test never scans the user's real multi-GB HF cache
        // (production defaults to it); production callers pass nothing.
        self.cacheDir = cacheDir ?? HFCache.defaultCacheDir()
        let agentsDir =
            launchAgentsDir
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
        launchAgentPlistPath = (agentsDir as NSString)
            .appendingPathComponent(MLXCommand.launchdLabel + ".plist")

        let decodedConfig =
            defaults.data(forKey: Self.serverConfigKey)
            .flatMap { try? JSONDecoder().decode(MLXServerConfig.self, from: $0) }
            ?? MLXServerConfig()
        // WS-M1: absorb a hand-typed `--chat-template-args {"enable_thinking":…}`
        // into the first-class reasoning toggle (one-time; persisted below).
        serverConfig = MLXCommand.absorbingReasoning(from: decodedConfig)
        autostartEnabled = FileManager.default.fileExists(atPath: launchAgentPlistPath)
        managesServer = (defaults.object(forKey: Self.managedKey) as? Bool) ?? true
        serverLog = LogTailer(path: Self.serverLogPath(paths: paths))

        try? FileManager.default.createDirectory(
            atPath: paths.mlxDir, withIntermediateDirectories: true)
        // The HF hub cache must exist BEFORE the server serves: huggingface_hub's
        // scan_cache_dir() raises CacheNotFound on a missing directory, which made
        // every /v1/models request die with a traceback until the first download
        // created it (observed live in mlx-server.log).
        try? FileManager.default.createDirectory(
            atPath: self.cacheDir, withIntermediateDirectories: true)
        // Kill-switch off ⇒ nothing to monitor or tail: the probes and the tailer
        // stay idle until `setManagesServer(true)` (their churn was itself a perf
        // cost the toggle exists to remove).
        if managesServer {
            startMonitor()
            serverLog.start()
        }
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
        // Property observers don't fire during init — write the migrated config
        // back explicitly so the absorb happens exactly once.
        if serverConfig != decodedConfig { persistServerConfig() }
    }

    deinit {
        monitorTask?.cancel()
        jobTask?.cancel()
        jobLogFlushTask?.cancel()
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
        // Kill-switch off: nothing may launch (the monitor is idle, so a child
        // started here would sit in `.starting` forever). The UI hides the button.
        guard managesServer else { return }
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
        serverStartedAt = Date()
        if serverMemoryBytes != nil { serverMemoryBytes = nil }
        statsTick = 0
        if portDiagnosis != nil { portDiagnosis = nil }
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
        updateProbeStatus(.unknown)
        clearServerStats()
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
            if portDiagnosis != nil { portDiagnosis = nil }
            diagnostics.record(.mlx, .info, "MLX server stopped")
        } else {
            serverState = .failed(
                "The server exited unexpectedly (\(Self.describeExit(status))). See the log below.")
            diagnostics.record(.mlx, .error, "MLX server exited", "status \(status)")
            Self.log.error("mlx server exited status \(status, privacy: .public)")
            // The classic cause is a lost bind race — say WHO holds the port.
            Task { [weak self] in await self?.diagnosePortConflict() }
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
    /// after this launch can raise a warning for it. `nextLineID` counts the
    /// tailer's still-unpublished pending lines too, unlike `lines.last?.id`.
    private func beginLogScanForThisLaunch() {
        serverWarning = nil
        logScanBaselineID = serverLog.nextLineID
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
                    await self.trackServerStats(probe: result)
                } else {
                    self.updateProbeStatus(.unknown)
                    self.clearServerStats()
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: - Server stats + port diagnosis (WS-M1)

    /// Rides the 3 s monitor tick: every 5th tick (~15 s) sample the server
    /// process's RSS and start time via `ps`, resolving the pid through launchd
    /// when it owns the process. Also counts consecutive unreachable probes in
    /// launchd mode — three in a row triggers a one-shot port diagnosis (a
    /// launchd child that keeps losing the bind race never "exits" from our
    /// point of view, so the child-exit hook can't catch it).
    private func trackServerStats(probe: LLMHealthChecker.HealthResult) async {
        if autostartEnabled {
            if probe.isReachable {
                launchdUnreachableTicks = 0
            } else {
                launchdUnreachableTicks += 1
                if launchdUnreachableTicks == 3, portDiagnosis == nil {
                    await diagnosePortConflict()
                }
            }
        }
        defer { statsTick += 1 }
        guard statsTick % 5 == 0 else { return }
        let pid: Int32?
        if let process = serverProcess {
            pid = process.processIdentifier
        } else if autostartEnabled {
            let result = await Self.captureProcess(
                "/bin/launchctl", ["print", launchdServiceTarget])
            pid = result.status == 0 ? MLXCommand.parseLaunchdPID(fromPrint: result.output) : nil
        } else {
            pid = nil
        }
        guard let pid else {
            clearServerStats()
            // launchd mode, probe answering, but the launchd job has NO pid:
            // whoever is answering isn't ours (our copy lost the bind and died —
            // launchd children have no exit hook, so this is the only tell).
            if autostartEnabled, probe.isReachable {
                await diagnosePortConflict()
            }
            return
        }
        let ps = await Self.captureProcess(
            "/bin/ps", ["-o", "rss=", "-o", "etime=", "-p", String(pid)])
        guard ps.status == 0, let stats = MLXCommand.parseProcessStats(fromPS: ps.output) else {
            clearServerStats()
            return
        }
        setServerMemory(stats.rssBytes)
        setServerStarted(Date(timeIntervalSinceNow: -stats.elapsed))
    }

    private func clearServerStats() {
        if serverMemoryBytes != nil { serverMemoryBytes = nil }
        if serverStartedAt != nil { serverStartedAt = nil }
        launchdUnreachableTicks = 0
    }

    /// 16 MB granularity: RSS jitters constantly and must not republish the tab.
    private func setServerMemory(_ bytes: Int64) {
        let granularity: Int64 = 16 << 20
        let rounded = (bytes / granularity) * granularity
        if serverMemoryBytes != rounded { serverMemoryBytes = rounded }
    }

    /// 5 s tolerance: `etime` has one-second resolution, so a naive assignment
    /// would drift-republish on every sample.
    private func setServerStarted(_ date: Date) {
        if let current = serverStartedAt, abs(current.timeIntervalSince(date)) < 5 { return }
        serverStartedAt = date
    }

    /// lsof the configured port and surface a FOREIGN listener (our own child /
    /// launchd process is excluded — a bound-but-slow server is not a conflict).
    private func diagnosePortConflict() async {
        let port = serverConfig.port
        var excluded = Set<Int32>()
        if let process = serverProcess { excluded.insert(process.processIdentifier) }
        if autostartEnabled {
            let result = await Self.captureProcess(
                "/bin/launchctl", ["print", launchdServiceTarget])
            if let pid = MLXCommand.parseLaunchdPID(fromPrint: result.output) {
                excluded.insert(pid)
            }
        }
        let lsof = await Self.captureProcess(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        let owners = MLXCommand.parsePortOwners(fromLsof: lsof.output)
        guard
            let message = MLXCommand.portConflictMessage(
                port: port, owners: owners, excludingPIDs: excluded)
        else { return }
        if portDiagnosis != message {
            portDiagnosis = message
            diagnostics.record(.mlx, .warn, "MLX port conflict", message)
        }
    }

    /// The sneaky variant: the probe answers, but the answerer isn't OUR child —
    /// e.g. LM Studio already serves the port, our server lost the bind and is
    /// about to die. Run once on the starting→healthy transition in child mode.
    private func verifyPortOwnership(childPID: Int32) async {
        let port = serverConfig.port
        let lsof = await Self.captureProcess(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"])
        let owners = MLXCommand.parsePortOwners(fromLsof: lsof.output)
        guard !owners.isEmpty, !owners.contains(where: { $0.pid == childPID }),
            let foreign = owners.first
        else { return }
        let message =
            "Port \(port) is answering, but it's \(foreign.command) (pid \(foreign.pid)) — not the server Huginn started. Stop it there or change the port here."
        if portDiagnosis != message {
            portDiagnosis = message
            diagnostics.record(.mlx, .warn, "MLX port conflict", message)
        }
    }

    /// WS-M0 publish hygiene: a steady probe result must not invalidate the UI
    /// every 3 s — `probeStatus` writes only on change.
    private func updateProbeStatus(_ result: LLMHealthChecker.HealthResult) {
        if probeStatus != result { probeStatus = result }
    }

    /// Internal (not private) so the WS-M0 dedupe test can drive it directly —
    /// only the monitor loop calls it in production.
    func applyProbe(_ result: LLMHealthChecker.HealthResult) {
        updateProbeStatus(result)
        let healthy = result.isReachable
        switch serverState {
        case .starting where healthy:
            serverState = .running(healthy: true)
            diagnostics.record(.mlx, .success, "MLX server is answering", serverConfig.baseURL)
            // Healthy is only proof SOMEONE answered — make sure it's our child
            // and not e.g. LM Studio already holding the port (WS-M1).
            if let child = serverProcess {
                let childPID = child.processIdentifier
                Task { [weak self] in await self?.verifyPortOwnership(childPID: childPID) }
            }
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
            guard managesServer else { return }
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
            updateProbeStatus(.unknown)
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
            statsTick = 0
            launchdUnreachableTicks = 0
            if portDiagnosis != nil { portDiagnosis = nil }
            // A reachable result from the PREVIOUS server must not survive the
            // relaunch — makeBrain and the UI would read it as "the new model
            // is up". The next monitor tick re-probes the fresh process.
            updateProbeStatus(.unknown)
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
        updateProbeStatus(.unknown)
        if serverWarning != nil { serverWarning = nil }
        clearServerStats()
        if portDiagnosis != nil { portDiagnosis = nil }
        diagnostics.record(.mlx, .info, "MLX server (launchd) sent SIGTERM")
    }

    // MARK: - Managed-server kill-switch (WS-M0)

    /// How the server was running when management was switched OFF — restored
    /// when it comes back ON.
    private enum ResumeMode: String {
        case stopped, child, launchd
    }

    /// Flip "Huginn manages the model server".
    ///
    /// OFF: stop the child/launchd server, idle the 3 s health monitor and the
    /// server-log tailer (zero MLX-tab churn), and point the Eldr backend —
    /// `ConfigurationStore.llmURL`/`llmModel`, the exact seam `useAsEldrBackend`
    /// writes — at the saved external server. The pair is seeded from the current
    /// values the first time, so "run LM Studio's server on the same port" needs
    /// no edits at all.
    ///
    /// ON: keep whatever the user pointed Eldr at as the saved external pair,
    /// rewire the backend to the (independently persisted) MLX server config, and
    /// resume the server however it ran before — child process, launchd, or not
    /// at all. Non-destructive both ways.
    func setManagesServer(_ on: Bool, store: ConfigurationStore) async {
        guard on != managesServer else { return }
        if on {
            defaults.set(store.llmURL, forKey: Self.externalURLKey)
            defaults.set(store.llmModel, forKey: Self.externalModelKey)
            managesServer = true
            defaults.set(true, forKey: Self.managedKey)
            serverLog.start()
            startMonitor()
            useAsEldrBackend(store: store)
            switch ResumeMode(rawValue: defaults.string(forKey: Self.resumeModeKey) ?? "")
                ?? .stopped
            {
            case .launchd: await setAutostart(true)
            case .child: startServer()
            case .stopped: break
            }
            diagnostics.record(
                .mlx, .info, "Huginn manages the model server again", serverConfig.baseURL)
        } else {
            let resume: ResumeMode =
                autostartEnabled ? .launchd : (serverProcess != nil ? .child : .stopped)
            defaults.set(resume.rawValue, forKey: Self.resumeModeKey)
            if autostartEnabled {
                await setAutostart(false)
            } else if let process = serverProcess, process.isRunning {
                expectingServerStop = true
                terminateServerProcess(process)
            }
            monitorTask?.cancel()
            monitorTask = nil
            updateProbeStatus(.unknown)
            if serverWarning != nil { serverWarning = nil }
            clearServerStats()
            if portDiagnosis != nil { portDiagnosis = nil }
            serverLog.stop()
            let url = defaults.string(forKey: Self.externalURLKey) ?? store.llmURL
            let model = defaults.string(forKey: Self.externalModelKey) ?? store.llmModel
            defaults.set(url, forKey: Self.externalURLKey)
            defaults.set(model, forKey: Self.externalModelKey)
            store.llmURL = url
            store.llmModel = model
            managesServer = false
            defaults.set(false, forKey: Self.managedKey)
            diagnostics.record(.mlx, .info, "MLX management off — Eldr backend is \(url)")
        }
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

    /// WS-M1 one-click brain swap: validate → point the server at the model →
    /// (re)start → wait until it actually answers → wire the Eldr backend →
    /// confirm. The backend is rewired ONLY after the server proves healthy, so
    /// a failed swap never leaves Eldr pointing at a dead server. Collapses the
    /// old 7-step, 3-tab flow into one action on a cached model's row.
    func makeBrain(model: String, store: ConfigurationStore) async {
        guard !brainSwap.isWorking else { return }
        guard managesServer else {
            brainSwap = .failed(
                "Turn on \u{201C}Huginn manages the model server\u{201D} first — MLX serving is switched off."
            )
            return
        }
        guard envState.isReady else {
            brainSwap = .failed("Install the MLX environment first — see the card above.")
            return
        }
        if let problem = MLXCommand.validateServerModel(model) {
            brainSwap = .failed(problem)
            return
        }
        if serverConfig.model != model { serverConfig.model = model }
        // A stale .failed from an EARLIER launchd bootstrap would abort the loop
        // below before the fresh restart gets a chance — it no longer describes
        // reality once we're relaunching. (Child mode overwrites it synchronously
        // in launchServerProcess, so only launchd needs the reset.)
        if autostartEnabled, case .failed = serverState { serverState = .stopped }
        // Already serving EXACTLY this config and answering: just wire the
        // backend — don't reload multi-GB weights for nothing. Full-config
        // equality, not model equality: a changed port/flag still needs the
        // restart, or we'd wire a URL nothing listens on.
        if serverIsAnswering, launchedServerConfig == serverConfig {
            if await answeringServerIsOurs() {
                useAsEldrBackend(store: store)
                brainSwap = .done(model: model)
            } else {
                brainSwap = .failed(
                    portDiagnosis
                        ?? "Something else is answering on port \(serverConfig.port) — not the MLX server. Stop it there or change the port here."
                )
            }
            return
        }
        brainSwap = .working(model: model, phase: "Starting the server…")
        startServer()
        if case .failed(let why) = serverState {
            brainSwap = .failed(why)
            return
        }
        // Big models legitimately take minutes to load — poll generously, bail
        // early on a real failure (child exit, bootstrap error, kill-switch).
        // `launchedServerConfig == serverConfig` gates acceptance on the NEW
        // launch: right after a restart the OLD child/probe can still read
        // "answering" for a beat, and that must not count as success.
        let deadline = ContinuousClock.now.advanced(by: .seconds(240))
        var announcedLoading = false
        var waited = 0
        while ContinuousClock.now < deadline {
            guard managesServer else {
                brainSwap = .failed("MLX management was switched off mid-swap.")
                return
            }
            if case .failed(let why) = serverState {
                brainSwap = .failed(why)
                return
            }
            if serverIsAnswering, launchedServerConfig == serverConfig {
                // "Answering" only proves SOMEONE owns the port. If it isn't our
                // process (LM Studio got there first; our copy lost the bind and
                // died or is about to), wiring the backend would silently hand
                // Eldr to the wrong server with a green success note on top.
                if await answeringServerIsOurs() {
                    useAsEldrBackend(store: store)
                    brainSwap = .done(model: model)
                } else {
                    brainSwap = .failed(
                        portDiagnosis
                            ?? "Something else is answering on port \(serverConfig.port) — not the MLX server. Stop it there or change the port here."
                    )
                }
                return
            }
            if !announcedLoading, waited >= 8 {
                announcedLoading = true
                brainSwap = .working(
                    model: model,
                    phase: "Loading \(model) — large models can take a few minutes…")
            }
            try? await Task.sleep(for: .milliseconds(500))
            waited += 1
        }
        brainSwap = .failed(
            "The server still isn't answering after 4 minutes — see the server log for what it's doing."
        )
    }

    /// Ownership gate for the swap's success path: the answering port must be
    /// held by OUR process (child pid, or the launchd job's pid). Positive
    /// evidence of a foreign owner fails closed (and records the diagnosis);
    /// an empty/odd lsof result fails open — tooling hiccups must not block a
    /// genuinely healthy swap.
    private func answeringServerIsOurs() async -> Bool {
        let expectedPID: Int32?
        if let process = serverProcess {
            expectedPID = process.processIdentifier
        } else if autostartEnabled {
            let result = await Self.captureProcess(
                "/bin/launchctl", ["print", launchdServiceTarget])
            expectedPID = MLXCommand.parseLaunchdPID(fromPrint: result.output)
        } else {
            expectedPID = nil
        }
        let lsof = await Self.captureProcess(
            "/usr/sbin/lsof", ["-nP", "-iTCP:\(serverConfig.port)", "-sTCP:LISTEN", "-Fpc"])
        let owners = MLXCommand.parsePortOwners(fromLsof: lsof.output)
        guard !owners.isEmpty else { return expectedPID != nil }
        guard let expectedPID else {
            // Someone answers but no process of ours exists (launchd copy died).
            if let message = MLXCommand.portConflictMessage(
                port: serverConfig.port, owners: owners), portDiagnosis != message
            {
                portDiagnosis = message
                diagnostics.record(.mlx, .warn, "MLX port conflict", message)
            }
            return false
        }
        if owners.contains(where: { $0.pid == expectedPID }) { return true }
        if let message = MLXCommand.portConflictMessage(
            port: serverConfig.port, owners: owners, excludingPIDs: [expectedPID]),
            portDiagnosis != message
        {
            portDiagnosis = message
            diagnostics.record(.mlx, .warn, "MLX port conflict", message)
        }
        return false
    }

    /// "Answering" for the mode we're in: child mode trusts the state machine
    /// (which the probe drives), launchd mode trusts the probe directly.
    private var serverIsAnswering: Bool {
        if autostartEnabled { return probeStatus.isReachable }
        if case .running(true) = serverState { return true }
        return false
    }

    /// Dismiss a lingering done/failed swap note (the card's ✕).
    func clearBrainSwapNote() {
        if brainSwap != .idle, !brainSwap.isWorking { brainSwap = .idle }
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
    /// block on a silent multi-GB fetch. WS-M3: a free-disk guard runs BEFORE the
    /// job starts (AC103f) — it blocks a download that clearly won't fit rather
    /// than stranding a huge `.incomplete`.
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
        guard activeJob == nil else {
            modelsError = "Another MLX task is still running — wait for it or cancel it first."
            return
        }
        // A preflight is already in flight (the button is disabled; this catches
        // the race of a tap landing before the publish) — drop the duplicate.
        guard downloadPreflight == nil else { return }
        modelsError = nil
        Task { [weak self] in await self?.beginDownload(trimmed) }
    }

    /// The disk-guard preamble: measure free space on the cache volume, look up
    /// the model's true download size (HF tree API, best-effort), and let the pure
    /// guard decide. Runs off the main flow so the network lookup doesn't block the
    /// button; the job's own exclusivity is re-checked after the await.
    private func beginDownload(_ repoID: String) async {
        downloadPreflight = "Checking size and free disk space…"
        defer { if downloadPreflight != nil { downloadPreflight = nil } }
        let free = Self.volumeFreeBytes(atPath: cacheDir)
        let size = await Self.fetchDownloadSize(repoID: repoID)
        var lowDiskWarning: String?
        switch MLXCommand.downloadDiskGuard(freeBytes: free, estimatedBytes: size) {
        case .block(let message):
            modelsError = message
            diagnostics.record(.mlx, .warn, "Download blocked — not enough disk", message)
            return
        case .warn(let message):
            modelsError = message
            lowDiskWarning = message
            diagnostics.record(.mlx, .warn, "Download proceeding on low disk", message)
        case .ok:
            break
        }
        guard activeJob == nil else {
            modelsError = "Another MLX task is still running — wait for it or cancel it first."
            return
        }
        let python = venvPython
        startJob(
            .download, "Download \(repoID)",
            onFinish: { [weak self] success in
                // The low-disk caution was about THIS download; once it has
                // succeeded, leaving it up reads as a stale error (review-pass
                // catch). A different message (a real failure) is left alone.
                if success, let lowDiskWarning, self?.modelsError == lowDiskWarning {
                    self?.modelsError = nil
                }
                self?.refreshCachedModels()
            }
        ) { [self] in
            try await runJobStep(python, MLXCommand.downloadArguments(repoID: repoID))
        }
    }

    /// Free bytes on the volume backing `path` (the "important usage" figure macOS
    /// lets an app reclaim). Nil when the volume can't be queried — the guard then
    /// declines to block on our own probe failure.
    nonisolated static func volumeFreeBytes(atPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// Best-effort "available RAM" for the WS-M4 memory preflight: (free +
    /// inactive + purgeable + speculative) pages × page size — roughly what
    /// Activity Monitor calls available. It is an ESTIMATE (macOS compresses and
    /// reclaims under pressure); the UI always labels it so. `mach`, no subprocess.
    nonisolated static func availableMemoryBytes() -> Int64? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // `getpagesize()` (a function) instead of the `vm_page_size` global var,
        // which is not concurrency-safe under Swift 6 strict concurrency.
        let pageSize = Int64(getpagesize())
        // `free_count` already INCLUDES speculative pages (that's why `vm_stat`
        // SUBTRACTS speculative to display "Pages free" — verified against vm_stat
        // on this Mac). Adding speculative_count again would double-count toward
        // optimism, the wrong direction for an OOM preflight (review-pass catch).
        let pages =
            Int64(stats.free_count) + Int64(stats.inactive_count)
            + Int64(stats.purgeable_count)
        return pages * pageSize
    }

    /// Best-effort true download size from the HF file tree (sum of file sizes).
    /// Nil (⇒ size unknown, guard uses the floor) on any network/HTTP/decoding
    /// failure — never fatal to a download the user asked for.
    nonisolated static func fetchDownloadSize(repoID: String) async -> Int64? {
        guard let url = MLXCommand.treeURL(repoID: repoID) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return MLXCommand.sumTreeDownloadBytes(fromJSON: data)
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
        jobLogFlushTask?.cancel()
        jobLogFlushTask = nil
        pendingJobLogChunk = ""
        jobLog = TerminalLineBuffer()
        jobLogWindow = []
        jobLogKind = kind
        lastJobResult = nil
        if downloadProgress != nil { downloadProgress = nil }
        // Only a NEW fine-tune clears the loss chart — an unrelated job (e.g. a
        // download or a Playground generate) must not wipe the last run's curve.
        if kind == .finetune, !lossHistory.isEmpty { lossHistory = MLXLossHistory() }
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
        // Flush synchronously so the pane shows the complete output the moment the
        // result label appears (and so tests see a settled state after finish).
        flushJobLogNow()
        // The job is over — the result label replaces the determinate bar.
        if downloadProgress != nil { downloadProgress = nil }
        Self.log.info(
            "MLX job finished: \(job.kind.rawValue, privacy: .public) success=\(error == nil)")
        onFinish?(error == nil)
    }

    /// Buffered feed (WS-M0 publish hygiene): chunks accumulate in
    /// `pendingJobLogChunk` and land in `jobLog` in ~4 Hz batches instead of one
    /// `objectWillChange` per streamed line.
    func appendJobOutput(_ chunk: String) {
        pendingJobLogChunk += chunk
        guard jobLogFlushTask == nil else { return }
        jobLogFlushTask = Task { [weak self] in
            guard let interval = self?.jobLogFlushInterval else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.jobLogFlushTask = nil
            self?.flushJobLog()
        }
    }

    private func flushJobLogNow() {
        jobLogFlushTask?.cancel()
        jobLogFlushTask = nil
        flushJobLog()
    }

    private func flushJobLog() {
        guard !pendingJobLogChunk.isEmpty else { return }
        jobLog.feed(pendingJobLogChunk)
        pendingJobLogChunk = ""
        jobLogWindow = Self.window(of: jobLog.lines)
        if jobLogKind == .download { updateDownloadProgress() }
        if jobLogKind == .finetune { updateLossHistory() }
    }

    /// Rebuild the loss history from the fine-tune log and publish only on change
    /// (WS-M0 hygiene). Full re-parse is cheap: the buffer is bounded (2 000
    /// lines) and only a handful are loss rows.
    private func updateLossHistory() {
        let parsed = MLXCommand.parseLossHistory(fromLines: jobLog.lines)
        if parsed != lossHistory { lossHistory = parsed }
    }

    /// Publish the latest tqdm frame from the download log (pure pick in
    /// `MLXCommand.latestProgress`). A publish only on a real change (WS-M0
    /// hygiene); if nothing parses yet, the prior frame stands.
    private func updateDownloadProgress() {
        if let parsed = MLXCommand.latestProgress(inLines: jobLog.lines),
            downloadProgress != parsed
        {
            downloadProgress = parsed
        }
    }

    // MARK: - Window projection (WS-M0)

    /// Job-log window: ids are the lines' absolute indices, stable across appends
    /// (they only shift when the 2000-line buffer cap trims the head).
    private static func window(of lines: [String]) -> [MLXLogRow] {
        let base = max(0, lines.count - logWindowMaxLines)
        return lines.suffix(logWindowMaxLines).enumerated().map {
            MLXLogRow(id: base + $0.offset, text: $0.element)
        }
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
