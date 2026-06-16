import Combine
import Foundation
import PQRCACP

/// Polls the configured LLM's `GET /v1/models` so the UI can show a live green/red
/// dot and the discovered model list. Polls every 30s while the app is foregrounded;
/// stops when backgrounded (NSApplication active/resign notifications). The network
/// call is async URLSession, so it never blocks the main thread despite this being a
/// @MainActor object (SwiftUI needs the published state on the main actor).
@MainActor
final class LLMHealthChecker: ObservableObject {

    enum HealthResult: Equatable {
        case unknown
        case checking
        case reachable(models: [String])
        case unreachable(error: String)

        var isReachable: Bool { if case .reachable = self { return true }; return false }
    }

    @Published private(set) var result: HealthResult = .unknown

    /// Supplies the current LLM config each poll (so config edits take effect without
    /// rewiring). Set by the owner. `@MainActor`-isolated: the UI wires it to store state.
    var configProvider: @MainActor () -> LLMConfig = { LLMConfig.fromEnvironment([:]) }

    private var pollTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// Begin foreground-gated polling. Idempotent.
    func startPolling(interval: TimeInterval = 30) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkNow()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One immediate health check (used by the wizard's "Test connection" step).
    func checkNow() async {
        let config = configProvider()
        result = .checking
        result = await Self.probe(config)
    }

    /// Issue `GET <base>/models`, returning the model id list or a reason it failed.
    nonisolated static func probe(_ config: LLMConfig) async -> HealthResult {
        guard let url = modelsEndpoint(config.url) else {
            return .unreachable(error: "Invalid LLM URL.")
        }
        var request = URLRequest(url: url, timeoutInterval: 6)
        if !config.token.isEmpty {
            request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .unreachable(error: "HTTP \(http.statusCode)")
            }
            let models = parseModelIDs(data)
            return .reachable(models: models)
        } catch {
            return .unreachable(error: (error as NSError).localizedDescription)
        }
    }

    /// Normalize whatever slice of the OpenAI path the user typed to a `/v1/models`
    /// URL (mirrors OpenAICompatibleLLMClient.endpoint's normalization).
    nonisolated static func modelsEndpoint(_ raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/models") { return URL(string: base) }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
        }
        if base.hasSuffix("/v1") { return URL(string: base + "/models") }
        if let u = URL(string: base), u.path.isEmpty || u.path == "/" {
            return URL(string: base + "/v1/models")
        }
        return URL(string: base + "/models")
    }

    /// `{ "data": [ { "id": "…" } ] }` → ["…"]. Tolerant of odd shapes.
    nonisolated static func parseModelIDs(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = json["data"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { $0["id"] as? String }
    }
}
