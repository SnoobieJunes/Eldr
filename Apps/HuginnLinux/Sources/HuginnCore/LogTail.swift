// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public struct LogLine: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case error, llm, tool, info }
    public let id: Int
    public let text: String
    public let kind: Kind
}

/// Port of the macOS `LogTailer`, POLLING instead of a kqueue DispatchSource (which is
/// macOS-only for vnode events): each `poll()` reads what was appended since the last
/// offset, restarts from 0 when the file shrank (rotation/truncation), and keeps the
/// last `capacity` lines. Classification is the Mac rule verbatim.
public actor LogTailer {
    public let path: String
    private let capacity: Int
    private var offset: UInt64 = 0
    private var partial = ""
    private var nextID = 0
    public private(set) var lines: [LogLine] = []

    public init(path: String, capacity: Int = 2000, startAtEnd: Bool = false) {
        self.path = path
        self.capacity = capacity
        if startAtEnd, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 {
            offset = size
        }
    }

    /// Returns only the lines new since the previous poll.
    @discardableResult
    public func poll() -> [LogLine] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = "" }
        guard size > offset else { return [] }
        do { try handle.seek(toOffset: offset) } catch { return [] }
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        let text = partial + String(decoding: data, as: UTF8.self)
        var parts = text.components(separatedBy: "\n")
        partial = parts.removeLast()
        var fresh: [LogLine] = []
        for p in parts where !p.isEmpty {
            fresh.append(LogLine(id: nextID, text: p, kind: Self.classify(p)))
            nextID += 1
        }
        lines.append(contentsOf: fresh)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        return fresh
    }

    public static func classify(_ line: String) -> LogLine.Kind {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("exit 1") || lower.contains("failed") {
            return .error
        }
        if lower.contains("llm url=") || lower.contains("complete(") || lower.contains("http") {
            return .llm
        }
        if lower.contains("run_shell") || lower.contains("write_file")
            || lower.contains("read_file") || lower.contains("list_dir")
        {
            return .tool
        }
        return .info
    }
}
