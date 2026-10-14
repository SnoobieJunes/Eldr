// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP

/// Huginn's Configuration tab model (port of the macOS `ConfigurationStore`'s persisted
/// fields). Loading goes THROUGH `LLMConfig.fromEnvironment` / `AgentConfig.fromEnvironment`
/// on the parsed env file, so Huginn shows exactly what `eldr-acp` will run with; saving
/// writes the env file plus the `tools` / `skills` / `prompt-preamble` / `system-prompt`
/// files the agent also reads. C-8: the LLM token is never written to the env file.
public struct HuginnSettings: Sendable, Equatable {
    public var llmURL: String
    public var llmModel: String
    public var llmTimeoutSeconds: Double
    public var visionEnabled: Bool
    public var maxToolResultBytes: Int
    public var maxReadFileBytes: Int
    public var maxHistoryTurns: Int
    public var maxContextChars: Int
    public var toolResultKeepVerbatim: Int
    public var toolResultSpillEnabled: Bool
    public var maxAgentSteps: Int
    public var shellTimeoutSeconds: Double
    public var permissionTimeoutSeconds: Double
    public var allowUngatedTools: Bool
    public var cloudAgentDelegationEnabled: Bool
    public var learningEnabled: Bool
    public var contextFilePath: String
    public var contextGraphEnabled: Bool
    public var contextGraphURL: String
    public var contextGraphAgentName: String
    public var tools: [String]
    /// nil = all skills; [] with `skillsEnabled == false` = none.
    public var skillsEnabled: Bool
    public var skillAllowlist: [String]?
    public var promptPreamble: String
    public var systemPrompt: String
    /// Test Chat / agent workspace folder ("" = throwaway scratch dir).
    public var workdir: String

    public static func load(paths: HuginnPaths) -> HuginnSettings {
        let env = EnvFile.read(paths.envFile)
        let llm = LLMConfig.fromEnvironment(env)
        let agent = AgentConfig.fromEnvironment(env, configDir: paths.configDir)
        let workdir =
            (try? String(contentsOfFile: paths.workdirFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HuginnSettings(
            llmURL: llm.url, llmModel: llm.model, llmTimeoutSeconds: llm.requestTimeoutSeconds,
            visionEnabled: agent.visionEnabled,
            maxToolResultBytes: agent.maxToolResultBytes, maxReadFileBytes: agent.maxReadFileBytes,
            maxHistoryTurns: agent.maxHistoryTurns, maxContextChars: agent.maxContextChars,
            toolResultKeepVerbatim: agent.toolResultKeepVerbatim,
            toolResultSpillEnabled: agent.toolResultSpillEnabled,
            maxAgentSteps: agent.maxIterations, shellTimeoutSeconds: agent.shellTimeoutSeconds,
            permissionTimeoutSeconds: agent.permissionTimeoutSeconds,
            allowUngatedTools: agent.allowUngatedTools,
            cloudAgentDelegationEnabled: agent.cloudAgentDelegationEnabled,
            // Learning is on unless the env file pins the events file to "" (the Mac rule).
            learningEnabled: env["ELDR_ACP_EVENTS_FILE"].map { !$0.isEmpty } ?? true,
            contextFilePath: agent.contextFilePath ?? "",
            contextGraphEnabled: agent.contextGraphEnabled,
            contextGraphURL: agent.contextGraphURL,
            contextGraphAgentName: agent.contextGraphAgentName ?? "",
            tools: agent.toolAllowlist, skillsEnabled: agent.skillsEnabled,
            skillAllowlist: agent.skillAllowlist,
            promptPreamble: agent.promptPreamble ?? "", systemPrompt: agent.systemPromptOverride ?? "",
            workdir: workdir)
    }

    /// The env-file pairs, in a stable order.
    public func envPairs(paths: HuginnPaths) -> [(String, String)] {
        [
            ("ELDR_LLM_URL", llmURL),
            ("ELDR_LLM_MODEL", llmModel),
            ("ELDR_LLM_VISION", visionEnabled ? "1" : "0"),
            ("ELDR_LLM_TIMEOUT_SECONDS", Self.num(llmTimeoutSeconds)),
            ("ELDR_ACP_MAX_TOOL_RESULT_BYTES", String(maxToolResultBytes)),
            ("ELDR_ACP_MAX_READ_FILE_BYTES", String(maxReadFileBytes)),
            ("ELDR_ACP_MAX_HISTORY_TURNS", String(maxHistoryTurns)),
            ("ELDR_ACP_MAX_CONTEXT_CHARS", String(maxContextChars)),
            ("ELDR_ACP_TOOL_RESULT_KEEP", String(toolResultKeepVerbatim)),
            ("ELDR_ACP_TOOL_RESULT_SPILL", toolResultSpillEnabled ? "1" : "0"),
            ("ELDR_ACP_MAX_ITERATIONS", String(maxAgentSteps)),
            ("ELDR_ACP_SHELL_TIMEOUT", Self.num(shellTimeoutSeconds)),
            ("ELDR_ACP_PERMISSION_TIMEOUT", Self.num(permissionTimeoutSeconds)),
            ("ELDR_ACP_ALLOW_UNGATED_TOOLS", allowUngatedTools ? "1" : "0"),
            ("ELDR_ACP_ALLOW_CLOUD_DELEGATION", cloudAgentDelegationEnabled ? "1" : "0"),
            ("ELDR_ACP_EVENTS_FILE", learningEnabled ? paths.eventsFile : ""),
            ("ELDR_ACP_CONTEXT_FILE", contextFilePath),
            ("ELDR_ACP_CONTEXTGRAPH", contextGraphEnabled ? "1" : "0"),
            ("ELDR_ACP_CONTEXTGRAPH_URL", contextGraphURL),
            ("ELDR_ACP_CONTEXTGRAPH_AGENT", contextGraphAgentName),
        ]
    }

    static func num(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }

    public enum SaveError: Error, Equatable { case writeFailed(String) }

    /// Write every file. Empty text files are REMOVED (the agent treats "absent" and
    /// "empty" alike, and a stale file must not linger after the user clears a field).
    public func save(paths: HuginnPaths) throws(SaveError) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        } catch { throw .writeFailed(paths.configDir) }
        let env = EnvFile.render(
            envPairs(paths: paths),
            header: "Written by Huginn (Linux). Sourced by eldr-acp-launch.\nThe LLM token is NOT here; it lives in Huginn's keystore.")
        try write(env, to: paths.envFile, mode: 0o600)
        try writeOrRemove(tools.joined(separator: ","), paths.toolsFile)
        let skills: String
        if !skillsEnabled { skills = "none" } else if let list = skillAllowlist { skills = list.joined(separator: ",") } else { skills = "" }
        try writeOrRemove(skills, paths.skillsFile)
        try writeOrRemove(promptPreamble, paths.preambleFile)
        try writeOrRemove(systemPrompt, paths.systemPromptFile)
        try writeOrRemove(workdir, paths.workdirFile)
    }

    private func write(_ text: String, to path: String, mode: Int) throws(SaveError) {
        do {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        } catch { throw .writeFailed(path) }
    }

    private func writeOrRemove(_ text: String, _ path: String) throws(SaveError) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(atPath: path)
        } else {
            try write(text, to: path, mode: 0o600)
        }
    }

    /// What `eldr-acp` will actually run with after a save — the round-trip contract.
    public func agentConfig(paths: HuginnPaths) -> AgentConfig {
        AgentConfig.fromEnvironment(EnvFile.read(paths.envFile), configDir: paths.configDir)
    }

    public func llmConfig(token: String) -> LLMConfig {
        LLMConfig(url: llmURL, token: token, model: llmModel, requestTimeoutSeconds: llmTimeoutSeconds)
    }
}
