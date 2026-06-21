import Foundation
import Testing

@testable import PQRCACP

// Path-1 unit coverage for the new tools (edit_file, search), read_file's disk-side
// backpressure, and the SSE StreamAssembler. All hermetic: real temp files, no
// network, no client (Foundation fallbacks).

@Suite("edit_file")
struct EditFileTests {
    private func executor(workdir: String) -> ToolExecutor {
        ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1")
    }

    private func tempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func replacesUniqueSubstring() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("a.swift")
        try "let x = 1\nlet y = 2\n".write(toFile: path, atomically: true, encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "edit_file",
            args: .object([
                "path": .string("a.swift"),
                "old_string": .string("let x = 1"),
                "new_string": .string("let x = 42"),
            ]))
        #expect(!result.isError)
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        #expect(updated == "let x = 42\nlet y = 2\n")
    }

    @Test func failsWhenOldStringMissing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("a.swift")
        try "hello\n".write(toFile: path, atomically: true, encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "edit_file",
            args: .object([
                "path": .string("a.swift"),
                "old_string": .string("nonexistent"),
                "new_string": .string("x"),
            ]))
        #expect(result.isError)
        #expect(result.text.contains("not found"))
        // File untouched.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "hello\n")
    }

    @Test func failsWhenOldStringAmbiguous() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("a.swift")
        try "dup\ndup\n".write(toFile: path, atomically: true, encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "edit_file",
            args: .object([
                "path": .string("a.swift"),
                "old_string": .string("dup"),
                "new_string": .string("x"),
            ]))
        #expect(result.isError)
        #expect(result.text.contains("not unique"))
        // File untouched (no partial edit).
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "dup\ndup\n")
    }

    @Test func newStringContainingOldStringReplacesOnce() async throws {
        // A replacement that re-introduces old_string must not loop/double-replace.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("a.txt")
        try "AB\n".write(toFile: path, atomically: true, encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "edit_file",
            args: .object([
                "path": .string("a.txt"),
                "old_string": .string("AB"),
                "new_string": .string("ABAB"),
            ]))
        #expect(!result.isError)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "ABAB\n")
    }
}

@Suite("search")
struct SearchTests {
    private func executor(workdir: String) -> ToolExecutor {
        ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1")
    }

    @Test func findsMatchingLines() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let canary = "FINDME_\(UUID().uuidString.prefix(8))"
        try "first line\n\(canary) here\nlast line\n".write(
            toFile: (dir as NSString).appendingPathComponent("f.txt"), atomically: true,
            encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "search", args: .object(["query": .string(String(canary))]))
        #expect(!result.isError)
        #expect(result.text.contains(String(canary)))
        #expect(result.text.contains("f.txt"))
    }

    @Test func reportsNoMatches() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "nothing to see\n".write(
            toFile: (dir as NSString).appendingPathComponent("f.txt"), atomically: true,
            encoding: .utf8)

        let ex = executor(workdir: dir)
        let result = await ex.run(
            tool: "search", args: .object(["query": .string("ZZZ_absent_ZZZ")]))
        #expect(!result.isError)
        #expect(result.text.contains("no matches"))
    }

    @Test func capsResultsAndNotesTruncation() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Spread > cap matches across several files (each under any per-file cap), so
        // both the ripgrep and Foundation engines agree on the total-truncation note.
        let cap = ToolExecutor.searchMatchCap
        let perFile = (cap / 4) + 10
        for fileIndex in 0..<5 {
            let lines = (0..<perFile).map { "needle line \($0)" }.joined(separator: "\n")
            try lines.write(
                toFile: (dir as NSString).appendingPathComponent("f\(fileIndex).txt"),
                atomically: true, encoding: .utf8)
        }

        let ex = executor(workdir: dir)
        let result = await ex.run(tool: "search", args: .object(["query": .string("needle")]))
        #expect(!result.isError)
        #expect(result.text.contains("more than \(cap) matches"))
        let matchLines = result.text.split(separator: "\n").filter { $0.contains("needle") }
        #expect(matchLines.count <= cap)
    }
}

@Suite("read_file backpressure")
struct ReadBackpressureTests {
    @Test func overCapFileReadsBoundedPrefix() async throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("big-\(UUID().uuidString).txt")
        let big = String(repeating: "A", count: 50_000)
        try big.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Read cap well below the file size; result must be a bounded prefix + note,
        // NOT the whole 50 KB loaded then trimmed.
        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: dir),
            connection: nil, sessionId: "s1", maxReadFileBytes: 4096)
        let result = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(!result.isError)
        #expect(result.text.contains("showing first"))
        #expect(result.text.contains("read cap"))
        // The bounded prefix is ~4 KB of 'A' plus the note — far under 50 KB.
        #expect(result.text.utf8.count < 8_000)
    }

    @Test func underCapFileReadsWhole() async throws {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("small-\(UUID().uuidString).txt")
        let body = "exactly these bytes\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let ex = ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: dir),
            connection: nil, sessionId: "s1", maxReadFileBytes: 4096)
        let result = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(!result.isError)
        #expect(result.text == body)
    }
}

@Suite("SSE StreamAssembler")
struct StreamAssemblerTests {
    private func contentEvent(_ text: String) -> JSONValue {
        .object(["choices": .array([.object(["delta": .object(["content": .string(text)])])])])
    }

    @Test func emitsVisibleTextInOrder() {
        var assembler = StreamAssembler()
        let a = assembler.consume(contentEvent("Hel"))
        let b = assembler.consume(contentEvent("lo"))
        #expect(a == "Hel")
        #expect(b == "lo")
        #expect(assembler.finish().content == "Hello")
    }

    @Test func buffersReasoningUntilClosedThenStreamsAnswer() {
        var assembler = StreamAssembler()
        // Reasoning arrives first, split across deltas — nothing should emit until the
        // </think> closes and the visible answer begins.
        #expect(assembler.consume(contentEvent("<think>")) == nil)
        #expect(assembler.consume(contentEvent("plotting…")) == nil)
        #expect(assembler.consume(contentEvent("</think>")) == nil)
        #expect(assembler.consume(contentEvent("Answer")) == "Answer")
        #expect(assembler.consume(contentEvent(" here")) == " here")
        #expect(assembler.finish().content == "Answer here")
    }

    @Test func assemblesToolCallFromFragments() {
        var assembler = StreamAssembler()
        // tool_calls deltas: id+name in the first, arguments fragmented across two.
        let e1: JSONValue = .object([
            "choices": .array([
                .object([
                    "delta": .object([
                        "tool_calls": .array([
                            .object([
                                "index": .int(0), "id": .string("call_x"),
                                "function": .object([
                                    "name": .string("read_file"),
                                    "arguments": .string("{\"pa"),
                                ]),
                            ])
                        ])
                    ])
                ])
            ])
        ])
        let e2: JSONValue = .object([
            "choices": .array([
                .object([
                    "delta": .object([
                        "tool_calls": .array([
                            .object([
                                "index": .int(0),
                                "function": .object(["arguments": .string("th\":\"a.txt\"}")]),
                            ])
                        ])
                    ])
                ])
            ])
        ])
        #expect(assembler.consume(e1) == nil)  // tool-call deltas emit no visible text
        #expect(assembler.consume(e2) == nil)
        let response = assembler.finish()
        #expect(response.toolCalls.count == 1)
        #expect(response.toolCalls.first?.name == "read_file")
        #expect(response.toolCalls.first?.id == "call_x")
        #expect(response.toolCalls.first?.argumentsJSON["path"]?.stringValue == "a.txt")
    }
}
