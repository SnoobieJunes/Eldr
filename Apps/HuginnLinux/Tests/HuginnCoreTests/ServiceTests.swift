// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP
import Testing
@testable import HuginnCore

@Suite("Installer, launcher, logs, learner")
struct ServiceTests {
    @Test("install copies binaries 0755 and the launcher sources env, fetches secrets, execs, logs stderr")
    func installAndLaunch() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        let src = tmp.sub("build")
        // A stand-in eldr-acp that reports what it was started with.
        write("#!/bin/bash\necho \"model=$ELDR_LLM_MODEL token=$ELDR_LLM_TOKEN key=$ELDR_ACP_METADATA_KEY args=$*\"\necho 'to-stderr' >&2\n", src + "/eldr-acp", mode: 0o755)
        write("#!/bin/bash\ncase \"$2\" in llm-token) echo SECRET-TOKEN;; metadata-key) echo S0VZ;; esac\n", src + "/huginn-cli", mode: 0o755)
        let r = try HuginnInstaller(paths: paths).install(from: [tmp.sub("nope"), src])
        #expect(r.installed == ["eldr-acp", "huginn-cli"])
        let mode = (try FileManager.default.attributesOfItem(atPath: paths.installedBinary))[.posixPermissions] as? Int
        #expect(mode == 0o755)
        var s = HuginnSettings.load(paths: paths)
        s.llmModel = "it's-a-model"
        try s.save(paths: paths)
        let (rc, out) = try run(paths.launcher, ["--flag"], env: ["PATH": "/usr/bin:/bin"])
        #expect(rc == 0)
        #expect(out.contains("model=it's-a-model token=SECRET-TOKEN key=S0VZ args=--flag"), "\(out)")
        #expect(!out.contains("to-stderr"))
        let log = try String(contentsOfFile: paths.logFile, encoding: .utf8)
        #expect(log.contains("to-stderr"))
        // A client-provided token wins over the keystore.
        let (_, out2) = try run(paths.launcher, [], env: ["PATH": "/usr/bin:/bin", "ELDR_LLM_TOKEN": "from-client"])
        #expect(out2.contains("token=from-client"))
        HuginnInstaller(paths: paths).uninstall()
        #expect(!HuginnInstaller(paths: paths).isInstalled)
    }

    @Test("install fails closed without an eldr-acp binary")
    func installMissing() {
        let tmp = TempDir(); defer { tmp.remove() }
        #expect(throws: HuginnInstaller.InstallError.missingAgentBinary(searched: [tmp.path])) {
            try HuginnInstaller(paths: tmp.paths).install(from: [tmp.path])
        }
    }

    @Test("log tailer: incremental, partial lines, truncation, classification")
    func tail() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let f = tmp.sub("a.log")
        write("first\nLLM url=http://x\nhalf", f)
        let t = LogTailer(path: f)
        let a = await t.poll()
        #expect(a.map(\.text) == ["first", "LLM url=http://x"])
        #expect(a.map(\.kind) == [.info, .llm])
        let h = try #require(FileHandle(forWritingAtPath: f))
        try h.seekToEnd(); h.write(Data("-line run_shell\nerror: boom\n".utf8)); try h.close()
        let b = await t.poll()
        #expect(b.map(\.text) == ["half-line run_shell", "error: boom"])
        #expect(b.map(\.kind) == [.tool, .error])
        write("new\n", f)  // truncated/rotated
        #expect(await t.poll().map(\.text) == ["new"])
    }

    @Test("learner: failed command, session end, user edit after write_file, sealed events")
    func learner() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        try FileManager.default.createDirectory(atPath: paths.configDir, withIntermediateDirectories: true)
        let key = Data(repeating: 7, count: 32)
        let cwd = tmp.sub("proj")
        let edited = cwd + "/a.txt"
        write("agent version", edited)
        func line(_ j: String) -> String { ACPMetadataCrypto.sealLine(j, key: key) ?? j }
        let events = [
            #"{"type":"shell_result","cwd":"\#(cwd)","cmd":"swift build","exit":1,"summary":"error: x\nmore"}"#,
            #"{"type":"write_file","cwd":"\#(cwd)","path":"\#(edited)"}"#,
            #"{"type":"session_end","cwd":"\#(cwd)","ts":"T","summary":"did it","files":1,"build":"ok"}"#,
        ].map(line).joined(separator: "\n") + "\n"
        write(events, paths.eventsFile)
        let l = ContextLearner(paths: paths, metadataKey: key)
        let t0 = Date()
        await l.poll(now: t0)
        #expect(await l.watchedFiles == [edited])
        try await Task.sleep(for: .milliseconds(20))
        write("user version", edited)
        await l.poll(now: t0.addingTimeInterval(5))
        #expect(await l.watchedFiles.isEmpty)
        let projects = await l.projects()
        #expect(projects.map(\.cwd) == [cwd])
        let text = await l.memoryText(projects[0])
        #expect(text.contains("Command failed (exit 1): `swift build` — error: x"))
        #expect(text.contains("T: did it (files: 1, build: ok)"))
        #expect(text.contains("You edited `a.txt` after the agent wrote it"))
        // On disk it is sealed (B2), not plaintext.
        let raw = try Data(contentsOf: URL(fileURLWithPath: projects[0].path))
        #expect(String(decoding: raw, as: UTF8.self).hasPrefix(ProjectContext.sealedHeader))
        // Without the key the memory is unreadable (never rendered as text).
        #expect(await ContextLearner(paths: paths, metadataKey: nil).memoryText(projects[0]) == "")
        await l.clear(projects[0])
        #expect(await l.projects().isEmpty)
    }

    @Test("learner: write_file watch expires after 15 minutes")
    func watchExpiry() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        let f = tmp.sub("w.txt"); write("x", f)
        write(#"{"type":"write_file","cwd":"/p","path":"\#(f)"}"# + "\n", paths.eventsFile)
        let l = ContextLearner(paths: paths, metadataKey: nil)
        let t0 = Date()
        await l.poll(now: t0)
        #expect(await l.watchedFiles == [f])
        await l.poll(now: t0.addingTimeInterval(ContextLearner.watchWindow + 1))
        #expect(await l.watchedFiles.isEmpty)
        #expect(await l.projects().isEmpty)
    }

    @Test("learner resumes from the persisted offset: a second process never re-learns an event")
    func persistedOffset() async throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        write(#"{"type":"session_end","cwd":"/p","ts":"one","summary":"s"}"# + "\n" + #"{"type":"session_end","cwd":"/p","ts":"tw"#, paths.eventsFile)
        await ContextLearner(paths: paths, metadataKey: nil).poll()
        // The partial second line is completed later and read by a NEW learner (new process).
        let h = try #require(FileHandle(forWritingAtPath: paths.eventsFile))
        try h.seekToEnd(); h.write(Data(#"o","summary":"s"}"#.utf8 + Data("\n".utf8))); try h.close()
        let second = ContextLearner(paths: paths, metadataKey: nil)
        await second.poll()
        await ContextLearner(paths: paths, metadataKey: nil).poll()  // a third run adds nothing
        let p = try #require(await second.projects().first)
        let text = await second.memoryText(p)
        #expect(text.components(separatedBy: "one: s").count == 2, "\(text)")
        #expect(text.components(separatedBy: "two: s").count == 2, "\(text)")
    }

    @Test("learner skipExisting does not replay old events")
    func skipExisting() async {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        write(#"{"type":"session_end","cwd":"/p","ts":"old","summary":"s"}"# + "\n", paths.eventsFile)
        let l = ContextLearner(paths: paths, metadataKey: nil)
        await l.skipExisting()
        await l.poll()
        #expect(await l.projects().isEmpty)
    }
}
