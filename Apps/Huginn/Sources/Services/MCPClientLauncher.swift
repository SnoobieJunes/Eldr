// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Writes the env-injecting wrapper launchers an MCP client is pointed at when it
/// can't pass env vars to a stdio server (e.g. Hermes' `hermes mcp add --command`).
///
/// Our `pqrc-mcp-bridge` (secure chat) and `eldr-gooseworld` (town wall) shims each
/// REQUIRE a loopback socket path + pairing token in their environment or they fail
/// closed. This mirrors the ACP-agent launcher pattern (`InstallerService.writeLauncher`):
/// the client is pointed at a stable wrapper that sources a 0600 env file (holding the
/// secret) and execs the shim.
///
/// Load-bearing security property: the WRAPPER SCRIPT carries no secret. `hermes mcp
/// list`, editor config dumps, and process listings show only the wrapper path — never
/// the token, which lives solely in the 0600 env file (same rule as AC132's
/// secret-free generated `found-town` script). The env file is written 0600 and, if it
/// already exists, is NEVER overwritten — so re-running install can't clobber a token
/// the user already pasted in.
enum MCPClientLauncher {

    /// The two walls, each with its shim + env-var names. Keeps the wrapper body
    /// identical bar the four strings that differ between them.
    enum Wall {
        case secureChat
        case gooseworldTown

        /// The env-var names the shim reads (socket, then token). Documented in each
        /// shim's `main.swift` header.
        var socketEnvVar: String {
            switch self {
            case .secureChat: return "PQRC_MCP_SOCKET"
            case .gooseworldTown: return "ELDR_GOOSEWORLD_SOCKET"
            }
        }
        var tokenEnvVar: String {
            switch self {
            case .secureChat: return "PQRC_MCP_TOKEN"
            case .gooseworldTown: return "ELDR_GOOSEWORLD_TOKEN"
            }
        }

        func launcherPath(_ paths: ConfigPaths) -> String {
            switch self {
            case .secureChat: return paths.mcpBridgeLauncher
            case .gooseworldTown: return paths.gooseworldLauncher
            }
        }
        func envFilePath(_ paths: ConfigPaths) -> String {
            switch self {
            case .secureChat: return paths.mcpBridgeEnvFile
            case .gooseworldTown: return paths.gooseworldEnvFile
            }
        }
        func shimPath(_ paths: ConfigPaths) -> String {
            switch self {
            case .secureChat: return paths.mcpBridgeShim
            case .gooseworldTown: return paths.gooseworldShim
            }
        }
    }

    enum LauncherError: Error {
        case encodingFailed
    }

    /// Write the wrapper (0700) and, only if it does not already exist, a template
    /// 0600 env file the user fills in with the Socket + Pairing token from Settings.
    /// Creates `binDir`/`configDir` as needed. Returns the two paths for surfacing in UI.
    @discardableResult
    static func install(
        _ wall: Wall, paths: ConfigPaths, fileManager: FileManager = .default
    ) throws -> (launcher: String, envFile: String) {
        let launcherPath = wall.launcherPath(paths)
        let envFilePath = wall.envFilePath(paths)

        try fileManager.createDirectory(atPath: paths.binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)

        // The wrapper — SECRET-FREE by design. POSIX sh (no zsh needed; this does no
        // toolchain juggling like the ACP launcher). `. file` is `source` in sh.
        let script = """
            #!/bin/sh
            # Written by Huginn. An MCP client whose add-a-server flow can't set env
            # vars (e.g. `hermes mcp add --command`) is pointed at THIS wrapper. It
            # sources the socket + pairing token from a sibling 0600 env file and execs
            # the bridge shim. This script carries NO secret by design — the token lives
            # only in the sourced env file, never here (so `mcp list`/config dumps and
            # process listings can't leak it).
            if [ -f "\(envFilePath)" ]; then . "\(envFilePath)"; fi
            exec "\(wall.shimPath(paths))" "$@"
            """
        guard let data = script.data(using: .utf8) else { throw LauncherError.encodingFailed }
        try data.write(to: URL(fileURLWithPath: launcherPath), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcherPath)

        // Template env file — written ONLY if absent, so a re-install never clobbers a
        // token the user already pasted. 0600 (owner read/write only).
        if !fileManager.fileExists(atPath: envFilePath) {
            let template = """
                # Written by Huginn (template). Paste the values Settings shows for
                # \"Local agent access (MCP)\". This file is 0600 and holds the secret;
                # the wrapper that sources it does not.
                # \(wall.socketEnvVar)=/path/to/loopback.sock
                # \(wall.tokenEnvVar)=paste-the-pairing-token-here
                """
            guard let tdata = template.data(using: .utf8) else { throw LauncherError.encodingFailed }
            try tdata.write(to: URL(fileURLWithPath: envFilePath), options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFilePath)
        }

        return (launcherPath, envFilePath)
    }
}
