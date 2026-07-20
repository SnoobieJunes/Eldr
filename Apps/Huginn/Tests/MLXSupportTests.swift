// SPDX-License-Identifier: AGPL-3.0-only
import Combine
import Foundation
import Testing

@testable import Huginn

// WS-MLX: the pure logic behind the MLX tab — command construction for every
// mlx_lm subcommand, the HF cache scanner, the launchd plist, and the
// terminal-output buffer. No test spawns a process or touches the network.

@Suite("MLX command construction")
struct MLXCommandTests {

    @Test func serverArgumentsCoreOnly() {
        var config = MLXServerConfig()
        config.model = "mlx-community/Qwen3-4B-4bit"
        let args = MLXCommand.serverArguments(config)
        #expect(
            args == [
                "-m", "mlx_lm", "server",
                "--model", "mlx-community/Qwen3-4B-4bit",
                "--host", "127.0.0.1",
                "--port", "8080",
            ])
    }

    @Test func serverArgumentsWithEverything() {
        var config = MLXServerConfig()
        config.model = "/models/foo"
        config.host = "0.0.0.0"
        config.port = 9999
        config.maxTokens = 2048
        config.temperature = 0.7
        config.topP = 0.9
        config.trustRemoteCode = true
        config.useDefaultChatTemplate = true
        config.chatTemplate = "{{ messages }}"
        config.adapterPath = "/adapters"
        config.extraArguments = "--log-level  DEBUG"
        let args = MLXCommand.serverArguments(config)
        #expect(args.contains(["--max-tokens", "2048"]))
        #expect(args.contains(["--temp", "0.7"]))
        #expect(args.contains(["--top-p", "0.9"]))
        #expect(args.contains("--trust-remote-code"))
        #expect(args.contains("--use-default-chat-template"))
        #expect(args.contains("--chat-template={{ messages }}"))
        #expect(args.contains(["--adapter-path", "/adapters"]))
        // Extra args are whitespace-split with empties dropped.
        #expect(args.suffix(2) == ["--log-level", "DEBUG"])
    }

    @Test func serverProbeHostMapsWildcardToLoopback() {
        var config = MLXServerConfig()
        config.host = "0.0.0.0"
        config.port = 8080
        #expect(config.baseURL == "http://127.0.0.1:8080/v1")
        config.host = "192.168.1.5"
        #expect(config.baseURL == "http://192.168.1.5:8080/v1")
    }

    @Test func generateArgumentsKeepPromptAsOneElement() {
        var config = MLXGenerateConfig()
        config.model = "m"
        config.prompt = "tell me a story\nwith two lines & 'quotes'"
        config.maxTokens = 64
        let args = MLXCommand.generateArguments(config)
        #expect(args.contains("--prompt=tell me a story\nwith two lines & 'quotes'"))
        #expect(!args.contains("--temp"))
        #expect(!args.contains("--adapter-path"))
    }

    @Test func generateArgumentsSurviveLeadingDashPrompt() {
        var config = MLXGenerateConfig()
        config.model = "m"
        config.prompt = "-1 + 1 = ?"
        config.maxTokens = 0  // clamped so mlx never sees a nonsensical value
        let args = MLXCommand.generateArguments(config)
        #expect(args.contains("--prompt=-1 + 1 = ?"))
        #expect(args.contains(["--max-tokens", "1"]))
    }

    @Test func convertArgumentsQuantizeToggle() {
        var config = MLXConvertConfig()
        config.hfPath = "org/model"
        config.mlxPath = "/out"
        config.quantize = true
        config.qBits = 8
        config.qGroupSize = 32
        let quantized = MLXCommand.convertArguments(config)
        #expect(quantized.contains("-q"))
        #expect(quantized.contains(["--q-bits", "8"]))
        #expect(quantized.contains(["--q-group-size", "32"]))

        config.quantize = false
        config.dtype = "bfloat16"
        config.uploadRepo = "me/quantized"
        let plain = MLXCommand.convertArguments(config)
        #expect(!plain.contains("-q"))
        #expect(!plain.contains("--q-bits"))
        #expect(plain.contains(["--dtype", "bfloat16"]))
        #expect(plain.contains(["--upload-repo", "me/quantized"]))
    }

    @Test func loraYAMLQuotesAndKeys() {
        var config = MLXFineTuneConfig()
        config.model = "/models/it's here"
        config.dataDir = "/data"
        config.adapterPath = "/adapters"
        config.fineTuneType = "dora"
        config.numLayers = 24
        config.batchSize = 2
        config.iters = 100
        config.learningRate = 1e-5
        config.loraRank = 16
        let yaml = MLXCommand.loraConfigYAML(config)
        #expect(yaml.contains("model: '/models/it''s here'"))
        #expect(yaml.contains("train: true"))
        #expect(yaml.contains("fine_tune_type: dora"))
        #expect(yaml.contains("data: '/data'"))
        #expect(yaml.contains("adapter_path: '/adapters'"))
        #expect(yaml.contains("num_layers: 24"))
        #expect(yaml.contains("batch_size: 2"))
        #expect(yaml.contains("iters: 100"))
        #expect(yaml.contains("learning_rate: 1e-05"))
        #expect(yaml.contains("rank: 16"))

        let args = MLXCommand.loraArguments(configPath: "/tmp/c.yaml")
        #expect(args == ["-m", "mlx_lm", "lora", "--config", "/tmp/c.yaml", "--train"])
    }

    @Test func fuseArguments() {
        let args = MLXCommand.fuseArguments(model: "base", adapterPath: "/a", savePath: "/s")
        #expect(
            args == [
                "-m", "mlx_lm", "fuse", "--model", "base", "--adapter-path", "/a", "--save-path",
                "/s",
            ])
    }

    @Test func repoIDValidation() {
        #expect(MLXCommand.isValidRepoID("mlx-community/Qwen3-4B-Instruct-4bit"))
        #expect(MLXCommand.isValidRepoID("a/b.c_d-e"))
        #expect(!MLXCommand.isValidRepoID(""))
        #expect(!MLXCommand.isValidRepoID("noslash"))
        #expect(!MLXCommand.isValidRepoID("has space/model"))
        #expect(!MLXCommand.isValidRepoID("a/b/c"))
        #expect(!MLXCommand.isValidRepoID("org/model\"; import os"))
        #expect(!MLXCommand.isValidRepoID("org/model'x"))
        #expect(!MLXCommand.isValidRepoID("-leading/dash"))
    }

    @Test func downloadArgumentsEmbedValidatedID() {
        let args = MLXCommand.downloadArguments(repoID: "mlx-community/Tiny")
        #expect(args.first == "-c")
        #expect(args.count == 2)
        #expect(args[1].contains("snapshot_download(repo_id=\"mlx-community/Tiny\")"))
    }

    @Test func launchdPlistRoundTrips() throws {
        let data = try MLXCommand.launchdPlist(
            pythonPath: "/venv/bin/python3",
            serverArguments: ["-m", "mlx_lm", "server", "--model", "m", "--host", "h", "--port", "1"],
            logPath: "/logs/mlx-server.log")
        let plist =
            try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        let plistDict = try #require(plist)
        #expect(plistDict["Label"] as? String == "chat.eldr.mlx-server")
        #expect(plistDict["RunAtLoad"] as? Bool == true)
        #expect(plistDict["KeepAlive"] as? Bool == false)
        #expect(plistDict["StandardOutPath"] as? String == "/logs/mlx-server.log")
        #expect(plistDict["StandardErrorPath"] as? String == "/logs/mlx-server.log")
        #expect(
            plistDict["ProgramArguments"] as? [String] == [
                "/venv/bin/python3", "-m", "mlx_lm", "server", "--model", "m", "--host", "h",
                "--port", "1",
            ])
        let env = plistDict["EnvironmentVariables"] as? [String: String]
        #expect(env?["HF_HUB_DISABLE_PROGRESS_BARS"] == "1")
    }

    @Test func searchURLComposition() throws {
        let url = try #require(
            MLXCommand.searchURL(
                query: "qwen 4bit", author: "mlx-community", mlxOnly: true, limit: 20))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "huggingface.co")
        #expect(components.path == "/api/models")
        let items = components.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "author", value: "mlx-community")))
        #expect(items.contains(URLQueryItem(name: "search", value: "qwen 4bit")))
        #expect(items.contains(URLQueryItem(name: "sort", value: "downloads")))
        // MLX filter = the `mlx` library tag, independent of publisher.
        #expect(items.contains(URLQueryItem(name: "filter", value: "mlx")))
        // The UI captions need these expanded row fields.
        let expanded = items.filter { $0.name == "expand[]" }.compactMap(\.value)
        #expect(Set(expanded).isSuperset(of: ["downloads", "likes", "lastModified", "tags"]))

        let noAuthor = try #require(
            MLXCommand.searchURL(query: "", author: nil, mlxOnly: false))
        let noAuthorItems =
            URLComponents(url: noAuthor, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!noAuthorItems.contains { $0.name == "author" })
        #expect(!noAuthorItems.contains { $0.name == "search" })
        #expect(!noAuthorItems.contains { $0.name == "filter" })

        let sorted = try #require(
            MLXCommand.searchURL(query: "x", author: "unsloth", mlxOnly: true, sort: "likes"))
        let sortedItems =
            URLComponents(url: sorted, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(sortedItems.contains(URLQueryItem(name: "sort", value: "likes")))
        #expect(sortedItems.contains(URLQueryItem(name: "author", value: "unsloth")))
    }

    @Test func hubModelDecodesSearchRow() throws {
        let json = """
            [{"id":"lmstudio-community/Qwen3.6-27B-MLX-4bit","downloads":995364,"likes":7,
              "lastModified":"2026-04-22T14:25:11.000Z",
              "tags":["transformers","safetensors","mlx","4-bit","region:us"]}]
            """
        let rows = try JSONDecoder().decode([MLXHubModel].self, from: Data(json.utf8))
        let row = try #require(rows.first)
        #expect(row.isMLX)
        #expect(row.quantLabel == "4-bit")
        #expect(row.lastModified?.hasPrefix("2026-04-22") == true)
    }

    @Test func serverModelValidation() throws {
        // Repo ids pass; junk fails.
        #expect(MLXCommand.validateServerModel("mlx-community/Qwen3-4bit") == nil)
        #expect(MLXCommand.validateServerModel("") != nil)
        #expect(MLXCommand.validateServerModel("not a repo id") != nil)

        // A nonexistent absolute path fails with a message naming the path — the
        // exact live failure: server "healthy", load thread dead, every chat hung.
        let missing = MLXCommand.validateServerModel("/nonexistent/model-folder")
        #expect(missing?.contains("/nonexistent/model-folder") == true)

        // A real folder without config.json is rejected; with config.json it passes.
        let dir = NSTemporaryDirectory() + "mlx-validate-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(MLXCommand.validateServerModel(dir)?.contains("config.json") == true)
        FileManager.default.createFile(
            atPath: (dir as NSString).appendingPathComponent("config.json"),
            contents: Data("{}".utf8))
        #expect(MLXCommand.validateServerModel(dir) == nil)

        // A FILE path (e.g. a .gguf) is rejected as not-a-folder.
        let file = (dir as NSString).appendingPathComponent("weights.gguf")
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(MLXCommand.validateServerModel(file)?.contains("folder") == true)
    }
}

@Suite("Terminal line buffer")
struct TerminalLineBufferTests {

    @Test func newlineCommitsLines() {
        var buffer = TerminalLineBuffer()
        buffer.feed("hello\nworld")
        #expect(buffer.lines == ["hello", "world"])
        #expect(buffer.text == "hello\nworld")
        buffer.feed("!\n")
        #expect(buffer.lines == ["hello", "world!"])
    }

    @Test func carriageReturnReplacesLiveLine() {
        var buffer = TerminalLineBuffer()
        buffer.feed("downloading:  10%\r")
        buffer.feed("downloading:  55%\r")
        buffer.feed("downloading: 100%\n")
        #expect(buffer.lines == ["downloading: 100%"])
    }

    @Test func carriageReturnNewlineIsOneEOL() {
        var buffer = TerminalLineBuffer()
        buffer.feed("line one\r\nline two\r\n")
        #expect(buffer.lines == ["line one", "line two"])
    }

    @Test func splitAcrossChunksAtControlCharacters() {
        var buffer = TerminalLineBuffer()
        buffer.feed("50%")
        buffer.feed("\r")
        buffer.feed("60%")
        #expect(buffer.lines == ["60%"])
        buffer.feed("\rdone\n")
        #expect(buffer.lines == ["done"])
    }

    @Test func capBoundsCommittedLines() {
        var buffer = TerminalLineBuffer(maxLines: 3)
        for index in 0..<10 { buffer.feed("line \(index)\n") }
        #expect(buffer.lines == ["line 7", "line 8", "line 9"])
    }
}

@Suite("HF cache scanner")
struct HFCacheTests {

    @Test func repoIDDecoding() {
        #expect(HFCache.repoID(fromFolderName: "models--mlx-community--Qwen3-4B-4bit")
            == "mlx-community/Qwen3-4B-4bit")
        // HF forbids "--" INSIDE either half, so the first "--" is the separator;
        // anything pathological after it stays in the name half verbatim.
        #expect(HFCache.repoID(fromFolderName: "models--org--name--extra") == "org/name--extra")
        #expect(HFCache.repoID(fromFolderName: "datasets--org--name") == nil)
        #expect(HFCache.repoID(fromFolderName: "models--orgonly") == nil)
        #expect(HFCache.repoID(fromFolderName: ".locks") == nil)
    }

    @Test func scanFindsModelsAndSumsRealBytesOnly() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-cache-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }

        let entry = (root as NSString).appendingPathComponent("models--mlx-community--Tiny")
        let blobs = (entry as NSString).appendingPathComponent("blobs")
        let snapshots = (entry as NSString).appendingPathComponent("snapshots/abc")
        try fm.createDirectory(atPath: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: snapshots, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(
            to: URL(fileURLWithPath: (blobs as NSString).appendingPathComponent("blob1")))
        try Data(repeating: 2, count: 5).write(
            to: URL(fileURLWithPath: (blobs as NSString).appendingPathComponent("blob2")))
        // Snapshot symlink into blobs must NOT double-count.
        try fm.createSymbolicLink(
            atPath: (snapshots as NSString).appendingPathComponent("weights.safetensors"),
            withDestinationPath: (blobs as NSString).appendingPathComponent("blob2"))
        // Non-model entries are ignored.
        try fm.createDirectory(
            atPath: (root as NSString).appendingPathComponent("datasets--a--b"),
            withIntermediateDirectories: true)
        try fm.createDirectory(
            atPath: (root as NSString).appendingPathComponent(".locks"),
            withIntermediateDirectories: true)

        let models = HFCache.scanModels(cacheDir: root)
        #expect(models.count == 1)
        #expect(models.first?.repoID == "mlx-community/Tiny")
        #expect(models.first?.sizeBytes == 8)
        #expect(models.first?.path == entry)
    }

    @Test func scanOfMissingDirIsEmpty() {
        #expect(HFCache.scanModels(cacheDir: "/nonexistent/definitely-not-here").isEmpty)
    }

    @Test func cacheDirHonorsEnvOverrides() {
        #expect(
            HFCache.defaultCacheDir(env: ["HUGGINGFACE_HUB_CACHE": "/x/hub-cache"])
                == "/x/hub-cache")
        #expect(HFCache.defaultCacheDir(env: ["HF_HOME": "/y"]) == "/y/hub")
        #expect(
            HFCache.defaultCacheDir(env: [:])
                == (NSHomeDirectory() as NSString)
                .appendingPathComponent(".cache/huggingface/hub"))
    }
}

@Suite("MLX service wiring")
struct MLXServiceWiringTests {

    /// "Use as Eldr LLM backend" writes the existing Local-LLM fields through
    /// ConfigurationStore — the standard LLMClient seam, no new abstraction.
    @MainActor
    @Test func useAsBackendWritesLLMConfig() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let keychain = KeychainBox(service: "test-mlx-\(UUID().uuidString)")
        defer { keychain.delete(account: "llm-token") }
        let store = ConfigurationStore(paths: paths, keychain: keychain)
        let defaults = try #require(UserDefaults(suiteName: "mlx-test-\(UUID().uuidString)"))

        let service = MLXService(paths: paths, defaults: defaults, launchAgentsDir: tmp)
        service.serverConfig.model = "mlx-community/Tiny"
        service.serverConfig.host = "0.0.0.0"
        service.serverConfig.port = 9123

        service.useAsEldrBackend(store: store)
        #expect(store.llmURL == "http://127.0.0.1:9123/v1")
        #expect(store.llmModel == "mlx-community/Tiny")
    }

    /// The server config round-trips through the injected UserDefaults.
    @MainActor
    @Test func serverConfigPersistsAcrossInstances() throws {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let suite = "mlx-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = MLXService(paths: paths, defaults: defaults, launchAgentsDir: tmp)
        first.serverConfig.model = "mlx-community/Persisted"
        first.serverConfig.port = 4242

        let second = MLXService(paths: paths, defaults: defaults, launchAgentsDir: tmp)
        #expect(second.serverConfig.model == "mlx-community/Persisted")
        #expect(second.serverConfig.port == 4242)
    }
}

// WS-M0 — publish hygiene + the managed-server kill-switch.

@Suite("MLX publish hygiene (WS-M0)")
struct MLXPublishHygieneTests {

    @MainActor
    private func makeService(
        jobFlush: Duration = .milliseconds(250)
    ) throws -> (MLXService, cleanup: () -> Void) {
        let tmp = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-hygiene-\(UUID().uuidString)")
        let paths = ConfigPaths(configDir: tmp, binDir: tmp)
        let suite = "mlx-hygiene-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = MLXService(
            paths: paths, defaults: defaults, launchAgentsDir: tmp, jobLogFlushInterval: jobFlush)
        return (
            service,
            {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(atPath: tmp)
            }
        )
    }

    /// A steady probe result writes `probeStatus` (and so publishes) only on
    /// change — the old code invalidated the whole MLX Form every 3 s forever.
    @MainActor
    @Test func probeStatusPublishesOnlyOnChange() throws {
        let (service, cleanup) = try makeService()
        defer { cleanup() }

        var publishes = 0
        let cancellable = service.objectWillChange.sink { _ in publishes += 1 }
        defer { cancellable.cancel() }

        service.applyProbe(.unreachable(error: "connection refused"))
        #expect(publishes == 1)
        service.applyProbe(.unreachable(error: "connection refused"))
        #expect(publishes == 1, "identical probe result published again")
        service.applyProbe(.reachable(models: ["m"]))
        #expect(publishes == 2)
        service.applyProbe(.reachable(models: ["m"]))
        #expect(publishes == 2, "identical probe result published again")
    }

    /// Job output lands in `jobLog` in batches, never synchronously per line.
    @MainActor
    @Test func jobOutputIsBatchedNotPerLine() async throws {
        let (service, cleanup) = try makeService(jobFlush: .milliseconds(40))
        defer { cleanup() }

        service.appendJobOutput("alpha\n")
        service.appendJobOutput("beta\n")
        // Buffered: nothing published yet — the per-line publish is gone.
        #expect(service.jobLog.isEmpty)
        #expect(service.jobLogWindow.isEmpty)

        var landed = false
        for _ in 0..<100 {
            if service.jobLog.lines == ["alpha", "beta"] {
                landed = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(landed, "buffered job output never flushed: \(service.jobLog.lines)")
        // The precomputed window tracks the flush.
        #expect(service.jobLogWindow.map(\.text) == ["alpha", "beta"])
    }

    /// `jobPaneState(for:)` scopes job UI state to the section that owns the job
    /// kind, so another section's pane input stays empty (and its view untouched).
    @MainActor
    @Test func jobPaneStateFiltersByKind() async throws {
        let (service, cleanup) = try makeService(jobFlush: .milliseconds(40))
        defer { cleanup() }

        // Fake venv python: answers the version probe; any other invocation echoes
        // one line and exits 0 (a fast, successful "generate").
        let binDir = ((service.venvDir) as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let script =
            "#!/bin/zsh\nif [[ \"$1\" == \"-c\" ]]; then echo \"0.0.0-test\"; exit 0; fi\n"
            + "echo \"GEN-OUTPUT\"\nexit 0\n"
        try script.write(toFile: service.venvPython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: service.venvPython)

        await service.refreshEnvironment()
        #expect(service.envState == .ready(version: "0.0.0-test"))

        service.runGenerate(MLXGenerateConfig(model: "fake/model", prompt: "hi"))
        #expect(service.jobPaneState(for: [.generate]).activeJob != nil)
        #expect(
            service.jobPaneState(for: [.download])
                == MLXService.JobPaneState(activeJob: nil, lastResult: nil, logWindow: []))

        var finished = false
        for _ in 0..<300 {
            if service.lastJobResult != nil {
                finished = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(finished, "generate job never finished")
        let generatePane = service.jobPaneState(for: [.generate])
        #expect(generatePane.lastResult?.success == true)
        #expect(generatePane.logWindow.contains { $0.text.contains("GEN-OUTPUT") })
        #expect(service.jobPaneState(for: [.download]).logWindow.isEmpty)
        #expect(service.jobPaneState(for: [.download]).lastResult == nil)
    }
}

@Suite("MLX managed-server kill-switch (WS-M0)")
struct MLXManagedToggleTests {

    /// Everything one toggle test needs, on isolated paths/defaults/keychain.
    @MainActor
    private struct Fixture {
        let service: MLXService
        let store: ConfigurationStore
        let paths: ConfigPaths
        let defaults: UserDefaults
        let cleanup: () -> Void

        init() throws {
            let tmp = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("eldr-mlx-toggle-\(UUID().uuidString)")
            let suite = "mlx-toggle-\(UUID().uuidString)"
            let localPaths = ConfigPaths(configDir: tmp, binDir: tmp)
            let localDefaults = try #require(UserDefaults(suiteName: suite))
            let keychain = KeychainBox(service: "test-mlx-toggle-\(UUID().uuidString)")
            paths = localPaths
            defaults = localDefaults
            store = ConfigurationStore(paths: localPaths, keychain: keychain)
            service = MLXService(paths: localPaths, defaults: localDefaults, launchAgentsDir: tmp)
            cleanup = {
                keychain.delete(account: "llm-token")
                localDefaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(atPath: tmp)
            }
        }

        /// Install the fake venv python (version probe + `exec sleep` server) so a
        /// child server can actually launch and be SIGTERMed.
        func installFakePython() throws {
            let binDir = (service.venvDir as NSString).appendingPathComponent("bin")
            try FileManager.default.createDirectory(
                atPath: binDir, withIntermediateDirectories: true)
            let script =
                "#!/bin/zsh\nif [[ \"$1\" == \"-c\" ]]; then echo \"0.0.0-test\"; exit 0; fi\n"
                + "exec sleep 60\n"
            try script.write(toFile: service.venvPython, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: service.venvPython)
        }
    }

    /// OFF hands the Eldr backend to the (seeded) external pair; ON rewires it to
    /// the MLX server; the next OFF restores the externally-typed pair — the
    /// round-trip is non-destructive in both directions.
    @MainActor
    @Test func backendHandoffAndRestoreRoundTrips() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        let store = fixture.store

        service.serverConfig.model = "mlx-community/Tiny"
        service.serverConfig.host = "127.0.0.1"
        service.serverConfig.port = 9123
        service.useAsEldrBackend(store: store)
        #expect(service.managesServer)

        // First OFF: no saved external pair yet — seeded from the current values,
        // so nothing changes (the "run LM Studio on the same port" path).
        await service.setManagesServer(false, store: store)
        #expect(!service.managesServer)
        #expect(store.llmURL == "http://127.0.0.1:9123/v1")
        #expect(store.llmModel == "mlx-community/Tiny")

        // The user points Eldr at LM Studio's default while unmanaged.
        store.llmURL = "http://127.0.0.1:1234/v1"
        store.llmModel = "lmstudio-community/Some-Model"

        // ON: backend rewired to the MLX server config (which persisted untouched).
        await service.setManagesServer(true, store: store)
        #expect(service.managesServer)
        #expect(store.llmURL == "http://127.0.0.1:9123/v1")
        #expect(store.llmModel == "mlx-community/Tiny")

        // OFF again: the externally-typed pair comes back, not a re-seed.
        await service.setManagesServer(false, store: store)
        #expect(store.llmURL == "http://127.0.0.1:1234/v1")
        #expect(store.llmModel == "lmstudio-community/Some-Model")
    }

    /// The flag persists, and a service that loads with it OFF starts with the
    /// probes and the server-log tailer idle (the zero-churn state).
    @MainActor
    @Test func managedOffPersistsAndIdlesMonitoring() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        #expect(service.managesServer)
        #expect(service.serverLog.isTailing)
        #expect(service.isMonitoringHealth)

        await service.setManagesServer(false, store: fixture.store)
        #expect(!service.serverLog.isTailing)
        #expect(!service.isMonitoringHealth)
        #expect(service.probeStatus == .unknown)

        let second = MLXService(
            paths: fixture.paths, defaults: fixture.defaults, launchAgentsDir: fixture.paths.configDir)
        #expect(!second.managesServer)
        #expect(!second.serverLog.isTailing)
        #expect(!second.isMonitoringHealth)
    }

    /// OFF stops a running child server; ON resumes it (child mode round-trip).
    @MainActor
    @Test func offStopsRunningChildAndOnResumesIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        try fixture.installFakePython()

        await service.refreshEnvironment()
        #expect(service.envState == .ready(version: "0.0.0-test"))
        service.serverConfig.model = "fake/model"
        service.serverConfig.port = 39_408  // nothing listens; probe fails quietly
        service.startServer()
        #expect(service.serverState == .starting)

        await service.setManagesServer(false, store: fixture.store)
        var stopped = false
        for _ in 0..<300 {
            if service.serverState == .stopped {
                stopped = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(stopped, "child server never reached .stopped after management OFF")
        #expect(!service.isMonitoringHealth)
        #expect(!service.serverLog.isTailing)

        await service.setManagesServer(true, store: fixture.store)
        #expect(service.serverState == .starting, "child server did not resume on ON")
        #expect(service.isMonitoringHealth)
        #expect(service.serverLog.isTailing)

        service.stopServer()
        for _ in 0..<300 where service.serverState != .stopped {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// While OFF, startServer() is inert — nothing may spawn a child that the
    /// idled monitor would never mark healthy.
    @MainActor
    @Test func startServerIsInertWhileOff() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        try fixture.installFakePython()
        await service.refreshEnvironment()
        service.serverConfig.model = "fake/model"

        await service.setManagesServer(false, store: fixture.store)
        service.startServer()
        #expect(service.serverState == .stopped)
    }
}

// WS-M1 — serve surface: reasoning toggle, server cache knobs, playground KV
// quantization, and the port/process diagnosis parsers.

@Suite("MLX serve surface arguments (WS-M1)")
struct MLXServeSurfaceArgumentTests {

    @Test func reasoningToggleEmitsChatTemplateArgs() {
        var config = MLXServerConfig()
        config.model = "m"

        #expect(!MLXCommand.serverArguments(config).contains("--chat-template-args"))

        config.reasoning = false
        var args = MLXCommand.serverArguments(config)
        #expect(args.contains(["--chat-template-args", "{\"enable_thinking\":false}"]))

        config.reasoning = true
        args = MLXCommand.serverArguments(config)
        #expect(args.contains(["--chat-template-args", "{\"enable_thinking\":true}"]))
    }

    /// Extras stay LAST so a hand-typed duplicate flag keeps winning (argparse
    /// takes the final occurrence).
    @Test func extrasStillTrailTheNewFlags() {
        var config = MLXServerConfig()
        config.model = "m"
        config.reasoning = true
        config.promptCacheSize = 8
        config.extraArguments = "--log-level DEBUG"
        let args = MLXCommand.serverArguments(config)
        #expect(args.suffix(2) == ["--log-level", "DEBUG"])
    }

    @Test func promptCacheFlagsEmitOnlyWhenSet() {
        var config = MLXServerConfig()
        config.model = "m"
        let bare = MLXCommand.serverArguments(config)
        #expect(!bare.contains("--prompt-cache-size"))
        #expect(!bare.contains("--prompt-cache-bytes"))

        config.promptCacheSize = 12
        config.promptCacheBytes = 2_147_483_648
        let args = MLXCommand.serverArguments(config)
        #expect(args.contains(["--prompt-cache-size", "12"]))
        #expect(args.contains(["--prompt-cache-bytes", "2147483648"]))
    }

    @Test func generateKVFlagsGateOnKVBits() {
        var config = MLXGenerateConfig()
        config.model = "m"
        config.prompt = "p"
        // Group size / start without bits: meaningless, must not emit.
        config.kvGroupSize = 32
        config.quantizedKVStart = 100
        var args = MLXCommand.generateArguments(config)
        #expect(!args.contains("--kv-bits"))
        #expect(!args.contains("--kv-group-size"))
        #expect(!args.contains("--quantized-kv-start"))

        config.kvBits = 4
        args = MLXCommand.generateArguments(config)
        #expect(args.contains(["--kv-bits", "4"]))
        #expect(args.contains(["--kv-group-size", "32"]))
        #expect(args.contains(["--quantized-kv-start", "100"]))

        config.maxKVSize = 4096
        args = MLXCommand.generateArguments(config)
        #expect(args.contains(["--max-kv-size", "4096"]))
    }

    @Test func gigabyteConversionRoundTrips() {
        #expect(MLXCommand.bytes(fromGB: 2) == 2_147_483_648)
        #expect(MLXCommand.bytes(fromGB: 0) == nil)
        #expect(MLXCommand.bytes(fromGB: -1) == nil)
        #expect(MLXCommand.gigabytes(fromBytes: 2_147_483_648) == 2)
        #expect(MLXCommand.bytes(fromGB: 0.5) == 536_870_912)
        // User-typed absurdities must yield nil, never an Int64-conversion trap.
        #expect(MLXCommand.bytes(fromGB: 1e15) == nil)
        #expect(MLXCommand.bytes(fromGB: .infinity) == nil)
    }

    /// Persisted configs from before WS-M1 have none of the new keys — they must
    /// decode with nils, not fail.
    @Test func legacyServerConfigJSONDecodes() throws {
        let legacy = """
            {"model":"m","host":"127.0.0.1","port":8080,"trustRemoteCode":false,
             "useDefaultChatTemplate":false,"chatTemplate":"","adapterPath":"",
             "extraArguments":""}
            """
        let config = try JSONDecoder().decode(MLXServerConfig.self, from: Data(legacy.utf8))
        #expect(config.reasoning == nil)
        #expect(config.promptCacheSize == nil)
        #expect(config.promptCacheBytes == nil)
    }
}

@Suite("MLX reasoning absorb migration (WS-M1)")
struct MLXReasoningAbsorbTests {

    private func config(extras: String, reasoning: Bool? = nil) -> MLXServerConfig {
        var config = MLXServerConfig()
        config.model = "m"
        config.extraArguments = extras
        config.reasoning = reasoning
        return config
    }

    @Test func absorbsUnspacedForm() {
        let migrated = MLXCommand.absorbingReasoning(
            from: config(extras: "--chat-template-args {\"enable_thinking\":false}"))
        #expect(migrated.reasoning == false)
        #expect(migrated.extraArguments.isEmpty)
    }

    /// The owner's live server was launched with a SPACE inside the JSON — the
    /// whitespace split turns it into two tokens that must rejoin.
    @Test func absorbsSpacedForm() {
        let migrated = MLXCommand.absorbingReasoning(
            from: config(extras: "--chat-template-args {\"enable_thinking\": false}"))
        #expect(migrated.reasoning == false)
        #expect(migrated.extraArguments.isEmpty)
    }

    @Test func absorbsEqualsFormAndKeepsNeighbors() {
        let migrated = MLXCommand.absorbingReasoning(
            from: config(
                extras: "--log-level DEBUG --chat-template-args={\"enable_thinking\":true} --pipeline"
            ))
        #expect(migrated.reasoning == true)
        #expect(migrated.extraArguments == "--log-level DEBUG --pipeline")
    }

    /// Richer JSON (other keys) is NOT ours to absorb — left untouched, and the
    /// trailing-extras rule keeps it winning over the toggle.
    @Test func leavesRicherJSONAlone() {
        let extras = "--chat-template-args {\"enable_thinking\":true,\"foo\":1}"
        let migrated = MLXCommand.absorbingReasoning(from: config(extras: extras))
        #expect(migrated.reasoning == nil)
        #expect(migrated.extraArguments == extras)
    }

    @Test func leavesUnrelatedExtrasAlone() {
        let migrated = MLXCommand.absorbingReasoning(from: config(extras: "--log-level DEBUG"))
        #expect(migrated.reasoning == nil)
        #expect(migrated.extraArguments == "--log-level DEBUG")
    }

    /// Already migrated (reasoning set): never touch extras again.
    @Test func idempotentOnceReasoningIsSet() {
        let extras = "--chat-template-args {\"enable_thinking\":false}"
        let migrated = MLXCommand.absorbingReasoning(
            from: config(extras: extras, reasoning: true))
        #expect(migrated.reasoning == true)
        #expect(migrated.extraArguments == extras)
    }
}

@Suite("MLX port/process diagnosis parsers (WS-M1)")
struct MLXDiagnosisParserTests {

    @Test func parsesLsofFieldOutput() {
        let output = "p843\ncLM Studio Helper\nf12\np1201\ncPython\nf9\n"
        let owners = MLXCommand.parsePortOwners(fromLsof: output)
        #expect(
            owners == [
                MLXCommand.PortOwner(pid: 843, command: "LM Studio Helper"),
                MLXCommand.PortOwner(pid: 1201, command: "Python"),
            ])
        #expect(MLXCommand.parsePortOwners(fromLsof: "").isEmpty)
    }

    @Test func conflictMessageExcludesOwnPIDs() {
        let owners = [
            MLXCommand.PortOwner(pid: 843, command: "LM Studio Helper"),
            MLXCommand.PortOwner(pid: 999, command: "Python"),
        ]
        let message = MLXCommand.portConflictMessage(port: 1337, owners: owners)
        #expect(message == "Port 1337 is held by LM Studio Helper (pid 843) — stop it there or change the port here.")

        // Our own server holding the port is NOT a conflict.
        #expect(
            MLXCommand.portConflictMessage(
                port: 1337, owners: [owners[1]], excludingPIDs: [999]) == nil)
        #expect(MLXCommand.portConflictMessage(port: 1337, owners: []) == nil)

        // Own pid excluded, foreign one still reported.
        let mixed = MLXCommand.portConflictMessage(
            port: 1337, owners: owners, excludingPIDs: [843])
        #expect(mixed?.contains("Python (pid 999)") == true)
    }

    @Test func parsesEtimeFormats() {
        #expect(MLXCommand.parseEtime("03:07") == 187)
        #expect(MLXCommand.parseEtime("01:02:03") == 3723)
        #expect(MLXCommand.parseEtime("2-01:02:03") == 176_523)
        #expect(MLXCommand.parseEtime("  00:42  ") == 42)
        #expect(MLXCommand.parseEtime("") == nil)
        #expect(MLXCommand.parseEtime("42") == nil)
        #expect(MLXCommand.parseEtime("junk") == nil)
    }

    @Test func parsesPSStats() throws {
        let stats = try #require(MLXCommand.parseProcessStats(fromPS: " 15234416   01:02:03 \n"))
        #expect(stats.rssBytes == Int64(15_234_416) * 1024)
        #expect(stats.elapsed == 3723)
        #expect(MLXCommand.parseProcessStats(fromPS: "") == nil)
        #expect(MLXCommand.parseProcessStats(fromPS: "notanumber 01:02") == nil)
    }

    @Test func parsesLaunchdPrintPID() {
        let output = """
            chat.eldr.mlx-server = {
                active count = 1
                path = /Users/x/Library/LaunchAgents/chat.eldr.mlx-server.plist
                state = running

                program = /venv/bin/python3
                pid = 54321
            }
            """
        #expect(MLXCommand.parseLaunchdPID(fromPrint: output) == 54321)
        #expect(MLXCommand.parseLaunchdPID(fromPrint: "state = not running") == nil)
    }
}

@Suite("MLX brain swap (WS-M1)")
struct MLXBrainSwapTests {

    @MainActor
    private struct Fixture {
        let service: MLXService
        let store: ConfigurationStore
        let defaults: UserDefaults
        let paths: ConfigPaths
        let cleanup: () -> Void

        init() throws {
            let tmp = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("eldr-mlx-brain-\(UUID().uuidString)")
            let suite = "mlx-brain-\(UUID().uuidString)"
            let localPaths = ConfigPaths(configDir: tmp, binDir: tmp)
            let localDefaults = try #require(UserDefaults(suiteName: suite))
            let keychain = KeychainBox(service: "test-mlx-brain-\(UUID().uuidString)")
            paths = localPaths
            defaults = localDefaults
            store = ConfigurationStore(paths: localPaths, keychain: keychain)
            service = MLXService(paths: localPaths, defaults: localDefaults, launchAgentsDir: tmp)
            cleanup = {
                keychain.delete(account: "llm-token")
                localDefaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(atPath: tmp)
            }
        }
    }

    /// A bad model fails the swap BEFORE any server/state/backend change.
    @MainActor
    @Test func invalidModelFailsFastWithoutSideEffects() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service
        let urlBefore = fixture.store.llmURL

        // Force env "ready" via the fake python so validation is the gate under test.
        let binDir = (service.venvDir as NSString).appendingPathComponent("bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try "#!/bin/zsh\necho \"0.0.0-test\"\n".write(
            toFile: service.venvPython, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: service.venvPython)
        await service.refreshEnvironment()

        await service.makeBrain(model: "not a repo id", store: fixture.store)
        guard case .failed(let why) = service.brainSwap else {
            Issue.record("expected .failed, got \(service.brainSwap)")
            return
        }
        #expect(why.contains("isn't a Hugging Face model id"))
        #expect(service.serverState == .stopped)
        #expect(fixture.store.llmURL == urlBefore)
    }

    /// The kill-switch wins: no swap while Huginn isn't managing the server.
    @MainActor
    @Test func refusesWhileUnmanaged() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service

        await service.setManagesServer(false, store: fixture.store)
        let urlBefore = fixture.store.llmURL
        await service.makeBrain(model: "mlx-community/Tiny", store: fixture.store)
        guard case .failed(let why) = service.brainSwap else {
            Issue.record("expected .failed, got \(service.brainSwap)")
            return
        }
        #expect(why.contains("manages the model server"))
        #expect(fixture.store.llmURL == urlBefore)

        service.clearBrainSwapNote()
        #expect(service.brainSwap == .idle)
    }

    /// Missing environment is reported as such (after the managed gate, before
    /// model validation).
    @MainActor
    @Test func missingEnvironmentFailsFast() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        await fixture.service.makeBrain(model: "mlx-community/Tiny", store: fixture.store)
        guard case .failed(let why) = fixture.service.brainSwap else {
            Issue.record("expected .failed, got \(fixture.service.brainSwap)")
            return
        }
        #expect(why.contains("MLX environment"))
    }

    /// A hand-typed `--chat-template-args {"enable_thinking": false}` in the
    /// persisted config is absorbed into `reasoning` ON INIT, persisted, and not
    /// re-absorbed later (the exact flag the owner has been typing by hand).
    @MainActor
    @Test func initAbsorbsHandTypedReasoningAndPersists() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var legacy = MLXServerConfig()
        legacy.model = "lmstudio-community/Qwen3.6-27B-MLX-4bit"
        legacy.port = 1337
        legacy.extraArguments = "--chat-template-args {\"enable_thinking\": false}"
        fixture.defaults.set(try JSONEncoder().encode(legacy), forKey: "mlx.serverConfig")

        let service = MLXService(
            paths: fixture.paths, defaults: fixture.defaults,
            launchAgentsDir: fixture.paths.configDir)
        #expect(service.serverConfig.reasoning == false)
        #expect(service.serverConfig.extraArguments.isEmpty)
        #expect(service.serverConfig.model == legacy.model)

        // And the migrated form is what's now on disk.
        let persisted = fixture.defaults.data(forKey: "mlx.serverConfig")
            .flatMap { try? JSONDecoder().decode(MLXServerConfig.self, from: $0) }
        #expect(persisted?.reasoning == false)
        #expect(persisted?.extraArguments.isEmpty == true)
    }
}

// WS-M3 — model library polish. Fixtures are REAL output captured on this Mac:
// the tqdm frames are exactly what `huggingface_hub` 1.24.0 emits through the
// app's non-TTY pipe (a FILE-COUNT bar; per-file byte bars are suppressed off a
// TTY), and the tags/config/tree JSON are from the live HF API + cached configs.

@Suite("MLX download-progress parser (WS-M3)")
struct MLXDownloadProgressParserTests {

    /// Round the fraction to an integer percent — avoids Double-equality flake and
    /// the AC116 macro type-inference trap.
    private func percent(_ progress: MLXDownloadProgress?) -> Int? {
        progress.map { Int(($0.fraction * 100).rounded()) }
    }

    @Test func parsesRealFetchingFilesFrames() throws {
        // The opening frame: 0%, rate is "?it/s" (no number) ⇒ no rate token.
        let zero = try #require(
            MLXCommand.parseTqdmProgress(
                "Fetching 10 files:   0%|          | 0/10 [00:00<?, ?it/s]"))
        #expect(percent(zero) == 0)
        #expect(zero.caption == "Fetching 10 files")

        // it/s rate variant.
        let ten = try #require(
            MLXCommand.parseTqdmProgress(
                "Fetching 10 files:  10%|█         | 1/10 [00:00<00:04,  2.06it/s]"))
        #expect(percent(ten) == 10)
        #expect(ten.caption == "Fetching 10 files · 2.06it/s")

        // s/it rate variant.
        let fifty = try #require(
            MLXCommand.parseTqdmProgress(
                "Fetching 10 files:  50%|█████     | 5/10 [00:15<00:16,  3.24s/it]"))
        #expect(percent(fifty) == 50)
        #expect(fifty.caption == "Fetching 10 files · 3.24s/it")

        let done = try #require(
            MLXCommand.parseTqdmProgress(
                "Fetching 10 files: 100%|██████████| 10/10 [00:15<00:00,  1.54s/it]"))
        #expect(percent(done) == 100)
        #expect(done.caption == "Fetching 10 files · 1.54s/it")
    }

    /// The unauth Warning concatenates onto the 0% frame with no `\r` before it, so
    /// the buffer commits them as one line — the parser must still read the leading
    /// bar and ignore the trailing prose.
    @Test func parsesFrameWithTrailingWarningJunk() throws {
        let line =
            "Fetching 10 files:   0%|          | 0/10 [00:00<?, ?it/s]Warning: You are sending "
            + "unauthenticated requests to the HF Hub. Please set a HF_TOKEN to enable higher "
            + "rate limits and faster downloads."
        let parsed = try #require(MLXCommand.parseTqdmProgress(line))
        #expect(percent(parsed) == 0)
        #expect(parsed.caption == "Fetching 10 files")
    }

    /// Robustness for a per-file byte bar, should one ever appear (MB/s rate).
    @Test func parsesByteBarWithRate() throws {
        let parsed = try #require(
            MLXCommand.parseTqdmProgress(
                "model.safetensors:  45%|████      | 120M/269M [00:03<00:04, 40.0MB/s]"))
        #expect(percent(parsed) == 45)
        #expect(parsed.caption == "model.safetensors · 40.0MB/s")
    }

    @Test func rejectsNonProgressLines() {
        // No bar pipe ⇒ a bare "50%" in prose must not false-match.
        #expect(MLXCommand.parseTqdmProgress("Download is 50% done") == nil)
        #expect(MLXCommand.parseTqdmProgress("") == nil)
        #expect(
            MLXCommand.parseTqdmProgress(
                "Traceback (most recent call last):") == nil)
        #expect(
            MLXCommand.parseTqdmProgress(
                "RepositoryNotFoundError: 401 Client Error.") == nil)
    }

    @Test func clampsImpossiblePercent() {
        // A malformed 3-digit percent above 100 is rejected (not a real tqdm line).
        #expect(MLXCommand.parseTqdmProgress("x: 250%|##| 1/1 [00:00, 1it/s]") == nil)
    }

    /// The service picks the newest frame from the log tail (the wiring behind the
    /// determinate ProgressView), pure and subprocess-free.
    @Test func latestProgressPicksNewestFrameFromTail() {
        #expect(MLXCommand.latestProgress(inLines: []) == nil)
        #expect(MLXCommand.latestProgress(inLines: ["starting…", "connecting"]) == nil)

        // Among the tail, the LAST (newest) parseable frame wins.
        let log = [
            "$ python -m mlx_lm ...",
            "Fetching 10 files:  50%|#####     | 5/10 [00:01<00:01,  3.24s/it]",
            "Fetching 10 files: 100%|##########| 10/10 [00:02<00:00,  1.54s/it]",
        ]
        let latest = MLXCommand.latestProgress(inLines: log)
        #expect(Int(((latest?.fraction ?? -1) * 100).rounded()) == 100)
        #expect(latest?.caption == "Fetching 10 files · 1.54s/it")

        // Only the last 6 lines are scanned — a frame older than that is ignored.
        let stale =
            ["Fetching 2 files: 100%|##| 2/2 [00:00<00:00, 1it/s]"]
            + (0..<6).map { "postprocess step \($0)" }
        #expect(MLXCommand.latestProgress(inLines: stale) == nil)
    }
}

@Suite("MLX format classifier (WS-M3)")
struct MLXFormatClassifierTests {

    @Test func mlxTagLoadsWithoutWarning() {
        let format = MLXCommand.classifyFormat(
            id: "lmstudio-community/Qwen3.6-27B-MLX-4bit",
            tags: ["transformers", "safetensors", "mlx", "4-bit", "region:us"])
        #expect(format == .mlx)
        #expect(format.advisory == nil)
        #expect(format.badge == nil)
        #expect(!format.isBlocking)
    }

    /// The exact cached UX-failure model: its id carries "NVFP4", so it's flagged
    /// as a hard cannot-load even though the tag set is generic compressed-tensors.
    @Test func nvfp4ByNameCannotLoad() {
        let realTags = [
            "transformers", "safetensors", "qwen3_5", "image-text-to-text", "unsloth", "qwen",
            "conversational", "compressed-tensors", "region:us",
        ]
        let format = MLXCommand.classifyFormat(id: "unsloth/Qwen3.6-27B-NVFP4", tags: realTags)
        #expect(format.isBlocking)
        #expect(format.badge == "can't load")
        #expect(format.advisory?.contains("NVFP4") == true)
    }

    @Test func ggufCannotLoadByTagOrName() {
        let byTag = MLXCommand.classifyFormat(
            id: "bartowski/Some-Model", tags: ["gguf", "transformers"])
        #expect(byTag.isBlocking)
        #expect(byTag.advisory?.contains("GGUF") == true)

        let byName = MLXCommand.classifyFormat(id: "TheBloke/Model-GGUF", tags: ["transformers"])
        #expect(byName.isBlocking)
    }

    /// A plain non-MLX safetensors model (no gguf/nvfp4 signal) is the softer
    /// "not an MLX build" caution, not a hard cannot-load.
    @Test func plainNonMLXIsNotMLXBuild() {
        let format = MLXCommand.classifyFormat(
            id: "meta-llama/Llama-3-8B-Instruct",
            tags: ["transformers", "safetensors", "llama"])
        #expect(format == .notMLXBuild)
        #expect(!format.isBlocking)
        #expect(format.badge == "not MLX")
        #expect(format.advisory?.contains("Not a pre-built MLX model") == true)
    }

    @Test func hubModelExposesFormat() {
        let mlx = MLXHubModel(
            id: "mlx-community/X", downloads: 1, likes: 1, lastModified: nil,
            tags: ["mlx", "4-bit"])
        #expect(mlx.format == .mlx)
        let gguf = MLXHubModel(
            id: "x/y-GGUF", downloads: 1, likes: 1, lastModified: nil, tags: ["gguf"])
        #expect(gguf.format.isBlocking)
    }
}

@Suite("MLX disk guard + tree size (WS-M3)")
struct MLXDiskGuardTests {

    private let gib: Int64 = 1 << 30

    @Test func okWhenRoomToSpare() {
        #expect(
            MLXCommand.downloadDiskGuard(freeBytes: 100 * gib, estimatedBytes: 15 * gib) == .ok)
    }

    @Test func blocksWhenClearlyInsufficient() {
        // required = 10 GiB + max(2 GiB, 1 GiB) = 12 GiB; 11 GiB free < 12 ⇒ block.
        let verdict = MLXCommand.downloadDiskGuard(freeBytes: 11 * gib, estimatedBytes: 10 * gib)
        guard case .block(let message) = verdict else {
            Issue.record("expected .block, got \(verdict)")
            return
        }
        #expect(message.contains("Free up space"))
        // Just enough room clears it.
        #expect(
            MLXCommand.downloadDiskGuard(freeBytes: 20 * gib, estimatedBytes: 10 * gib) == .ok)
    }

    @Test func unknownSizeWarnsOnlyWhenCriticallyLow() {
        guard case .warn = MLXCommand.downloadDiskGuard(freeBytes: 3 * gib, estimatedBytes: nil)
        else {
            Issue.record("expected .warn when size unknown and disk low")
            return
        }
        // Plenty free + unknown size ⇒ proceed silently.
        #expect(MLXCommand.downloadDiskGuard(freeBytes: 50 * gib, estimatedBytes: nil) == .ok)
        // Zero/absurd size is treated as unknown, not "0 bytes needed".
        #expect(MLXCommand.downloadDiskGuard(freeBytes: 50 * gib, estimatedBytes: 0) == .ok)
    }

    /// Our own measurement failing (nil free) must never block the user.
    @Test func nilFreeNeverBlocks() {
        #expect(MLXCommand.downloadDiskGuard(freeBytes: nil, estimatedBytes: 999 * gib) == .ok)
    }

    /// An absurd/hostile size must BLOCK (won't fit any disk), never overflow-trap.
    @Test func enormousSizeBlocksWithoutTrapping() {
        #expect(MLXCommand.downloadDiskGuard(freeBytes: 100 * gib, estimatedBytes: .max) != .ok)
        // A tree summing past Int64.max clamps to .max (⇒ the guard blocks it).
        let huge = """
            [{"type":"file","path":"a","size":9223372036854775807},
             {"type":"file","path":"b","size":9223372036854775807}]
            """
        #expect(MLXCommand.sumTreeDownloadBytes(fromJSON: Data(huge.utf8)) == Int64.max)
    }

    @Test func sumsRealTreeJSON() throws {
        // Real HF tree shape: `size` already equals `lfs.size`; directories skipped.
        let json = """
            [{"type":"file","path":".gitattributes","size":1519,"lfs":null},
             {"type":"file","path":"config.json","size":944,"lfs":null},
             {"type":"file","path":"model.safetensors","size":269060381,
              "lfs":{"oid":"989e","size":269060381,"pointerSize":134}},
             {"type":"directory","path":"snapshots","size":0}]
            """
        let total = try #require(MLXCommand.sumTreeDownloadBytes(fromJSON: Data(json.utf8)))
        #expect(total == Int64(1519 + 944 + 269_060_381))

        // No files ⇒ nil (size unknown), not 0.
        #expect(
            MLXCommand.sumTreeDownloadBytes(
                fromJSON: Data("[{\"type\":\"directory\",\"path\":\"d\"}]".utf8)) == nil)
        #expect(MLXCommand.sumTreeDownloadBytes(fromJSON: Data("not json".utf8)) == nil)
    }

    @Test func treeURLValidatesRepoID() {
        #expect(MLXCommand.treeURL(repoID: "mlx-community/Tiny") != nil)
        #expect(MLXCommand.treeURL(repoID: "not a repo id") == nil)
    }
}

@Suite("MLX cache metadata (WS-M3)")
struct MLXCacheMetadataTests {

    @Test func quantLabelFromRealConfigs() {
        // The working MLX build's config.
        let mlx = """
            {"model_type":"qwen3_5","quantization":{"group_size":64,"bits":4,"mode":"affine"}}
            """
        #expect(MLXCommand.quantLabel(fromConfigJSON: Data(mlx.utf8)) == "4-bit")

        // The NVFP4 build's config (quant_method, no top-level quantization).
        let nvfp4 = """
            {"model_type":"qwen3_5","quantization_config":{"quant_method":"compressed-tensors",
             "format":"nvfp4"}}
            """
        #expect(
            MLXCommand.quantLabel(fromConfigJSON: Data(nvfp4.utf8)) == "compressed-tensors")

        // bits inside quantization_config wins over the method name.
        let awq = """
            {"quantization_config":{"quant_method":"awq","bits":8}}
            """
        #expect(MLXCommand.quantLabel(fromConfigJSON: Data(awq.utf8)) == "8-bit")

        // Nested text_config (multimodal) still resolves.
        let nested = """
            {"text_config":{"quantization_config":{"quant_method":"mxfp4"}}}
            """
        #expect(MLXCommand.quantLabel(fromConfigJSON: Data(nested.utf8)) == "mxfp4")

        // Full-precision ⇒ nil; garbage ⇒ nil.
        #expect(MLXCommand.quantLabel(fromConfigJSON: Data("{\"model_type\":\"llama\"}".utf8)) == nil)
        #expect(MLXCommand.quantLabel(fromConfigJSON: Data("nope".utf8)) == nil)
    }

    @Test func sortOrders() {
        let now = Date()
        let a = MLXCachedModel(
            repoID: "z/big", path: "/a", sizeBytes: 900, modified: nil,
            lastUsed: now.addingTimeInterval(-3600), quant: nil)
        let b = MLXCachedModel(
            repoID: "a/small", path: "/b", sizeBytes: 100, modified: nil,
            lastUsed: now, quant: nil)
        let c = MLXCachedModel(
            repoID: "m/mid", path: "/c", sizeBytes: 500, modified: nil,
            lastUsed: nil, quant: nil)
        let models = [c, b, a]

        #expect(MLXCommand.sortedModels(models, by: .largest).map(\.repoID) == ["z/big", "m/mid", "a/small"])
        #expect(MLXCommand.sortedModels(models, by: .name).map(\.repoID) == ["a/small", "m/mid", "z/big"])
        // Known-atime first (newest first), unknown-atime last.
        #expect(MLXCommand.sortedModels(models, by: .lastUsed).map(\.repoID) == ["a/small", "z/big", "m/mid"])
    }

    /// The scanner populates `quant` from a snapshot config.json and `lastUsed`
    /// from file atime (both new WS-M3 fields), in the same walk that sums size.
    @Test func scanReadsQuantAndLastUsed() throws {
        let fm = FileManager.default
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-mlx-meta-\(UUID().uuidString)")
        defer { try? fm.removeItem(atPath: root) }

        let entry = (root as NSString).appendingPathComponent("models--mlx-community--Q")
        let snap = (entry as NSString).appendingPathComponent("snapshots/abc")
        try fm.createDirectory(atPath: snap, withIntermediateDirectories: true)
        let configData = Data("{\"quantization\":{\"bits\":4}}".utf8)
        try configData.write(
            to: URL(fileURLWithPath: (snap as NSString).appendingPathComponent("config.json")))
        // Weight-class file (≥ 1 MiB): the ONLY thing "last used" may read from —
        // small metadata's atime is bumped by the scan itself (the quantLabel
        // read), which would turn "last used" into "last refreshed".
        let weightCount = (1 << 20) + 1
        try Data(repeating: 7, count: weightCount).write(
            to: URL(fileURLWithPath: (snap as NSString).appendingPathComponent("model.safetensors")))

        // A second cached model with ONLY small files must report no "last used".
        let smallEntry = (root as NSString).appendingPathComponent("models--x--SmallOnly")
        let smallSnap = (smallEntry as NSString).appendingPathComponent("snapshots/def")
        try fm.createDirectory(atPath: smallSnap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: URL(fileURLWithPath: (smallSnap as NSString).appendingPathComponent("config.json")))

        let models = HFCache.scanModels(cacheDir: root)
        #expect(models.count == 2)
        let model = try #require(models.first { $0.repoID == "mlx-community/Q" })
        #expect(model.quant == "4-bit")
        // The weight file was just written, so its atime is present on this volume.
        #expect(model.lastUsed != nil)
        #expect(model.sizeBytes == Int64(weightCount + configData.count))
        let smallOnly = try #require(models.first { $0.repoID == "x/SmallOnly" })
        #expect(smallOnly.lastUsed == nil)
    }
}

// WS-M4 — teachable fine-tune. Loss fixtures are the REAL ANSI-colored rich
// output captured from a live `mlx_lm lora` 0.31.3 run through a pipe (its
// trainer emits color even off a TTY); the plan's `Iter N: Train loss …` format
// is stale. \u{1B} = ESC, \u{25BC}/\u{25B2} = the ▼/▲ trend arrows.

@Suite("MLX loss parser (WS-M4)")
struct MLXLossParserTests {

    @Test func stripsANSIEscapes() {
        let line = "\u{1B}[38;5;244m   5\u{1B}[0m    \u{1B}[1;32m3.459 \u{25BC}\u{1B}[0m"
        #expect(MLXCommand.stripANSI(line) == "   5    3.459 \u{25BC}")
        // No ESC → returned unchanged (fast path); box-art unicode is left intact.
        #expect(MLXCommand.stripANSI("plain line") == "plain line")
    }

    @Test func parsesRealTrainValSaveLines() {
        let valLine =
            "  \u{1B}[38;5;244m   1\u{1B}[0m    \u{1B}[1;35mval\u{1B}[0m \u{1B}[1m4.073\u{1B}[0m    \u{1B}[38;5;244m0.53s\u{1B}[0m"
        #expect(MLXCommand.parseLossLine(valLine) == .val(iter: 1, loss: 4.073))

        let trainDown =
            "  \u{1B}[38;5;244m   5\u{1B}[0m    \u{1B}[1;32m3.459 \u{25BC}\u{1B}[0m    \u{1B}[1m  191\u{1B}[0m    \u{1B}[38;5;244m  0.5k\u{1B}[0m"
        #expect(MLXCommand.parseLossLine(trainDown) == .train(iter: 5, loss: 3.459))

        // ▲ (loss went up) still parses as a train row.
        let trainUp =
            "  \u{1B}[38;5;244m  30\u{1B}[0m    \u{1B}[1;33m0.186 \u{25B2}\u{1B}[0m    \u{1B}[1m4,331\u{1B}[0m"
        #expect(MLXCommand.parseLossLine(trainUp) == .train(iter: 30, loss: 0.186))

        let saveLine =
            "  \u{1B}[1;32msave\u{1B}[0m  \u{1B}[38;5;244m0000010_adapters.safetensors\u{1B}[0m"
        #expect(
            MLXCommand.parseLossLine(saveLine) == .save(checkpoint: "0000010_adapters.safetensors"))
    }

    @Test func rejectsNonLossLines() {
        #expect(MLXCommand.parseLossLine("Loading pretrained model") == nil)
        #expect(MLXCommand.parseLossLine("  iter   train_loss     tok/s     tokens") == nil)
        #expect(
            MLXCommand.parseLossLine("Trainable parameters: 0.242% (0.326M/134.515M)") == nil)
        #expect(MLXCommand.parseLossLine("") == nil)
    }

    @Test func buildsHistoryAndDedupesCheckpoints() {
        let lines = [
            "  \u{1B}[38;5;244m   1\u{1B}[0m    \u{1B}[1;35mval\u{1B}[0m \u{1B}[1m4.073\u{1B}[0m    0.53s",
            "   5    3.459 \u{25BC}    191    0.5k",
            "  save  0000010_adapters.safetensors",
            "  save  0000010_adapters.safetensors",  // a re-parse must not double it
            "  10    val 0.803    0.05s",
        ]
        let history = MLXCommand.parseLossHistory(fromLines: lines)
        #expect(history.train.map(\.iter) == [5])
        #expect(history.val.map(\.iter) == [1, 10])
        #expect(history.val.map(\.loss) == [4.073, 0.803])
        #expect(history.checkpoints == ["0000010_adapters.safetensors"])
    }

    @Test func trendReadsDirection() {
        var history = MLXLossHistory()
        history.val = [MLXLossPoint(iter: 1, loss: 4.0), MLXLossPoint(iter: 10, loss: 0.5)]
        #expect(MLXCommand.lossTrend(history).contains("learning"))
        history.val = [MLXLossPoint(iter: 1, loss: 0.2), MLXLossPoint(iter: 10, loss: 0.9)]
        #expect(MLXCommand.lossTrend(history).lowercased().contains("rising"))
        history.val = [MLXLossPoint(iter: 1, loss: 0.50), MLXLossPoint(iter: 10, loss: 0.49)]
        #expect(MLXCommand.lossTrend(history).lowercased().contains("flat"))
        #expect(MLXCommand.lossTrend(MLXLossHistory()).contains("Waiting"))
    }
}

@Suite("MLX fine-tune presets + YAML (WS-M4)")
struct MLXFineTunePresetTests {

    @Test func presetsApplyKnobsAndKeepIdentity() {
        var base = MLXFineTuneConfig()
        base.model = "m"
        base.dataDir = "/d"
        base.fineTuneType = "dora"
        base.loraRank = 16
        let quick = MLXFineTunePreset.quickTest.applied(to: base)
        #expect(quick.iters == 100 && quick.batchSize == 2 && quick.numLayers == 8)
        // Identity fields (model / data / type / rank) are untouched by the preset.
        #expect(quick.model == "m" && quick.dataDir == "/d")
        #expect(quick.fineTuneType == "dora" && quick.loraRank == 16)
        let thorough = MLXFineTunePreset.thorough.applied(to: base)
        #expect(thorough.iters == 1500 && thorough.numLayers == 32)
    }

    @Test func yamlEmitsNewKeysAndSkipsLoraForFull() {
        var config = MLXFineTuneConfig()
        config.model = "m"
        config.dataDir = "/d"
        config.adapterPath = "/a"
        config.saveEvery = 50
        config.valEvery = 25
        config.maxSeqLength = 1024
        config.gradCheckpoint = true
        let yaml = MLXCommand.loraConfigYAML(config)
        // Line-structure (not just substring) — YAML is indentation-sensitive and
        // each key must be on its OWN unindented line (guards the multiline
        // trailing-newline / concatenation trap the plain contains-checks miss).
        #expect(yaml.contains("\nmodel: "))  // top-level, no leading indent
        #expect(yaml.contains("\nsave_every: 50\n"))
        #expect(yaml.contains("\nsteps_per_eval: 25\n"))
        #expect(yaml.contains("\nmax_seq_length: 1024\n"))
        #expect(yaml.contains("grad_checkpoint: true\n"))
        #expect(yaml.contains("\nlora_parameters:\n"))
        #expect(yaml.contains("\n  rank: 8\n"))  // indented 2 under lora_parameters

        // Full fine-tuning omits the LoRA-only block (there's nothing to configure).
        config.fineTuneType = "full"
        let fullYAML = MLXCommand.loraConfigYAML(config)
        #expect(!fullYAML.contains("lora_parameters:"))
        #expect(fullYAML.contains("fine_tune_type: full"))
    }
}

@Suite("MLX dataset assistant (WS-M4)")
struct MLXDatasetAssistantTests {

    @Test func detectsFormatsWithMLXPrecedence() {
        let comp = """
            {"prompt":"a","completion":"b"}
            {"prompt":"c","completion":"d"}
            """
        let r1 = MLXCommand.validateDataset(Data(comp.utf8))
        #expect(r1.format == .completions && r1.recordCount == 2 && r1.ok)

        #expect(
            MLXCommand.validateDataset(
                Data("{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}".utf8)).format == .chat
        )
        #expect(MLXCommand.validateDataset(Data("{\"text\":\"hello\"}".utf8)).format == .text)

        // Precedence: prompt+completion wins even when `text` is also present.
        #expect(
            MLXCommand.validateDataset(
                Data("{\"prompt\":\"a\",\"completion\":\"b\",\"text\":\"c\"}".utf8)).format
                == .completions)
    }

    @Test func reportsErrorsByLineAndKindOnly() {
        let data = """
            {"prompt":"secret","completion":"b"}
            notjson
            {"foo":1}
            """
        let report = MLXCommand.validateDataset(Data(data.utf8))
        #expect(report.recordCount == 1)
        #expect(report.errors.count == 2)
        #expect(report.errors[0] == MLXDatasetError(line: 2, kind: "not a JSON object"))
        #expect(report.errors[1].line == 3)
        // Privacy (inv. 12 / SPEC §0): no record CONTENT leaks — the bad records'
        // bodies never appear in an error kind (only line numbers + fixed kinds).
        #expect(
            !report.errors.contains {
                $0.kind.contains("secret") || $0.kind.contains("notjson") || $0.kind.contains("foo")
            })
    }

    @Test func splitAndCSVBuilder() {
        let records = (0..<10).map { "{\"prompt\":\"p\($0)\",\"completion\":\"c\($0)\"}" }
        let split = MLXCommand.splitJSONL(records, validFraction: 0.2)
        #expect(split.train.count == 8 && split.valid.count == 2)
        #expect(split.valid == Array(records[8...]))  // validation from the tail

        // CSV with a header row + a quoted field containing a comma.
        let csv = """
            prompt,completion
            Hello,"Bonjour, ami"
            Bye,Au revoir
            """
        let built = MLXCommand.completionsFromCSV(csv)
        #expect(built.records.count == 2)  // header skipped
        #expect(built.skippedRows == 0)
        #expect(built.records[0].contains("Bonjour, ami"))
        // Each built row is valid JSON with the right keys.
        let obj =
            try? JSONSerialization.jsonObject(with: Data(built.records[0].utf8))
            as? [String: String]
        #expect(obj?["prompt"] == "Hello")
        #expect(obj?["completion"] == "Bonjour, ami")
    }

    @Test func templatesAreValidJSON() {
        for format in [MLXDatasetFormat.completions, .chat, .text] {
            let firstLine =
                MLXCommand.datasetTemplate(format).split(separator: "\n").first.map(String.init) ?? ""
            #expect((try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) != nil)
        }
    }
}

@Suite("MLX memory preflight (WS-M4)")
struct MLXMemoryPreflightTests {

    private let gib: Int64 = 1 << 30

    @Test func estimateScalesWithTypeAndIsOverflowSafe() {
        let base = 10 * gib
        let lora = MLXCommand.estimateTrainingPeakBytes(baseModelBytes: base, fineTuneType: "lora")
        let full = MLXCommand.estimateTrainingPeakBytes(baseModelBytes: base, fineTuneType: "full")
        let loraPeak = try? #require(lora)
        let fullPeak = try? #require(full)
        #expect((loraPeak ?? 0) > 0 && (fullPeak ?? 0) > (loraPeak ?? 0))
        // Unknown / zero base ⇒ nil (verdict then says "unknown").
        #expect(MLXCommand.estimateTrainingPeakBytes(baseModelBytes: nil, fineTuneType: "lora") == nil)
        #expect(MLXCommand.estimateTrainingPeakBytes(baseModelBytes: 0, fineTuneType: "lora") == nil)
        // Absurd base clamps to .max, never traps (AC116/AC118 discipline).
        #expect(
            MLXCommand.estimateTrainingPeakBytes(baseModelBytes: .max, fineTuneType: "full") == .max)
    }

    @Test func verdictBuckets() {
        #expect(
            MLXCommand.memoryVerdict(availableBytes: 64 * gib, estimatedPeakBytes: 10 * gib).level
                == .comfortable)
        #expect(
            MLXCommand.memoryVerdict(availableBytes: 12 * gib, estimatedPeakBytes: 10 * gib).level
                == .tight)
        #expect(
            MLXCommand.memoryVerdict(availableBytes: 8 * gib, estimatedPeakBytes: 10 * gib).level
                == .risky)
        #expect(
            MLXCommand.memoryVerdict(availableBytes: nil, estimatedPeakBytes: 10 * gib).level
                == .unknown)
        #expect(
            MLXCommand.memoryVerdict(availableBytes: 64 * gib, estimatedPeakBytes: nil).level
                == .unknown)
        // Every non-unknown message is hedged as an estimate.
        #expect(
            MLXCommand.memoryVerdict(availableBytes: 64 * gib, estimatedPeakBytes: 10 * gib)
                .message.contains("Estimate"))
    }
}

// Review-pass fixes over WS-M3/WS-M4 (AC120): CRLF honesty, skipped-row counts,
// the overfit-turnaround trend, and the bounded validation sample.

@Suite("MLX review-pass fixes (WS-M3/M4)")
struct MLXReviewFixTests {

    /// CRLF (Excel-style) CSVs: without trimming newlines, the header goes
    /// unrecognized and every completion is baked with a trailing \r.
    @Test func csvHandlesCRLFAndCountsSkippedRows() throws {
        let csv = "prompt,completion\r\nHello,World\r\nonly-one-column\r\n"
        let built = MLXCommand.completionsFromCSV(csv)
        #expect(built.records.count == 1)  // header skipped, bad row counted
        #expect(built.skippedRows == 1)
        let obj = try #require(
            (try? JSONSerialization.jsonObject(with: Data(built.records[0].utf8)))
                as? [String: String])
        #expect(obj["prompt"] == "Hello")
        #expect(obj["completion"] == "World")  // no trailing \r
    }

    @Test func validatorAndSplitterHandleCRLF() {
        let crlf = "{\"text\":\"a\"}\r\n{\"text\":\"b\"}\r\n"
        let report = MLXCommand.validateDataset(Data(crlf.utf8))
        #expect(report.recordCount == 2)
        #expect(report.ok)
        let split = MLXCommand.splitJSONL(["{\"text\":\"a\"}\r", "{\"text\":\"b\"}\r"])
        #expect(split.train == ["{\"text\":\"a\"}"])
        #expect(split.valid == ["{\"text\":\"b\"}"])
    }

    /// A val curve that bottoms out and climbs again must be called overfitting
    /// (naming the best iter), not "learning" off a first-vs-last comparison.
    @Test func trendFlagsOverfitTurnaround() {
        var history = MLXLossHistory()
        history.val = [
            MLXLossPoint(iter: 1, loss: 4.0), MLXLossPoint(iter: 10, loss: 0.5),
            MLXLossPoint(iter: 20, loss: 0.9),
        ]
        let trend = MLXCommand.lossTrend(history)
        #expect(trend.contains("overfitting"))
        #expect(trend.contains("iter 10"))
        // A still-falling curve keeps the plain "learning" read.
        history.val = [
            MLXLossPoint(iter: 1, loss: 4.0), MLXLossPoint(iter: 10, loss: 1.0),
            MLXLossPoint(iter: 20, loss: 0.5),
        ]
        #expect(MLXCommand.lossTrend(history).contains("learning"))
    }

    /// The validation sample is read bounded (a picked train.jsonl can be GBs) and
    /// cut at a whole line so truncation can't fake a corrupt record.
    @Test func boundedSampleCutsAtWholeLines() throws {
        let fm = FileManager.default
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("eldr-sample-\(UUID().uuidString).jsonl")
        defer { try? fm.removeItem(atPath: path) }
        try Data("aaa\nbbb\nccc\n".utf8).write(to: URL(fileURLWithPath: path))

        let full = try #require(MLXCommand.boundedSample(fileAt: path, limit: 64))
        #expect(full.truncated == false)
        #expect(full.data == Data("aaa\nbbb\nccc\n".utf8))

        let cut = try #require(MLXCommand.boundedSample(fileAt: path, limit: 7))
        #expect(cut.truncated)
        #expect(cut.data == Data("aaa\n".utf8))  // whole lines only

        #expect(MLXCommand.boundedSample(fileAt: path + ".missing") == nil)
    }
}
