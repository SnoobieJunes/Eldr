// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A2A protocol version negotiation (docs/specification.md §7).
///
/// Clients MUST send `A2A-Version` on every request; servers MUST process requests
/// with the requested `Major.Minor` semantics or return `VersionNotSupportedError`.
/// An empty/absent header means 0.3 by definition — this SDK targets 1.0 only, so
/// its server surface rejects that (recorded in DEVIATIONS; 0.3 compatibility is an
/// explicit non-goal for v1 of the SDK).
public enum A2AVersion {
    /// The protocol version this SDK implements.
    public static let current = "1.0"

    /// Versions the SDK's server surface accepts.
    public static let supported: Set<String> = ["1.0"]

    /// The HTTP header / service-parameter name.
    public static let headerName = "A2A-Version"

    /// The extension-negotiation header name (comma-separated extension URIs).
    public static let extensionsHeaderName = "A2A-Extensions"

    /// Whether a request-declared version (nil/empty = 0.3 per spec) is supported.
    public static func isSupported(_ version: String?) -> Bool {
        guard let version, !version.isEmpty else { return false }
        return supported.contains(version)
    }
}

/// JSON-RPC method names for the A2A v1.0 binding (docs/specification.md §9.4).
/// v1.0 uses the proto RPC names directly — NOT the 0.3-era `message/send` style.
public enum A2AMethod: String, Sendable, CaseIterable {
    case sendMessage = "SendMessage"
    case sendStreamingMessage = "SendStreamingMessage"
    case getTask = "GetTask"
    case listTasks = "ListTasks"
    case cancelTask = "CancelTask"
    case subscribeToTask = "SubscribeToTask"
    case createTaskPushNotificationConfig = "CreateTaskPushNotificationConfig"
    case getTaskPushNotificationConfig = "GetTaskPushNotificationConfig"
    case listTaskPushNotificationConfigs = "ListTaskPushNotificationConfigs"
    case deleteTaskPushNotificationConfig = "DeleteTaskPushNotificationConfig"
    case getExtendedAgentCard = "GetExtendedAgentCard"

    /// Methods whose responses stream (SSE over HTTP).
    public var isStreaming: Bool {
        switch self {
        case .sendStreamingMessage, .subscribeToTask: return true
        default: return false
        }
    }
}
