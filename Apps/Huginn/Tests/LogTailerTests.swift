import Foundation
import Testing

@testable import Huginn

// Regression for the MLX-tab crash (2026-07-17 crash report): LogTailer's
// dispatch-source event handler is a closure formed in a @MainActor context, so
// Swift 6's dynamic isolation check traps (EXC_BREAKPOINT in
// _dispatch_assert_queue_fail) the moment the source fires it on a background
// queue — which the MLX server section triggers reliably by writing the server
// log header while the pane tails that same file. The fix delivers source
// events on the main queue, where the handler's inferred isolation is correct.

@Suite("LogTailer delivers events without isolation traps")
struct LogTailerTests {

    @MainActor
    @Test func appendWhileTailingDeliversLines() async throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-logtailer-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        FileManager.default.createFile(atPath: path, contents: nil)

        let tailer = LogTailer(path: path)
        tailer.start()
        defer { tailer.stop() }

        // Append the way the MLX server child does: a plain write to the watched
        // file from outside the tailer. This is what fired the crashing event.
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("===== mlx server starting =====\n".utf8))
        try handle.close()

        // The event hops source-queue → main actor; poll briefly for it to land.
        var seen = false
        for _ in 0..<150 {
            if tailer.lines.contains(where: { $0.text == "===== mlx server starting =====" }) {
                seen = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(seen, "appended line never arrived — tailer event was lost")
    }
}

/// Replays the exact crashing gesture from the 2026-07-17 report end-to-end,
/// in-process: a LogTailer watches mlx-server.log while MLXService.startServer()
/// writes the header + spawns the child (the moment that trapped), then Stop
/// exercises the @Sendable terminationHandler on its arbitrary Foundation queue.
@Suite("MLX server lifecycle survives the crash-report sequence")
struct MLXServerLifecycleTests {

    @MainActor
    @Test func startTailStopWithoutIsolationTraps() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let paths = ConfigPaths(configDir: root, binDir: root)

        // Fake venv python: answers the version probe, then `exec sleep` for the
        // "server" so SIGTERM lands on the child directly.
        let binDir = (root as NSString).appendingPathComponent("mlx/venv/bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let fakePython = (binDir as NSString).appendingPathComponent("python3")
        let script = "#!/bin/zsh\nif [[ \"$1\" == \"-c\" ]]; then echo \"0.0.0-test\"; exit 0; fi\nexec sleep 60\n"
        try script.write(toFile: fakePython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakePython)

        let suite = "mlx-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MLXService(paths: paths, defaults: defaults, launchAgentsDir: root)

        await service.refreshEnvironment()
        #expect(service.envState == .ready(version: "0.0.0-test"))

        // Tail the server log like MLXView does, BEFORE the server starts.
        let tailer = LogTailer(path: service.serverLogPath)
        tailer.start()
        defer { tailer.stop() }

        service.serverConfig.model = "fake/model"
        service.serverConfig.port = 39_407  // nothing listens; probe just fails quietly
        service.startServer()
        #expect(service.serverState == .starting)

        // The header write is the event that SIGTRAPped the app.
        var sawHeader = false
        for _ in 0..<150 {
            if tailer.lines.contains(where: { $0.text.contains("mlx_lm.server starting") }) {
                sawHeader = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawHeader, "server-log header never reached the tailer")

        // Stop → SIGTERM → terminationHandler (arbitrary queue) → .stopped on main.
        service.stopServer()
        var stopped = false
        for _ in 0..<300 {
            if service.serverState == .stopped {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stopped, "server never reached .stopped after stopServer()")
    }
}
