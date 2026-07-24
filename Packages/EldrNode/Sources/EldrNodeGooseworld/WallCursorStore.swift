// SPDX-License-Identifier: Apache-2.0
import Foundation

// WS-G5 — wall CURSOR persistence (the one durable piece of wall state).
//
// `TownWall` is a pure value type and deliberately does no I/O; gtwall keeps each
// reader's position in a file, and so do we — one small JSON object mapping reader id →
// monotonic sequence cursor. POSTS are NOT persisted: the wall is transient
// store-and-forward coordination state (the same posture as the relay — transport, not
// storage), bounded in memory, and honest about gaps after a restart (`missedPosts` /
// cursor-above-highest are both already-handled cases in `TownWall.restoreCursor`).
//
// Failure posture mirrors gtwall's, stated rather than implied: an unreadable or
// corrupt cursor file loads as EMPTY (every reader replays from 0 — duplicate delivery,
// never silent loss), and a failed save leaves the previous file intact (atomic
// temp+rename), so the worst outcome of any I/O failure is re-reading, not skipping.
// Cursors are positions, not secrets; the file is still written 0600 like everything
// else under the node's data dir.
public struct WallCursorStore: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    /// Load the persisted cursors, or `[:]` when missing/corrupt (replay-from-0 —
    /// duplicates over loss, per the header).
    public func load() -> [String: UInt64] {
        guard let data = FileManager.default.contents(atPath: path),
            let decoded = try? JSONDecoder().decode([String: UInt64].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Persist `cursors` atomically (temp file + rename, 0600). Best-effort: false on
    /// failure, with the previous file left intact.
    @discardableResult
    public func save(_ cursors: [String: UInt64]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cursors) else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        let temp = path + ".tmp-\(UUID().uuidString.prefix(8))"
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: temp), options: [])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temp)
            // rename(2) is atomic on the same filesystem; replace any previous file.
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: temp))
            } else {
                try FileManager.default.moveItem(atPath: temp, toPath: path)
            }
            return true
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            return false
        }
    }
}
