// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// NIP-01 / NIP-42 WebSocket framing — the JSON array messages exchanged
/// between a Nostr client and a relay. Shared by `NostrWebSocketTransport`
/// (client side) and `NostrRelayServer` (the pqrc-relay frontend), so the two
/// can never drift apart.
///
/// Decoding is tolerant by design (SPEC §12 forward compatibility): unknown
/// message types, extra array elements, and unknown filter fields all decode
/// to `nil` / are ignored — never fatal.

/// Messages a client sends to a relay.
public enum NostrClientMessage: Sendable {
    case event(NostrEvent)
    case req(subscriptionID: String, filters: [NostrFilter])
    case close(subscriptionID: String)
    /// NIP-42: the signed kind-22242 answer to a relay challenge.
    case auth(NostrEvent)
}

/// Messages a relay sends to a client.
public enum NostrRelayMessage: Sendable {
    case event(subscriptionID: String, NostrEvent)
    case ok(eventID: String, accepted: Bool, message: String)
    case eose(subscriptionID: String)
    /// NIP-42: the relay's challenge string.
    case auth(challenge: String)
    case notice(String)
    /// The relay ended a subscription server-side (NIP-01 CLOSED).
    case closed(subscriptionID: String, message: String)
}

public enum NostrWire {
    // MARK: Encoding

    public static func encode(_ message: NostrClientMessage) throws -> String {
        switch message {
        case .event(let event):
            return try arrayJSON(["EVENT", try jsonObject(event)])
        case .req(let subscriptionID, let filters):
            return try arrayJSON(["REQ", subscriptionID] + filters.map(filterObject))
        case .close(let subscriptionID):
            return try arrayJSON(["CLOSE", subscriptionID])
        case .auth(let event):
            return try arrayJSON(["AUTH", try jsonObject(event)])
        }
    }

    public static func encode(_ message: NostrRelayMessage) throws -> String {
        switch message {
        case .event(let subscriptionID, let event):
            return try arrayJSON(["EVENT", subscriptionID, try jsonObject(event)])
        case .ok(let eventID, let accepted, let text):
            return try arrayJSON(["OK", eventID, accepted, text])
        case .eose(let subscriptionID):
            return try arrayJSON(["EOSE", subscriptionID])
        case .auth(let challenge):
            return try arrayJSON(["AUTH", challenge])
        case .notice(let text):
            return try arrayJSON(["NOTICE", text])
        case .closed(let subscriptionID, let text):
            return try arrayJSON(["CLOSED", subscriptionID, text])
        }
    }

    // MARK: Decoding

    public static func decodeClient(_ text: String) -> NostrClientMessage? {
        guard let array = parseArray(text), let type = array.first as? String else { return nil }
        switch type {
        case "EVENT":
            guard array.count >= 2, let event = event(from: array[1]) else { return nil }
            return .event(event)
        case "REQ":
            guard array.count >= 2, let subscriptionID = array[1] as? String else { return nil }
            let filters = array.dropFirst(2).compactMap { $0 as? [String: Any] }.map(filter(from:))
            return .req(subscriptionID: subscriptionID, filters: filters)
        case "CLOSE":
            guard array.count >= 2, let subscriptionID = array[1] as? String else { return nil }
            return .close(subscriptionID: subscriptionID)
        case "AUTH":
            guard array.count >= 2, let event = event(from: array[1]) else { return nil }
            return .auth(event)
        default:
            return nil
        }
    }

    public static func decodeRelay(_ text: String) -> NostrRelayMessage? {
        guard let array = parseArray(text), let type = array.first as? String else { return nil }
        switch type {
        case "EVENT":
            guard array.count >= 3, let subscriptionID = array[1] as? String,
                let event = event(from: array[2])
            else { return nil }
            return .event(subscriptionID: subscriptionID, event)
        case "OK":
            guard array.count >= 3, let eventID = array[1] as? String,
                let accepted = array[2] as? Bool
            else { return nil }
            return .ok(eventID: eventID, accepted: accepted, message: array.count >= 4 ? array[3] as? String ?? "" : "")
        case "EOSE":
            guard array.count >= 2, let subscriptionID = array[1] as? String else { return nil }
            return .eose(subscriptionID: subscriptionID)
        case "AUTH":
            guard array.count >= 2, let challenge = array[1] as? String else { return nil }
            return .auth(challenge: challenge)
        case "NOTICE":
            guard array.count >= 2, let text = array[1] as? String else { return nil }
            return .notice(text)
        case "CLOSED":
            guard array.count >= 2, let subscriptionID = array[1] as? String else { return nil }
            return .closed(
                subscriptionID: subscriptionID,
                message: array.count >= 3 ? array[2] as? String ?? "" : "")
        default:
            return nil
        }
    }

    // MARK: JSON plumbing

    /// `NostrEvent` is Codable with NIP-01 field names; round-trip through
    /// Data to splice it into the heterogeneous JSON arrays NIP-01 uses.
    private static func jsonObject(_ event: NostrEvent) throws -> Any {
        try JSONSerialization.jsonObject(with: WireJSON.encoder().encode(event))
    }

    private static func event(from value: Any) -> NostrEvent? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return try? WireJSON.decoder().decode(NostrEvent.self, from: data)
    }

    /// NIP-01 filter wire names: `kinds`, `authors`, `ids`, `since`, `#p`.
    private static func filterObject(_ filter: NostrFilter) -> [String: Any] {
        var object: [String: Any] = [:]
        if let kinds = filter.kinds { object["kinds"] = kinds }
        if let authors = filter.authors { object["authors"] = authors }
        if let ids = filter.ids { object["ids"] = ids }
        if let since = filter.since { object["since"] = since }
        if let pTags = filter.pTags { object["#p"] = pTags }
        return object
    }

    private static func filter(from object: [String: Any]) -> NostrFilter {
        NostrFilter(
            kinds: object["kinds"] as? [Int],
            authors: object["authors"] as? [String],
            pTags: object["#p"] as? [String],
            ids: object["ids"] as? [String],
            since: (object["since"] as? NSNumber)?.int64Value)
    }

    private static func arrayJSON(_ array: [Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: array, options: [.withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseArray(_ text: String) -> [Any]? {
        guard let data = text.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        return array
    }
}
