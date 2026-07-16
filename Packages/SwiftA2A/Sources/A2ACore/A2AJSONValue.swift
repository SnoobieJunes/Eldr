import Foundation

/// A JSON value (`google.protobuf.Value` / `google.protobuf.Struct` on the A2A wire).
///
/// Vendored rather than shared with any Eldr package: SwiftA2A must remain extractable
/// as a standalone SDK. Numeric equality is semantic (`.int(10) == .double(10.0)`) so
/// round-trip fixture tests are not sensitive to integer/float re-encoding.
public enum A2AJSONValue: Sendable {
    case object([String: A2AJSONValue])
    case array([A2AJSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
}

extension A2AJSONValue: Equatable {
    public static func == (lhs: A2AJSONValue, rhs: A2AJSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.bool(a), .bool(b)): return a == b
        case (.null, .null): return true
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): return Double(a) == b
        default: return false
        }
    }
}

extension A2AJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([A2AJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: A2AJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

extension A2AJSONValue {
    /// Object-member access; nil for non-objects or missing keys.
    public subscript(key: String) -> A2AJSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: A2AJSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }
}

extension A2AJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(arrayLiteral elements: A2AJSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, A2AJSONValue)...) {
        self = .object(.init(uniqueKeysWithValues: elements))
    }
}

/// Encoding helpers giving proto3-JSON "omit default/empty" semantics so re-encoded
/// values stay key-for-key faithful to canonical A2A JSON.
extension KeyedEncodingContainer {
    mutating func encodeIfNotEmpty(_ value: String, forKey key: Key) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }

    mutating func encodeIfNotEmpty(_ value: [some Encodable], forKey key: Key) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }

    mutating func encodeIfNotEmpty(
        _ value: [String: some Encodable], forKey key: Key
    ) throws {
        if !value.isEmpty { try encode(value, forKey: key) }
    }
}
