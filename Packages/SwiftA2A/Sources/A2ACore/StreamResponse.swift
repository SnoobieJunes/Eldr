import Foundation

// Streaming / response wrapper types from lf.a2a.v1 (a2a.proto): `StreamResponse`,
// `SendMessageResponse`, `TaskStatusUpdateEvent`, `TaskArtifactUpdateEvent`.

/// Notifies the client of a change in a task's status (`TaskStatusUpdateEvent`).
public struct A2ATaskStatusUpdateEvent: Sendable, Equatable {
    public var taskId: String
    public var contextId: String
    public var status: A2ATaskStatus
    public var metadata: A2AJSONValue?

    public init(
        taskId: String, contextId: String = "", status: A2ATaskStatus,
        metadata: A2AJSONValue? = nil
    ) {
        self.taskId = taskId
        self.contextId = contextId
        self.status = status
        self.metadata = metadata
    }
}

extension A2ATaskStatusUpdateEvent: Codable {
    private enum CodingKeys: String, CodingKey { case taskId, contextId, status, metadata }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        status =
            try container.decodeIfPresent(A2ATaskStatus.self, forKey: .status)
            ?? A2ATaskStatus(state: .unspecified)
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(taskId, forKey: .taskId)
        try container.encodeIfNotEmpty(contextId, forKey: .contextId)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// A task delta carrying a generated or updated artifact (`TaskArtifactUpdateEvent`).
public struct A2ATaskArtifactUpdateEvent: Sendable, Equatable {
    public var taskId: String
    public var contextId: String
    public var artifact: A2AArtifact
    /// Append this content to a previously sent artifact with the same id.
    public var append: Bool
    /// True when this is the final chunk of the artifact.
    public var lastChunk: Bool
    public var metadata: A2AJSONValue?

    public init(
        taskId: String, contextId: String = "", artifact: A2AArtifact,
        append: Bool = false, lastChunk: Bool = false, metadata: A2AJSONValue? = nil
    ) {
        self.taskId = taskId
        self.contextId = contextId
        self.artifact = artifact
        self.append = append
        self.lastChunk = lastChunk
        self.metadata = metadata
    }
}

extension A2ATaskArtifactUpdateEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case taskId, contextId, artifact, append, lastChunk, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        artifact =
            try container.decodeIfPresent(A2AArtifact.self, forKey: .artifact)
            ?? A2AArtifact(artifactId: "", parts: [])
        append = try container.decodeIfPresent(Bool.self, forKey: .append) ?? false
        lastChunk = try container.decodeIfPresent(Bool.self, forKey: .lastChunk) ?? false
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(taskId, forKey: .taskId)
        try container.encodeIfNotEmpty(contextId, forKey: .contextId)
        try container.encode(artifact, forKey: .artifact)
        if append { try container.encode(true, forKey: .append) }
        if lastChunk { try container.encode(true, forKey: .lastChunk) }
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Response payload of `SendMessage` — a proto `oneof` over task | message.
public enum A2ASendMessageResponse: Sendable, Equatable {
    case task(A2ATask)
    case message(A2AMessage)
}

extension A2ASendMessageResponse: Codable {
    private enum CodingKeys: String, CodingKey { case task, message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let task = try container.decodeIfPresent(A2ATask.self, forKey: .task) {
            self = .task(task)
        } else if let message = try container.decodeIfPresent(
            A2AMessage.self, forKey: .message)
        {
            self = .message(message)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "SendMessageResponse must populate one of task/message"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .task(let task): try container.encode(task, forKey: .task)
        case .message(let message): try container.encode(message, forKey: .message)
        }
    }
}

/// Streaming wrapper (`StreamResponse`) — a proto `oneof` over
/// task | message | statusUpdate | artifactUpdate. Implementations MUST deliver
/// events in generation order; streams close on a terminal task state.
public enum A2AStreamResponse: Sendable, Equatable {
    case task(A2ATask)
    case message(A2AMessage)
    case statusUpdate(A2ATaskStatusUpdateEvent)
    case artifactUpdate(A2ATaskArtifactUpdateEvent)
}

extension A2AStreamResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case task, message, statusUpdate, artifactUpdate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let task = try container.decodeIfPresent(A2ATask.self, forKey: .task) {
            self = .task(task)
        } else if let message = try container.decodeIfPresent(
            A2AMessage.self, forKey: .message)
        {
            self = .message(message)
        } else if let update = try container.decodeIfPresent(
            A2ATaskStatusUpdateEvent.self, forKey: .statusUpdate)
        {
            self = .statusUpdate(update)
        } else if let update = try container.decodeIfPresent(
            A2ATaskArtifactUpdateEvent.self, forKey: .artifactUpdate)
        {
            self = .artifactUpdate(update)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "StreamResponse must populate one of task/message/statusUpdate/artifactUpdate"
                ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .task(let task): try container.encode(task, forKey: .task)
        case .message(let message): try container.encode(message, forKey: .message)
        case .statusUpdate(let update): try container.encode(update, forKey: .statusUpdate)
        case .artifactUpdate(let update):
            try container.encode(update, forKey: .artifactUpdate)
        }
    }
}
