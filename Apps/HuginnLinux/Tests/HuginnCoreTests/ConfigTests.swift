// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP
import Testing
@testable import HuginnCore

@Suite("Config: env file, settings, secrets")
struct ConfigTests {
    @Test("env-file quoting round-trips hostile values through the parser AND through bash")
    func envRoundTrip() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let values: [(String, String)] = [
            ("A", "plain"), ("B", "it's quoted"), ("C", "$(touch /tmp/pwned) `x` $HOME"),
            ("D", ""), ("E", "a b\tc"), ("F", "'''"),
        ]
        let text = EnvFile.render(values, header: "test")
        let parsed = EnvFile.parse(text)
        for (k, v) in values { #expect(parsed[k] == v, "\(k)") }
        let file = tmp.sub("env")
        write(text, file)
        // bash must read back the same bytes and must NOT execute anything.
        let marker = tmp.sub("pwned")
        let (rc, out) = try run("/bin/bash", ["-c", "source \(file); for k in A B C D E F; do printf '%s=<%s>\\n' $k \"${!k}\"; done; test ! -e \(marker)"])
        #expect(rc == 0)
        for (k, v) in values { #expect(out.contains("\(k)=<\(v)>"), "\(k): \(out)") }
    }

    @Test("parser accepts hand-edited shapes")
    func handEdited() {
        let p = EnvFile.parse("# c\nexport X=1\nY=\"two words\"\n  Z='z'\nbad line\n=nokey\n")
        #expect(p == ["X": "1", "Y": "two words", "Z": "z"])
    }

    @Test("settings save → eldr-acp's own parsers read back exactly what Huginn shows; token never on disk")
    func settingsRoundTrip() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        var s = HuginnSettings.load(paths: paths)  // defaults from an empty dir
        #expect(s.llmURL == "http://127.0.0.1:1337/v1")
        s.llmURL = "http://127.0.0.1:18080/v1"
        s.llmModel = "mock-model"
        s.maxAgentSteps = 7
        s.tools = ["read_file", "write_file"]
        s.skillsEnabled = false
        s.promptPreamble = "Be brief."
        s.systemPrompt = ""
        s.learningEnabled = false
        s.allowUngatedTools = true
        s.workdir = tmp.path
        try s.save(paths: paths)
        let back = HuginnSettings.load(paths: paths)
        #expect(back == s)
        let agent = back.agentConfig(paths: paths)
        #expect(agent.maxIterations == 7)
        #expect(agent.toolAllowlist == ["read_file", "write_file"])
        #expect(agent.skillsEnabled == false)
        #expect(agent.promptPreamble == "Be brief.")
        #expect(agent.systemPromptOverride == nil)
        #expect(agent.eventsFilePath == nil)  // learning off ⇒ ELDR_ACP_EVENTS_FILE=""
        #expect(agent.allowUngatedTools)
        let env = try String(contentsOfFile: paths.envFile, encoding: .utf8)
        #expect(!env.contains("ELDR_LLM_TOKEN"))
        let mode = (try FileManager.default.attributesOfItem(atPath: paths.envFile))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!FileManager.default.fileExists(atPath: paths.systemPromptFile))
        // Learning on ⇒ the agent is pointed at Huginn's events file.
        var on = back; on.learningEnabled = true
        try on.save(paths: paths)
        #expect(on.agentConfig(paths: paths).eventsFilePath == paths.eventsFile)
    }

    @Test("keystore: metadata key is minted once (32 bytes) and stable; huginn profile is its own")
    func secrets() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let s = testSecrets(tmp)
        let k1 = try HuginnSecrets.metadataKey(s)
        let k2 = try HuginnSecrets.metadataKey(s)
        #expect(k1.count == 32 && k1 == k2)
        try s.save(Data("tok".utf8), account: HuginnSecrets.llmTokenAccount)
        #expect(HuginnSecrets.string(s, HuginnSecrets.llmTokenAccount) == "tok")
        #expect(HuginnSecrets.profile.hkdfSaltLabel != "eldr-node/keystore/v1")
        #expect(HuginnSecrets.profile.hkdfSaltLabel != "eldr-chat/keystore/v1")
    }

    @Test("keystore opens via the passphrase rung and refuses with no source")
    func keystoreLadder() throws {
        let tmp = TempDir(); defer { tmp.remove() }
        let paths = tmp.paths
        guard !FileManager.default.fileExists(atPath: "/dev/tpmrm0"), !FileManager.default.fileExists(atPath: "/dev/tpm0") else { return }
        #expect(throws: (any Error).self) { _ = try HuginnSecrets.open(paths: paths, environment: [:]) }
        let (store, posture) = try HuginnSecrets.open(paths: paths, environment: ["HUGINN_PASSPHRASE": "correct horse battery staple"])
        try store.save(Data("x".utf8), account: "llm-token")
        let (again, _) = try HuginnSecrets.open(paths: paths, environment: ["HUGINN_PASSPHRASE": "correct horse battery staple"])
        #expect(HuginnSecrets.string(again, "llm-token") == "x")
        #expect(!posture.isEmpty)
    }
}
