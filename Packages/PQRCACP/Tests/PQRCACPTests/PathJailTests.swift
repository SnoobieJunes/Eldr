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

    @Test func writeThroughSymlinkedDirToNewFileIsRejected() async throws {
        // CR-2: write_file to a NEW path THROUGH a symlinked directory. The leaf doesn't
        // exist yet, so `resolvingSymlinksInPath` used to leave the symlinked PARENT
        // unresolved → the prefix check passed while `Data.write` followed the link OUT.
        let dir = try tempDir("write-link-new")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretDir = try tempDir("write-link-secret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        // A symlinked DIR inside the workdir pointing at the outside secret dir.
        let link = (dir as NSString).appendingPathComponent("dotlink")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secretDir)

        let w = await executor(workdir: dir).run(
            tool: "write_file",
            args: .object([
                "path": .string("dotlink/authorized_keys"), "content": .string("pwned"),
            ]))
        #expect(w.isError)
        #expect(w.text.contains("outside the working directory"))
        // The byte never landed in the symlink's target dir.
        #expect(
            !FileManager.default.fileExists(
                atPath: (secretDir as NSString).appendingPathComponent("authorized_keys")))
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

    // MARK: edit_file — same jail as read/write, asserted both by the refusal message
    // AND by proving the out-of-jail target file is never mutated.

    @Test func editRejectsDotDotTraversalAndLeavesTargetUntouched() async throws {
        let dir = try tempDir("edit-dotdot")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A real file OUTSIDE the workdir whose contents we will prove unchanged.
        let outside = try tempDir("edit-secret")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let target = (outside as NSString).appendingPathComponent("hosts")
        try "127.0.0.1 localhost".write(toFile: target, atomically: true, encoding: .utf8)

        // `../../etc/hosts`-style traversal: must refuse before reading/writing.
        let edit = await executor(workdir: dir).run(
            tool: "edit_file",
            args: .object([
                "path": .string("../../etc/hosts"),
                "old_string": .string("127.0.0.1 localhost"),
                "new_string": .string("0.0.0.0 evil"),
            ]))
        #expect(edit.isError)
        #expect(edit.text.contains("outside the working directory"))
        // The planted file is byte-for-byte unchanged (no read, no write happened).
        #expect(
            (try? String(contentsOfFile: target, encoding: .utf8)) == "127.0.0.1 localhost")
    }

    @Test func editRejectsSymlinkEscapeAndLeavesTargetUntouched() async throws {
        let dir = try tempDir("edit-link")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretDir = try tempDir("edit-linksecret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        let target = (secretDir as NSString).appendingPathComponent("secret.txt")
        try "ORIGINAL".write(toFile: target, atomically: true, encoding: .utf8)
        // A symlink inside the workdir pointing at the outside file: a successful edit
        // would resolve through it and overwrite ORIGINAL.
        let link = (dir as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let edit = await executor(workdir: dir).run(
            tool: "edit_file",
            args: .object([
                "path": .string("escape"),
                "old_string": .string("ORIGINAL"),
                "new_string": .string("TAMPERED"),
            ]))
        #expect(edit.isError)
        #expect(edit.text.contains("outside the working directory"))
        // Symlink can't tunnel an edit out: the target still reads ORIGINAL.
        #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "ORIGINAL")
    }

    // MARK: search — read-only, but the jail still confines WHERE it can read.

    @Test func searchRejectsDotDotTraversal() async throws {
        let dir = try tempDir("search-dotdot")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Plant a secret OUTSIDE the workdir; a working `../../..` search would surface it.
        let outside = try tempDir("search-secret")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let secret = (outside as NSString).appendingPathComponent("id_ed25519")
        try "PRIVATE-KEY-MATERIAL".write(toFile: secret, atomically: true, encoding: .utf8)

        let result = await executor(workdir: dir).run(
            tool: "search",
            args: .object([
                "query": .string("PRIVATE-KEY-MATERIAL"), "path": .string("../../.."),
            ]))
        #expect(result.isError)
        #expect(result.text.contains("outside the working directory"))
        #expect(!result.text.contains("PRIVATE-KEY-MATERIAL"))  // never exfiltrated
    }

    @Test func searchRejectsSymlinkEscape() async throws {
        let dir = try tempDir("search-link")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretDir = try tempDir("search-linksecret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        let secret = (secretDir as NSString).appendingPathComponent("id_ed25519")
        try "LEAK-VIA-SEARCH".write(toFile: secret, atomically: true, encoding: .utf8)
        // A symlinked subdir inside the workdir pointing at the outside secret dir.
        let link = (dir as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secretDir)

        let result = await executor(workdir: dir).run(
            tool: "search",
            args: .object(["query": .string("LEAK-VIA-SEARCH"), "path": .string("escape")]))
        #expect(result.isError)
        #expect(result.text.contains("outside the working directory"))
        #expect(!result.text.contains("LEAK-VIA-SEARCH"))  // symlink can't tunnel search out
    }

    // MARK: list_dir — escaping path is refused (no directory listing of ~ or /etc).

    @Test func listDirRejectsDotDotTraversal() async throws {
        let dir = try tempDir("ls-dotdot")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ls = await executor(workdir: dir).run(
            tool: "list_dir", args: .object(["path": .string("../../../../../../etc")]))
        #expect(ls.isError)
        #expect(ls.text.contains("outside the working directory"))
    }

    @Test func listDirRejectsSymlinkEscape() async throws {
        let dir = try tempDir("ls-link")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let secretDir = try tempDir("ls-linksecret")
        defer { try? FileManager.default.removeItem(atPath: secretDir) }
        let secret = (secretDir as NSString).appendingPathComponent("secret.txt")
        try "DIR-ENTRY-LEAK".write(toFile: secret, atomically: true, encoding: .utf8)
        // A symlinked dir inside the workdir pointing out: listing it would enumerate
        // the outside dir's entries.
        let link = (dir as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: secretDir)

        let ls = await executor(workdir: dir).run(
            tool: "list_dir", args: .object(["path": .string("escape")]))
        #expect(ls.isError)
        #expect(ls.text.contains("outside the working directory"))
        #expect(!ls.text.contains("secret.txt"))  // outside entries never enumerated
    }
}
