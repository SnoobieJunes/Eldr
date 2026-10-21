// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Child-process supervision for everything Huginn runs (eldr-node bridge, one
/// eldr-buzz-agent per Buzz connection). Port of the process halves of the macOS
/// `ACPBridgeService` / `BuzzGatewayService`: stdout+stderr append to a per-child log the
/// Logs/Bridge/Buzz tabs tail; `stop` sends SIGTERM then SIGKILL after a grace period;
/// `stopAll` runs on app quit so Huginn never leaves a child running.
public actor ChildSupervisor {
    public enum State: Sendable, Equatable {
        case stopped
        case running(pid: Int32)
        case exited(status: Int32)
        case failedToStart(String)

        public var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .running(let pid): return "Running (pid \(pid))"
            case .exited(let s): return s == 0 ? "Exited" : "Exited with status \(s)"
            case .failedToStart(let why): return "Could not start: \(why)"
            }
        }
        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    private var processes: [String: Process] = [:]
    private var logHandles: [String: FileHandle] = [:]
    public private(set) var states: [String: State] = [:]
    private let onChange: @Sendable (String) -> Void

    public init(onChange: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onChange = onChange
    }

    public func state(_ id: String) -> State { states[id] ?? .stopped }

    @discardableResult
    public func start(
        id: String, executable: String, arguments: [String], environment: [String: String],
        logPath: String, workingDirectory: String? = nil
    ) -> State {
        if state(id).isRunning { return state(id) }
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable) else {
            return set(id, .failedToStart("\(executable) is not an executable file"))
        }
        try? fm.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logPath) {
            fm.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let log = FileHandle(forWritingAtPath: logPath) else {
            return set(id, .failedToStart("cannot open \(logPath)"))
        }
        _ = try? log.seekToEnd()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        if let workingDirectory { p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.exited(id: id, process: proc, status: status) }
        }
        do {
            try p.run()
        } catch {
            try? log.close()
            return set(id, .failedToStart(error.localizedDescription))
        }
        processes[id] = p
        logHandles[id] = log
        return set(id, .running(pid: p.processIdentifier))
    }

    private func exited(id: String, process: Process, status: Int32) {
        // Ignore a late exit from a process we've already replaced.
        guard processes[id] === process else { return }
        processes[id] = nil
        try? logHandles.removeValue(forKey: id)?.close()
        set(id, .exited(status: status))
    }

    @discardableResult
    private func set(_ id: String, _ s: State) -> State {
        states[id] = s
        onChange(id)
        return s
    }

    /// SIGTERM, wait up to `grace`, then SIGKILL. Returns once the child is gone.
    public func stop(id: String, grace: Duration = .seconds(3)) async {
        guard let p = processes[id] else { return }
        processes[id] = nil
        if p.isRunning { p.terminate() }
        let deadline = ContinuousClock.now + grace
        while p.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        while p.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        try? logHandles.removeValue(forKey: id)?.close()
        set(id, .stopped)
    }

    public func stopAll() async {
        for id in Array(processes.keys) { await stop(id: id) }
    }

    public var runningIDs: [String] { processes.filter { $0.value.isRunning }.map(\.key).sorted() }
}
