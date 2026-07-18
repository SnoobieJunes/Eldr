#if os(macOS)

import Foundation

/// Constant-time bearer-token check for the A2A HTTP binding (PRIVACY RULE: bearer
/// auth is required on every route, including the agent card — nothing is served
/// unauthenticated).
public struct BearerAuthenticator: Sendable {
    private let expected: [UInt8]

    public init(token: String) {
        self.expected = Array("Bearer \(token)".utf8)
    }

    /// `headerValue` is the raw `Authorization` header value, if present.
    public func authorize(_ headerValue: String?) -> Bool {
        guard let headerValue else { return false }
        return Self.constantTimeEquals(Array(headerValue.utf8), expected)
    }

    /// Byte-for-byte comparison that does not short-circuit on the first mismatch,
    /// so timing does not reveal how many leading bytes of a guess were correct.
    /// A length mismatch is checked first — unavoidably observable via timing (it's
    /// a single branch), but leaks nothing about the token's content.
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }
}

#endif
