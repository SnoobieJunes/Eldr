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

    /// The launchers ACP clients invoke. Each sources the env file (so the GUI's
    /// settings reach the agent) and appends stderr to the log the LogTailer
    /// follows. The Xcode and OpenClaw launchers share an identical body — the
    /// agent is client-agnostic; the only reason for two files is so each client
    /// points at a stable, recognizable path.
    private func writeLauncher() throws {
        try writeLauncherScript(
            at: paths.launcher, comment: "Xcode is pointed at this launcher.")
        try writeLauncherScript(
            at: paths.openClawLauncher,
            comment: "OpenClaw (and other ACP clients) are pointed at this launcher.")
    }

    private func writeLauncherScript(at path: String, comment: String) throws {
        let script = """
            #!/bin/zsh
            # Written by Huginn. \(comment)
            # EldrChat builds against the iOS 27 / macOS 26 beta SDK (Private Cloud
            # Compute symbols), which exist only in Xcode-beta. Force the agent's
            # xcodebuild/xcrun onto the beta toolchain even when xcode-select (or the
            # client that spawned this launcher) defaults to stable Xcode — otherwise
            # the agent's builds fail on the missing PCC symbols. The env file sourced
            # below can still override DEVELOPER_DIR for a non-default toolchain.
            if [[ -d "/Applications/Xcode-beta.app/Contents/Developer" ]]; then
              export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
            fi
            source "\(paths.envFile)" 2>/dev/null || true
            # C-8: the LLM token is NOT in the env file (it lives in the Keychain).
            # If the spawning client didn't already provide it, read it from the Keychain.
            # (The Configurator injects it directly; this covers external clients like
            # Xcode/OpenClaw.) The Configurator keeps a FILE-keychain mirror of the token
            # precisely so `/usr/bin/security` can read it — the data-protection copy used
            # by Huginn itself is invisible to the `security` CLI. The first read prompts
            # once and the grant STICKS, because `/usr/bin/security` is Apple-signed and
            # stable across Huginn rebuilds (the recurring prompts were Huginn re-reading
            # its OWN items under a changed signature — now on the data-protection keychain).
            if [[ -z "${ELDR_LLM_TOKEN:-}" ]]; then
              ELDR_LLM_TOKEN="$(security find-generic-password -w -s 'chat.eldr.huginn' -a 'llm-token' 2>/dev/null)"
              export ELDR_LLM_TOKEN
            fi
            exec "\(paths.installedBinary)" "$@" 2>> "\(paths.logFile)"
            """
        guard let data = script.data(using: .utf8) else { throw InstallError.encodingFailed }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    // MARK: - WS-B3: source-freshness staleness (Status section)
    //
    // Separate from `refreshState()`'s bundled-vs-installed VERSION comparison above,
    // which only fires if `ACPAgent.agentVersion` was bumped — it's a static "0.1.0"
    // string, so an ordinary source edit + rebuild leaves it unchanged. This compares
    // FILE TIMES instead: is the installed `~/.local/bin/eldr-acp` older than the
    // newest edit under Packages/PQRCACP/Sources? That catches the case that actually
    // bites during development — "I edited the agent, did I reinstall?" — regardless
    // of version bumps.
    //
    // Chosen over "newest commit touching Packages/PQRCACP" (the other option on the
    // table): no `git` invocation or working-tree assumptions, and it reflects
    // uncommitted local edits too, which a commit-log-based check would miss entirely
    // during exactly the workflow this exists to catch.

    /// The checkout root this file was compiled from. Huginn is a companion dev tool
    /// built directly from this monorepo — never relocated or shipped standalone (see
    /// CLAUDE.md's repository layout) — so `#filePath`'s compile-time absolute path
    /// reliably locates `Packages/PQRCACP/Sources` without a user-configured setting.
    /// If the checkout is ever moved after building, this resolves to a stale/
    /// nonexistent path and `newestPQRCACPSourceDate()` returns nil (fail-soft — the
    /// Status row just hides the staleness warning rather than showing a wrong one).
    private nonisolated static var repoRootFromCompiledPath: String {
        var url = URL(fileURLWithPath: #filePath)
        // InstallerService.swift → Services → Sources → Huginn → Apps → repo root
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.path
    }

    /// Newest file-modification date among Packages/PQRCACP/Sources files — the
    /// staleness baseline. nil if the checkout can't be found there (e.g. a relocated
    /// build) or the directory is empty/unreadable.
    nonisolated static func newestPQRCACPSourceDate(fileManager: FileManager = .default) -> Date? {
        let dir = (repoRootFromCompiledPath as NSString)
            .appendingPathComponent("Packages/PQRCACP/Sources")
        guard
            let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: dir, isDirectory: true),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var newest: Date?
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                let date = values.contentModificationDate
            else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    /// The installed binary's mtime (`~/.local/bin/eldr-acp`). nil when not installed.
    func installedBinaryModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: paths.installedBinary))?[
            .modificationDate] as? Date
    }

    /// Pure comparison, extracted so it's unit-testable with synthetic dates rather
    /// than the real checkout/install state.
    nonisolated static func isStale(installedDate: Date, newestSourceDate: Date) -> Bool {
        installedDate < newestSourceDate
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
