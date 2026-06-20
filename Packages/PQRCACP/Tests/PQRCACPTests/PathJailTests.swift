import Foundation
import Testing

@testable import PQRCACP

// C-2: the file tools (read_file / write_file / edit_file / list_dir / search) must
// stay WITHIN the session working directory. An absolute path outside it, a `../`
// traversal, or a symlink pointing out is rejected with a tool error — so the agent
// serves the project tree but never `~/.ssh` or `../../etc/...`. run_shell is the
// deliberate, permission-gated escape hatch and is not jailed here.

@Suite("ToolExecutor path jail (C-2)")
struct ToolExecutorPathJailTests {
    private func executor(workdir: String) -> ToolExecutor {
        ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: nil, sessionId: "s1")
    }

    private func tempDir(_ tag: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-jail-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readRejectsAbsolutePathOutsideWorkdir() async throws {
        let dir = try tempDir("read")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A real secret that exists OUTSIDE the workdir (a sibling temp dir).
        let secretDir = try tempDir("secret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        let secret = (secretDir as NSString).appendingPathComponent("id_ed25519")
        try "PRIVATE-KEY".write(toFile: secret, atomically: true, encoding: .utf8)

        let read = await executor(workdir: dir).run(
            tool: "read_file", args: .object(["path": .string(secret)]))
        #expect(read.isError)
        #expect(!read.text.contains("PRIVATE-KEY"))  // never exfiltrated
        #expect(read.text.contains("outside the working directory"))
    }

    @Test func readRejectsDotDotTraversal() async throws {
        let dir = try tempDir("dotdot")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let read = await executor(workdir: dir).run(
            tool: "read_file", args: .object(["path": .string("../../../../../../etc/hosts")]))
        #expect(read.isError)
        #expect(read.text.contains("outside the working directory"))
    }

    @Test func writeRejectsEscapeAndLeavesNoFile() async throws {
        let dir = try tempDir("write")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let outside = try tempDir("wsecret")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let target = (outside as NSString).appendingPathComponent("planted.txt")

        let w = await executor(workdir: dir).run(
            tool: "write_file", args: .object(["path": .string(target), "content": .string("x")]))
        #expect(w.isError)
        #expect(!FileManager.default.fileExists(atPath: target))  // never written
    }

    @Test func allowsPathsInsideWorkdir() async throws {
        let dir = try tempDir("inside")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let inside = (dir as NSString).appendingPathComponent("ok.txt")
        try "hello".write(toFile: inside, atomically: true, encoding: .utf8)
        let ex = executor(workdir: dir)

        // Relative and absolute, both inside, are allowed.
        let rel = await ex.run(tool: "read_file", args: .object(["path": .string("ok.txt")]))
        #expect(!rel.isError)
        #expect(rel.text == "hello")
        let abs = await ex.run(tool: "read_file", args: .object(["path": .string(inside)]))
        #expect(!abs.isError)
        #expect(abs.text == "hello")

        // Writing a new file inside the workdir is allowed.
        let w = await ex.run(
            tool: "write_file", args: .object(["path": .string("new.txt"), "content": .string("y")]))
        #expect(!w.isError)
        #expect(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("new.txt")))

        // list_dir of the workdir root is allowed.
        let ls = await ex.run(tool: "list_dir", args: .object(["path": .string(".")]))
        #expect(!ls.isError)
        #expect(ls.text.contains("ok.txt"))
    }

    @Test func symlinkOutOfWorkdirIsRejected() async throws {
        let dir = try tempDir("link")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretDir = try tempDir("linksecret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        let secret = (secretDir as NSString).appendingPathComponent("secret.txt")
        try "LEAK".write(toFile: secret, atomically: true, encoding: .utf8)
        // A symlink INSIDE the workdir that points at the outside secret.
        let link = (dir as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secret)

        let read = await executor(workdir: dir).run(
            tool: "read_file", args: .object(["path": .string("escape")]))
        #expect(read.isError)
        #expect(!read.text.contains("LEAK"))  // symlink can't tunnel out
    }
}
