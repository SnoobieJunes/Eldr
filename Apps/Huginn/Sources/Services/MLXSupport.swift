import Foundation

// Pure, process-free MLX logic: command-line construction for every `mlx_lm`
// subcommand the MLX tab drives, the Hugging Face cache scanner, the launchd
// plist, and the terminal-output line buffer. Everything here is deterministic
// and unit-tested (MLXSupportTests); MLXService owns the actual subprocesses.

// MARK: - Configurations

/// Everything `mlx_lm.server` can be told from the GUI. The nil/empty optionals
/// are OMITTED from the command line: the sampling-default flags (`--temp`,
/// `--top-p`, `--max-tokens`) only exist on recent mlx-lm versions, so an unset
/// field must not break an older install. Persisted by MLXService (UserDefaults —
/// a Huginn-only pref, not an eldr-acp env var, same rationale as
/// `sybilclawGatewayPort`).
struct MLXServerConfig: Equatable, Codable, Sendable {
    /// HF repo id (`mlx-community/…`) or a local model folder path. A repo id the
    /// cache doesn't hold yet is downloaded by the server at startup.
    var model: String = ""
    var host: String = "127.0.0.1"
    var port: Int = 8080
    /// Request-default sampling knobs (recent mlx-lm only; omitted when nil).
    var maxTokens: Int?
    var temperature: Double?
    var topP: Double?
    var trustRemoteCode: Bool = false
    var useDefaultChatTemplate: Bool = false
    /// Jinja chat-template override, passed verbatim to `--chat-template`.
    var chatTemplate: String = ""
    var adapterPath: String = ""
    /// Free-form extra args, whitespace-split (no shell quoting — documented in the UI).
    var extraArguments: String = ""
    /// WS-M1 reasoning ("thinking") toggle: nil = model default (flag omitted);
    /// true/false emits `--chat-template-args {"enable_thinking":…}`. Replaces the
    /// hand-typed Extra-arguments JSON (absorbed once by `absorbingReasoning`).
    var reasoning: Bool?
    /// WS-M1 server-side KV/prompt-cache bounds. These are the cache knobs
    /// `mlx_lm.server` actually has (verified against 0.31.3 — the `--kv-bits`
    /// quantization family is generate-only); omitted when nil.
    var promptCacheSize: Int?
    var promptCacheBytes: Int64?

    /// `0.0.0.0` means "listen on everything" — clients (health probe, the agent)
    /// still connect via loopback.
    var probeHost: String {
        (host == "0.0.0.0" || host.isEmpty) ? "127.0.0.1" : host
    }
    /// The OpenAI-compatible base URL the existing `LLMClient` seam consumes.
    var baseURL: String { "http://\(probeHost):\(port)/v1" }
}

struct MLXGenerateConfig: Equatable, Sendable {
    var model: String = ""
    var prompt: String = ""
    var maxTokens: Int = 512
    var temperature: Double?
    var topP: Double?
    var adapterPath: String = ""
    /// WS-M1 KV-cache controls — `mlx_lm generate` is where the quantization
    /// family actually lives (the server has none of these; verified 0.31.3).
    /// `kvGroupSize`/`quantizedKVStart` are only meaningful (and only emitted)
    /// when `kvBits` is set.
    var kvBits: Int?
    var kvGroupSize: Int?
    var quantizedKVStart: Int?
    var maxKVSize: Int?
}

struct MLXConvertConfig: Equatable, Sendable {
    /// Source: HF repo id or local folder.
    var hfPath: String = ""
    /// Output folder (`--mlx-path`). mlx_lm errors if it already exists.
    var mlxPath: String = ""
    var quantize: Bool = true
    var qBits: Int = 4
    var qGroupSize: Int = 64
    /// "", "float16", "bfloat16", "float32" — "" = mlx_lm's default.
    var dtype: String = ""
    /// Optional `--upload-repo` (pushes the converted model to HF).
    var uploadRepo: String = ""
}

struct MLXFineTuneConfig: Equatable, Sendable {
    var model: String = ""
    /// Folder containing `train.jsonl` + `valid.jsonl` (mlx_lm.lora's layout).
    var dataDir: String = ""
    /// Where the trained adapters land (`adapter_path`).
    var adapterPath: String = ""
    /// lora | dora | full
    var fineTuneType: String = "lora"
    var numLayers: Int = 16
    var batchSize: Int = 4
    var iters: Int = 600
    var learningRate: Double = 1e-5
    var loraRank: Int = 8
    var loraScale: Double = 20.0
    var loraDropout: Double = 0.0
}

// MARK: - Model-library value types (WS-M3)

/// A parsed download-progress frame, as it appears in the job log. Through the
/// app's non-TTY pipe, `huggingface_hub` 1.24.0 emits a FILE-COUNT tqdm bar
/// (`Fetching N files: P%|…| x/N [elapsed<remaining, rate]`) — the per-file byte
/// bars are suppressed off a TTY (verified live). So `fraction` is files-based,
/// not bytes, and the caption keeps tqdm's own honest wording.
struct MLXDownloadProgress: Equatable, Sendable {
    /// 0…1 (percent/100).
    var fraction: Double
    /// Plain-language line, e.g. "Fetching 10 files · 3.24s/it".
    var caption: String
}

/// Whether `mlx_lm` can load a model of a given format — used to warn honestly on
/// non-MLX search results when the "MLX format only" filter is off (the NVFP4
/// lesson). Truth derived from the installed mlx-lm 0.31.3 loader: it needs
/// `model*.safetensors` (no GGUF path anywhere in generate/server/utils), and its
/// quant handling force-maps `compressed-tensors` to affine 4-bit — which can't
/// unpack NVFP4-packed weights.
enum MLXModelFormat: Equatable, Sendable {
    /// Tagged `mlx` — a ready MLX build; loads.
    case mlx
    /// A format mlx_lm genuinely cannot load (GGUF, NVFP4). Carries the reason.
    case cannotLoad(reason: String)
    /// Plain non-MLX safetensors: MIGHT load (fp16, awq, gptq, mxfp4) or might
    /// not (exotic quants), and always heavier than an MLX build.
    case notMLXBuild

    /// The user-facing advisory shown under the result (nil for MLX builds).
    var advisory: String? {
        switch self {
        case .mlx:
            return nil
        case .cannotLoad(let reason):
            return reason
        case .notMLXBuild:
            return
                "Not a pre-built MLX model. mlx_lm may fail to load it (some quantizations, e.g. NVFP4, aren't supported) or run it slower than an MLX build — prefer the mlx-community equivalent, or Convert it in Advanced."
        }
    }

    /// Short capsule label (nil for MLX builds).
    var badge: String? {
        switch self {
        case .mlx: return nil
        case .cannotLoad: return "can't load"
        case .notMLXBuild: return "not MLX"
        }
    }

    /// True only for formats that positively cannot load — a hard (red) warning
    /// vs the softer "not an MLX build" caution.
    var isBlocking: Bool {
        if case .cannotLoad = self { return true }
        return false
    }
}

/// The pre-download free-disk verdict — a pure decision so it's unit-testable; the
/// measurement (volume free bytes) and the size lookup (HF tree API) are the
/// impure edges in MLXService.
enum MLXDiskGuard: Equatable, Sendable {
    /// Enough room (or we can't tell and it isn't critically low) — proceed.
    case ok
    /// Proceed, but surface the caution (size unknown + low disk).
    case warn(String)
    /// Refuse: the model clearly won't fit.
    case block(String)
}

/// How the cached-model list is ordered — the "free up space" affordance defaults
/// to `.largest` so the biggest models to delete are on top.
enum MLXModelSort: String, CaseIterable, Sendable {
    case largest
    case lastUsed
    case name

    var label: String {
        switch self {
        case .largest: return "Largest"
        case .lastUsed: return "Recently used"
        case .name: return "Name"
        }
    }
}

// MARK: - Command construction

enum MLXCommand {

    /// Argument vector after the venv's python binary: `python -m mlx_lm server …`.
    /// `python -m` (not the console script) so the command works regardless of how
    /// the entry points were installed; the unified `mlx_lm <sub>` form because the
    /// old `mlx_lm.<sub>` module form prints a deprecation warning on every run
    /// (verified against mlx-lm 0.31.3 — all subcommands support the unified form).
    static func serverArguments(_ c: MLXServerConfig) -> [String] {
        var args = [
            "-m", "mlx_lm", "server",
            "--model", c.model,
            "--host", c.host,
            "--port", String(c.port),
        ]
        if let maxTokens = c.maxTokens { args += ["--max-tokens", String(maxTokens)] }
        if let temperature = c.temperature { args += ["--temp", formatNumber(temperature)] }
        if let topP = c.topP { args += ["--top-p", formatNumber(topP)] }
        if c.trustRemoteCode { args.append("--trust-remote-code") }
        if c.useDefaultChatTemplate { args.append("--use-default-chat-template") }
        // `=`-form: a template starting with "-" would otherwise be parsed as a flag.
        if !c.chatTemplate.isEmpty { args.append("--chat-template=\(c.chatTemplate)") }
        if !c.adapterPath.isEmpty { args += ["--adapter-path", c.adapterPath] }
        if let reasoning = c.reasoning {
            args += ["--chat-template-args", "{\"enable_thinking\":\(reasoning)}"]
        }
        if let promptCacheSize = c.promptCacheSize {
            args += ["--prompt-cache-size", String(promptCacheSize)]
        }
        if let promptCacheBytes = c.promptCacheBytes {
            args += ["--prompt-cache-bytes", String(promptCacheBytes)]
        }
        // Extras stay LAST: argparse takes the final occurrence of a repeated
        // flag, so a hand-typed duplicate keeps winning (documented in the UI).
        args += splitExtraArguments(c.extraArguments)
        return args
    }

    /// One-time migration for the WS-M1 reasoning toggle: if Extra arguments
    /// carries a `--chat-template-args` whose JSON is EXACTLY
    /// `{"enable_thinking": <bool>}` (the value the owner has been hand-typing),
    /// absorb it into the first-class `reasoning` field and strip the tokens.
    /// Anything richer (other keys, unparseable JSON) is left untouched — extras
    /// are emitted last, so a kept duplicate still wins over the toggle.
    static func absorbingReasoning(from config: MLXServerConfig) -> MLXServerConfig {
        guard config.reasoning == nil else { return config }
        var tokens = splitExtraArguments(config.extraArguments)
        for (index, token) in tokens.enumerated() {
            // (json, index of the last token the JSON spans)
            var candidates: [(json: String, consumedThrough: Int)] = []
            if token == "--chat-template-args" {
                // The JSON may have been split by whitespace ({"enable_thinking":
                // false} is two tokens) — rejoin progressively and try each span.
                var joined = ""
                for next in (index + 1)..<min(tokens.count, index + 9) {
                    joined = joined.isEmpty ? tokens[next] : joined + " " + tokens[next]
                    candidates.append((joined, next))
                }
            } else if token.hasPrefix("--chat-template-args=") {
                candidates = [
                    (String(token.dropFirst("--chat-template-args=".count)), index)
                ]
            } else {
                continue
            }
            for candidate in candidates {
                guard
                    let object = try? JSONSerialization.jsonObject(
                        with: Data(candidate.json.utf8)) as? [String: Any],
                    object.count == 1,
                    let value = object["enable_thinking"] as? Bool
                else { continue }
                var updated = config
                updated.reasoning = value
                tokens.removeSubrange(index...candidate.consumedThrough)
                updated.extraArguments = tokens.joined(separator: " ")
                return updated
            }
            return config  // flag present but not a pure enable_thinking object
        }
        return config
    }

    static func generateArguments(_ c: MLXGenerateConfig) -> [String] {
        var args = [
            "-m", "mlx_lm", "generate",
            "--model", c.model,
            // `=`-form: a prompt starting with "-" would otherwise be eaten by
            // argparse as a flag (and a bare "-" means "read stdin").
            "--prompt=\(c.prompt)",
            "--max-tokens", String(max(1, c.maxTokens)),
        ]
        if let temperature = c.temperature { args += ["--temp", formatNumber(temperature)] }
        if let topP = c.topP { args += ["--top-p", formatNumber(topP)] }
        if !c.adapterPath.isEmpty { args += ["--adapter-path", c.adapterPath] }
        if let maxKVSize = c.maxKVSize { args += ["--max-kv-size", String(maxKVSize)] }
        if let kvBits = c.kvBits {
            args += ["--kv-bits", String(kvBits)]
            // Group size / start only mean anything when quantization is on.
            if let kvGroupSize = c.kvGroupSize {
                args += ["--kv-group-size", String(kvGroupSize)]
            }
            if let quantizedKVStart = c.quantizedKVStart {
                args += ["--quantized-kv-start", String(quantizedKVStart)]
            }
        }
        return args
    }

    static func convertArguments(_ c: MLXConvertConfig) -> [String] {
        var args = [
            "-m", "mlx_lm", "convert",
            "--hf-path", c.hfPath,
            "--mlx-path", c.mlxPath,
        ]
        if c.quantize {
            args += ["-q", "--q-bits", String(c.qBits), "--q-group-size", String(c.qGroupSize)]
        }
        if !c.dtype.isEmpty { args += ["--dtype", c.dtype] }
        if !c.uploadRepo.isEmpty { args += ["--upload-repo", c.uploadRepo] }
        return args
    }

    /// Fine-tune runs off a generated `--config` YAML instead of flags: the LoRA
    /// rank/scale/dropout are config-only (`lora_parameters` has no CLI flag), and
    /// the config keys have been stable across the flag renames (`--lora-layers` →
    /// `--num-layers`). `--train` is passed explicitly as well — it's merge-safe
    /// with the config and makes the intent unmissable.
    static func loraArguments(configPath: String) -> [String] {
        ["-m", "mlx_lm", "lora", "--config", configPath, "--train"]
    }

    static func loraConfigYAML(_ c: MLXFineTuneConfig) -> String {
        """
        # Written by Huginn (MLX fine-tune). Keys mirror mlx_lm.lora's CONFIG_DEFAULTS.
        model: \(yamlQuote(c.model))
        train: true
        fine_tune_type: \(c.fineTuneType)
        data: \(yamlQuote(c.dataDir))
        adapter_path: \(yamlQuote(c.adapterPath))
        num_layers: \(c.numLayers)
        batch_size: \(c.batchSize)
        iters: \(c.iters)
        learning_rate: \(formatNumber(c.learningRate))
        lora_parameters:
          rank: \(c.loraRank)
          scale: \(formatNumber(c.loraScale))
          dropout: \(formatNumber(c.loraDropout))

        """
    }

    static func fuseArguments(model: String, adapterPath: String, savePath: String) -> [String] {
        [
            "-m", "mlx_lm", "fuse",
            "--model", model,
            "--adapter-path", adapterPath,
            "--save-path", savePath,
        ]
    }

    /// Import check doubling as the version probe: exit 0 + version on stdout
    /// proves the venv actually works, not just that a folder exists.
    static let versionProbeArguments = ["-c", "import mlx_lm; print(mlx_lm.__version__)"]

    /// Warm the HF cache via `snapshot_download` (a python API stable across the
    /// `huggingface-cli` → `hf` console-script rename). The repo id is embedded in
    /// the program text, so callers MUST validate it with `isValidRepoID` first —
    /// the validator's character set excludes quotes/backslashes/newlines, making
    /// the interpolation injection-safe.
    static func downloadArguments(repoID: String) -> [String] {
        [
            "-c",
            "from huggingface_hub import snapshot_download\n"
                + "snapshot_download(repo_id=\"\(repoID)\")",
        ]
    }

    /// `owner/name` where both halves are HF-legal (alphanumeric plus `.`, `_`,
    /// `-`; HF forbids `--` and `..` inside ids, but those are harmless here — the
    /// character set is what makes embedding safe).
    static func isValidRepoID(_ s: String) -> Bool {
        s.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._\-]*/[A-Za-z0-9._\-]+/#) != nil
    }

    /// Whitespace-split; deliberately no shell-style quoting (the UI documents it).
    static func splitExtraArguments(_ s: String) -> [String] {
        s.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: launchd

    static let launchdLabel = "chat.eldr.mlx-server"

    /// The LaunchAgent for login autostart. KeepAlive is intentionally false: a
    /// misconfigured model must not crash-loop at every login — the user restarts
    /// from the MLX tab after fixing it.
    static func launchdPlist(
        pythonPath: String, serverArguments: [String], logPath: String
    ) throws -> Data {
        let dict: [String: Any] = [
            "Label": launchdLabel,
            "ProgramArguments": [pythonPath] + serverArguments,
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            // tqdm progress bars are \r-redrawn junk in a log file; disable them
            // for the launchd copy (the in-app server child gets the same env).
            "EnvironmentVariables": ["HF_HUB_DISABLE_PROGRESS_BARS": "1"],
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: Discovery

    /// Locate a tool by name across the common install dirs plus $PATH. GUI apps
    /// launch with a minimal PATH, so the explicit dirs (Homebrew, ~/.local/bin)
    /// do the real work.
    static func findExecutable(
        named name: String,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let home = NSHomeDirectory()
        var dirs = [
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        dirs += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The publishers the Models section offers as source filters — the same houses
    /// LM Studio's discover surface leans on. "" = any publisher.
    static let searchPublishers = [
        "", "mlx-community", "lmstudio-community", "unsloth", "Qwen", "bartowski",
    ]

    /// Search sort orders the HF list API accepts (label → API value).
    static let searchSorts: [(label: String, value: String)] = [
        ("Downloads", "downloads"),
        ("Likes", "likes"),
        ("Trending", "trendingScore"),
        ("Updated", "lastModified"),
    ]

    /// Hugging Face model-search endpoint. `mlxOnly` filters by the `mlx` library tag
    /// (any publisher's MLX-format builds — the only kind `mlx_lm.server` can load);
    /// `author` narrows to one publisher (mlx-community / lmstudio-community / unsloth
    /// / …; empty = all). `expand[]` requests the row fields the UI captions
    /// (downloads/likes/updated/tags — verified against the live API). `nil` only for
    /// a query URLComponents can't percent-encode.
    static func searchURL(
        query: String, author: String? = nil, mlxOnly: Bool = true,
        sort: String = "downloads", limit: Int = 30
    ) -> URL? {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            return nil
        }
        var items = [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !query.isEmpty { items.append(URLQueryItem(name: "search", value: query)) }
        if let author, !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        if mlxOnly { items.append(URLQueryItem(name: "filter", value: "mlx")) }
        for field in ["downloads", "likes", "lastModified", "tags"] {
            items.append(URLQueryItem(name: "expand[]", value: field))
        }
        components.queryItems = items
        return components.url
    }

    /// Pre-launch validation of the server's `--model` value, so a typo'd local path
    /// fails HERE with a real message instead of what actually happens without it:
    /// `mlx_lm.server` starts, its model-load thread dies (HFValidationError), and
    /// `/v1/models` keeps answering 200 — a "healthy" server whose every chat hangs.
    /// Returns the user-facing problem, or nil when the value is launchable.
    static func validateServerModel(
        _ raw: String, fileManager: FileManager = .default
    ) -> String? {
        let model = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        guard !model.isEmpty else {
            return "Set a model first — pick one in the Models section."
        }
        if model.hasPrefix("/") {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: model, isDirectory: &isDir) else {
                return "That model folder doesn't exist: \(model). Pick a cached model from the Models section, or Browse… to a real MLX model folder."
            }
            guard isDir.boolValue else {
                return "The model path must be a folder holding the MLX model files (config.json + weights), not a single file. (A .gguf file is LM Studio/llama.cpp format — mlx_lm can't load it; download an MLX build instead.)"
            }
            guard fileManager.fileExists(
                atPath: (model as NSString).appendingPathComponent("config.json"))
            else {
                return "That folder has no config.json, so it isn't an MLX model folder. Pick the folder that directly contains config.json and the .safetensors weights."
            }
            return nil
        }
        return isValidRepoID(model)
            ? nil
            : "\u{201C}\(raw)\u{201D} isn't a Hugging Face model id (owner/name) or an absolute folder path."
    }

    // MARK: Port / process diagnosis (WS-M1)

    /// One process listening on a diagnosed port.
    struct PortOwner: Equatable, Sendable {
        let pid: Int32
        let command: String
    }

    /// Parse `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fpc` field output: `p<pid>`
    /// starts a process record, `c<command>` names it (IPv4+IPv6 listeners of one
    /// process share a single record). lsof exits 1 with empty output when nobody
    /// listens — callers treat that as "no owners", not an error.
    static func parsePortOwners(fromLsof output: String) -> [PortOwner] {
        var owners: [PortOwner] = []
        var pendingPID: Int32?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                pendingPID = Int32(line.dropFirst())
            } else if line.hasPrefix("c"), let pid = pendingPID {
                let command = String(line.dropFirst())
                if !owners.contains(where: { $0.pid == pid }) {
                    owners.append(PortOwner(pid: pid, command: command))
                }
                pendingPID = nil
            }
        }
        return owners
    }

    /// The plain-language port-conflict line ("port 1337 is held by LM Studio —
    /// stop it there or change the port here"), or nil when the port's only
    /// listeners are our own (excluded) processes — or nobody.
    static func portConflictMessage(
        port: Int, owners: [PortOwner], excludingPIDs: Set<Int32> = []
    ) -> String? {
        guard let foreign = owners.first(where: { !excludingPIDs.contains($0.pid) }) else {
            return nil
        }
        return
            "Port \(port) is held by \(foreign.command) (pid \(foreign.pid)) — stop it there or change the port here."
    }

    /// `ps -o etime=` → seconds. Format is `[[dd-]hh:]mm:ss`.
    static func parseEtime(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dayParts = trimmed.split(separator: "-", maxSplits: 1)
        var days = 0
        let clock: Substring
        if dayParts.count == 2 {
            guard let parsed = Int(dayParts[0]) else { return nil }
            days = parsed
            clock = dayParts[1]
        } else {
            clock = dayParts[0]
        }
        let pieces = clock.split(separator: ":")
        guard (2...3).contains(pieces.count) else { return nil }
        var values: [Int] = []
        for piece in pieces {
            guard let value = Int(piece), value >= 0, value < 100_000 else { return nil }
            values.append(value)
        }
        guard days < 100_000 else { return nil }  // overflow-proof: ps never emits this
        let (hours, minutes, seconds) =
            values.count == 3 ? (values[0], values[1], values[2]) : (0, values[0], values[1])
        return TimeInterval(((days * 24 + hours) * 60 + minutes) * 60 + seconds)
    }

    /// First `rss` + `etime` pair from `ps -o rss= -o etime= -p <pid>` (rss is
    /// reported in KB).
    static func parseProcessStats(
        fromPS output: String
    ) -> (rssBytes: Int64, elapsed: TimeInterval)? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2,
            let kilobytes = Int64(fields[0]),
            let elapsed = parseEtime(String(fields[1]))
        else { return nil }
        return (kilobytes * 1024, elapsed)
    }

    /// The `pid = N` line from `launchctl print gui/<uid>/<label>` — nil when the
    /// job is loaded but not running.
    static func parseLaunchdPID(fromPrint output: String) -> Int32? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("pid = ") else { continue }
            return Int32(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Helpers

    /// UI-side GiB ↔ bytes for `--prompt-cache-bytes` (nobody types byte counts).
    /// Nil for zero/negative/absurd input — `Int64(Double)` TRAPS past Int64.max,
    /// and this converts text the user typed.
    static func bytes(fromGB gigabytes: Double) -> Int64? {
        guard gigabytes > 0, gigabytes.isFinite else { return nil }
        let bytes = (gigabytes * 1_073_741_824).rounded()
        guard bytes < 9.2e18 else { return nil }  // < Int64.max, exactly representable
        return Int64(bytes)
    }

    static func gigabytes(fromBytes bytes: Int64) -> Double {
        Double(bytes) / 1_073_741_824
    }

    /// `%g` so 0.7 stays "0.7" and 1e-5 stays "1e-05" — readable in both argv and YAML.
    static func formatNumber(_ value: Double) -> String {
        String(format: "%g", value)
    }

    /// Single-quoted YAML scalar (only `'` needs doubling).
    private static func yamlQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: Model library (WS-M3)

    /// Parse ONE collapsed tqdm line into a progress frame, or nil if the line
    /// isn't a progress bar. Anchors on the percent that immediately precedes the
    /// bar pipe (`P%|`), so stray "%" in surrounding text can't false-match; the
    /// rate is the numeric token after the last comma inside `[…]` (absent on the
    /// opening `?it/s` frame). Locale-proof: tqdm never localizes these digits.
    static func parseTqdmProgress(_ raw: String) -> MLXDownloadProgress? {
        guard let percentMatch = raw.firstMatch(of: /(\d{1,3})%\|/),
            let percent = Int(percentMatch.output.1), percent <= 100
        else { return nil }
        let description = String(raw[raw.startIndex..<percentMatch.range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
        var rate: String?
        // The `/` in the rate unit (s/it, it/s, MB/s) is escaped so it doesn't
        // close the regex literal.
        if let rateMatch = raw.firstMatch(of: /,\s*([0-9][0-9.]*[A-Za-z\/]+)\]/) {
            rate = String(rateMatch.output.1)
        }
        var caption = description.isEmpty ? "Downloading" : description
        if let rate { caption += " · \(rate)" }
        return MLXDownloadProgress(fraction: Double(percent) / 100, caption: caption)
    }

    /// The latest download-progress frame in a job log — the live (`\r`-collapsed)
    /// tqdm line is the last committed/pending row, so scan the tail backward and
    /// take the first that parses. Nil until a frame appears (so the caller keeps
    /// the prior frame rather than clearing it).
    static func latestProgress(inLines lines: [String]) -> MLXDownloadProgress? {
        lines.suffix(6).reversed().lazy.compactMap(parseTqdmProgress).first
    }

    /// Classify a search result's format from its id + HF tags. `mlx` tag ⇒ a
    /// ready MLX build; a GGUF/NVFP4 signal ⇒ genuinely unloadable; everything else
    /// is plain non-MLX safetensors (might load, always heavier).
    static func classifyFormat(id: String, tags: [String]?) -> MLXModelFormat {
        let tagSet = Set((tags ?? []).map { $0.lowercased() })
        let lowerID = id.lowercased()
        if tagSet.contains("mlx") { return .mlx }
        if tagSet.contains("gguf") || lowerID.contains("gguf") {
            return .cannotLoad(
                reason:
                    "GGUF is a llama.cpp / LM Studio format — mlx_lm can't load it. Look for an mlx-community MLX build, or Convert a source model in Advanced."
            )
        }
        if tagSet.contains("nvfp4") || lowerID.contains("nvfp4") {
            return .cannotLoad(
                reason:
                    "NVFP4 — mlx_lm can't load this quantization. Use the mlx-community MLX build of this model instead."
            )
        }
        return .notMLXBuild
    }

    /// The HF model file-tree endpoint (recursive), for a validated repo id.
    static func treeURL(repoID: String, revision: String = "main") -> URL? {
        guard isValidRepoID(repoID) else { return nil }
        return URL(
            string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)?recursive=true")
    }

    /// Sum the real download bytes from the HF tree JSON (`size` already equals
    /// `lfs.size` for LFS files). Nil when the JSON has no files (so the guard
    /// treats size as unknown rather than "0 bytes").
    static func sumTreeDownloadBytes(fromJSON data: Data) -> Int64? {
        struct Entry: Decodable {
            let type: String?
            let size: Int64?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return nil }
        var total: Int64 = 0
        var sawFile = false
        for entry in entries where entry.type == "file" {
            if let size = entry.size, size >= 0 {
                // Overflow-safe: a pathological (or hostile) response summing past
                // Int64.max clamps to "enormous" (which the guard then blocks)
                // instead of trapping.
                let (sum, overflow) = total.addingReportingOverflow(size)
                total = overflow ? .max : sum
                sawFile = true
            }
        }
        return sawFile ? total : nil
    }

    /// Pre-download free-disk decision. Blocks only when the model clearly won't
    /// fit (near-certain mid-download failure that would strand a huge
    /// `.incomplete`); an unknown size never blocks — it only warns when disk is
    /// already critically low. A nil `freeBytes` (our own probe failed) never
    /// blocks the user. `floorBytes` is the "critically low" threshold.
    static func downloadDiskGuard(
        freeBytes: Int64?, estimatedBytes: Int64?, floorBytes: Int64 = 5 << 30
    ) -> MLXDiskGuard {
        guard let free = freeBytes else { return .ok }
        let human: (Int64) -> String = { $0.formatted(.byteCount(style: .file)) }
        if let need = estimatedBytes, need > 0 {
            // Headroom for the `.incomplete` staging + non-weight files. Overflow-
            // safe: an enormous `need` (past Int64.max once the margin is added)
            // can't fit any disk, so it blocks rather than trapping.
            let (required, overflow) = need.addingReportingOverflow(max(2 << 30, need / 10))
            if overflow || free < required {
                return .block(
                    "This model needs about \(human(need)) but only \(human(free)) is free. Free up space (delete a cached model below) and try again."
                )
            }
            return .ok
        }
        if free < floorBytes {
            return .warn(
                "Only \(human(free)) free and this model's size is unknown — MLX models are often several GB, so the download may fail if there isn't room."
            )
        }
        return .ok
    }

    /// The quantization label for a cached model, from its `config.json`: MLX
    /// builds carry `quantization.bits`; upstream quantized checkpoints carry
    /// `quantization_config.quant_method` (e.g. NVFP4's `compressed-tensors`).
    /// Nil for an unquantized (full-precision) model.
    static func quantLabel(fromConfigJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let quantization = object["quantization"] as? [String: Any],
            let bits = quantization["bits"] as? Int
        {
            return "\(bits)-bit"
        }
        let quantConfig =
            (object["quantization_config"] as? [String: Any])
            ?? ((object["text_config"] as? [String: Any])?["quantization_config"] as? [String: Any])
        if let quantConfig {
            if let bits = quantConfig["bits"] as? Int { return "\(bits)-bit" }
            if let method = quantConfig["quant_method"] as? String { return method }
        }
        return nil
    }

    /// Order cached models for display. `.largest` (the "free up space" default)
    /// and `.name` are total; `.lastUsed` puts known-used first (newest first),
    /// unknown-atime models last, size-broken ties.
    static func sortedModels(_ models: [MLXCachedModel], by sort: MLXModelSort) -> [MLXCachedModel] {
        switch sort {
        case .largest:
            return models.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:
            return models.sorted {
                $0.repoID.localizedCaseInsensitiveCompare($1.repoID) == .orderedAscending
            }
        case .lastUsed:
            return models.sorted {
                switch ($0.lastUsed, $1.lastUsed) {
                case let (lhs?, rhs?): return lhs > rhs
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return $0.sizeBytes > $1.sizeBytes
                }
            }
        }
    }
}

// MARK: - Hugging Face hub cache

/// One `models--…` entry in the HF hub cache.
struct MLXCachedModel: Identifiable, Equatable, Sendable {
    var id: String { repoID }
    let repoID: String
    /// The `models--owner--name` directory itself (delete target).
    let path: String
    let sizeBytes: Int64
    let modified: Date?
    /// Most-recent access time across the model's files (HF's `scan-cache`
    /// "last used" — blob atime). Nil when the volume doesn't track atime, so the
    /// UI shows "—" rather than a wrong date (WS-M3).
    var lastUsed: Date?
    /// Quantization label from `config.json` ("4-bit", "compressed-tensors", …),
    /// or nil for a full-precision model (WS-M3).
    var quant: String?

    init(
        repoID: String, path: String, sizeBytes: Int64, modified: Date?,
        lastUsed: Date? = nil, quant: String? = nil
    ) {
        self.repoID = repoID
        self.path = path
        self.sizeBytes = sizeBytes
        self.modified = modified
        self.lastUsed = lastUsed
        self.quant = quant
    }
}

/// Native reader of the Hugging Face hub cache layout — the same directories
/// `mlx_lm.manage --scan` renders as a table. Scanning it directly is
/// deterministic (no human-table parsing) and `--delete`'s interactive y/N
/// confirmation can't hang a GUI-driven subprocess.
enum HFCache {

    /// Cache root, honoring the same env vars huggingface_hub does.
    static func defaultCacheDir(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let explicit = env["HUGGINGFACE_HUB_CACHE"], !explicit.isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let hfHome = env["HF_HOME"], !hfHome.isEmpty {
            return ((hfHome as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent("hub")
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// `models--owner--name` → `owner/name`. HF forbids `--` inside either half,
    /// so splitting on the FIRST `--` after the prefix is exact.
    static func repoID(fromFolderName name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let rest = name.dropFirst("models--".count)
        guard let separator = rest.range(of: "--") else { return nil }
        let owner = rest[..<separator.lowerBound]
        let repo = rest[separator.upperBound...]
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    /// All cached models with their true disk usage. Sizes sum regular files only
    /// — snapshot trees are symlinks into `blobs/`, so following them would
    /// double-count every weight file.
    static func scanModels(cacheDir: String) -> [MLXCachedModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: cacheDir) else { return [] }
        var models: [MLXCachedModel] = []
        for entry in entries {
            guard let repoID = repoID(fromFolderName: entry) else { continue }
            let path = (cacheDir as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let modified =
                (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
            let usage = directoryUsage(path)
            models.append(
                MLXCachedModel(
                    repoID: repoID, path: path,
                    sizeBytes: usage.bytes, modified: modified,
                    lastUsed: usage.lastUsed, quant: quantLabel(forModelAt: path)))
        }
        return models.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// Recursive size of regular files, symlinks excluded (not followed, not counted).
    static func directorySize(_ path: String) -> Int64 {
        directoryUsage(path).bytes
    }

    /// One file walk yielding both the on-disk size (regular files only; symlinks
    /// excluded so snapshot trees don't double-count) AND the newest access time
    /// (blob atime — HF's "last used"). Combining them means the atime read costs
    /// no extra traversal.
    static func directoryUsage(_ path: String) -> (bytes: Int64, lastUsed: Date?) {
        let url = URL(fileURLWithPath: path)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentAccessDateKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [])
        else { return (0, nil) }
        var total: Int64 = 0
        var lastUsed: Date?
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                values.isSymbolicLink != true,
                values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
            if let accessed = values.contentAccessDate,
                lastUsed.map({ accessed > $0 }) ?? true
            {
                lastUsed = accessed
            }
        }
        return (total, lastUsed)
    }

    /// The quant label from the first snapshot's `config.json` (a symlink into
    /// `blobs/`, transparently followed by a read). Nil when there's no config or
    /// it isn't quantized.
    static func quantLabel(forModelAt path: String) -> String? {
        let snapshots = (path as NSString).appendingPathComponent("snapshots")
        guard let hashes = try? FileManager.default.contentsOfDirectory(atPath: snapshots) else {
            return nil
        }
        for hash in hashes.sorted() {
            let configPath = ((snapshots as NSString).appendingPathComponent(hash) as NSString)
                .appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)) {
                return MLXCommand.quantLabel(fromConfigJSON: data)
            }
        }
        return nil
    }
}

/// One row from the HF model-search API (extra fields ignored).
struct MLXHubModel: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let lastModified: String?
    let tags: [String]?

    /// The quantization tag HF carries for MLX builds ("4-bit"/"8-bit"/…), if any.
    var quantLabel: String? {
        tags?.first { $0.hasSuffix("-bit") }
    }

    var isMLX: Bool { tags?.contains("mlx") ?? false }

    /// Whether mlx_lm can load this build — drives the format-honesty warning
    /// when the "MLX format only" filter is off (WS-M3).
    var format: MLXModelFormat { MLXCommand.classifyFormat(id: id, tags: tags) }
}

// MARK: - Log-pane rows

/// One rendered log-pane row, id stable across appends so SwiftUI's diff keeps
/// unchanged rows. WS-M0: MLXService precomputes a bounded window of these
/// (`jobLogWindow`) at publish time, so the 300-row suffix+map runs once per
/// (coalesced) publish instead of once per Form re-evaluation. (The server-log
/// window moved to WS-M2's LogConsoleView, which tails the file itself.)
struct MLXLogRow: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
}

// MARK: - Terminal output buffer

/// Accumulates child-process output the way a terminal would: `\n` commits the
/// pending line; `\r` rewinds it so the next text REPLACES it in place. That
/// turns tqdm/huggingface download bars (thousands of `\r`-redrawn updates) into
/// one live, updating progress line instead of a scrolling wall of stale copies.
struct TerminalLineBuffer: Equatable, Sendable {
    private(set) var committed: [String] = []
    private var pending: String = ""
    /// Saw `\r`: the next visible character replaces `pending` (deferred so a
    /// trailing `\r\n` still commits the finished line).
    private var rewound = false
    let maxLines: Int

    init(maxLines: Int = 2000) { self.maxLines = maxLines }

    mutating func feed(_ chunk: String) {
        // Unicode SCALARS, not Characters: Swift's grapheme segmentation fuses
        // "\r\n" into a single Character that would match neither control case.
        for scalar in chunk.unicodeScalars {
            switch scalar {
            case "\n":
                committed.append(pending)
                pending = ""
                rewound = false
                if committed.count > maxLines {
                    committed.removeFirst(committed.count - maxLines)
                }
            case "\r":
                rewound = true
            default:
                if rewound {
                    pending = ""
                    rewound = false
                }
                pending.unicodeScalars.append(scalar)
            }
        }
    }

    var lines: [String] { pending.isEmpty ? committed : committed + [pending] }
    var text: String { lines.joined(separator: "\n") }
    var isEmpty: Bool { committed.isEmpty && pending.isEmpty }
}
