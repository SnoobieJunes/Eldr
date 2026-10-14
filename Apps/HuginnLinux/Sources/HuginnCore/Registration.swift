// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Register the eldr-acp launcher with ACP clients. acpx/OpenClaw is the Mac
/// `HarnessRegistration` logic; Zed (`agent_servers` in settings.json) replaces the
/// macOS-only Xcode registration (DEVIATIONS AC208). Every write is preceded by a plan
/// (no disk writes) and a one-time `.huginn.bak` backup; a file that isn't plain JSON
/// (Zed allows comments) is never rewritten — the snippet is shown for pasting instead.
public enum HarnessRegistration {
    public enum Target: Equatable, Sendable {
        case acpxGlobal
        case gateway(path: String)
        case zed

        var isGatewayWatched: Bool { if case .gateway = self { return true }; return false }
    }

    public enum RegError: Error, Equatable {
        case notJSONObject(String)
        case readFailed(String)
        case writeFailed(String)
        public var message: String {
            switch self {
            case .notJSONObject(let p): return "\(p) isn't plain JSON (comments?). Paste the snippet by hand instead."
            case .readFailed(let m): return "Couldn't read the config: \(m)"
            case .writeFailed(let m): return "Couldn't write the config: \(m)"
            }
        }
    }

    public struct Plan: Sendable, Equatable {
        public let path: String
        public let isGatewayWatched: Bool
        public let json: String
        public let alreadyRegistered: Bool
    }

    public enum Outcome: Equatable, Sendable {
        case wrote(path: String, backup: String?)
        case unchanged(path: String)
        case deferredGatewayRunning(path: String, json: String)
    }

    public static func plan(
        target: Target, launcherPath: String, agentName: String = "eldr",
        contextGraphURL: String? = nil, home: String = NSHomeDirectory()
    ) throws(RegError) -> Plan {
        let path = path(for: target, home: home)
        let before = try readRoot(path)
        var root = before
        switch target {
        case .acpxGlobal:
            var agents = root["agents"] as? [String: Any] ?? [:]
            agents[agentName] = ["command": launcherPath, "args": [String]()]
            root["agents"] = agents
        case .zed:
            var servers = root["agent_servers"] as? [String: Any] ?? [:]
            servers[zedName(agentName)] = ["command": launcherPath, "args": [String](), "env": [String: String]()]
            root["agent_servers"] = servers
        case .gateway:
            var plugins = root["plugins"] as? [String: Any] ?? [:]
            var entries = plugins["entries"] as? [String: Any] ?? [:]
            var acpx = entries["acpx"] as? [String: Any] ?? [:]
            acpx["enabled"] = true
            var cfg = acpx["config"] as? [String: Any] ?? [:]
            var agents = cfg["agents"] as? [String: Any] ?? [:]
            agents[agentName] = ["command": launcherPath, "args": [String]()]
            cfg["agents"] = agents
            acpx["config"] = cfg
            entries["acpx"] = acpx
            if let cg = contextGraphURL, !cg.isEmpty {
                var e = entries["contextgraph"] as? [String: Any] ?? [:]
                e["enabled"] = true
                var c = e["config"] as? [String: Any] ?? [:]
                c["endpoint"] = cg
                e["config"] = c
                entries["contextgraph"] = e
            }
            plugins["entries"] = entries
            root["plugins"] = plugins
            var acp = root["acp"] as? [String: Any] ?? [:]
            var allowed = acp["allowedAgents"] as? [String] ?? []
            if !allowed.contains(agentName) { allowed.append(agentName) }
            acp["allowedAgents"] = allowed
            root["acp"] = acp
        }
        return Plan(path: path, isGatewayWatched: target.isGatewayWatched, json: try pretty(root),
                    alreadyRegistered: canonicalEqual(before, root))
    }

    static func zedName(_ agentName: String) -> String { agentName == "eldr" ? "Eldr" : agentName }

    /// What to paste into Zed's settings.json when it can't be rewritten automatically.
    public static func zedSnippet(launcherPath: String) -> String {
        """
        "agent_servers": {
          "Eldr": { "command": "\(launcherPath)", "args": [], "env": {} }
        }
        """
    }

    @discardableResult
    public static func apply(_ plan: Plan, gatewayRunning: Bool) throws(RegError) -> Outcome {
        if plan.alreadyRegistered { return .unchanged(path: plan.path) }
        if plan.isGatewayWatched && gatewayRunning { return .deferredGatewayRunning(path: plan.path, json: plan.json) }
        let backup = backUpIfNeeded(plan.path)
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (plan.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do { try Data(plan.json.utf8).write(to: URL(fileURLWithPath: plan.path), options: .atomic) }
        catch { throw .writeFailed(error.localizedDescription) }
        return .wrote(path: plan.path, backup: backup)
    }

    public static func isRegistered(target: Target, agentName: String = "eldr", home: String = NSHomeDirectory()) -> Bool {
        guard let root = try? readRoot(path(for: target, home: home)) else { return false }
        if let a = root["agents"] as? [String: Any], a[agentName] != nil { return true }
        if let s = root["agent_servers"] as? [String: Any], s[zedName(agentName)] != nil { return true }
        if let p = root["plugins"] as? [String: Any], let e = p["entries"] as? [String: Any],
            let x = e["acpx"] as? [String: Any], let c = x["config"] as? [String: Any],
            let a = c["agents"] as? [String: Any], a[agentName] != nil
        { return true }
        return false
    }

    public static func path(for target: Target, home: String = NSHomeDirectory()) -> String {
        switch target {
        case .acpxGlobal: return (home as NSString).appendingPathComponent(".acpx/config.json")
        case .zed: return (home as NSString).appendingPathComponent(".config/zed/settings.json")
        case .gateway(let p):
            return p.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(p.dropFirst(2))) : p
        }
    }

    static func readRoot(_ path: String) throws(RegError) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }
        guard let data = fm.contents(atPath: path) else { throw .readFailed(path) }
        if data.isEmpty { return [:] }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw .notJSONObject(path)
        }
        return obj
    }

    static func pretty(_ obj: [String: Any]) throws(RegError) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            throw .writeFailed("could not encode JSON")
        }
        return String(decoding: d, as: UTF8.self)
    }

    static func canonicalEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])
        let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        return da == db
    }

    static func backUpIfNeeded(_ path: String) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let backup = path + ".huginn.bak"
        if !fm.fileExists(atPath: backup) { try? fm.copyItem(atPath: path, toPath: backup) }
        return fm.fileExists(atPath: backup) ? backup : nil
    }
}
