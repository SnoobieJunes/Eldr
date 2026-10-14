// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Port of the macOS `InstallerService`: copy `eldr-acp` (plus `huginn-cli`, and
/// `eldr-node` / `eldr-buzz-agent` when present) into `~/.local/bin` (0755) and write
/// the `eldr-acp-launch` launcher an ACP client (Zed, acpx, OpenClaw) is pointed at.
///
/// The launcher sources the env file, then — only if the spawning client did not
/// already provide them — asks `huginn-cli secret` for the LLM token and the B2
/// metadata key from Huginn's keystore (the Linux stand-in for the Mac launcher's
/// `security find-generic-password`), and execs the agent with stderr appended to the
/// log Huginn's Logs tab tails.
public struct HuginnInstaller: Sendable {
    public let paths: HuginnPaths
    public init(paths: HuginnPaths) { self.paths = paths }

    public static let binaries = ["eldr-acp", "huginn-cli", "eldr-node", "eldr-buzz-agent"]

    public enum InstallError: Error, Equatable {
        case missingAgentBinary(searched: [String])
        case copyFailed(String)
        case launcherWriteFailed(String)
    }

    public struct Report: Sendable, Equatable {
        public var installed: [String]
        public var launcher: String
    }

    /// Find each binary in the first source directory that has it.
    public static func locate(_ name: String, in dirs: [String]) -> String? {
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    public func install(from sourceDirs: [String]) throws(InstallError) -> Report {
        let fm = FileManager.default
        guard Self.locate("eldr-acp", in: sourceDirs) != nil else {
            throw .missingAgentBinary(searched: sourceDirs)
        }
        do {
            try fm.createDirectory(atPath: paths.binDir, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        } catch { throw .copyFailed(paths.binDir) }
        var installed: [String] = []
        for name in Self.binaries {
            guard let src = Self.locate(name, in: sourceDirs) else { continue }
            let dst = (paths.binDir as NSString).appendingPathComponent(name)
            // Never copy a file onto itself (running from an already-installed tree).
            if URL(fileURLWithPath: src).standardizedFileURL == URL(fileURLWithPath: dst).standardizedFileURL {
                installed.append(name); continue
            }
            let tmp = dst + ".huginn-tmp"
            try? fm.removeItem(atPath: tmp)
            do {
                try fm.copyItem(atPath: src, toPath: tmp)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
                guard rename(tmp, dst) == 0 else { throw InstallError.copyFailed(dst) }
            } catch {
                try? fm.removeItem(atPath: tmp)
                throw .copyFailed(dst)
            }
            installed.append(name)
        }
        try writeLauncher()
        return Report(installed: installed, launcher: paths.launcher)
    }

    public func launcherScript() -> String {
        let q = EnvFile.quote
        return """
            #!/usr/bin/env bash
            # Written by Huginn (Linux). ACP clients (Zed, acpx, OpenClaw) are pointed at this launcher.
            source \(q(paths.envFile)) 2>/dev/null || true
            # C-8: the LLM token is not in the env file. If the spawning client did not provide
            # it, read it from Huginn's keystore (needs HUGINN_PASSPHRASE_FILE or a TPM credential).
            if [[ -z "${ELDR_LLM_TOKEN:-}" && -x \(q(paths.installedCLI)) ]]; then
              ELDR_LLM_TOKEN="$(\(q(paths.installedCLI)) secret llm-token 2>/dev/null)"
              export ELDR_LLM_TOKEN
            fi
            if [[ -z "${ELDR_ACP_METADATA_KEY:-}" && -x \(q(paths.installedCLI)) ]]; then
              ELDR_ACP_METADATA_KEY="$(\(q(paths.installedCLI)) secret metadata-key 2>/dev/null)"
              export ELDR_ACP_METADATA_KEY
            fi
            exec \(q(paths.installedBinary)) "$@" 2>> \(q(paths.logFile))

            """
    }

    public func writeLauncher() throws(InstallError) {
        do {
            try Data(launcherScript().utf8).write(to: URL(fileURLWithPath: paths.launcher), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.launcher)
        } catch { throw .launcherWriteFailed(paths.launcher) }
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: paths.installedBinary)
            && FileManager.default.isExecutableFile(atPath: paths.launcher)
    }

    /// Remove only what Huginn installed (binaries + launcher); config is left alone.
    public func uninstall() {
        for name in Self.binaries + ["eldr-acp-launch"] {
            try? FileManager.default.removeItem(atPath: (paths.binDir as NSString).appendingPathComponent(name))
        }
    }
}
