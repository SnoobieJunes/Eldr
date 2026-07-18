import A2ACore
import Foundation

/// Outcome of attempting to verify an `AgentCard`'s JWS signature(s).
public struct A2ACardVerification: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case unverified
        case verified
        case failed(String)
    }

    public var status: Status

    public init(status: Status) {
        self.status = status
    }
}

/// Verifies an `AgentCard`'s `signatures` (RFC 7515 JWS over the JCS-canonicalized
/// card, per docs/specification.md §8.4).
public protocol AgentCardSignatureVerifier: Sendable {
    func verify(card: A2AAgentCard, rawCardJSON: Data) async -> A2ACardVerification
}

/// The default verifier: always reports `.unverified`.
///
/// Full JWS verification (RFC 7515 signature check + JCS/RFC 8785 canonicalization
/// of the card per specification §8.4) is a pre-upstream milestone, not yet
/// implemented — recorded in DEVIATIONS.md. Callers that need signature assurance
/// must supply their own `AgentCardSignatureVerifier` until then.
public struct NoopAgentCardSignatureVerifier: AgentCardSignatureVerifier {
    public init() {}

    public func verify(card: A2AAgentCard, rawCardJSON: Data) async -> A2ACardVerification {
        A2ACardVerification(status: .unverified)
    }
}

/// Fetches and validates an `AgentCard` from its well-known HTTP location.
public struct AgentCardResolver: Sendable {
    private let session: URLSession
    private let verifier: any AgentCardSignatureVerifier

    public init(
        session: URLSession = .shared,
        verifier: any AgentCardSignatureVerifier = NoopAgentCardSignatureVerifier()
    ) {
        self.session = session
        self.verifier = verifier
    }

    /// Fetch and validate the card at `url`, returning it alongside its signature
    /// verification outcome.
    public func fetch(from url: URL) async throws -> (
        card: A2AAgentCard, verification: A2ACardVerification
    ) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(A2AVersion.current, forHTTPHeaderField: A2AVersion.headerName)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw A2AClientError.malformedResponse("response is not an HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw A2AClientError.httpStatus(httpResponse.statusCode)
        }

        let card: A2AAgentCard
        do {
            card = try A2AWireCodec.decode(A2AAgentCard.self, from: data)
        } catch {
            throw A2AClientError.invalidAgentCard(
                "could not decode agent card: \(error)")
        }
        guard !card.name.isEmpty else {
            throw A2AClientError.invalidAgentCard("card has an empty name")
        }
        guard !card.version.isEmpty else {
            throw A2AClientError.invalidAgentCard("card has an empty version")
        }
        guard !card.supportedInterfaces.isEmpty else {
            throw A2AClientError.invalidAgentCard("card declares no supported interfaces")
        }

        let verification = await verifier.verify(card: card, rawCardJSON: data)
        return (card, verification)
    }

    /// The well-known discovery URL for `baseURL`'s scheme/host/port (any path
    /// component on `baseURL` is dropped, per the well-known-URI convention).
    public static func wellKnownURL(host baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = A2AAgentCard.wellKnownPath
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent(A2AAgentCard.wellKnownPath)
    }
}
