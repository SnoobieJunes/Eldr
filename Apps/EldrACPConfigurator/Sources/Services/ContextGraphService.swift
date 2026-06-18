import Foundation

/// Manages the local `rdevaul/contextgraph` service (graph-based context manager)
/// for the Configurator: install/start it from a user-supplied checkout, and
/// health-check the running REST endpoint.
///
/// The Configurator does NOT vendor Python — the user points us at a contextgraph
/// checkout and we run its documented setup (`pip install`, the spaCy model, and
/// `scripts/install-service.sh`, then `launchctl load`). This depends on the
/// user's Python toolchain and may need the app's sandbox relaxed; every step
/// surfaces its failure rather than silently no-op'ing, and the fallback is
/// "point me at an already-running endpoint" (the health check still works).
@MainActor
final class ContextGraphService: ObservableObject {

    enum ServiceState: Equatable {
        case unknown
        case down
        case up(messages: Int)
    }

    @Published private(set) var state: ServiceState = .unknown
    @Published var repoDir: String = ""
    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    /// Tail of the setup output, shown in the wizard so failures are diagnosable.
    @Published private(set) var setupLog: String = ""

    /// The endpoint we health-check; kept in sync with ConfigurationStore.contextGraphURL.
    var endpoint: String

    init(endpoint: String = "http://localhost:8302") {
        self.endpoint = endpoint
    }

    // MARK: - Health

    /// `GET <endpoint>/health` → up(messages_in_store) / down. Never throws.
    func refreshHealth() async {
        guard let url = URL(string: "health", relativeTo: URL(string: endpoint)) else {
            state = .down
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                state = .down
                return
            }
            let count =
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
                .flatMap { $0["messages_in_store"] as? Int } ?? 0
            state = .up(messages: count)
        } catch {
            state = .down
        }
    }

    // MARK: - Install / start

    /// Run contextgraph's documented setup in the chosen checkout, then load the
    /// launchd service and health-check. Throws with a readable message (and the
    /// captured output in `setupLog`) on the first failing step.
    func installAndStart() async throws {
        lastError = nil
        setupLog = ""
        isWorking = true
        defer { isWorking = false }

        let repo = (repoDir as NSString).expandingTildeInPath
        guard !repo.isEmpty, FileManager.default.fileExists(atPath: repo) else {
            let msg = "Pick the contextgraph checkout folder first."
            lastError = msg
            throw ServiceError.message(msg)
        }

        // contextgraph's documented setup, then launchd load. Run via zsh -c so we
        // can `cd` into the repo and chain the steps the way the README does.
        let script = """
            cd \(shellQuote(repo)) || exit 91
            pip install -r requirements.txt || exit 92
            python -m spacy download en_core_web_sm || exit 93
            ./scripts/install-service.sh || exit 94
            launchctl load "$HOME/Library/LaunchAgents/com.glados.tag-context.plist" 2>/dev/null || true
            """
        let result = await ProcessRunner.run("/bin/zsh", ["-c", script])
        setupLog = String(result.out.suffix(4000))
        guard result.exit == 0 else {
            let msg = Self.describeExit(result.exit)
            lastError = msg
            throw ServiceError.message(msg)
        }

        // Give the service a moment, then confirm it answers.
        await refreshHealth()
        if case .down = state {
            let msg =
                "Setup ran but the service isn't answering on \(endpoint) yet. Give it a few seconds and re-check, or start it manually."
            lastError = msg
            throw ServiceError.message(msg)
        }
    }

    // MARK: - Helpers

    enum ServiceError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let m): return m }
        }
    }

    private static func describeExit(_ code: Int32) -> String {
        switch code {
        case 91: return "Couldn't enter the contextgraph folder."
        case 92: return "`pip install -r requirements.txt` failed — check your Python/venv."
        case 93: return "Downloading the spaCy model failed."
        case 94: return "`scripts/install-service.sh` failed."
        default: return "contextgraph setup failed (exit \(code)). See the log below."
        }
    }

    /// Minimal POSIX single-quote so a path with spaces is safe in the zsh script.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
