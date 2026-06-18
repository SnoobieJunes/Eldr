import Foundation

/// Replaces secrets in agent output with opaque markers before that text is shown to
/// anyone but its owner. The PQRC watch-along bridge fans an agent answer out
/// per-recipient: the owner's session carries the raw text, everyone else's carries
/// `scrub(text)`. This is the one security-critical seam in that flow, so it's pure,
/// synchronous, and unit-tested in isolation.
///
/// Design rules (Path 2 §10):
///  - CONSERVATIVE toward leaking: a false positive merely redacts a non-secret in
///    the OTHER participants' copy (never the owner's), which is the privacy-maximizing
///    failure (SPEC §0). A false NEGATIVE would leak a real secret — far worse — so the
///    patterns lean broad.
///  - Detects common shapes: OpenAI/Anthropic `sk-…`, AWS `AKIA…`, GitHub/Slack
///    tokens, `Bearer …`, `api_key = …` / `password: …` assignments, and long
///    high-entropy base64/hex runs.
///  - Never emits the secret in the replacement; the marker is fixed text.
public enum CredentialRedactor {
    /// Marker substituted for key-shaped secrets.
    public static let apiKeyMarker = "‹redacted:api-key›"
    /// Marker substituted for token/password-shaped secrets.
    public static let tokenMarker = "‹redacted:token›"

    /// Replace every detected secret in `text` with a marker. Returns the input
    /// unchanged when nothing matched.
    public static func scrub(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template)
        }
        return result
    }

    /// True if `text` contains anything `scrub` would redact (handy for logging
    /// "redacted N secrets" without echoing them).
    public static func containsSecret(_ text: String) -> Bool { scrub(text) != text }

    // MARK: - Rules

    private struct Rule { let regex: NSRegularExpression; let template: String }

    /// Compiled once. Applied in order: specific, labeled shapes first so they get the
    /// right marker, then the generic high-entropy catch-all last (over text that the
    /// earlier rules have already turned into inert markers).
    private static let rules: [Rule] = {
        let specs: [(String, String, NSRegularExpression.Options)] = [
            // OpenAI / Anthropic secret keys: sk-… and sk-ant-… (the `ant-` is covered
            // by the char class, so one pattern handles both).
            ("sk-[A-Za-z0-9_-]{12,}", apiKeyMarker, []),
            // AWS access key ids (AKIA/ASIA/AROA/AIDA + 12+ uppercase/digits).
            ("(?:AKIA|ASIA|AROA|AIDA)[A-Z0-9]{12,}", apiKeyMarker, []),
            // GitHub tokens (ghp_/gho_/ghu_/ghs_/ghr_ + 20+).
            ("gh[pousr]_[A-Za-z0-9]{20,}", tokenMarker, []),
            // Slack tokens (xoxb-/xoxp-/…).
            ("xox[baprs]-[A-Za-z0-9-]{10,}", tokenMarker, []),
            // Google API keys.
            ("AIza[A-Za-z0-9_-]{20,}", apiKeyMarker, []),
            // Bearer tokens — keep the "Bearer " prefix, redact the credential.
            ("(Bearer )[A-Za-z0-9._~+/=-]{12,}", "$1\(tokenMarker)", [.caseInsensitive]),
            // key=value / key: "value" assignments for secret-named keys. Preserve the
            // key, separator, and any quotes; redact only the value.
            (
                "((?:api[_-]?key|secret|access[_-]?token|auth[_-]?token|access[_-]?key|token|password|passwd|pwd))(\\s*[:=]\\s*)([\"']?)([^\\s\"']{6,})([\"']?)",
                "$1$2$3\(tokenMarker)$5", [.caseInsensitive]
            ),
            // High-entropy base64/base64url run with BOTH a letter and a digit (the
            // dual lookahead skips long all-letter words and slash-only paths).
            (
                "(?=[A-Za-z0-9+/=_-]*[0-9])(?=[A-Za-z0-9+/=_-]*[A-Za-z])[A-Za-z0-9+/=_-]{40,}",
                tokenMarker, []
            ),
            // Long hex runs (sha1/sha256, 40+ hex chars).
            ("\\b[0-9a-fA-F]{40,}\\b", tokenMarker, []),
        ]
        return specs.compactMap { pattern, template, options in
            // Patterns are compile-time constants; `try?` (not `try!`, per CLAUDE.md)
            // degrades safely — a (never-expected) bad pattern is simply skipped, and
            // the scrubber tests would catch a regression.
            (try? NSRegularExpression(pattern: pattern, options: options))
                .map { Rule(regex: $0, template: template) }
        }
    }()
}
