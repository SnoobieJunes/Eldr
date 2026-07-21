// SPDX-License-Identifier: Apache-2.0
import Foundation

// `Task`, `TaskStatus` and `TaskState` from lf.a2a.v1 (a2a.proto). The Swift type is
// `A2ATask` to keep `Swift.Task` unambiguous in async contexts.

/// Lifecycle state of a task (`TaskState`), serialized as the full proto enum name
/// (`TASK_STATE_SUBMITTED`). Unknown wire values are preserved, never fatal.
public enum A2ATaskState: Sendable, Equatable {
    case unspecified
    case submitted
    case working
    case completed
    case failed
    case canceled
    case inputRequired
    case rejected
    case authRequired
    case unknown(String)

    /// Terminal states end the task; streams for the task MUST close.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .canceled, .rejected: return true
        default: return false
        }
    }

    /// Interrupted states pause the task awaiting client action.
    public var isInterrupted: Bool {
        switch self {
        case .inputRequired, .authRequired: return true
        default: return false
        }
    }

    public var wireName: String {
        switch self {
        case .unspecified: return "TASK_STATE_UNSPECIFIED"
        case .submitted: return "TASK_STATE_SUBMITTED"
        case .working: return "TASK_STATE_WORKING"
        case .completed: return "TASK_STATE_COMPLETED"
        case .failed: return "TASK_STATE_FAILED"
        case .canceled: return "TASK_STATE_CANCELED"
        case .inputRequired: return "TASK_STATE_INPUT_REQUIRED"
        case .rejected: return "TASK_STATE_REJECTED"
        case .authRequired: return "TASK_STATE_AUTH_REQUIRED"
        case .unknown(let name): return name
        }
    }

    public init(wireName: String) {
        switch wireName {
        case "TASK_STATE_UNSPECIFIED": self = .unspecified
        case "TASK_STATE_SUBMITTED": self = .submitted
        case "TASK_STATE_WORKING": self = .working
        case "TASK_STATE_COMPLETED": self = .completed
        case "TASK_STATE_FAILED": self = .failed
        case "TASK_STATE_CANCELED": self = .canceled
        case "TASK_STATE_INPUT_REQUIRED": self = .inputRequired
        case "TASK_STATE_REJECTED": self = .rejected
        case "TASK_STATE_AUTH_REQUIRED": self = .authRequired
        default: self = .unknown(wireName)
        }
    }
}

extension A2ATaskState: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireName: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }
}

/// Status container for a task (`TaskStatus`). The timestamp stays an ISO 8601 string
/// on the wire type (the spec mandates UTC `YYYY-MM-DDTHH:mm:ss.sssZ`); use `date` for
/// a parsed value.
public struct A2ATaskStatus: Sendable, Equatable {
    public var state: A2ATaskState
    public var message: A2AMessage?
    public var timestamp: String?

    public init(state: A2ATaskState, message: A2AMessage? = nil, timestamp: String? = nil)
    {
        self.state = state
        self.message = message
        self.timestamp = timestamp
    }

    public var date: Date? {
        guard let timestamp else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser.date(from: timestamp)
            ?? ISO8601DateFormatter().date(from: timestamp)
    }
}

extension A2ATaskStatus: Codable {
    private enum CodingKeys: String, CodingKey { case state, message, timestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state =
            try container.decodeIfPresent(A2ATaskState.self, forKey: .state)
            ?? .unspecified
        message = try container.decodeIfPresent(A2AMessage.self, forKey: .message)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
    }
}

/// The core unit of action in A2A (`Task`). Ids are server-generated.
public struct A2ATask: Sendable, Equatable {
    public var id: String
    public var contextId: String
    public var status: A2ATaskStatus
    public var artifacts: [A2AArtifact]
    public var history: [A2AMessage]
    public var metadata: A2AJSONValue?

    public init(
        id: String, contextId: String = "", status: A2ATaskStatus,
        artifacts: [A2AArtifact] = [], history: [A2AMessage] = [],
        metadata: A2AJSONValue? = nil
    ) {
        self.id = id
        self.contextId = contextId
        self.status = status
        self.artifacts = artifacts
        self.history = history
        self.metadata = metadata
    }
}

extension A2ATask: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, contextId, status, artifacts, history, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        status =
            try container.decodeIfPresent(A2ATaskStatus.self, forKey: .status)
            ?? A2ATaskStatus(state: .unspecified)
        artifacts =
            try container.decodeIfPresent([A2AArtifact].self, forKey: .artifacts) ?? []
        history = try container.decodeIfPresent([A2AMessage].self, forKey: .history) ?? []
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(id, forKey: .id)
        try container.encodeIfNotEmpty(contextId, forKey: .contextId)
        try container.encode(status, forKey: .status)
        try container.encodeIfNotEmpty(artifacts, forKey: .artifacts)
        try container.encodeIfNotEmpty(history, forKey: .history)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}
