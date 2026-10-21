// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP

/// Where Huginn-on-Linux keeps everything. The agent config dir is the SAME directory
/// `eldr-acp` reads (`AgentConfig.defaultConfigDir`: `$ELDR_ACP_CONFIG_DIR`, else
/// `$XDG_CONFIG_HOME/eldr-acp`, else `~/.config/eldr-acp`), so a file Huginn writes is
/// the file the agent loads — the same contract as the macOS app's `ConfigPaths`.
public struct HuginnPaths: Sendable, Equatable {
    public let configDir: String
    public let binDir: String

    public init(configDir: String, binDir: String) {
        self.configDir = configDir
        self.binDir = binDir
    }

    /// The real locations for this user (`binDir` = `$HUGINN_BIN_DIR` or `~/.local/bin`).
    public static func standard(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> HuginnPaths {
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let config =
            AgentConfig.defaultConfigDir(env)
            ?? ((home as NSString).appendingPathComponent(".config/eldr-acp"))
        let bin =
            env["HUGINN_BIN_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".local/bin")
        return HuginnPaths(configDir: config, binDir: bin)
    }

    func join(_ a: String, _ b: String) -> String { (a as NSString).appendingPathComponent(b) }

    public var envFile: String { join(configDir, "env") }
    public var toolsFile: String { join(configDir, "tools") }
    public var skillsFile: String { join(configDir, "skills") }
    public var preambleFile: String { join(configDir, "prompt-preamble") }
    public var systemPromptFile: String { join(configDir, "system-prompt") }
    public var logFile: String { join(configDir, "eldr-acp.log") }
    public var eventsFile: String { join(configDir, "events.jsonl") }
    public var projectsDir: String { join(configDir, "projects") }
    public var workdirFile: String { join(configDir, "workdir") }
    public var gooseworldEnvFile: String { join(configDir, "mcp-town.env") }
    public var buzzConnectionsFile: String { join(configDir, "buzz-connections.json") }
    public var buzzLogDir: String { join(configDir, "buzz-logs") }
    public func buzzLogFile(connectionID: String) -> String {
        join(buzzLogDir, "\(connectionID).log")
    }
    public var nodeLogFile: String { join(configDir, "eldr-node.log") }
    public var bridgeFile: String { join(configDir, "huginn-bridge.json") }
    /// The EldrKeystore directory holding Huginn's secrets (LLM token, B2 metadata key,
    /// Buzz agent keys) — Linux stand-in for the macOS Keychain (DEVIATIONS AC204).
    public var keystoreDir: String { join(configDir, "huginn-keystore") }

    public var installedBinary: String { join(binDir, "eldr-acp") }
    public var launcher: String { join(binDir, "eldr-acp-launch") }
    public var installedCLI: String { join(binDir, "huginn-cli") }
}
