import Foundation
import OSLog

/// All app logging funnels through here.
///
/// Policy (cardinal rule, SPEC §0): message payloads are NEVER logged — not
/// even with `privacy: .private`, because the emitting process (and anyone
/// who attaches to it) can read private interpolations back via OSLogStore.
/// Only non-payload metadata is ever interpolated, and identifying values are
/// hashed. The canary-scan test enforces this.
enum Log {
    static let engine = Logger(subsystem: "chat.pqrc", category: "engine")
    static let store = Logger(subsystem: "chat.pqrc", category: "store")
    static let ui = Logger(subsystem: "chat.pqrc", category: "ui")

    /// Logs a pipeline phase. Accepts byte counts and ids — never content.
    static func messageEvent(_ phase: String, conversationID: String, payloadBytes: Int) {
        engine.info(
            "\(phase, privacy: .public) conversation=\(conversationID, privacy: .private(mask: .hash)) bytes=\(payloadBytes, privacy: .public)"
        )
    }
}
