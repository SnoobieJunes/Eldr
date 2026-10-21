// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP

public struct ProjectMemory: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let cwd: String
    public let path: String
    public let preview: String
}

/// Port of the macOS `ContextLearner` (project memory, `eldr.md`). The agent appends
/// JSON events to `events.jsonl`; this turns them into per-project corrections and
/// session history the agent reads back next session:
///  - `shell_result` with a non-zero exit → a correction naming the failed command;
///  - `write_file` → watch that file for 15 minutes; a later user edit → "prefer your
///    version of that file";
///  - `session_end` → a session-history line.
/// Linux has no kqueue vnode sources, so both the events file and the watched files are
/// POLLED (`poll(now:)`, driven by the app's timer) — DEVIATIONS AC206.
public actor ContextLearner {
    private let paths: HuginnPaths
    private let metadataKey: Data?
    private var offset: UInt64 = 0
    private var partial = ""
    /// path → (cwd, mtime when the agent wrote it, expiry)
    private var watches: [String: (cwd: String, mtime: Date, expires: Date)] = [:]
    public static let watchWindow: TimeInterval = 15 * 60

    public init(paths: HuginnPaths, metadataKey: Data?) {
        self.paths = paths
        self.metadataKey = metadataKey
        // Resume where the last run (GUI or CLI) stopped, so no event is learned twice.
        offset = Self.loadOffset(paths)
    }

    /// `learner.offset` beside the events file: how far into events.jsonl has been learned.
    static func offsetFile(_ paths: HuginnPaths) -> String {
        (paths.configDir as NSString).appendingPathComponent("learner.offset")
    }
    static func loadOffset(_ paths: HuginnPaths) -> UInt64 {
        (try? String(contentsOfFile: offsetFile(paths), encoding: .utf8))
            .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }
    private func saveOffset() {
        try? Data(String(offset).utf8).write(to: URL(fileURLWithPath: Self.offsetFile(paths)), options: .atomic)
    }

    /// Start from the END of an existing events file (old events were already learned by
    /// a previous run; replaying them would duplicate corrections).
    public func skipExisting() {
        offset = (try? FileManager.default.attributesOfItem(atPath: paths.eventsFile))?[.size] as? UInt64 ?? 0
        saveOffset()
    }

    private func saveOffsetExcludingPartial() {
        let complete = offset - UInt64(partial.utf8.count)
        try? Data(String(complete).utf8).write(to: URL(fileURLWithPath: Self.offsetFile(paths)), options: .atomic)
    }

    public var watchedFiles: [String] { watches.keys.sorted() }

    public func poll(now: Date = Date()) {
        readEvents(now: now)
        checkWatches(now: now)
    }

    private func readEvents(now: Date) {
        guard let handle = FileHandle(forReadingAtPath: paths.eventsFile) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = ""; saveOffset() }  // rotated/truncated
        guard size > offset else { return }
        do { try handle.seek(toOffset: offset) } catch { return }
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        var lines = (partial + String(decoding: data, as: UTF8.self)).components(separatedBy: "\n")
        partial = lines.removeLast()
        // Persist only up to the last COMPLETE line; a partial tail is re-read next time.
        saveOffsetExcludingPartial()
        for raw in lines where !raw.isEmpty {
            // B2: a sealed line opens to its plaintext JSON; a legacy plaintext line is
            // kept; a sealed line without the key stays base64 and fails to parse.
            let plain = metadataKey.flatMap { ACPMetadataCrypto.openLine(raw, key: $0) } ?? raw
            if let json = JSONValue.parse(plain) { ingest(json, now: now) }
        }
    }

    func ingest(_ json: JSONValue, now: Date) {
        guard let type = json["type"]?.stringValue, let cwd = json["cwd"]?.stringValue else { return }
        switch type {
        case "shell_result":
            if let exit = json["exit"]?.intValue, exit != 0 {
                let cmd = json["cmd"]?.stringValue ?? ""
                let summary = Self.firstLine(json["summary"]?.stringValue ?? "")
                let note = "Command failed (exit \(exit)): `\(cmd)`" + (summary.isEmpty ? "" : " — \(summary)")
                update(cwd: cwd) { $0.addCorrection(note) }
            }
        case "write_file":
            if let path = json["path"]?.stringValue, watches[path] == nil,
                let m = Self.mtime(path)
            {
                watches[path] = (cwd, m, now.addingTimeInterval(Self.watchWindow))
            }
        case "session_end":
            let ts = json["ts"]?.stringValue ?? ""
            let summary = json["summary"]?.stringValue ?? ""
            let files = json["files"]?.intValue ?? 0
            let build = json["build"]?.stringValue ?? "unknown"
            update(cwd: cwd) { $0.addSession("\(ts): \(summary) (files: \(files), build: \(build))") }
        default:
            break
        }
    }

    private func checkWatches(now: Date) {
        for (path, w) in watches {
            if now > w.expires { watches[path] = nil; continue }
            guard let m = Self.mtime(path) else { watches[path] = nil; continue }  // deleted
            if m > w.mtime {
                let name = (path as NSString).lastPathComponent
                update(cwd: w.cwd) {
                    $0.addCorrection("You edited `\(name)` after the agent wrote it — prefer your version of that file.")
                }
                watches[path] = nil
            }
        }
    }

    static func mtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - eldr.md

    private func update(cwd: String, _ mutate: (inout ProjectMemoryDoc) -> Void) {
        let mdPath = ProjectContext.memoryPath(configDir: paths.configDir, cwd: cwd)
        let dir = (mdPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let marker = (dir as NSString).appendingPathComponent("cwd")
        // Audit-2 H1: the directory is a HASH of the cwd; a plaintext marker would undo
        // that. Sealed with the metadata key when there is one; 0600 either way.
        if !FileManager.default.fileExists(atPath: marker) {
            let m = metadataKey.flatMap { ProjectContext.sealForDisk(cwd, key: $0) } ?? Data(cwd.utf8)
            FileManager.default.createFile(atPath: marker, contents: m, attributes: [.posixPermissions: 0o600])
        }
        var doc = ProjectMemoryDoc(parsing: Self.readMemoryText(mdPath, key: metadataKey))
        mutate(&doc)
        doc.cap(toBytes: 4096)
        let serialized = doc.serialized()
        let out: Data
        if let metadataKey, let sealed = ProjectContext.sealForDisk(serialized, key: metadataKey) {
            out = sealed
        } else {
            out = Data(serialized.utf8)
        }
        try? out.write(to: URL(fileURLWithPath: mdPath), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mdPath)
    }

    public func projects() -> [ProjectMemory] {
        let fm = FileManager.default
        guard let hashes = try? fm.contentsOfDirectory(atPath: paths.projectsDir) else { return [] }
        var result: [ProjectMemory] = []
        for hash in hashes {
            let dir = (paths.projectsDir as NSString).appendingPathComponent(hash)
            let md = (dir as NSString).appendingPathComponent("eldr.md")
            guard fm.fileExists(atPath: md) else { continue }
            let markerData = fm.contents(atPath: (dir as NSString).appendingPathComponent("cwd")) ?? Data()
            let cwd = ProjectContext.openFromDisk(markerData, key: metadataKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? hash
            let doc = ProjectMemoryDoc(parsing: Self.readMemoryText(md, key: metadataKey))
            result.append(ProjectMemory(cwd: cwd, path: md, preview: doc.preview))
        }
        return result.sorted { $0.cwd < $1.cwd }
    }

    public func memoryText(_ project: ProjectMemory) -> String {
        Self.readMemoryText(project.path, key: metadataKey)
    }

    public func clear(_ project: ProjectMemory) {
        try? FileManager.default.removeItem(atPath: (project.path as NSString).deletingLastPathComponent)
    }

    static func readMemoryText(_ path: String, key: Data?) -> String {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        return ProjectContext.openFromDisk(data, key: key) ?? ""
    }
}
