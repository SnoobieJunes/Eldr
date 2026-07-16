import Foundation

// The JSON-RPC 2.0 envelope for the A2A v1.0 JSON-RPC binding
// (docs/specification.md §9). Vendored: SwiftA2A must be extractable standalone.

/// A JSON-RPC request id: string or number (null ids are not used by A2A clients).
public enum JSONRPCID: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)

    public var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        }
    }
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "JSON-RPC id must be a string or number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

/// A JSON-RPC 2.0 request or notification (no id = notification).
public struct JSONRPCRequest: Sendable, Equatable {
    public var id: JSONRPCID?
    public var method: String
    public var params: A2AJSONValue?

    public init(id: JSONRPCID?, method: String, params: A2AJSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// Build a request with typed params.
    public init(id: JSONRPCID?, method: A2AMethod, params: (some Encodable)?) throws {
        self.id = id
        self.method = method.rawValue
        self.params = try params.map { try A2AWireCodec.jsonValue(from: $0) }
    }

    /// Decode the params into a typed request object.
    public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
        try A2AWireCodec.decode(type, from: params ?? .object([:]))
    }
}

extension JSONRPCRequest: Codable {
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        guard version == "2.0" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "jsonrpc must be \"2.0\""))
        }
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(A2AJSONValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// A JSON-RPC 2.0 response: exactly one of result / error.
public struct JSONRPCResponse: Sendable, Equatable {
    public var id: JSONRPCID?
    public var result: A2AJSONValue?
    public var error: A2AErrorObject?

    public init(id: JSONRPCID?, result: A2AJSONValue) {
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID?, error: A2AErrorObject) {
        self.id = id
        self.result = nil
        self.error = error
    }

    /// Build a success response with a typed result.
    public init(id: JSONRPCID?, result: some Encodable) throws {
        self.id = id
        self.result = try A2AWireCodec.jsonValue(from: result)
        self.error = nil
    }

    /// Decode the result into a typed value, or throw the endpoint's error.
    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        if let error { throw A2AClientError.endpoint(error) }
        guard let result else {
            throw A2AClientError.malformedResponse("response has neither result nor error")
        }
        return try A2AWireCodec.decode(type, from: result)
    }
}

extension JSONRPCResponse: Codable {
    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        guard version == "2.0" else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "jsonrpc must be \"2.0\""))
        }
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        result = try container.decodeIfPresent(A2AJSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(A2AErrorObject.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "JSON-RPC response must carry exactly one of result/error"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Shared JSON coding for the A2A wire: plain `JSONEncoder`/`JSONDecoder` with no
/// key strategy — every type's CodingKeys already carry the exact wire spellings.
public enum A2AWireCodec {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func encodeString(_ value: some Encodable) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws
        -> T
    {
        try decode(type, from: Data(string.utf8))
    }

    /// Re-encode any Encodable into the JSON value tree (for JSON-RPC params/result).
    public static func jsonValue(from value: some Encodable) throws -> A2AJSONValue {
        try decode(A2AJSONValue.self, from: try encode(value))
    }

    /// Decode a typed value out of a JSON value tree.
    public static func decode<T: Decodable>(_ type: T.Type, from value: A2AJSONValue)
        throws -> T
    {
        try decode(type, from: try encode(value))
    }
}
