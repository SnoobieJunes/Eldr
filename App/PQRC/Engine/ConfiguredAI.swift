import Foundation
import PQRCAgent

/// One AI a person has tethered to themselves. A user can configure several at
/// once (e.g. on-device Core AI + Claude) so they can share context with each
/// other in a chat or thread (multi-AI tethering). Stored in UserDefaults; API
/// keys stay in the Keychain, keyed by `kind`.
struct ConfiguredAI: Identifiable, Codable, Equatable, Sendable {
    var id: String
    /// Friendly, user-editable display name (a friendly codename by default).
    var name: String
    /// Inference backend: "ondevice" | "claude" | "openai" | "gemini" | "demo".
    var kind: String

    /// The selectable backends and their labels.
    static let kinds: [(tag: String, label: String)] = [
        ("ondevice", "On-device Core AI"),
        ("claude", "Claude (Anthropic)"),
        ("openai", "OpenAI"),
        ("gemini", "Gemini"),
        ("demo", "Demo (simulated)"),
    ]

    static func label(for kind: String) -> String {
        kinds.first { $0.tag == kind }?.label ?? kind
    }

    /// Backends that send conversation content off-device — require explicit
    /// consent and a Keychain API key.
    static func isRemote(_ kind: String) -> Bool {
        ["claude", "openai", "gemini"].contains(kind)
    }

    /// Keychain account holding the API key for a remote backend, if any.
    static func keyAccount(for kind: String) -> String? {
        switch kind {
        case "claude": return "anthropic-api-key"
        case "openai": return "openai-api-key"
        case "gemini": return "gemini-api-key"
        default: return nil
        }
    }
}

/// A configured AI bound to a live provider instance — the runtime's view of a
/// tethered AI. `provider` is `Sendable` (the protocol requires it).
struct TetheredAI: Sendable {
    let id: String
    let name: String
    let provider: any AgentProvider
}

/// One line of the read-only "what your AI sees" context preview (Settings).
struct ContextPreviewLine: Identifiable, Sendable {
    let id = UUID()
    let role: String
    let text: String
    /// True when this entry is peer content a context-sharing grant authorized.
    let shared: Bool
}
