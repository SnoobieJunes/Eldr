import Foundation

/// Registers the `eldr-acp` agent into OpenClaw's config WITHOUT clobbering any
/// existing settings. OpenClaw loads ACP agents through its `acpx` plugin:
///
///   { "plugins": { "entries": { "acpx": {
///       "enabled": true,
///       "config": { "agents": { "eldr": { "command": "<launcher>", "args": [] } } } } } } }
///
/// We read-modify-write the JSON via `JSONSerialization` so unrelated OpenClaw
/// keys (other plugins, editor settings) survive untouched. This is the
/// first-class equivalent of the Xcode wizard step — one click instead of a
/// hand-edited config (DEVIATIONS — OpenClaw integration).
///
/// NOTE: the exact OpenClaw config filename is user-overridable in the wizard
/// (default `~/.config/openclaw/config.json`); the `acpx` plugin shape is taken
/// from the project's SETUP-GUIDE. Verify against the installed OpenClaw if it
/// rejects the entry.
enum OpenClawRegistration {

    enum RegError: LocalizedError {
        case notJSONObject(String)
        case readFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notJSONObject(let p):
                return "The OpenClaw config at \(p) isn't a JSON object. Open it and check it's valid JSON, or point at a different file."
            case .readFailed(let m): return "Couldn't read the OpenClaw config: \(m)"
            case .writeFailed(let m): return "Couldn't write the OpenClaw config: \(m)"
            }
        }
    }

    /// Merge the agent entry (and, when `contextGraphURL` is set, the contextgraph
    /// plugin) into the config at `configPath`, creating the file/dir if absent.
    /// Returns the resolved path written.
    @discardableResult
    static func register(
        configPath: String,
        launcherPath: String,
        agentName: String = "eldr",
        contextGraphURL: String? = nil
    ) throws -> String {
        let fm = FileManager.default

        var root: [String: Any] = [:]
        if fm.fileExists(atPath: configPath) {
            guard let data = fm.contents(atPath: configPath) else {
                throw RegError.readFailed(configPath)
            }
            // An empty file is a fresh start, not an error.
            if !data.isEmpty {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RegError.notJSONObject(configPath)
                }
                root = obj
            }
        }

        // plugins.entries.acpx.config.agents.<name> = { command, args }
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

        // Optional: enable contextgraph's bundled OpenClaw plugin pointed at the
        // same local service (D4). Shape is best-effort — see note above.
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

        // Ensure the parent dir exists; write pretty + sorted for stable diffs.
        let dir = (configPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        } catch let e as RegError {
            throw e
        } catch {
            throw RegError.writeFailed(error.localizedDescription)
        }
        return configPath
    }
}
