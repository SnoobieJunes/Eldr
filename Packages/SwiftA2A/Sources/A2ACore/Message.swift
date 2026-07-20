// SPDX-License-Identifier: Apache-2.0
import Foundation

// `Message`, `Part`, `Artifact` and `Role` from lf.a2a.v1 (a2a.proto), in the proto3
// canonical JSON mapping: lowerCamelCase keys, enums as their full proto names
// (`ROLE_USER`), `bytes` as base64 strings, absent fields = proto defaults.

/// The sender of a message (`Role`). Unknown wire values are preserved, never fatal
/// (forward compatibility — the same rule PQRC applies to unknown JSON fields).
public enum A2ARole: Sendable, Equatable {
    case unspecified
    case user
    case agent
    case unknown(String)

    public var wireName: String {
        switch self {
        case .unspecified: return "ROLE_UNSPECIFIED"
        case .user: return "ROLE_USER"
        case .agent: return "ROLE_AGENT"
        case .unknown(let name): return name
        }
    }

    public init(wireName: String) {
        switch wireName {
        case "ROLE_UNSPECIFIED": self = .unspecified
        case "ROLE_USER": self = .user
        case "ROLE_AGENT": self = .agent
        default: self = .unknown(wireName)
        }
    }
}

extension A2ARole: Codable {
    public init(from decoder: Decoder) throws {
        self.init(wireName: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireName)
    }
}

/// One section of communication content (`Part`) — a proto `oneof` over
/// text | raw | url | data, plus part-wide fields that apply to every variant.
///
/// `raw` stays a base64 String on the wire type (use `rawData` for bytes) so a
/// payload we merely relay round-trips byte-for-byte even if it is not valid base64.
public struct A2APart: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// Base64-encoded bytes, kept in wire form.
        case raw(base64: String)
        case url(String)
        case data(A2AJSONValue)
    }

    public var content: Content
    public var metadata: A2AJSONValue?
    public var filename: String?
    public var mediaType: String?

    public init(
        content: Content, metadata: A2AJSONValue? = nil, filename: String? = nil,
        mediaType: String? = nil
    ) {
        self.content = content
        self.metadata = metadata
        self.filename = filename
        self.mediaType = mediaType
    }

    public static func text(_ text: String) -> A2APart { A2APart(content: .text(text)) }

    /// Decoded bytes of a `.raw` part, or nil for other variants / invalid base64.
    public var rawData: Data? {
        if case .raw(let base64) = content { return Data(base64Encoded: base64) }
        return nil
    }

    /// The text of a `.text` part, or nil.
    public var text: String? {
        if case .text(let value) = content { return value }
        return nil
    }
}

extension A2APart: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, raw, url, data, metadata, filename, mediaType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var found: [Content] = []
        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            found.append(.text(text))
        }
        if let raw = try container.decodeIfPresent(String.self, forKey: .raw) {
            found.append(.raw(base64: raw))
        }
        if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            found.append(.url(url))
        }
        if let data = try container.decodeIfPresent(A2AJSONValue.self, forKey: .data) {
            found.append(.data(data))
        }
        guard found.count == 1 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Part must populate exactly one of text/raw/url/data (found \(found.count))"
                ))
        }
        content = found[0]
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
        filename = try container.decodeIfPresent(String.self, forKey: .filename)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch content {
        case .text(let text): try container.encode(text, forKey: .text)
        case .raw(let base64): try container.encode(base64, forKey: .raw)
        case .url(let url): try container.encode(url, forKey: .url)
        case .data(let data): try container.encode(data, forKey: .data)
        }
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(filename, forKey: .filename)
        try container.encodeIfPresent(mediaType, forKey: .mediaType)
    }
}

/// One unit of communication between client and server (`Message`).
public struct A2AMessage: Sendable, Equatable {
    /// Creator-generated unique id (e.g. UUID). Proto default "" when absent.
    public var messageId: String
    public var contextId: String
    public var taskId: String
    public var role: A2ARole
    public var parts: [A2APart]
    public var metadata: A2AJSONValue?
    /// URIs of extensions present or contributed to this message.
    public var extensions: [String]
    public var referenceTaskIds: [String]

    public init(
        messageId: String = "", contextId: String = "", taskId: String = "",
        role: A2ARole, parts: [A2APart], metadata: A2AJSONValue? = nil,
        extensions: [String] = [], referenceTaskIds: [String] = []
    ) {
        self.messageId = messageId
        self.contextId = contextId
        self.taskId = taskId
        self.role = role
        self.parts = parts
        self.metadata = metadata
        self.extensions = extensions
        self.referenceTaskIds = referenceTaskIds
    }
}

extension A2AMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case messageId, contextId, taskId, role, parts, metadata, extensions,
            referenceTaskIds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try container.decodeIfPresent(String.self, forKey: .messageId) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        role =
            try container.decodeIfPresent(A2ARole.self, forKey: .role) ?? .unspecified
        parts = try container.decodeIfPresent([A2APart].self, forKey: .parts) ?? []
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
        extensions =
            try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
        referenceTaskIds =
            try container.decodeIfPresent([String].self, forKey: .referenceTaskIds) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(messageId, forKey: .messageId)
        try container.encodeIfNotEmpty(contextId, forKey: .contextId)
        try container.encodeIfNotEmpty(taskId, forKey: .taskId)
        if role != .unspecified { try container.encode(role, forKey: .role) }
        try container.encodeIfNotEmpty(parts, forKey: .parts)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfNotEmpty(extensions, forKey: .extensions)
        try container.encodeIfNotEmpty(referenceTaskIds, forKey: .referenceTaskIds)
    }
}

/// A task output (`Artifact`). Results SHOULD be returned as artifacts, not messages.
public struct A2AArtifact: Sendable, Equatable {
    public var artifactId: String
    public var name: String
    public var description: String
    public var parts: [A2APart]
    public var metadata: A2AJSONValue?
    public var extensions: [String]

    public init(
        artifactId: String, name: String = "", description: String = "",
        parts: [A2APart], metadata: A2AJSONValue? = nil, extensions: [String] = []
    ) {
        self.artifactId = artifactId
        self.name = name
        self.description = description
        self.parts = parts
        self.metadata = metadata
        self.extensions = extensions
    }
}

extension A2AArtifact: Codable {
    private enum CodingKeys: String, CodingKey {
        case artifactId, name, description, parts, metadata, extensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artifactId = try container.decodeIfPresent(String.self, forKey: .artifactId) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description =
            try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        parts = try container.decodeIfPresent([A2APart].self, forKey: .parts) ?? []
        metadata = try container.decodeIfPresent(A2AJSONValue.self, forKey: .metadata)
        extensions =
            try container.decodeIfPresent([String].self, forKey: .extensions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfNotEmpty(artifactId, forKey: .artifactId)
        try container.encodeIfNotEmpty(name, forKey: .name)
        try container.encodeIfNotEmpty(description, forKey: .description)
        try container.encodeIfNotEmpty(parts, forKey: .parts)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfNotEmpty(extensions, forKey: .extensions)
    }
}
