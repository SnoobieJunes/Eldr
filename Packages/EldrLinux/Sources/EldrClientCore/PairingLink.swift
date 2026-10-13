// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCNostr

/// The `pqrc:add?npub=…` contact link EldrChat shows as a QR (Settings ▸ share) and
/// handles as a deep link. EldrChat reads `npub` and the optional `type` (e.g.
/// `coding_agent`); other query items (we add `relay`) are ignored by the phone.
public struct PairingLink: Sendable, Equatable {
    public let nostrPubkeyHex: String
    public let type: String?
    public let relay: String?

    public init(nostrPubkeyHex: String, type: String? = nil, relay: String? = nil) {
        self.nostrPubkeyHex = nostrPubkeyHex
        self.type = type
        self.relay = relay
    }

    public var npub: String { Bech32.npub(nostrPubkeyHex) }

    public var uri: String {
        var s = "pqrc:add?npub=\(npub)"
        if let type { s += "&type=\(type)" }
        if let relay { s += "&relay=\(relay)" }
        return s
    }

    /// Accepts a full `pqrc:add?…` link, a bare `npub1…`, or a 64-char Nostr pubkey hex.
    /// Returns nil for anything else (never guesses).
    public static func parse(_ input: String) -> PairingLink? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("pqrc:") {
            guard let c = URLComponents(string: s), c.scheme == "pqrc",
                let npub = c.queryItems?.first(where: { $0.name == "npub" })?.value,
                let hex = Bech32.pubkeyHex(fromNpub: npub)
            else { return nil }
            let item = { (n: String) in c.queryItems?.first(where: { $0.name == n })?.value }
            return PairingLink(nostrPubkeyHex: hex, type: item("type"), relay: item("relay"))
        }
        if s.hasPrefix("npub1") {
            return Bech32.pubkeyHex(fromNpub: s).map { PairingLink(nostrPubkeyHex: $0) }
        }
        let lower = s.lowercased()
        if lower.count == 64, lower.allSatisfy({ $0.isHexDigit }) {
            return PairingLink(nostrPubkeyHex: lower)
        }
        return nil
    }
}
