import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// A relay double that mimics khatru gating kind-1059 reads: the FIRST
/// subscription is closed with NIP-42 `auth-required`; only after `authenticate`
/// runs does a subscription stay open (and deliver). Mirrors the real
/// relay.lerants.com behavior our probe observed (AUTH + CLOSED on the REQ,
/// never an unprompted challenge on connect).
private actor AuthGatingRelay: RelayTransport {
    private var authed = false
    /// khatru issues the AUTH challenge ONLY in response to the gated REQ — so
    /// an upfront authenticate (before any subscribe) has no challenge and
    /// fails. Auth only succeeds after a gated subscribe.
    private var challengeIssued = false
    private(set) var subscribeCount = 0
    private(set) var authenticateCalled = false

    func publish(_ event: NostrEvent) async throws -> PublishAck {
        PublishAck(eventID: event.id, accepted: true)
    }

    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        subscribeCount += 1
        let isAuthed = authed
        if !isAuthed { challengeIssued = true }  // the gated REQ issues a challenge
        return AsyncThrowingStream { continuation in
            if isAuthed {
                // Authenticated: a live subscription that simply stays open.
            } else {
                continuation.finish(throwing: NostrError.authRequired)
            }
        }
    }

    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {
        authenticateCalled = true
        guard challengeIssued else { throw NostrError.notAuthenticated }  // upfront: no challenge yet
        authed = true
    }

    func currentStatus() async -> RelayStatus { .connected }
}

/// Reactive NIP-42: the receive pump must subscribe first, and when the relay
/// gates the read with `auth-required`, authenticate with the challenge and
/// re-subscribe — instead of the old eager-auth path that skipped subscribing
/// entirely (so writes worked but nothing was ever received).
@Suite("Reactive NIP-42 auth")
struct ReactiveAuthTests {
    @Test func authRequiredOnRead_triggersAuthenticateAndResubscribe() async throws {
        let relay = AuthGatingRelay()
        let me = try await Persona.make(
            name: "Me", seedByte: "a1", seed: 1, transports: [relay])
        _ = try await me.messenger.start()

        // The reactive loop should: subscribe → authRequired → authenticate →
        // re-subscribe (now open). Poll briefly so the test isn't timing-brittle.
        var authed = false
        var resubscribed = false
        for _ in 0..<50 {
            authed = await relay.authenticateCalled
            resubscribed = await relay.subscribeCount >= 2
            if authed && resubscribed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(authed, "client must authenticate when the relay returns auth-required")
        #expect(resubscribed, "client must re-subscribe after authenticating")
    }
}
