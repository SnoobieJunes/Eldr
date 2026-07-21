// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SwiftUI

/// A small, bounded, in-memory event bus the Agent Inspector renders live. Every
/// interesting thing the node does — each LLM round-trip, tool call, relay/node
/// lifecycle event — posts here, so a human can SEE what the agent is doing instead of
/// hunting through `log stream` and `eldr-acp.log` (the pain that motivated this).
///
/// Privacy: this is on the operator's own Mac and shows only the operator's own
/// activity (no peer secret-chat content flows through the coding agent). Still, we keep
/// detail to short previews, never full file contents or tokens.
@MainActor
final class DiagnosticsLog: ObservableObject {
    // `nonisolated` so the LLM decorator (a nonisolated `LLMClient`) can reference
    // `.shared` as a default arg and call `post(...)` off the main actor. The type is
    // Sendable (a @MainActor class) and the init is trivial, so this is safe.
    nonisolated static let shared = DiagnosticsLog()
    nonisolated init() {}

    enum Category: String, CaseIterable, Identifiable {
        case llm = "LLM"
        case acp = "ACP"
        case node = "Node"
        case mlx = "MLX"
        /// WS-B2: relay connect/disconnect/error/EOSE/NIP-42 AUTH lifecycle events,
        /// forwarded from `NostrWebSocketTransport.transportEvents()` by
        /// `ACPBridgeService`. Distinct from `.node` (which covers the relay-carried
        /// ACP host's own start/stop), so relay transport health is filterable on its own.
        case relay = "Relay"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .llm: return "brain"
            case .acp: return "wrench.and.screwdriver"
            case .node: return "antenna.radiowaves.left.and.right"
            case .mlx: return "memorychip"
            case .relay: return "server.rack"
            }
        }
    }

    enum Severity: String {
        case info, success, warn, error
        var color: Color {
            switch self {
            case .info: return .secondary
            case .success: return .green
            case .warn: return .orange
            case .error: return .red
            }
        }
    }

    struct Event: Identifiable {
        let id = UUID()
        let at: Date
        let category: Category
        let severity: Severity
        let title: String
        let detail: String
    }

    @Published private(set) var events: [Event] = []
    private let cap = 500

    func record(_ category: Category, _ severity: Severity, _ title: String, _ detail: String = "") {
        events.append(Event(at: Date(), category: category, severity: severity, title: title, detail: detail))
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    func clear() { events.removeAll() }

    /// Safe to call from any isolation (the LLM decorator runs off the main actor):
    /// hops to the main actor to mutate the published store.
    nonisolated func post(
        _ category: Category, _ severity: Severity, _ title: String, _ detail: String = ""
    ) {
        Task { @MainActor in DiagnosticsLog.shared.record(category, severity, title, detail) }
    }
}
