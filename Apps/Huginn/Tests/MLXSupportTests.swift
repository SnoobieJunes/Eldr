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
