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
