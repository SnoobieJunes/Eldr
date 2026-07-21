// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A `Sendable`, `Codable` JSON value. ACP messages cross actor boundaries
/// (the stdio transport hands a parsed request to the agent actor; the agent
/// hands outbound notifications/requests back), and `[String: Any]` is not
/// `Sendable` under Swift 6 strict concurrency — so the wire is modeled as this
/// concrete enum instead of `Any`. It also gives us a stable, allocation-light
/// way to build JSON-RPC envelopes and pull fields out by key/path.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Convenience accessors (nil when the type doesn't match)

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            // `Int(d)` TRAPS (fatal error) on a non-finite or out-of-range double.
            // A malformed wire message (e.g. an `id`/`n`/`exit` field of `1e400`,
            // which JSONSerialization parses to +inf) would otherwise crash the
            // agent the moment any field is read as Int. Reject those instead.
            // Upper bound is strict: `Double(Int.max)` rounds UP to 2^63, and
            // `Int(2^63)` itself traps (Int.max is 2^63 − 1), so `<` not `<=`.
            guard d.isFinite,
                d >= Double(Int.min), d < Double(Int.max)
            else { return nil }
            return Int(d)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }; return nil
    }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Subscript into an object by key; `nil` for non-objects or missing keys.
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    // MARK: Foundation bridging (JSONSerialization interop on the stdio boundary)

    /// Parse one line of UTF-8 JSON. Returns `nil` on empty/invalid input.
    public static func parse(_ string: String) -> JSONValue? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSONValue(foundation: object)
    }

    /// Build from a `JSONSerialization` object graph (`NSNull`/`NSNumber`/…).
    public init(foundation object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            // Distinguish Bool from numeric (NSNumber bridges both).
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if CFNumberIsFloatType(n) {
                self = .double(n.doubleValue)
            } else {
                self = .int(n.intValue)
            }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map { JSONValue(foundation: $0) })
        case let d as [String: Any]:
            self = .object(d.mapValues { JSONValue(foundation: $0) })
        default:
            self = .null
        }
    }

    /// Convert back to a `JSONSerialization`-compatible object graph.
    public var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { $0.foundation }
        case .object(let o): return o.mapValues { $0.foundation }
        }
    }

    /// Serialize to a single-line JSON string (no trailing newline). Falls back to
    /// `null` on the (unreachable for valid JSONValue) serialization failure.
    public func serialized() -> String {
        let object = self.foundation
        // Top-level fragments (string/number/bool/null) need .fragmentsAllowed.
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else { return "null" }
        return string
    }
}

// MARK: - Ergonomic literal construction

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
