import Foundation

// A2A error model: the JSON-RPC 2.0 error object plus the A2A-specific code range
// (-32001…-32099), per docs/specification.md §5.4 and §9.5.

/// Error codes an A2A endpoint can return. Standard JSON-RPC codes plus the
/// A2A-specific range; unknown codes are preserved.
public enum A2AErrorCode: Sendable, Equatable, Hashable {
    // Standard JSON-RPC 2.0
    case jsonParseError  // -32700
    case invalidRequest  // -32600
    case methodNotFound  // -32601
    case invalidParams  // -32602
    case internalError  // -32603
    // A2A-specific
    case taskNotFound  // -32001
    case taskNotCancelable  // -32002
    case pushNotificationNotSupported  // -32003
    case unsupportedOperation  // -32004
    case contentTypeNotSupported  // -32005
    case invalidAgentResponse  // -32006
    case extendedAgentCardNotConfigured  // -32007
    case extensionSupportRequired  // -32008
    case versionNotSupported  // -32009
    case other(Int)

    public var rawValue: Int {
        switch self {
        case .jsonParseError: return -32700
        case .invalidRequest: return -32600
        case .methodNotFound: return -32601
        case .invalidParams: return -32602
        case .internalError: return -32603
        case .taskNotFound: return -32001
        case .taskNotCancelable: return -32002
        case .pushNotificationNotSupported: return -32003
        case .unsupportedOperation: return -32004
        case .contentTypeNotSupported: return -32005
        case .invalidAgentResponse: return -32006
        case .extendedAgentCardNotConfigured: return -32007
        case .extensionSupportRequired: return -32008
        case .versionNotSupported: return -32009
        case .other(let code): return code
        }
    }

    public init(rawValue: Int) {
        switch rawValue {
        case -32700: self = .jsonParseError
        case -32600: self = .invalidRequest
        case -32601: self = .methodNotFound
        case -32602: self = .invalidParams
        case -32603: self = .internalError
        case -32001: self = .taskNotFound
        case -32002: self = .taskNotCancelable
        case -32003: self = .pushNotificationNotSupported
        case -32004: self = .unsupportedOperation
        case -32005: self = .contentTypeNotSupported
        case -32006: self = .invalidAgentResponse
        case -32007: self = .extendedAgentCardNotConfigured
        case -32008: self = .extensionSupportRequired
        case -32009: self = .versionNotSupported
        default: self = .other(rawValue)
        }
    }

    /// The spec's default human-readable message for this code.
    public var defaultMessage: String {
        switch self {
        case .jsonParseError: return "Invalid JSON payload"
        case .invalidRequest: return "Request payload validation error"
        case .methodNotFound: return "Method not found"
        case .invalidParams: return "Invalid parameters"
        case .internalError: return "Internal error"
        case .taskNotFound: return "Task not found"
        case .taskNotCancelable: return "Task cannot be canceled"
        case .pushNotificationNotSupported: return "Push Notification is not supported"
        case .unsupportedOperation: return "This operation is not supported"
        case .contentTypeNotSupported: return "Incompatible content types"
        case .invalidAgentResponse: return "Invalid agent response"
        case .extendedAgentCardNotConfigured: return "Extended agent card not configured"
        case .extensionSupportRequired: return "Extension support required"
        case .versionNotSupported: return "Version not supported"
        case .other: return "Error"
        }
    }
}

extension A2AErrorCode: Codable {
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The JSON-RPC 2.0 error object as A2A profiles it: `data` is an array of objects,
/// each carrying a `@type` key (ProtoJSON `Any`), e.g. `google.rpc.ErrorInfo`.
public struct A2AErrorObject: Sendable, Equatable, Error {
    public var code: A2AErrorCode
    public var message: String
    public var data: [A2AJSONValue]?

    public init(code: A2AErrorCode, message: String? = nil, data: [A2AJSONValue]? = nil) {
        self.code = code
        self.message = message ?? code.defaultMessage
        self.data = data
    }
}

extension A2AErrorObject: Codable {
    private enum CodingKeys: String, CodingKey { case code, message, data }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code =
            try container.decodeIfPresent(A2AErrorCode.self, forKey: .code)
            ?? .internalError
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        data = try container.decodeIfPresent([A2AJSONValue].self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

/// Typed failures the SDK itself raises (distinct from wire `A2AErrorObject`s an
/// endpoint returns, though `.endpoint` wraps those).
public enum A2AClientError: Error, Sendable, Equatable {
    /// The remote endpoint returned a JSON-RPC error.
    case endpoint(A2AErrorObject)
    /// A response that is not valid JSON-RPC / not valid A2A JSON.
    case malformedResponse(String)
    /// HTTP-level failure (non-2xx status outside the JSON-RPC envelope).
    case httpStatus(Int)
    /// The agent card could not be fetched or failed validation.
    case invalidAgentCard(String)
    /// The card declares no interface this SDK can use.
    case noUsableInterface
    /// The transport was closed before the operation finished.
    case transportClosed
}
