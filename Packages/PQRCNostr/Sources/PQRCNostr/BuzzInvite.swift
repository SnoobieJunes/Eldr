// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession lives here on Linux
#endif

// MARK: - The link

/// A parsed Buzz workspace invite.
///
/// Buzz mints stateless HMAC'd invite codes and shares them as
/// `https://<relay>/invite/<code>`; the `buzz://join?relay=…&code=…` form is the
/// installed-app handoff from that landing page. Both are accepted here, exactly
/// as Buzz's own client accepts them (`mobile/lib/shared/deeplink/deep_link.dart`).
///
/// `relayURL` is always normalised to the WebSocket scheme the rest of the stack
/// dials (`https` → `wss`, `http` → `ws`), because a Buzz destination is the pair
/// *(relay host, channel)* and the host is what resolves the community — see
/// `docs/done/2026-07-24/ELDR-BUZZ-PAIRING.md §7`.
public struct BuzzInviteLink: Sendable, Equatable {
    /// `wss://…` or `ws://…` — never the http form.
    public let relayURL: String
    /// The opaque `<payload>.<mac>` invite code.
    public let code: String
    /// Receipt proving the join policy was accepted, when the operator requires one.
    public let policyReceipt: String?

    public init(relayURL: String, code: String, policyReceipt: String? = nil) {
        self.relayURL = relayURL
        self.code = code
        self.policyReceipt = policyReceipt
    }

    /// Parse a canonical HTTPS invite link or a `buzz://join` handoff.
    /// Returns nil for anything else — a half-formed target is never surfaced.
    public static func parse(_ raw: String) -> BuzzInviteLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased()
        else { return nil }

        switch scheme {
        case "https", "http":
            // https://<relay>/invite/<payload>.<mac>
            guard let host = components.host, !host.isEmpty else { return nil }
            let marker = "/invite/"
            guard let range = components.path.range(of: marker) else { return nil }
            let code = String(components.path[range.upperBound...])
            guard !code.isEmpty, !code.contains("/") else { return nil }
            var relay = URLComponents()
            relay.scheme = scheme == "https" ? "wss" : "ws"
            relay.host = host
            relay.port = components.port
            guard let relayURL = relay.string else { return nil }
            return BuzzInviteLink(
                relayURL: relayURL, code: code,
                policyReceipt: nonEmptyQueryItem(components, "policy_receipt"))

        case "buzz":
            // buzz://join?relay=<ws(s)://relay>&code=<code>
            guard components.host?.lowercased() == "join" else { return nil }
            guard let relay = nonEmptyQueryItem(components, "relay"),
                let code = nonEmptyQueryItem(components, "code"),
                let relayScheme = URLComponents(string: relay)?.scheme?.lowercased(),
                relayScheme == "ws" || relayScheme == "wss"
            else { return nil }
            return BuzzInviteLink(
                relayURL: relay, code: code,
                policyReceipt: nonEmptyQueryItem(components, "policy_receipt"))

        default:
            return nil
        }
    }

    private static func nonEmptyQueryItem(_ components: URLComponents, _ name: String) -> String? {
        guard let value = components.queryItems?.first(where: { $0.name == name })?.value,
            !value.isEmpty
        else { return nil }
        return value
    }
}

// MARK: - Wire results

/// The operator-configured join policy, when there is one
/// (`GET /api/join-policy` → `{"policy": {...}}`, or `{}` for none).
public struct BuzzJoinPolicy: Sendable, Equatable, Codable {
    public var termsMarkdown: String?
    public var privacyMarkdown: String?
    public var ageAttestationRequired: Bool
    public var version: String

    enum CodingKeys: String, CodingKey {
        case termsMarkdown = "terms_markdown"
        case privacyMarkdown = "privacy_markdown"
        case ageAttestationRequired = "age_attestation_required"
        case version
    }

    public init(
        termsMarkdown: String? = nil, privacyMarkdown: String? = nil,
        ageAttestationRequired: Bool = false, version: String
    ) {
        self.termsMarkdown = termsMarkdown
        self.privacyMarkdown = privacyMarkdown
        self.ageAttestationRequired = ageAttestationRequired
        self.version = version
    }
}

/// `POST /api/invites/claim` success body. `status` is `joined` on first claim
/// and `already_member` on a repeat — the endpoint is idempotent, so a retry
/// after a dropped response is safe.
public struct BuzzClaimResult: Sendable, Equatable, Codable {
    public var status: String
    public var communityID: String
    public var host: String
    public var role: String

    public var isNewMember: Bool { status == "joined" }

    enum CodingKeys: String, CodingKey {
        case status
        case communityID = "community_id"
        case host, role
    }
}

public enum BuzzInviteError: Error, Equatable, Sendable {
    /// The string was not a Buzz invite link.
    case malformedLink
    /// The relay URL did not carry a `ws`/`wss` scheme.
    case unsupportedRelayScheme(String)
    /// `invite_expired` — post-MAC, so the relay tells us this one honestly.
    case expired
    /// `invite_invalid` — deliberately coarse on the relay side (bad MAC, wrong
    /// community, malformed). Do not try to infer more than "this code is no good".
    case invalid
    /// The operator requires join-policy acceptance; obtain a receipt first.
    case joinPolicyRequired
    /// The acceptance was refused: either the policy version we displayed is
    /// stale, or the operator requires an age attestation the user has not
    /// given. Re-fetch the policy, show it, and pass `ageConfirmed: true` only
    /// once the user has actually confirmed.
    case joinPolicyNotAccepted
    /// Per-pubkey claim rate limit (10/min).
    case rateLimited
    /// Any other HTTP failure, with the status and the relay's message.
    case http(status: Int, message: String)
    /// The response was not the JSON we expect.
    case malformedResponse
}

// MARK: - HTTP seam

/// A minimal request/response pair so the Buzz REST calls can be driven by a
/// stub in tests. CLAUDE.md: no unit test touches the network.
public struct BuzzHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: String, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct BuzzHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol BuzzHTTPTransport: Sendable {
    func send(_ request: BuzzHTTPRequest) async throws -> BuzzHTTPResponse
}

/// Production transport. Kept deliberately dumb — no retries, no caching: an
/// invite claim is idempotent but a *silent* retry would mask a rate limit.
public struct URLSessionBuzzHTTPTransport: BuzzHTTPTransport {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        self.timeout = timeout
    }

    public func send(_ request: BuzzHTTPRequest) async throws -> BuzzHTTPResponse {
        guard let url = URL(string: request.url) else { throw BuzzInviteError.malformedLink }
        var urlRequest = URLRequest(url: url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return BuzzHTTPResponse(status: status, body: data)
    }
}

// MARK: - The client

/// The three REST calls that get an Eldr user into a Buzz workspace.
///
/// **Which key claims the invite is a product decision.** Buzz's own client
/// mints a *fresh* keypair per community, and Eldr should too: it is the
/// privacy-maximising default (CLAUDE.md's tie-breaker), it keeps one
/// workspace's activity unlinkable from another's, and it keeps the Eldr
/// identity key out of a relay we do not control. This type takes whatever
/// keypair it is handed and does not choose for you.
public struct BuzzInviteClient: Sendable {
    /// `wss://…` / `ws://…` — the workspace's relay.
    public let relayURL: String
    private let http: any BuzzHTTPTransport
    private let randomSource: any RandomSource

    public init(
        relayURL: String, randomSource: any RandomSource,
        http: any BuzzHTTPTransport = URLSessionBuzzHTTPTransport()
    ) {
        self.relayURL = relayURL
        self.http = http
        self.randomSource = randomSource
    }

    /// Fetch the operator's join policy, if any. nil means "no policy configured"
    /// and the claim needs no receipt.
    public func joinPolicy() async throws -> BuzzJoinPolicy? {
        let url = try Self.endpoint(relayURL: relayURL, path: "/api/join-policy")
        let response = try await http.send(BuzzHTTPRequest(method: "GET", url: url))
        try Self.throwIfFailed(response)
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw BuzzInviteError.malformedResponse }
        guard let policy = object["policy"] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: policy),
            let decoded = try? JSONDecoder().decode(BuzzJoinPolicy.self, from: data)
        else { throw BuzzInviteError.malformedResponse }
        return decoded
    }

    /// Exchange a displayed policy version for a receipt bound to this invite code.
    public func acceptPolicy(
        code: String, policyVersion: String, ageConfirmed: Bool, keypair: NostrKeypair
    ) async throws -> String {
        let url = try Self.endpoint(relayURL: relayURL, path: "/api/invites/accept-policy")
        let body = try JSONSerialization.data(
            withJSONObject: [
                "code": code, "policy_version": policyVersion, "age_confirmed": ageConfirmed,
            ], options: [.sortedKeys])
        let response = try await post(url: url, body: body, keypair: keypair)
        try Self.throwIfFailed(response)
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
            let receipt = object["receipt"] as? String
        else { throw BuzzInviteError.malformedResponse }
        return receipt
    }

    /// Claim the invite. On success the signing pubkey is a relay member of that
    /// community and can open an authenticated WebSocket immediately.
    public func claim(
        code: String, policyReceipt: String? = nil, keypair: NostrKeypair
    ) async throws -> BuzzClaimResult {
        let url = try Self.endpoint(relayURL: relayURL, path: "/api/invites/claim")
        var payload: [String: Any] = ["code": code]
        if let policyReceipt { payload["policy_receipt"] = policyReceipt }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let response = try await post(url: url, body: body, keypair: keypair)
        try Self.throwIfFailed(response)
        guard let result = try? JSONDecoder().decode(BuzzClaimResult.self, from: response.body)
        else { throw BuzzInviteError.malformedResponse }
        return result
    }

    /// Convenience: claim straight from a parsed link, fetching a policy receipt
    /// first when the operator requires one. `ageConfirmed` is only consulted if
    /// the policy demands an age attestation — the caller must have actually
    /// shown the terms before passing true.
    public func claim(
        link: BuzzInviteLink, keypair: NostrKeypair, ageConfirmed: Bool = false
    ) async throws -> BuzzClaimResult {
        var receipt = link.policyReceipt
        if receipt == nil, let policy = try await joinPolicy() {
            receipt = try await acceptPolicy(
                code: link.code, policyVersion: policy.version, ageConfirmed: ageConfirmed,
                keypair: keypair)
        }
        return try await claim(code: link.code, policyReceipt: receipt, keypair: keypair)
    }

    // MARK: Internals

    private func post(url: String, body: Data, keypair: NostrKeypair) async throws
        -> BuzzHTTPResponse
    {
        let header = try NIP98.authorizationHeader(
            method: "POST", url: url, body: body, keypair: keypair, randomSource: randomSource)
        return try await http.send(
            BuzzHTTPRequest(
                method: "POST", url: url,
                headers: ["Authorization": header, "Content-Type": "application/json"], body: body))
    }

    /// `wss://host[:port]` → `https://host[:port]<path>`. Buzz resolves the
    /// community from the Host header, so the host must survive verbatim.
    static func endpoint(relayURL: String, path: String) throws -> String {
        guard var components = URLComponents(string: relayURL), let scheme = components.scheme?.lowercased()
        else { throw BuzzInviteError.malformedLink }
        switch scheme {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: throw BuzzInviteError.unsupportedRelayScheme(scheme)
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.string else { throw BuzzInviteError.malformedLink }
        return url
    }

    static func throwIfFailed(_ response: BuzzHTTPResponse) throws {
        guard response.status < 200 || response.status >= 300 else { return }
        let message =
            (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any])?["error"]
            as? String ?? "HTTP \(response.status)"
        switch (response.status, message) {
        case (429, _): throw BuzzInviteError.rateLimited
        case (_, "invite_expired"): throw BuzzInviteError.expired
        case (_, "invite_invalid"): throw BuzzInviteError.invalid
        case (_, "join_policy_required"): throw BuzzInviteError.joinPolicyRequired
        case (_, "join_policy_not_accepted"): throw BuzzInviteError.joinPolicyNotAccepted
        default: throw BuzzInviteError.http(status: response.status, message: message)
        }
    }
}
