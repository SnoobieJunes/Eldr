// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI
import Testing

@testable import Huginn

// WS-M2: the log console's pure logic — classification/markup, the search
// model, remediation matching, and the bounded on-disk reads that let the
// console scroll and search past the tailer's 64 KB seed.

@MainActor
@Suite("Log markup classification")
struct LogMarkupTests {

    @Test func pythonLoggingLineGetsTimestampAndLevel() {
        let line = "2026-07-18 10:22:33,123 - INFO - Starting httpd at 127.0.0.1 on port 1337"
        let lineClass = LogMarkup.classify(line)
        #expect(lineClass.timestampLength == "2026-07-18 10:22:33,123".count)
        #expect(lineClass.level == .info)
        #expect(lineClass.httpStatus == nil)
        #expect(!lineClass.isTraceback)
    }

    @Test func levelTokensClassify() {
        #expect(LogMarkup.classify("ERROR: model load failed").level == .error)
        #expect(LogMarkup.classify("request failed after 3 retries").level == .error)
        #expect(LogMarkup.classify("WARNING: --temp needs a newer mlx-lm").level == .warn)
        #expect(LogMarkup.classify("DEBUG prompt cache hit").level == .debug)
        #expect(LogMarkup.classify("plain informational output").level == .none)
    }

    @Test func httpAccessLineStatusWinsOverTokens() {
        let ok = LogMarkup.classify(
            #"127.0.0.1 - - [18/Jul/2026 10:22:33] "POST /v1/chat/completions HTTP/1.1" 200 -"#)
        #expect(ok.httpStatus == 200)
        #expect(ok.level == .none)

        // "error" in the path must not paint a routine 200 red.
        let errorPath = LogMarkup.classify(#"127.0.0.1 - - "GET /error HTTP/1.1" 200 -"#)
        #expect(errorPath.httpStatus == 200)
        #expect(errorPath.level == .none)

        #expect(LogMarkup.classify(#""GET /v1/models HTTP/1.1" 404 -"#).level == .warn)
        #expect(LogMarkup.classify(#""GET /v1/models HTTP/1.1" 500 -"#).level == .error)
    }

    @Test func tracebackShapesAreErrors() {
        #expect(LogMarkup.classify("Traceback (most recent call last):").isTraceback)
        #expect(LogMarkup.classify("Traceback (most recent call last):").level == .error)
        let frame = LogMarkup.classify(#"  File "/x/server.py", line 3, in <module>"#)
        #expect(frame.isTraceback)
        #expect(frame.level == .error)
        #expect(LogMarkup.classify("ValueError: bad model path").level == .error)
    }

    @Test func attributedStylesTimestampAndHighlights() throws {
        let text = "2026-07-18 10:22:33 INFO hello"
        let lineClass = LogMarkup.classify(text)
        let attributed = LogMarkup.attributed(text, lineClass: lineClass)
        // Timestamp prefix renders secondary, the rest in the base color — at
        // least two distinct runs, the first one secondary.
        #expect(attributed.runs.count >= 2)
        #expect(attributed.runs.first?.foregroundColor == .secondary)

        let range = try #require(text.range(of: "hello"))
        let highlighted = LogMarkup.attributed(
            text, lineClass: lineClass, matches: [range], currentMatch: range)
        #expect(highlighted.runs.contains { $0.backgroundColor != nil })
    }

    @Test func carriageReturnsCollapseToLastSegment() {
        #expect(
            LogConsoleRow(id: 0, rawText: "10%\rdownloading 50%\rdownloading 99%").text
                == "downloading 99%")
        #expect(LogConsoleRow(id: 0, rawText: "done\r").text == "done")
        #expect(LogConsoleRow(id: 0, rawText: "\r\r").text == "")
        #expect(LogConsoleRow(id: 0, rawText: "untouched line").text == "untouched line")
    }
}

@MainActor
@Suite("Log search model")
struct LogSearchTests {

    private func rows(_ texts: [String]) -> [LogConsoleRow] {
        texts.enumerated().map { LogConsoleRow(id: $0.offset, rawText: $0.element) }
    }

    @Test func plainSearchIsCaseInsensitiveByDefault() throws {
        let matches = try #require(
            LogSearch.matches(
                in: rows(["Alpha error", "beta ERROR two", "clean"]),
                query: "error", options: LogSearchOptions()))
        #expect(matches.count == 2)
        #expect(matches.map(\.rowID) == [0, 1])
    }

    @Test func multipleOccurrencesInOneRowAllCount() throws {
        let matches = try #require(
            LogSearch.matches(
                in: rows(["error then error again"]), query: "error",
                options: LogSearchOptions()))
        #expect(matches.count == 2)
        #expect(matches.allSatisfy { $0.rowID == 0 })
    }

    @Test func caseSensitiveMatchesExactCaseOnly() throws {
        let matches = try #require(
            LogSearch.matches(
                in: rows(["Alpha error", "beta ERROR"]), query: "ERROR",
                options: LogSearchOptions(caseSensitive: true)))
        #expect(matches.map(\.rowID) == [1])
    }

    @Test func regexSearchWorksAndInvalidPatternReturnsNil() {
        let found = LogSearch.matches(
            in: rows(["err123 and err9"]), query: #"err\d+"#,
            options: LogSearchOptions(isRegex: true))
        #expect(found?.count == 2)

        let invalid = LogSearch.matches(
            in: rows(["anything"]), query: "(", options: LogSearchOptions(isRegex: true))
        #expect(invalid == nil)
    }

    @Test func zeroWidthRegexMatchesAreDropped() throws {
        let matches = try #require(
            LogSearch.matches(
                in: rows(["axa"]), query: "x*", options: LogSearchOptions(isRegex: true)))
        #expect(matches.count == 1)
        #expect(matches.allSatisfy { !$0.range.isEmpty })
    }

    @Test func emptyQueryMatchesNothing() throws {
        let matches = try #require(
            LogSearch.matches(in: rows(["anything"]), query: "", options: LogSearchOptions()))
        #expect(matches.isEmpty)
    }

    @Test func stepWrapsAroundBothDirections() {
        #expect(LogSearch.step(from: nil, count: 3, forward: true) == 0)
        #expect(LogSearch.step(from: nil, count: 3, forward: false) == 2)
        #expect(LogSearch.step(from: 2, count: 3, forward: true) == 0)
        #expect(LogSearch.step(from: 0, count: 3, forward: false) == 2)
        #expect(LogSearch.step(from: 1, count: 3, forward: true) == 2)
        #expect(LogSearch.step(from: nil, count: 0, forward: true) == nil)
    }
}

@Suite("Remediation catalog")
struct LogRemediationTests {

    @Test func knownPatternsProduceTheirHints() {
        #expect(
            LogRemediationCatalog.hint(
                for: "ModuleNotFoundError: No module named 'mlx_lm'")?.id == "env-broken")
        #expect(
            LogRemediationCatalog.hint(
                for: "huggingface_hub.utils._cache_manager.CacheNotFound: Cache directory not found"
            )?.id == "cache-missing")
        #expect(
            LogRemediationCatalog.hint(
                for: "huggingface_hub.errors.HFValidationError: Repo id must be in the form"
            )?.id == "bad-model-id")
        #expect(
            LogRemediationCatalog.hint(for: "FileNotFoundError: No safetensors found in")?.id
                == "wrong-format")
        #expect(
            LogRemediationCatalog.hint(for: "OSError: [Errno 48] Address already in use")?.id
                == "port-taken")
        #expect(
            LogRemediationCatalog.hint(for: "Exception in thread Thread-1:")?.id
                == "thread-crash")
        #expect(LogRemediationCatalog.hint(for: "routine INFO output") == nil)
    }

    @Test func perLineOrderPrefersTheSpecificPattern() {
        // A line carrying both the generic and a specific marker resolves to the
        // specific one (catalog order is most-specific-first).
        let hint = LogRemediationCatalog.hint(
            for: "Exception in thread while raising CacheNotFound")
        #expect(hint?.id == "cache-missing")
    }

    @Test func latestHintScansFromTheEnd() {
        let lines = [
            "Exception in thread Thread-1:",
            "Traceback (most recent call last):",
            "huggingface_hub.utils._cache_manager.CacheNotFound: missing",
            "routine line after",
        ]
        // The CacheNotFound line is the most recent recognizable failure — the
        // earlier generic thread-crash must not win.
        #expect(LogRemediationCatalog.latestHint(in: lines)?.id == "cache-missing")
        #expect(LogRemediationCatalog.latestHint(in: ["all", "benign"]) == nil)
    }
}

@Suite("Backscroll chunk reads")
struct LogBackscrollTests {

    /// Writes `line-0` … `line-<count-1>` and returns (path, per-line offsets).
    private func makeLineFile(count: Int) throws -> (path: String, offsets: [UInt64]) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-backscroll-\(UUID().uuidString).log")
        var content = ""
        var offsets: [UInt64] = []
        var position: UInt64 = 0
        for index in 0..<count {
            let line = "line-\(index)\n"
            offsets.append(position)
            position += UInt64(line.utf8.count)
            content += line
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, offsets)
    }

    @Test func chainedChunksReachTheBeginningExactlyOnce() throws {
        let (path, offsets) = try makeLineFile(count: 100)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Pretend the in-memory window starts at line 90; walk backwards in
        // small chunks and verify we recover lines 0–89 in order, no gaps, no
        // duplicates, every chunk line-aligned.
        var collected: [String] = []
        var end = offsets[90]
        while end > 0 {
            let chunk = try #require(
                LogBackscroll.readChunk(path: path, endingAt: end, maxBytes: 128))
            #expect(!chunk.lines.isEmpty, "no progress at offset \(end)")
            #expect(chunk.lines.first?.hasPrefix("line-") == true, "torn head line leaked")
            collected.insert(contentsOf: chunk.lines, at: 0)
            #expect(chunk.startOffset < end)
            end = chunk.startOffset
        }
        #expect(collected == (0..<90).map { "line-\($0)" })
    }

    @Test func beginningOfFileKeepsTheFirstLine() throws {
        let (path, offsets) = try makeLineFile(count: 5)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let chunk = try #require(
            LogBackscroll.readChunk(path: path, endingAt: offsets[2], maxBytes: 65_536))
        #expect(chunk.lines == ["line-0", "line-1"])
        #expect(chunk.startOffset == 0)
    }

    @Test func nothingBeforeZero() {
        #expect(LogBackscroll.readChunk(path: "/nonexistent", endingAt: 0) == nil)
    }

    @Test func giantSingleLineReportsNoProgress() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-backscroll-giant-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try String(repeating: "x", count: 8_192).write(
            toFile: path, atomically: true, encoding: .utf8)
        let chunk = try #require(
            LogBackscroll.readChunk(path: path, endingAt: 8_192, maxBytes: 1_024))
        #expect(chunk.lines.isEmpty)
        #expect(chunk.startOffset == 8_192, "no line boundary found ⇒ must report no progress")
    }
}

@Suite("On-disk stream search")
struct LogDiskSearchTests {

    private func makeFile(_ lines: [String]) throws -> (path: String, offsets: [UInt64]) {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-disksearch-\(UUID().uuidString).log")
        var offsets: [UInt64] = []
        var position: UInt64 = 0
        var content = ""
        for line in lines {
            offsets.append(position)
            position += UInt64(line.utf8.count + 1)
            content += line + "\n"
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, offsets)
    }

    @Test func countsOccurrencesAndReportsEarliestLineOffset() throws {
        let (path, offsets) = try makeFile(
            ["aaa", "match one", "bbb", "match two match three", "ccc"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = offsets[4] + UInt64("ccc\n".utf8.count)

        let all = LogBackscroll.searchOnDisk(
            path: path, query: "match", options: LogSearchOptions(), before: size)
        #expect(all.matchCount == 3)
        #expect(all.earliestMatchOffset == offsets[1])
        #expect(!all.truncated)

        // Region ends where the in-memory window starts: later matches excluded.
        let before = LogBackscroll.searchOnDisk(
            path: path, query: "match", options: LogSearchOptions(), before: offsets[3])
        #expect(before.matchCount == 1)
        #expect(before.earliestMatchOffset == offsets[1])
    }

    @Test func regexQueriesWork() throws {
        let (path, offsets) = try makeFile(["m1tch", "match", "mxtch"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = offsets[2] + UInt64("mxtch\n".utf8.count)
        let result = LogBackscroll.searchOnDisk(
            path: path, query: "m[a-z]tch", options: LogSearchOptions(isRegex: true),
            before: size)
        #expect(result.matchCount == 2)
        #expect(result.earliestMatchOffset == offsets[1])
    }

    @Test func boundedScanSkipsTornHeadAndFlagsTruncation() throws {
        let (path, offsets) = try makeFile(["match early", "padding line", "match late"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = offsets[2] + UInt64("match late\n".utf8.count)
        // Cap the scan so it starts INSIDE line 0: the torn head line must be
        // skipped (its "match" not counted) and the result flagged truncated.
        let cap = Int(size - 3)
        let result = LogBackscroll.searchOnDisk(
            path: path, query: "match", options: LogSearchOptions(), before: size,
            maxScanBytes: cap)
        #expect(result.truncated)
        #expect(result.matchCount == 1)
        #expect(result.earliestMatchOffset == offsets[2])
    }

    @Test func chunkBoundariesDoNotSplitMatches() throws {
        // Force many tiny read chunks; lines spanning chunk boundaries must still
        // match exactly once each.
        let lines = (0..<50).map { "prefix-\($0) match suffix" }
        let (path, offsets) = try makeFile(lines)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let size = offsets[49] + UInt64((lines[49] + "\n").utf8.count)
        let result = LogBackscroll.searchOnDisk(
            path: path, query: "match", options: LogSearchOptions(), before: size,
            chunkBytes: 7)
        #expect(result.matchCount == 50)
        #expect(result.earliestMatchOffset == offsets[0])
    }
}

@MainActor
@Suite("Log console model")
struct LogConsoleModelTests {

    /// Scratch ConfigPaths (agent log + mlx dir both live under one temp root).
    private func makePaths() throws -> (paths: ConfigPaths, root: String) {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-console-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("mlx"),
            withIntermediateDirectories: true)
        return (ConfigPaths(configDir: root, binDir: root), root)
    }

    private func append(_ text: String, to path: String) throws {
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func poll(
        deadlineMilliseconds: Int = 4_000, _ what: Comment, until condition: () -> Bool
    ) async throws {
        for _ in 0..<(deadlineMilliseconds / 20) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), what)
    }

    @Test func accumulatesPastTheTailersRetentionWindow() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }

        // Three appended batches totalling 2 400 lines: the tailer retains only
        // its last 2 000, but the console saw every publish and must keep all.
        var written = 0
        for _ in 0..<3 {
            var chunk = ""
            for _ in 0..<800 {
                chunk += "flood-line-\(written)\n"
                written += 1
            }
            try append(chunk, to: paths.logFile)
            let target = written
            try await poll("batch of \(target) never fully ingested") {
                model.rows.count == target
            }
        }
        #expect(model.rows.count == 2_400)
        #expect(model.rows.first?.text == "flood-line-0")
        #expect(model.rows.last?.text == "flood-line-2399")
        // Ids stay unique and ordered across the whole accumulation.
        let ids = model.rows.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)
    }

    @Test func clearEmptiesTheConsoleAndKeepsIngesting() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try append("before-clear\n", to: paths.logFile)
        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }
        try await poll("seed never arrived") { model.rows.count == 1 }

        model.clear()
        #expect(model.rows.isEmpty)

        try append("after-clear\n", to: paths.logFile)
        try await poll("post-clear line never arrived") {
            model.rows.map(\.text) == ["after-clear"]
        }
    }

    @Test func switchSourceSwapsTailersAndKeepsTheQuery() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try append("agent-line\n", to: paths.logFile)
        let mlxLog = MLXService.serverLogPath(paths: paths)
        try append("mlx-line\n", to: mlxLog)

        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }
        try await poll("agent seed never arrived") {
            model.rows.map(\.text) == ["agent-line"]
        }
        #expect(model.currentFilePath == paths.logFile)

        model.query = "line"
        model.switchSource(.mlxServer)
        #expect(model.source == .mlxServer)
        #expect(model.query == "line", "switching sources must keep the search")
        #expect(model.currentFilePath == mlxLog)
        try await poll("mlx seed never arrived") {
            model.rows.map(\.text) == ["mlx-line"]
        }
        try await poll("matches never recomputed for the new source") {
            model.matchCount == 1
        }
    }

    @Test func diagnosticsSourceRendersTheBusLive() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let bus = DiagnosticsLog()
        let model = LogConsoleModel(source: .diagnostics, paths: paths, diagnostics: bus)
        model.start()
        defer { model.stop() }

        bus.record(.mlx, .error, "MLX server exited", "status 1")
        try await poll("event never rendered") { model.rows.count == 1 }
        let text = try #require(model.rows.first?.text)
        #expect(text.contains("ERROR [MLX] MLX server exited — status 1"))
        #expect(model.rows.first?.lineClass.level == .error)
        #expect(model.currentFilePath == nil)

        model.clear()
        #expect(bus.events.isEmpty)
        #expect(model.rows.isEmpty)
    }

    @Test func formatDiagnosticsMapsSeverityToLevelTokens() {
        let warn = DiagnosticsLog.Event(
            at: Date(), category: .relay, severity: .warn, title: "Relay flapping", detail: "")
        #expect(LogConsoleModel.formatDiagnostics(warn).contains("WARNING [Relay] Relay flapping"))
        let info = DiagnosticsLog.Event(
            at: Date(), category: .node, severity: .info, title: "Node started", detail: "")
        let rendered = LogConsoleModel.formatDiagnostics(info)
        #expect(rendered.contains("[Node] Node started"))
        #expect(!rendered.contains("ERROR") && !rendered.contains("WARNING"))
    }

    @Test func remediationChipTracksLatestFailureAndDismisses() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }

        try append("OSError: [Errno 48] Address already in use\n", to: paths.logFile)
        try await poll("port-taken hint never appeared") {
            model.remediation?.id == "port-taken"
        }

        model.dismissRemediation()
        #expect(model.remediation == nil)

        // The SAME failure class stays dismissed…
        try append("OSError: [Errno 48] Address already in use\n", to: paths.logFile)
        try await poll("second port line never ingested") { model.rows.count == 2 }
        #expect(model.remediation == nil)

        // …a DIFFERENT one re-arms the chip.
        try append("huggingface_hub.errors.HFValidationError: bad repo id\n", to: paths.logFile)
        try await poll("bad-model-id hint never appeared") {
            model.remediation?.id == "bad-model-id"
        }
    }

    @Test func searchTracksAppendsWithoutLosingPosition() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try append("match one\nplain\nmatch two\n", to: paths.logFile)
        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }
        try await poll("seed never arrived") { model.rows.count == 3 }

        model.query = "match"
        #expect(model.searchActive)
        try await poll("debounced search never ran") { model.matchCount == 2 }
        #expect(model.currentMatchOrdinal == 1)

        model.stepMatch(forward: true)
        #expect(model.currentMatchOrdinal == 2)

        // New matching rows extend the count; the current position holds.
        try append("match three\n", to: paths.logFile)
        try await poll("append never joined the search") { model.matchCount == 3 }
        #expect(model.currentMatchOrdinal == 2)

        // Wraparound reaches the new match, then cycles back to the first.
        model.stepMatch(forward: true)
        #expect(model.currentMatchOrdinal == 3)
        model.stepMatch(forward: true)
        #expect(model.currentMatchOrdinal == 1)

        // An invalid regex reports itself instead of silently matching nothing.
        model.useRegex = true
        model.query = "("
        try await poll("invalid regex never flagged") { model.queryInvalid }
        #expect(model.matchCount == 0)
    }
}

@MainActor
@Suite("Console back-scroll + disk search + flood")
struct LogConsoleBackscrollTests {

    private func makePaths() throws -> (paths: ConfigPaths, root: String) {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-console-bs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent("mlx"),
            withIntermediateDirectories: true)
        return (ConfigPaths(configDir: root, binDir: root), root)
    }

    private func poll(
        deadlineMilliseconds: Int = 5_000, _ what: Comment, until condition: () -> Bool
    ) async throws {
        for _ in 0..<(deadlineMilliseconds / 20) {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), what)
    }

    /// A file well past the 64 KB seed: "needle-target" sits ONCE at the given
    /// index, everything else is numbered filler.
    private func writeBigLog(to path: String, lines: Int = 20_000, needleAt: Int = 5) throws {
        var blob = ""
        for index in 0..<lines {
            blob += index == needleAt ? "needle-target hiding here\n" : "line-\(index)\n"
        }
        try blob.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func lineNumber(of text: String) -> Int? {
        text.hasPrefix("line-") ? Int(text.dropFirst("line-".count)) : nil
    }

    @Test func loadOlderPrependsContiguousHistory() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try writeBigLog(to: paths.logFile)

        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }
        try await poll("seed never arrived") { !model.rows.isEmpty }
        #expect(model.canLoadOlder, "a 64 KB-seeded big file must offer Load older")

        let seamRow = try #require(model.rows.first)
        let seamNumber = try #require(lineNumber(of: seamRow.text))

        model.loadOlder()
        try await poll("older chunk never prepended") { model.rows.first?.id ?? 0 < 0 }
        try await poll("load flag never cleared") { !model.isLoadingOlder }

        // The seam must be EXACTLY contiguous: the row before the old top is the
        // previous line of the file — no gap, no duplicate.
        let seamIndex = try #require(model.rows.firstIndex(where: { $0.id == seamRow.id }))
        #expect(seamIndex > 0)
        let before = try #require(lineNumber(of: model.rows[seamIndex - 1].text))
        #expect(before == seamNumber - 1, "seam gap: line-\(before) then line-\(seamNumber)")
        #expect(model.lastPrependSeamID == seamRow.id)
        // Ids remain strictly ordered.
        let ids = model.rows.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count)
    }

    @Test func diskSearchFindsOlderMatchAndJumpLoadsIt() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // The needle must be outside the seeded window but INSIDE the row-cap
        // budget the jump may load (maxRows 10k − seed 2k): 7 000 lines back.
        try writeBigLog(to: paths.logFile, needleAt: 13_000)

        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }
        try await poll("seed never arrived") { !model.rows.isEmpty }
        #expect(!model.rows.contains { $0.text.contains("needle-target") },
            "the needle must start OUTSIDE the seeded window for this test to mean anything")

        model.query = "needle-target"
        try await poll("disk search never found the older match") {
            if case .found(let count, _) = model.diskSearch { return count == 1 }
            return false
        }
        #expect(model.matchCount == 0, "in-memory search must not see the on-disk needle")

        model.loadOlderToDiskMatch()
        try await poll(deadlineMilliseconds: 10_000, "jump never landed on the needle") {
            model.currentMatch != nil && model.matchCount == 1
        }
        let matchRow = try #require(
            model.rows.first(where: { $0.id == model.currentMatch?.rowID }))
        #expect(matchRow.text.contains("needle-target"))
        #expect(model.currentMatchOrdinal == 1)
    }

    @Test func floodPublishesStayBatchedThroughTheModel() async throws {
        let (paths, root) = try makePaths()
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: paths.logFile, contents: nil)
        let model = LogConsoleModel(source: .agent, paths: paths)
        model.start()
        defer { model.stop() }

        var publishes = 0
        let cancellable = model.$rows.dropFirst().sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        // 50 separate writes land as a handful of coalesced row batches — the
        // tailer's ~4 Hz publish hygiene must carry through the console model.
        let handle = try #require(FileHandle(forWritingAtPath: paths.logFile))
        for index in 0..<50 {
            try handle.write(contentsOf: Data("flood-\(index)\n".utf8))
        }
        try handle.close()
        try await poll("flood never fully ingested") { model.rows.count == 50 }
        #expect(publishes <= 15, "expected coalesced row publishes, saw \(publishes)")
        #expect(model.rows.first?.text == "flood-0")
        #expect(model.rows.last?.text == "flood-49")
    }
}

@Suite("LogTailer backscroll anchors")
struct LogTailerAnchorTests {

    @MainActor
    @Test func smallFileSeedAnchorsAtZero() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-anchor-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "one\ntwo\n".write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = LogTailer(path: path)
        tailer.start()
        defer { tailer.stop() }
        #expect(tailer.earliestSeedOffset == 0)
        #expect(tailer.fileGeneration == 0)
    }

    @MainActor
    @Test func boundedSeedAnchorsAtALineStart() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-anchor-big-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var blob = ""
        for index in 0..<5_000 { blob += "line-\(index)\n" }
        try blob.write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = LogTailer(path: path, maxSeedBytes: 4_096)
        tailer.start()
        defer { tailer.stop() }

        #expect(tailer.earliestSeedOffset > 0)
        // The anchor points exactly at the tailer's first retained line.
        let handle = try #require(FileHandle(forReadingAtPath: path))
        try handle.seek(toOffset: tailer.earliestSeedOffset)
        let data = try #require(try handle.read(upToCount: 64))
        try handle.close()
        let text = String(decoding: data, as: UTF8.self)
        let firstLine = try #require(tailer.lines.first?.text)
        #expect(text.hasPrefix(firstLine + "\n"), "anchor not at the first retained line")
    }

    // Regression (caught by the WS-M2 seam test): a 64 KB seed of SHORT lines
    // exceeds the 2000-line retention cap, publish trimmed the head after
    // ingest, and earliestSeedOffset pointed below the first retained line —
    // "Load older" then spliced older history in with a silent gap. The seed
    // is now bounded to the cap in data space, so the anchor is exact.
    @MainActor
    @Test func overlongSeedIsCappedWithExactAnchor() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-anchor-cap-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        var blob = ""
        for index in 0..<20_000 { blob += "line-\(index)\n" }  // ≈230 KB, ~11 B lines
        try blob.write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = LogTailer(path: path)  // default 64 KB seed ≫ 2000 lines
        tailer.start()
        defer { tailer.stop() }

        #expect(tailer.lines.count == 2_000, "seed must cap at retention")
        #expect(tailer.lines.last?.text == "line-19999")
        let handle = try #require(FileHandle(forReadingAtPath: path))
        try handle.seek(toOffset: tailer.earliestSeedOffset)
        let data = try #require(try handle.read(upToCount: 64))
        try handle.close()
        let firstLine = try #require(tailer.lines.first?.text)
        #expect(
            String(decoding: data, as: UTF8.self).hasPrefix(firstLine + "\n"),
            "anchor must point exactly at the first RETAINED line")
    }

    @MainActor
    @Test func resumeKeepsGenerationAndReseedBumpsIt() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-anchor-gen-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "one\ntwo\n".write(toFile: path, atomically: true, encoding: .utf8)

        let tailer = LogTailer(path: path, maxSeedBytes: 64)
        tailer.start()
        #expect(tailer.fileGeneration == 0)

        // Small append while stopped → resume path, same generation.
        tailer.stop()
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data("three\n".utf8))
        tailer.start()
        #expect(tailer.fileGeneration == 0)
        #expect(tailer.lines.map(\.text) == ["one", "two", "three"])

        // A gap larger than maxSeedBytes while stopped → fresh tail seed, new
        // generation (the accumulated console history no longer joins up).
        tailer.stop()
        for index in 0..<40 {
            try handle.write(contentsOf: Data("filler-line-\(index)\n".utf8))
        }
        try handle.close()
        tailer.start()
        defer { tailer.stop() }
        #expect(tailer.fileGeneration == 1)
        #expect(tailer.earliestSeedOffset > 0)
    }
}
