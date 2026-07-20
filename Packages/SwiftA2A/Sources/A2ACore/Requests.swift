// SPDX-License-Identifier: Apache-2.0
import Foundation

// Request/response messages from lf.a2a.v1 (a2a.proto). Every request carries an
// optional `tenant` routing field that MUST echo the selected AgentInterface's
// `tenant` when that is set.

/// Push-notification auth details (`AuthenticationInfo`). Modeled for wire
/// completeness; this SDK does not implement webhook push delivery (DEVIATIONS —
/// webhook registration leaks the client's address).
public struct A2AAuthenticationInfo: Sendable, Equatable {
    public var scheme: String
    public var credentials: String

    public init(scheme: String, credentials: String = "") {
        self.scheme = scheme
        self.credentials = credentials
    }
}

extension A2AAuthenticationInfo: Codable {
    private enum CodingKeys: String, CodingKey { case scheme, credentials }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scheme = try container.decodeIfPresent(String.self, forKey: .scheme) ?? ""
        credentials =
            try container.decodeIfPresent(String.self, forKey: .credentials) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(scheme, forKey: .scheme)
        try container.encodeIfNotEmpty(credentials, forKey: .credentials)
    }
}

/// Associates a push notification configuration with a task
/// (`TaskPushNotificationConfig`). Modeled for wire completeness only.
public struct A2ATaskPushNotificationConfig: Sendable, Equatable {
    public var tenant: String
    public var id: String
    public var taskId: String
    public var url: String
    public var token: String
    public var authentication: A2AAuthenticationInfo?

    public init(
        tenant: String = "", id: String = "", taskId: String = "", url: String,
        token: String = "", authentication: A2AAuthenticationInfo? = nil
    ) {
        self.tenant = tenant
        self.id = id
        self.taskId = taskId
        self.url = url
        self.token = token
        self.authentication = authentication
    }
}

extension A2ATaskPushNotificationConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case tenant, id, taskId, url, token, authentication
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        authentication = try container.decodeIfPresent(
            A2AAuthenticationInfo.self, forKey: .authentication)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(id, forKey: .id)
        try container.encodeIfNotEmpty(taskId, forKey: .taskId)
        try container.encodeIfNotEmpty(url, forKey: .url)
        try container.encodeIfNotEmpty(token, forKey: .token)
        try container.encodeIfPresent(authentication, forKey: .authentication)
    }
}

/// Configuration of a send-message request (`SendMessageConfiguration`).
public struct A2ASendMessageConfiguration: Sendable, Equatable {
    /// Media types the client accepts for response parts.
    public var acceptedOutputModes: [String]
    public var taskPushNotificationConfig: A2ATaskPushNotificationConfig?
    /// Max most-recent history messages to return; nil = no client-imposed limit.
    public var historyLength: Int?
    /// True: return immediately after task creation. False (default): wait for a
    /// terminal or interrupted state.
    public var returnImmediately: Bool

    public init(
        acceptedOutputModes: [String] = [],
        taskPushNotificationConfig: A2ATaskPushNotificationConfig? = nil,
        historyLength: Int? = nil, returnImmediately: Bool = false
    ) {
        self.acceptedOutputModes = acceptedOutputModes
        self.taskPushNotificationConfig = taskPushNotificationConfig
        self.historyLength = historyLength
        self.returnImmediately = returnImmediately
    }
}

extension A2ASendMessageConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case acceptedOutputModes, taskPushNotificationConfig, historyLength
        case returnImmediately
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acceptedOutputModes =
            try container.decodeIfPresent([String].self, forKey: .acceptedOutputModes)
            ?? []
        taskPushNotificationConfig = try container.decodeIfPresent(
            A2ATaskPushNotificationConfig.self, forKey: .taskPushNotificationConfig)
        historyLength = try container.decodeIfPresent(Int.self, forKey: .historyLength)
        returnImmediately =
            try container.decodeIfPresent(Bool.self, forKey: .returnImmediately) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(acceptedOutputModes, forKey: .acceptedOutputModes)
        try container.encodeIfPresent(
            taskPushNotificationConfig, forKey: .taskPushNotificationConfig)
        try container.encodeIfPresent(historyLength, forKey: .historyLength)
        if returnImmediately { try container.encode(true, forKey: .returnImmediately) }
    }
}

/// Params for `SendMessage` / `SendStreamingMessage` (`SendMessageRequest`).
public struct A2ASendMessageRequest: Sendable, Equatable {
    public var tenant: String
    public var message: A2AMessage
    public var configuration: A2ASendMessageConfiguration?
    public var metadata: A2AJSONValue?

    public init(
        tenant: String = "", message: A2AMessage,
        configuration: A2ASendMessageConfiguration? = nil, metadata: A2AJSONValue? = nil
    ) {
        self.tenant = tenant
        self.message = message
        self.configuration = configuration
        self.metadata = metadata
    }
}

extension A2ASendMessageRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case tenant, message, configuration, metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        message =
            try container.decodeIfPresent(A2AMessage.self, forKey: .message)
            ?? A2AMessage(role: .unspecified, parts: [])
        configuration = try container.decodeIfPresent(
            A2ASendMessageConfiguration.self, forKey: .configuration)
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Params for `GetTask` (`GetTaskRequest`).
public struct A2AGetTaskRequest: Sendable, Equatable {
    public var tenant: String
    public var id: String
    public var historyLength: Int?

    public init(tenant: String = "", id: String, historyLength: Int? = nil) {
        self.tenant = tenant
        self.id = id
        self.historyLength = historyLength
    }
}

extension A2AGetTaskRequest: Codable {
    private enum CodingKeys: String, CodingKey { case tenant, id, historyLength }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        historyLength = try container.decodeIfPresent(Int.self, forKey: .historyLength)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(id, forKey: .id)
        try container.encodeIfPresent(historyLength, forKey: .historyLength)
    }
}

/// Params for `ListTasks` (`ListTasksRequest`).
public struct A2AListTasksRequest: Sendable, Equatable {
    public var tenant: String
    public var contextId: String
    public var status: A2ATaskState?
    public var pageSize: Int?
    public var pageToken: String
    public var historyLength: Int?
    public var statusTimestampAfter: String?
    public var includeArtifacts: Bool?

    public init(
        tenant: String = "", contextId: String = "", status: A2ATaskState? = nil,
        pageSize: Int? = nil, pageToken: String = "", historyLength: Int? = nil,
        statusTimestampAfter: String? = nil, includeArtifacts: Bool? = nil
    ) {
        self.tenant = tenant
        self.contextId = contextId
        self.status = status
        self.pageSize = pageSize
        self.pageToken = pageToken
        self.historyLength = historyLength
        self.statusTimestampAfter = statusTimestampAfter
        self.includeArtifacts = includeArtifacts
    }
}

extension A2AListTasksRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case tenant, contextId, status, pageSize, pageToken, historyLength
        case statusTimestampAfter, includeArtifacts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        status = try container.decodeIfPresent(A2ATaskState.self, forKey: .status)
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize)
        pageToken = try container.decodeIfPresent(String.self, forKey: .pageToken) ?? ""
        historyLength = try container.decodeIfPresent(Int.self, forKey: .historyLength)
        statusTimestampAfter =
            try container.decodeIfPresent(String.self, forKey: .statusTimestampAfter)
        includeArtifacts =
            try container.decodeIfPresent(Bool.self, forKey: .includeArtifacts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(contextId, forKey: .contextId)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(pageSize, forKey: .pageSize)
        try container.encodeIfNotEmpty(pageToken, forKey: .pageToken)
        try container.encodeIfPresent(historyLength, forKey: .historyLength)
        try container.encodeIfPresent(statusTimestampAfter, forKey: .statusTimestampAfter)
        try container.encodeIfPresent(includeArtifacts, forKey: .includeArtifacts)
    }
}

/// Result of `ListTasks` (`ListTasksResponse`).
public struct A2AListTasksResponse: Sendable, Equatable {
    public var tasks: [A2ATask]
    public var nextPageToken: String
    public var pageSize: Int
    public var totalSize: Int

    public init(
        tasks: [A2ATask], nextPageToken: String = "", pageSize: Int = 0, totalSize: Int = 0
    ) {
        self.tasks = tasks
        self.nextPageToken = nextPageToken
        self.pageSize = pageSize
        self.totalSize = totalSize
    }
}

extension A2AListTasksResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case tasks, nextPageToken, pageSize, totalSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decodeIfPresent([A2ATask].self, forKey: .tasks) ?? []
        nextPageToken =
            try container.decodeIfPresent(String.self, forKey: .nextPageToken) ?? ""
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 0
        totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tasks, forKey: .tasks)
        try container.encodeIfNotEmpty(nextPageToken, forKey: .nextPageToken)
        if pageSize != 0 { try container.encode(pageSize, forKey: .pageSize) }
        if totalSize != 0 { try container.encode(totalSize, forKey: .totalSize) }
    }
}

/// Params for `CancelTask` (`CancelTaskRequest`).
public struct A2ACancelTaskRequest: Sendable, Equatable {
    public var tenant: String
    public var id: String
    public var metadata: A2AJSONValue?

    public init(tenant: String = "", id: String, metadata: A2AJSONValue? = nil) {
        self.tenant = tenant
        self.id = id
        self.metadata = metadata
    }
}

extension A2ACancelTaskRequest: Codable {
    private enum CodingKeys: String, CodingKey { case tenant, id, metadata }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(id, forKey: .id)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// Params for `SubscribeToTask` (`SubscribeToTaskRequest`).
public struct A2ASubscribeToTaskRequest: Sendable, Equatable {
    public var tenant: String
    public var id: String

    public init(tenant: String = "", id: String) {
        self.tenant = tenant
        self.id = id
    }
}

extension A2ASubscribeToTaskRequest: Codable {
    private enum CodingKeys: String, CodingKey { case tenant, id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
        try container.encodeIfNotEmpty(id, forKey: .id)
    }
}

/// Params for `GetExtendedAgentCard` (`GetExtendedAgentCardRequest`).
public struct A2AGetExtendedAgentCardRequest: Sendable, Equatable {
    public var tenant: String

    public init(tenant: String = "") {
        self.tenant = tenant
    }
}

extension A2AGetExtendedAgentCardRequest: Codable {
    private enum CodingKeys: String, CodingKey { case tenant }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tenant = try container.decodeIfPresent(String.self, forKey: .tenant) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(tenant, forKey: .tenant)
    }
}
