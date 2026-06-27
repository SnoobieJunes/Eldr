import SwiftUI

/// Per-backend visual identity — the single source of truth for "which kind of AI
/// is this", used by BOTH the Settings AI rows and the corner badge on agent chat
/// bubbles so they always match. One backend → one mark.
///
/// Brand logos (Claude / OpenAI / Gemini) are NOT SF Symbols; the symbols below
/// are distinct stand-ins until real logo assets are bundled. sybilclaw / OpenClaw
/// — an engine that can sit *behind* the `acp` Mac-Tethered-AI backend — gets its
/// own 🦞 glyph (user request: distinct from a generic Mac-Tethered-AI), surfaced
/// when the AI's name/model identifies it.
enum AITypeIcon {
    /// SF Symbol for a backend kind (BackendRegistry tag). `default` is the generic
    /// AI glyph (a peer's backend isn't broadcast, so it falls here).
    static func symbol(forKind kind: String) -> String {
        switch kind {
        case "ondevice": return "iphone"                  // on-device — a phone
        case "pcc": return "apple.logo"                   // Apple Private Cloud Compute
        case "claude": return "asterisk"                  // Anthropic's asterisk-like mark
        case "openai": return "circle.hexagonpath"
        case "gemini": return "sparkle"                   // Google's 4-point spark
        case "openrouter": return "arrow.triangle.branch"
        case "groq": return "bolt.fill"
        case "custom": return "server.rack"               // self-hosted (e.g. LM Studio/Ollama)
        case "hub": return "antenna.radiowaves.left.and.right"
        case "acp": return "desktopcomputer"              // Mac-Tethered-AI
        case "demo": return "ladybug"
        default: return "sparkles"                        // unknown / peer AI
        }
    }

    /// A real emoji per backend KIND, for the Settings backend picker (the user
    /// asked for emojis on the model rows). Distinct from `symbol(forKind:)` (SF
    /// Symbols, used by the corner badge) and from `glyph(...)` (the name-based
    /// engine override): this is a plain glyph the menu `Text` can prefix, chosen
    /// to read at a glance and to never collide with the 🦞 engine glyph.
    static func emoji(forKind kind: String) -> String {
        switch kind {
        case "ondevice": return "📱"          // on-device — your phone
        case "pcc": return "🍏"               // Apple Private Cloud Compute
        case "claude": return "✴️"            // Anthropic
        case "openai": return "🌀"            // OpenAI
        case "gemini": return "✨"            // Google Gemini (its mark IS a sparkle)
        case "openrouter": return "🔀"        // routes across many models
        case "groq": return "⚡️"             // speed
        case "custom": return "🏠"            // self-hosted on your own network
        case "hub": return "📡"               // nearby host over Multipeer
        case "acp": return "🖥️"              // Mac-Tethered-AI
        case "demo": return "🐞"              // simulated (matches the ladybug symbol)
        default: return "🤖"                  // unknown / peer AI
        }
    }

    /// An emoji glyph that OVERRIDES the SF Symbol when we can identify the engine
    /// behind a backend by its name/model — today only sybilclaw / OpenClaw (🦞),
    /// distinct from a generic Mac-Tethered-AI. nil ⇒ use `symbol(forKind:)`.
    static func glyph(forKind kind: String, model: String?, name: String?) -> String? {
        let hay = "\(model ?? "") \(name ?? "")".lowercased()
        if hay.contains("sybilclaw") || hay.contains("sibylclaw") || hay.contains("openclaw") {
            return "🦞"
        }
        return nil
    }

    /// Resolve a (symbol, glyph) badge for a configured AI — exactly one is set.
    static func badge(kind: String, model: String?, name: String?)
        -> (symbol: String?, glyph: String?)
    {
        if let glyph = glyph(forKind: kind, model: model, name: name) {
            return (nil, glyph)
        }
        return (symbol(forKind: kind), nil)
    }
}

/// A small reusable view rendering an `AITypeIcon` badge (SF Symbol OR emoji
/// glyph) at a consistent size, so the Settings row and the bubble corner look
/// identical. `tint` colors the SF-Symbol form; the emoji renders in its own hue.
struct AITypeBadgeView: View {
    let symbol: String?
    let glyph: String?
    var size: CGFloat = 11
    var tint: Color = .secondary

    var body: some View {
        if let glyph {
            Text(glyph).font(.system(size: size))
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
        }
    }
}
