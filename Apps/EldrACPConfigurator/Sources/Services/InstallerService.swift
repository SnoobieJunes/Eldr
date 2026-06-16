import Foundation
import PQRCACP

/// Installs the bundled `eldr-acp` binary to `~/.local/bin` and writes the
/// `eldr-acp-xcode` launcher Xcode 27 is pointed at. The launcher sources the env
/// file the ConfigurationStore writes and tees stderr to a log the LogTailer follows.
@MainActor
final class InstallerService: ObservableObject {

    enum InstallerState: Equatable {
        case unknown
        case notInstalled
        case installed(version: String)
        case updateAvailable(bundled: String, installed: String)
    }

    @Published private(set) var state: InstallerState = .unknown
    @Published private(set) var lastError: String?

    let paths: ConfigPaths
    init(paths: ConfigPaths = .standard) { self.paths = paths }

    /// The bundled binary shipped inside the app (copied in by the Run Script phase).
    var bundledBinary: URL? { Bundle.main.url(forResource: "eldr-acp", withExtension: nil) }

    // MARK: - State

    func refreshState() async {
        let installed = FileManager.default.isExecutableFile(atPath: paths.installedBinary)
        guard installed else {
            state = .notInstalled
            return
        }
        let installedVersion = await version(of: paths.installedBinary) ?? "unknown"
        if let bundled = bundledBinary, let bundledVersion = await version(of: bundled.path),
            bundledVersion != installedVersion
        {
            state = .updateAvailable(bundled: bundledVersion, installed: installedVersion)
        } else {
            state = .installed(version: installedVersion)
        }
    }

    /// `eldr-acp/<version>` → `<version>`; nil if the binary can't be run.
    private func version(of binaryPath: String) async -> String? {
        let result = await ProcessRunner.run(binaryPath, ["--version"])
        guard result.exit == 0 else { return nil }
        let line = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix("eldr-acp/") ? String(line.dropFirst("eldr-acp/".count)) : line
    }

    // MARK: - Install

    /// Copy the bundled binary into `~/.local/bin` (0755), write the launcher, and
    /// refresh state. Throws a descriptive error on failure.
    func install() async throws {
        lastError = nil
        do {
            guard let bundled = bundledBinary else {
                throw InstallError.missingBundledBinary
            }
            let fm = FileManager.default
            try fm.createDirectory(atPath: paths.binDir, withIntermediateDirectories: true)

            // Replace any existing install atomically-ish: remove then copy.
            if fm.fileExists(atPath: paths.installedBinary) {
                try fm.removeItem(atPath: paths.installedBinary)
            }
            try fm.copyItem(atPath: bundled.path, toPath: paths.installedBinary)
            try fm.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: paths.installedBinary)

            try writeLauncher()
            // Ensure the config dir exists so `source env` never errors.
            try fm.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        } catch let error as InstallError {
            lastError = error.message
            throw error
        } catch {
            lastError = error.localizedDescription
            throw error
        }
        await refreshState()
    }

    /// The launcher Xcode invokes. It sources the env file (so the GUI's settings
    /// reach the agent) and appends stderr to the log the LogTailer follows.
    private func writeLauncher() throws {
        let script = """
            #!/bin/zsh
            # Written by EldrACPConfigurator. Xcode 27 is pointed at this launcher.
            source "\(paths.envFile)" 2>/dev/null || true
            exec "\(paths.installedBinary)" "$@" 2>> "\(paths.logFile)"
            """
        guard let data = script.data(using: .utf8) else { throw InstallError.encodingFailed }
        try data.write(to: URL(fileURLWithPath: paths.launcher), options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.launcher)
    }

    enum InstallError: Error {
        case missingBundledBinary
        case encodingFailed
        var message: String {
            switch self {
            case .missingBundledBinary:
                return
                    "The bundled eldr-acp binary is missing from the app. Rebuild the app so the Run Script phase compiles and copies it."
            case .encodingFailed: return "Could not encode the launcher script."
            }
        }
    }
}

/// Runs a child process off the caller's actor and returns its captured stdout +
/// exit status. Everything is created and consumed inside the work closure, so the
/// whole thing is Sendable-clean under Swift 6.
enum ProcessRunner {
    static func run(
        _ launchPath: String, _ args: [String], env: [String: String]? = nil
    ) async -> (out: String, exit: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                if let env { process.environment = env }
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ("", -1))
                    return
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: (String(data: data, encoding: .utf8) ?? "", process.terminationStatus))
            }
        }
    }
}
