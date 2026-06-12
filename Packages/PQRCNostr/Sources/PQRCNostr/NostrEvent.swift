import Crypto
import Foundation
import PQRCCore

/// A NIP-01 Nostr event. `id` is the SHA-256 of the canonical serialization;
/// `sig` is a 64-byte BIP-340 Schnorr signature over `id` (hex). A rumor is an
/// event with an empty `sig` that MUST never be published unwrapped.
public struct NostrEvent: Codable, Equatable, Sendable {
    public var id: String
    public var pubkey: String
    public var createdAt: Int64
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var sig: String

    enum CodingKeys: String, CodingKey {
        case id, pubkey
        case createdAt = "created_at"
        case kind, tags, content, sig
    }

    public init(
        pubkey: String, createdAt: Int64, kind: Int, tags: [[String]], content: String,
        sig: String = ""
    ) {
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
        self.id = ""
        self.id = computedID()
    }

    public var isRumor: Bool { sig.isEmpty }

    /// NIP-01 canonical serialization: [0, pubkey, created_at, kind, tags, content]
    /// — UTF-8, no whitespace, minimal escaping.
    public func canonicalSerialization() -> Data {
        var out = "[0,"
        out += NostrJSON.string(pubkey) + ","
        out += String(createdAt) + ","
        out += String(kind) + ","
        out += NostrJSON.tags(tags) + ","
        out += NostrJSON.string(content)
        out += "]"
        return Data(out.utf8)
    }

    public func computedID() -> String {
        sha256(canonicalSerialization()).hexString
    }

    /// Structural validity: id matches content. Signature checks live in NostrKeypair.
    public func hasValidID() -> Bool {
        id == computedID()
    }

    public func firstTagValue(_ name: String) -> String? {
        tags.first { $0.count >= 2 && $0[0] == name }?[1]
    }
}

/// Minimal-escaping JSON string serializer per NIP-01: escape only
/// double-quote, backslash and control characters.
enum NostrJSON {
    static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func tags(_ tags: [[String]]) -> String {
        "[" + tags.map { tag in
            "[" + tag.map(string).joined(separator: ",") + "]"
        }.joined(separator: ",") + "]"
    }
}
