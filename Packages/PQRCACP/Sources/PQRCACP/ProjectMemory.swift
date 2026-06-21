import Foundation

// Phase-3 substrate: the structured `eldr.md` a project accumulates. Kept here
// (pure, no I/O) so it's unit-tested in the fast headless suite and so the agent and
// the Configurator's ContextLearner share one definition of the file's shape and its
// budget rules. The agent reads the rendered file via ProjectContext; the learner
// edits it through this model.

/// A project's persistent memory: a `## Session History` section (recent sessions,
/// newest last) and a `## LLM Corrections` section (durable do/don't notes derived
/// from failed commands and post-write edits). Round-trips through Markdown.
public struct ProjectMemoryDoc: Equatable, Sendable {
    public var sessionHistory: [String]
    public var corrections: [String]

    public static let historyHeader = "## Session History"
    public static let correctionsHeader = "## LLM Corrections"

    public init(sessionHistory: [String] = [], corrections: [String] = []) {
        self.sessionHistory = sessionHistory
        self.corrections = corrections
    }

    /// Parse an `eldr.md`: collect `- ` bullets under each known header. Lines outside
    /// a known section are ignored (forward-compatible with hand-added prose).
    public init(parsing text: String) {
        var history: [String] = []
        var corrections: [String] = []
        enum Section { case none, history, corrections }
        var section: Section = .none
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == Self.historyHeader { section = .history; continue }
            if trimmed == Self.correctionsHeader { section = .corrections; continue }
            if trimmed.hasPrefix("## ") { section = .none; continue }
            guard trimmed.hasPrefix("- ") else { continue }
            let bullet = String(trimmed.dropFirst(2))
            switch section {
            case .history: history.append(bullet)
            case .corrections: corrections.append(bullet)
            case .none: break
            }
        }
        self.init(sessionHistory: history, corrections: corrections)
    }

    /// Render to Markdown (always both headers, so a later parse is stable).
    public func serialized() -> String {
        var out = Self.historyHeader + "\n"
        out += sessionHistory.map { "- \($0)" }.joined(separator: "\n")
        out += "\n\n" + Self.correctionsHeader + "\n"
        out += corrections.map { "- \($0)" }.joined(separator: "\n")
        return out + "\n"
    }

    public var isEmpty: Bool { sessionHistory.isEmpty && corrections.isEmpty }

    /// A one-line preview for the Configurator's project list.
    public var preview: String {
        if let last = sessionHistory.last { return last }
        if let last = corrections.last { return last }
        return "(empty)"
    }

    // MARK: - Mutation

    /// Append a session entry, keeping only the most recent `keepRecent`.
    public mutating func addSession(_ entry: String, keepRecent: Int = 10) {
        sessionHistory.append(entry)
        if sessionHistory.count > keepRecent {
            sessionHistory.removeFirst(sessionHistory.count - keepRecent)
        }
    }

    /// Append a correction (de-duplicated against the most recent few so a repeated
    /// failure doesn't spam the file), keeping at most `max`.
    public mutating func addCorrection(_ note: String, max: Int = 50) {
        if corrections.suffix(5).contains(note) { return }
        corrections.append(note)
        if corrections.count > max {
            corrections.removeFirst(corrections.count - max)
        }
    }

    /// Trim until the serialized form fits `maxBytes`: drop oldest session-history
    /// first (transient), then oldest corrections (durable, dropped last).
    public mutating func cap(toBytes maxBytes: Int) {
        while serialized().utf8.count > maxBytes, !sessionHistory.isEmpty {
            sessionHistory.removeFirst()
        }
        while serialized().utf8.count > maxBytes, !corrections.isEmpty {
            corrections.removeFirst()
        }
    }
}
