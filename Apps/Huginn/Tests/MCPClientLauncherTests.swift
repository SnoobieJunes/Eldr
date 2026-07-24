// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import Huginn

// The env-injecting MCP-client wrappers (for clients like Hermes that can't pass env
// vars to a stdio server). The load-bearing property under test is SECRET-FREENESS:
// the wrapper the client points at must never contain a pairing token, because
// `hermes mcp list` and config dumps print it. The token lives only in a 0600 env file.

@Suite("MCP-client env-injecting wrappers")
struct MCPClientLauncherTests {

    /// A throwaway ConfigPaths rooted at a fresh tmp dir (binDir == configDir, as the
    /// existing launcher tests do), cleaned up by the caller's `defer`.
    private func makePaths() throws -> (ConfigPaths, String) {
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return (ConfigPaths(configDir: tmp, binDir: tmp), tmp)
    }

    @Test(arguments: [MCPClientLauncher.Wall.secureChat, .gooseworldTown])
    func writesSecretFreeWrapperAndTemplateEnvFileWithCorrectModes(_ wall: MCPClientLauncher.Wall)
        throws
    {
        let (paths, tmp) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let result = try MCPClientLauncher.install(wall, paths: paths)

        let fm = FileManager.default
        // Both files exist.
        #expect(fm.fileExists(atPath: result.launcher))
        #expect(fm.fileExists(atPath: result.envFile))
        #expect(fm.isExecutableFile(atPath: result.launcher))

        let script = try String(contentsOfFile: result.launcher, encoding: .utf8)
        // It sources the env file and execs the shim (the two things that make it work).
        #expect(script.contains(". \"\(result.envFile)\""))
        #expect(script.contains("exec \"\(wall.shimPath(paths))\""))

        // SECRET-FREE: the wrapper must not name the token env var at all (so it can
        // never carry a value), and must not contain any token-shaped material.
        #expect(!script.contains(wall.tokenEnvVar), "the wrapper must not reference the token")

        // Modes: wrapper 0700, env file 0600.
        let launcherPerms =
            (try fm.attributesOfItem(atPath: result.launcher)[.posixPermissions] as? NSNumber)?
            .intValue
        #expect(launcherPerms == 0o700)
        let envPerms =
            (try fm.attributesOfItem(atPath: result.envFile)[.posixPermissions] as? NSNumber)?
            .intValue
        #expect(envPerms == 0o600)

        // The template env file names BOTH env vars the shim reads, so the user knows
        // what to paste — but as commented placeholders, not live values.
        let env = try String(contentsOfFile: result.envFile, encoding: .utf8)
        #expect(env.contains(wall.socketEnvVar))
        #expect(env.contains(wall.tokenEnvVar))
    }

    /// Re-installing must NEVER clobber an env file the user already filled in — that
    /// would silently break a working integration by wiping the pasted token.
    @Test func reinstallPreservesAnExistingEnvFile() throws {
        let (paths, tmp) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        _ = try MCPClientLauncher.install(.secureChat, paths: paths)
        // Simulate the user pasting their real values.
        let real = "PQRC_MCP_SOCKET=/tmp/live.sock\nPQRC_MCP_TOKEN=super-secret-token\n"
        try real.write(toFile: paths.mcpBridgeEnvFile, atomically: true, encoding: .utf8)

        // Re-run install (e.g. an app update).
        _ = try MCPClientLauncher.install(.secureChat, paths: paths)

        let after = try String(contentsOfFile: paths.mcpBridgeEnvFile, encoding: .utf8)
        #expect(after == real, "re-install must not overwrite the user's pasted token")

        // And the wrapper STILL carries no secret even though the env file now has one.
        let script = try String(contentsOfFile: paths.mcpBridgeLauncher, encoding: .utf8)
        #expect(!script.contains("super-secret-token"))
    }
}
