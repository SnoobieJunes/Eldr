// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Registers the `eldr-acp` agent into an ACP harness's config **crash-safely**.
///
/// The hazard (confirmed against OpenClaw/sybilclaw behavior): the gateway *watches* its
/// config file and hot-reloads on change, defaulting to a mode that **restarts the
/// gateway process** when a change needs it — which tears down a live agent session.
/// Registering an acpx agent / editing `acp.allowedAgents` is exactly such a change. So
/// we **never hot-edit a running gateway's config**:
///
///   • The agent COMMAND always goes into acpx's own `~/.acpx/config.json` (`agents.<id>`),
///     which the gateway does not watch — safe to write anytime, picked up by standalone
///     `acpx` / `acpx --agent`.
///   • The gateway config (sybilclaw `~/.sybilclaw/sybilclaw.json`, OpenClaw
///     `~/.config/openclaw/config.json`) — which the gateway needs for the `acpx` plugin
///     enable + the `acp.allowedAgents` allowlist — is written **only when the gateway is
///     NOT running**. While it's running we DEFER: we return the exact JSON to apply when
///     the user is idle (the gateway reloads then), never a live edit.
///
/// Every write backs up the existing file once, writes atomically, and produces
/// syntactically valid JSON via `JSONSerialization`, preserving all unrelated keys.
enum HarnessRegistration {

    /// A client/config to register into.
    enum Target: Equatable, Sendable {
        /// acpx's own `~/.acpx/config.json` — NOT gateway-watched (crash-safe anytime).
        case acpxGlobal
        /// A gateway-watched config (sybilclaw / OpenClaw / a custom path).
        case gateway(path: String)

        var isGatewayWatched: Bool {
            if case .gateway = self { return true }
            return false
        }
    }

    enum RegError: LocalizedError {
        case notJSONObject(String)
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notJSONObject(let p):
                return "The config at \(p) isn't a JSON object. Open it, confirm it's valid JSON, or point at a different file."
            case .readFailed(let m): return "Couldn't read the config: \(m)"
            case .writeFailed(let m): return "Couldn't write the config: \(m)"
            }
        }
    }

    /// The merged config we WOULD write — computed without touching the live file, so the
    /// UI can preview the exact JSON and decide whether it's safe to apply now.
    struct Plan: Sendable {
        let path: String
        let isGatewayWatched: Bool
        /// Pretty-printed, key-sorted JSON: exactly what `apply` would write.
        let json: String
        /// The agent is already registered identically — applying would be a no-op.
        let alreadyRegistered: Bool
    }

    enum Outcome: Equatable, Sendable {
        case wrote(path: String, backup: String?)
        case unchanged(path: String)
        /// We refused to hot-edit a RUNNING gateway. `json` is what to apply when idle.
        case deferredGatewayRunning(path: String, json: String)
    }

    // MARK: - Plan (no disk writes)

    /// Build (without writing) the merged config for `target`, registering `agentName`
    /// → `launcherPath`. Preserves all existing keys. For a gateway target it also adds
    /// the `acpx` plugin enable + the `acp.allowedAgents` entry (+ optional contextgraph).
    static func plan(
        target: Target,
        launcherPath: String,
        agentName: String = "eldr",
        contextGraphURL: String? = nil
    ) throws -> Plan {
        let path = path(for: target)
        let before = try readRoot(path)
        var root = before

        switch target {
        case .acpxGlobal:
            // { "agents": { "<name>": { "command", "args" } } }
            var agents = root["agents"] as? [String: Any] ?? [:]
            agents[agentName] = ["command": launcherPath, "args": [String]()]
            root["agents"] = agents

        case .gateway:
            // plugins.entries.acpx.config.agents.<name> + acp.allowedAgents += <name>
            var plugins = root["plugins"] as? [String: Any] ?? [:]
            var entries = plugins["entries"] as? [String: Any] ?? [:]
            var acpx = entries["acpx"] as? [String: Any] ?? [:]
            acpx["enabled"] = true
            var acpxConfig = acpx["config"] as? [String: Any] ?? [:]
            var agents = acpxConfig["agents"] as? [String: Any] ?? [:]
            agents[agentName] = ["command": launcherPath, "args": [String]()]
            acpxConfig["agents"] = agents
            acpx["config"] = acpxConfig
            entries["acpx"] = acpx

            if let cg = contextGraphURL, !cg.isEmpty {
                var cgEntry = entries["contextgraph"] as? [String: Any] ?? [:]
                cgEntry["enabled"] = true
                var cgConfig = cgEntry["config"] as? [String: Any] ?? [:]
                cgConfig["endpoint"] = cg
                cgEntry["config"] = cgConfig
                entries["contextgraph"] = cgEntry
            }
            plugins["entries"] = entries
            root["plugins"] = plugins

            // acp.allowedAgents must list the agent or the gateway rejects it.
            var acp = root["acp"] as? [String: Any] ?? [:]
            var allowed = acp["allowedAgents"] as? [String] ?? []
            if !allowed.contains(agentName) { allowed.append(agentName) }
            acp["allowedAgents"] = allowed
            root["acp"] = acp
        }

        let json = try prettyJSON(root)
        return Plan(
            path: path,
            isGatewayWatched: target.isGatewayWatched,
            json: json,
            alreadyRegistered: canonicalEqual(before, root))
    }

    // MARK: - Apply (crash-safe)

    /// Apply a plan crash-safely. A gateway-watched path is written ONLY when
    /// `gatewayRunning == false`; otherwise we return `.deferredGatewayRunning` with the
    /// JSON to apply when the gateway is idle. Backs up an existing file once.
    @discardableResult
    static func apply(_ plan: Plan, gatewayRunning: Bool) throws -> Outcome {
        if plan.alreadyRegistered { return .unchanged(path: plan.path) }
        if plan.isGatewayWatched && gatewayRunning {
            return .deferredGatewayRunning(path: plan.path, json: plan.json)
        }
        let backup = backUpIfNeeded(plan.path)
        try writeAtomically(plan.json, to: plan.path)
        return .wrote(path: plan.path, backup: backup)
    }

    // MARK: - Read-only status (for post-wizard visibility)

    /// True if `agentName` is already present in the config at `path` — either the
    /// acpx-global shape (`agents.<id>`) or the gateway shape
    /// (`plugins.entries.acpx.config.agents.<id>`). Best-effort, never throws.
    static func isRegistered(path: String, agentName: String = "eldr") -> Bool {
        guard let root = try? readRoot((path as NSString).expandingTildeInPath) else { return false }
        if let agents = root["agents"] as? [String: Any], agents[agentName] != nil { return true }
        if let plugins = root["plugins"] as? [String: Any],
            let entries = plugins["entries"] as? [String: Any],
            let acpx = entries["acpx"] as? [String: Any],
            let cfg = acpx["config"] as? [String: Any],
            let agents = cfg["agents"] as? [String: Any], agents[agentName] != nil
        {
            return true
        }
        return false
    }

    // MARK: - Path resolution

    static func path(for target: Target) -> String {
        switch target {
        case .acpxGlobal:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return ((home as NSString).appendingPathComponent(".acpx") as NSString)
                .appendingPathComponent("config.json")
        case .gateway(let path):
            return (path as NSString).expandingTildeInPath
        }
    }

    // MARK: - Helpers

    private static func readRoot(_ path: String) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }
        guard let data = fm.contents(atPath: path) else { throw RegError.readFailed(path) }
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RegError.notJSONObject(path)
        }
        return obj
    }

    private static func prettyJSON(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Compare two JSON object trees by re-serializing them canonically (sorted keys).
    private static func canonicalEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return da == db
    }

    /// Copy the existing file to `<path>.huginn.bak` once — preserve the earliest pristine
    /// copy; don't clobber a prior backup. Returns the backup path if one exists/was made.
    private static func backUpIfNeeded(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let backup = path + ".huginn.bak"
        if !fm.fileExists(atPath: backup) {
            try? fm.copyItem(atPath: path, toPath: backup)
        }
        return fm.fileExists(atPath: backup) ? backup : nil
    }

    private static func writeAtomically(_ contents: String, to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try contents.data(using: .utf8)?.write(
                to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw RegError.writeFailed(error.localizedDescription)
        }
    }
}
