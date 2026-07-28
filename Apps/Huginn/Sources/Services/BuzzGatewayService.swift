// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine
import Foundation
import PQRCCore
import PQRCNostr
import os

/// WS-I7 Path A — the RUNNING half: supervises one `eldr-buzz-agent` child per
/// configured Buzz connection.
///
/// Shape follows `MLXService`'s server lifecycle deliberately (start/stop/restart,
/// log file the UI tails, termination handler, SIGTERM-then-SIGKILL, "stops when
/// Huginn quits"), because that lifecycle is the one already proven on this
/// machine. A managed CHILD rather than the in-process `BuzzGateway` actor: a
/// wedged model turn can't freeze the UI, a crash is visible and restartable, and
/// the log is a real file the existing console can tail. The in-process actor
/// stays available to the package tests.
///
/// Status comes from the child's OWN status lines (`BuzzGatewayStatus`, defined in
/// PQRCNostr and emitted by the gateway), not from log scraping: the counters are
/// a shared contract both sides are tested against.
@MainActor
final class BuzzGatewayService: ObservableObject {

    /// ONE app-wide instance — the children are machine-wide resources, so a
    /// rebuilt tab view must not lose track of them (the same bug MLXService's
    /// singleton exists to prevent).
    static let shared = BuzzGatewayService()

    enum State: Equatable {
        case stopped
        /// Process launched; waiting for the relay AUTH to land.
        case starting
        /// Authenticated and listening.
        case connected
        /// Refused to start, or the child exited unexpectedly.
        case failed(String)

        var isLive: Bool {
            switch self {
            case .starting, .connected: return true
            case .stopped, .failed: return false
            }
        }
    }

    let store: BuzzConnectionStore

    @Published private(set) var states: [String: State] = [:]
    @Published private(set) var counters: [String: BuzzGatewayCounters] = [:]
    /// Where the `eldr-buzz-agent` binary was found, or nil when it isn't
    /// installed yet (the UI offers Install).
    @Published private(set) var executablePath: String?

    private let paths: ConfigPaths
    private let diagnostics = DiagnosticsLog.shared
    private static let log = Logger(subsystem: "chat.eldr.huginn", category: "buzz")

    private var processes: [String: Process] = [:]
    private var logHandles: [String: FileHandle] = [:]
    private var tailers: [String: LogTailer] = [:]
    private var tailerSubscriptions: [String: AnyCancellable] = [:]
    /// Lines below this id belong to a PREVIOUS run of the same connection and
    /// must not be counted into this one (mirrors MLXService's scan baseline).
    private var countBaseline: [String: Int] = [:]
    private var expectingStop: Set<String> = []

    init(
        paths: ConfigPaths = .standard,
        store: BuzzConnectionStore? = nil,
        executableProvider: (() -> String?)? = nil
    ) {
        self.paths = paths
        self.store = store ?? BuzzConnectionStore(path: paths.buzzConnectionsFile)
        self.executableOverride = executableProvider
        executablePath = resolveExecutable()
        try? FileManager.default.createDirectory(
            atPath: paths.buzzDir, withIntermediateDirectories: true)
        // A gateway child must not outlive the app: it holds a live workspace
        // membership, and an orphan would keep answering in a channel after the
        // user quit the app that shows its status.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.terminateAll() }
        }
    }

    private let executableOverride: (() -> String?)?

    // MARK: - Executable resolution

    /// Where the gateway binary lives, in the order the app should trust:
    /// an injected path (tests), the installed copy in `~/.local/bin` (what the
    /// Install button writes), then the copy bundled inside the app.
    func resolveExecutable() -> String? {
        // Every candidate — including an injected one — must actually BE an
        // executable. Trusting the override blindly made a missing binary surface
        // as a raw spawn error ("The file 'nope' doesn't exist") instead of the
        // actionable "isn't installed yet — use Install below", which is the whole
        // point of the pre-check. Caught by `startFailsClosed`.
        if let executableOverride {
            guard let path = executableOverride(),
                FileManager.default.isExecutableFile(atPath: path)
            else { return nil }
            return path
        }
        let installed = paths.installedBuzzAgent
        if FileManager.default.isExecutableFile(atPath: installed) { return installed }
        if let bundled = Bundle.main.url(forResource: "eldr-buzz-agent", withExtension: nil),
            FileManager.default.isExecutableFile(atPath: bundled.path)
        {
            return bundled.path
        }
        return nil
    }

    func refreshExecutable() { executablePath = resolveExecutable() }

    // MARK: - Query

    func state(of id: String) -> State { states[id] ?? .stopped }
    func counters(of id: String) -> BuzzGatewayCounters { counters[id] ?? BuzzGatewayCounters() }
    func logPath(of id: String) -> String { paths.buzzLogFile(connectionID: id) }
    func isRunning(_ id: String) -> Bool { processes[id]?.isRunning == true }

    // MARK: - Lifecycle

    /// Start every connection that isn't paused. Called once at app launch, so a
    /// workspace agent survives a Huginn restart without the user re-clicking
    /// Connect. A paused (or invalid) connection stays down.
    func startEnabledConnections(llmURL: String, llmModel: String, llmToken: String) {
        for connection in store.connections where !connection.paused {
            start(connection, llmURL: llmURL, llmModel: llmModel, llmToken: llmToken)
        }
    }

    /// Launch (or relaunch) the gateway for one connection.
    ///
    /// Fails CLOSED: no key, no acknowledged disclosure, an unusable relay URL, or
    /// a missing binary all refuse to spawn with a stated reason rather than
    /// starting something that can't work.
    func start(_ connection: BuzzConnection, llmURL: String, llmModel: String, llmToken: String) {
        let problems = BuzzConnectionStore.problems(
            with: connection, hasKey: store.hasAgentKey(id: connection.id))
        if let first = problems.first {
            states[connection.id] = .failed(first.message)
            return
        }
        guard let executable = resolveExecutable() else {
            states[connection.id] = .failed(
                "The eldr-buzz-agent gateway isn't installed yet — use Install below.")
            return
        }
        guard let privateKeyHex = store.agentPrivateKeyHex(id: connection.id) else {
            states[connection.id] = .failed(
                "The agent key for this connection is missing from the Keychain.")
            return
        }
        if let existing = processes[connection.id], existing.isRunning {
            // Restart: stop first, then relaunch from the exit handler.
            pendingRestart.insert(connection.id)
            stop(id: connection.id)
            return
        }

        let logPath = paths.buzzLogFile(connectionID: connection.id)
        guard let handle = openLogHandle(at: logPath) else {
            states[connection.id] = .failed("Couldn't open the gateway log at \(logPath).")
            return
        }
        let header =
            "\n===== \(Date().ISO8601Format()) eldr-buzz-agent starting: "
            + "\(connection.displayName) → \(connection.relayURL) =====\n"
        try? handle.write(contentsOf: Data(header.utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.environment = Self.environment(
            for: connection, agentPrivateKeyHex: privateKeyHex, llmURL: llmURL,
            llmModel: llmModel, llmToken: llmToken)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        // Explicitly @Sendable: Foundation fires terminationHandler on an arbitrary
        // queue, and a @MainActor-inferred closure literal would trip Swift 6's
        // dynamic isolation check (the LogTailer crash class).
        let onExit: @Sendable (Process) -> Void = { [weak self] child in
            let status = child.terminationStatus
            Task { @MainActor [weak self] in self?.childExited(id: connection.id, status: status) }
        }
        process.terminationHandler = onExit

        // Attach the tailer BEFORE the child can write a byte. Its `start()` seeds
        // from the existing file, and the counting baseline is taken right after —
        // so this run's very first status line (the gateway emits one immediately)
        // lands on the NEW side of the baseline instead of being swallowed as
        // history. Started after the launch, a fast child's first lines would be
        // seeded and silently never counted.
        counters[connection.id] = BuzzGatewayCounters()
        attachTailer(id: connection.id, path: logPath)

        do {
            try process.run()
        } catch {
            try? handle.close()
            detachTailer(id: connection.id)
            states[connection.id] = .failed(
                "Couldn't launch the gateway: \(error.localizedDescription)")
            return
        }
        processes[connection.id] = process
        logHandles[connection.id] = handle
        states[connection.id] = .starting
        Self.log.info("buzz gateway starting for connection \(connection.id, privacy: .public)")
        diagnostics.record(
            .node, .info, "Buzz gateway starting",
            "\(connection.displayName) → \(connection.relayHost)")
    }

    private var pendingRestart: Set<String> = []

    /// Stop the child (SIGTERM now, SIGKILL if it lingers). The connection record
    /// is untouched — this is Pause/Disconnect, not Remove.
    func stop(id: String) {
        guard let process = processes[id], process.isRunning else {
            states[id] = .stopped
            detachTailer(id: id)
            return
        }
        expectingStop.insert(id)
        let pid = process.processIdentifier
        process.terminate()
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            kill(pid, SIGKILL)  // harmless ESRCH if it already exited
        }
    }

    /// Pause = stop and remember, so launch doesn't bring it back.
    func setPaused(_ paused: Bool, id: String, llmURL: String, llmModel: String, llmToken: String) {
        guard var connection = store.connection(id: id) else { return }
        connection.paused = paused
        store.update(connection)
        if paused {
            stop(id: id)
        } else {
            start(connection, llmURL: llmURL, llmModel: llmModel, llmToken: llmToken)
        }
    }

    private func childExited(id: String, status: Int32) {
        processes[id] = nil
        try? logHandles[id]?.close()
        logHandles[id] = nil
        let wasExpected = expectingStop.remove(id) != nil
        if pendingRestart.remove(id) != nil, let connection = store.connection(id: id) {
            // A restart requested while it was running: relaunch with the CURRENT
            // backend values (the caller's snapshot may be stale by now).
            states[id] = .stopped
            detachTailer(id: id)
            let backend = Self.currentBackend()
            start(
                connection, llmURL: backend.url, llmModel: backend.model, llmToken: backend.token)
            return
        }
        detachTailer(id: id)
        if wasExpected {
            states[id] = .stopped
            diagnostics.record(.node, .info, "Buzz gateway stopped")
        } else {
            let reason =
                counters(of: id).lastFailure
                ?? "The gateway exited unexpectedly (status \(status)). See its log."
            states[id] = .failed(reason)
            diagnostics.record(.node, .error, "Buzz gateway exited", "status \(status)")
            Self.log.error("buzz gateway exited status \(status, privacy: .public)")
        }
    }

    private func terminateAll() {
        for (_, process) in processes where process.isRunning {
            process.terminate()
        }
    }

    // MARK: - Log tail → counters

    private func attachTailer(id: String, path: String) {
        detachTailer(id: id)
        let tailer = LogTailer(path: path)
        tailers[id] = tailer
        tailer.start()
        // Only lines appended AFTER this launch belong to this run.
        countBaseline[id] = tailer.nextLineID
        tailerSubscriptions[id] =
            tailer.$lines
            .receive(on: RunLoop.main)
            .sink { [weak self] lines in self?.ingest(lines, for: id) }
    }

    private func detachTailer(id: String) {
        tailers[id]?.stop()
        tailers[id] = nil
        tailerSubscriptions[id] = nil
        countBaseline[id] = nil
    }

    private func ingest(_ lines: [LogLine], for id: String) {
        guard let baseline = countBaseline[id] else { return }
        var folded = counters[id] ?? BuzzGatewayCounters()
        var sawNew = false
        for line in lines where line.id >= baseline {
            guard let status = BuzzGatewayStatus.parse(line.text) else { continue }
            folded.ingest(status)
            sawNew = true
        }
        guard sawNew else { return }
        // Publish only on a real change (WS-M0 publish hygiene).
        if counters[id] != folded { counters[id] = folded }
        countBaseline[id] = (lines.last?.id).map { $0 + 1 } ?? baseline
        if folded.authenticated, states[id] != .connected, processes[id]?.isRunning == true {
            states[id] = .connected
            diagnostics.record(.node, .success, "Buzz gateway connected")
        }
    }

    // MARK: - Child environment (pure)

    /// The environment one gateway child runs with. Pure + static so the exact
    /// wiring — which secret goes where, and which knobs the record controls — is
    /// unit-tested without spawning anything.
    ///
    /// The agent's private key is passed in the environment (the same channel
    /// `buzz-acp` uses) and NEVER written to the env file on disk, which is world-
    /// readable-adjacent config; the owner's key is not here at all — it only ever
    /// signed the attestation, in memory, at setup.
    static func environment(
        for connection: BuzzConnection, agentPrivateKeyHex: String, llmURL: String,
        llmModel: String, llmToken: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["BUZZ_RELAY_URL"] = connection.relayURL
        env["BUZZ_PRIVATE_KEY"] = agentPrivateKeyHex
        if let authTag = connection.authTagJSON, !authTag.isEmpty {
            env["BUZZ_AUTH_TAG"] = authTag
        } else {
            env.removeValue(forKey: "BUZZ_AUTH_TAG")
        }
        env["ELDR_BUZZ_CHANNELS"] = connection.channelIds.joined(separator: ",")
        env["ELDR_BUZZ_DISPLAY_NAME"] = connection.displayName
        env["ELDR_BUZZ_ABOUT"] = connection.about
        if connection.pictureURL.isEmpty {
            env.removeValue(forKey: "ELDR_BUZZ_PICTURE")
        } else {
            env["ELDR_BUZZ_PICTURE"] = connection.pictureURL
        }
        env["ELDR_BUZZ_SYSTEM_PROMPT"] = connection.systemPrompt
        if let owner = connection.ownerPubkeyHex, !owner.isEmpty {
            env["ELDR_BUZZ_OWNER_PUBKEY"] = owner
        } else {
            env.removeValue(forKey: "ELDR_BUZZ_OWNER_PUBKEY")
        }
        env["ELDR_BUZZ_MENTIONS_ONLY"] = connection.respondToMentionsOnly ? "1" : "0"
        env["ELDR_BUZZ_REDACT"] = connection.redactOutbound ? "1" : "0"
        // The owner private key must never reach the child: it signed the
        // attestation once, in Huginn, and the gateway has no use for it.
        env.removeValue(forKey: "ELDR_BUZZ_OWNER_PRIVATE_KEY")
        // The brain: this connection's pin, else Huginn's current backend.
        env["ELDR_LLM_URL"] = connection.providerURL.isEmpty ? llmURL : connection.providerURL
        env["ELDR_LLM_MODEL"] = connection.model.isEmpty ? llmModel : connection.model
        if llmToken.isEmpty {
            env.removeValue(forKey: "ELDR_LLM_TOKEN")
        } else {
            env["ELDR_LLM_TOKEN"] = llmToken
        }
        // A stale fake-LLM flag inherited from the parent environment would make
        // the agent echo nonsense into a real workspace.
        env.removeValue(forKey: "ELDR_ACP_FAKE_LLM")
        return env
    }

    /// Huginn's current backend triple, read the same way every other surface
    /// reads it (`ConfigurationStore`'s persisted values + the Keychain token), for
    /// callers — like the restart path — that don't hold a live store.
    static func currentBackend() -> (url: String, model: String, token: String) {
        let env = ConfigurationStore.parseEnvFile(at: ConfigPaths.standard.envFile)
        let url = env["ELDR_LLM_URL"] ?? "http://127.0.0.1:1337/v1"
        let model = env["ELDR_LLM_MODEL"] ?? ""
        let token =
            KeychainBox().load(account: "llm-token").flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return (url, model, token)
    }

    private func openLogHandle(at path: String) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
