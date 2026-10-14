// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Port of `LLMHealthChecker.checkNow`: GET `<url>/models` and list the model ids, so
/// the status dot and the model picker show what the endpoint really serves.
public enum LLMHealth {
    public enum Result: Sendable, Equatable {
        case healthy(models: [String])
        case unauthorized
        case httpError(Int)
        case unreachable(String)
        case badResponse

        public var label: String {
            switch self {
            case .healthy(let m): return m.isEmpty ? "Reachable (no models listed)" : "Healthy · \(m.count) model\(m.count == 1 ? "" : "s")"
            case .unauthorized: return "Rejected the token (401/403)"
            case .httpError(let c): return "HTTP \(c)"
            case .unreachable(let why): return "Unreachable: \(why)"
            case .badResponse: return "Reachable, but /models was not OpenAI-shaped"
            }
        }
        public var isHealthy: Bool { if case .healthy = self { return true }; return false }
    }

    public static func modelsURL(_ base: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + "/models")
    }

    public static func parseModels(_ data: Data) -> [String]? {
        guard let json = JSONValue.parse(String(decoding: data, as: UTF8.self)),
            let items = json["data"]?.arrayValue
        else { return nil }
        return items.compactMap { $0["id"]?.stringValue }
    }

    public static func check(url: String, token: String, timeout: TimeInterval = 5) async -> Result {
        guard let u = modelsURL(url), u.scheme == "http" || u.scheme == "https" else {
            return .unreachable("not an http(s) URL")
        }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { return .unauthorized }
            guard (200..<300).contains(code) else { return .httpError(code) }
            guard let models = parseModels(data) else { return .badResponse }
            return .healthy(models: models)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
