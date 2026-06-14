import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// A relay double that holds NO events and reports a fixed connection status.
/// Subscriptions finish immediately (empty), so a key fetch can't find the
/// peer — letting us assert the messenger's *reason* for failure.
private struct EmptyRelay: RelayTransport {
    let status: RelayStatus

    func publish(_ event: NostrEvent) async throws -> PublishAck {
        PublishAck(eventID: event.id, accepted: true)
    }
    func subscribe(_ filters: [NostrFilter]) async -> AsyncThrowingStream<NostrEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func authenticate(keypair: NostrKeypair, randomSource: any RandomSource) async throws {}
    func currentStatus() async -> RelayStatus { status }
    func checkConnection() async -> RelayStatus { status }
}

/// Honest reachability errors: the messenger must distinguish "relay is fine
/// but the peer hasn't published their keys" from "relay is unreachable" so the
/// UI can tell the user something true instead of guessing.
@Suite("Reachability errors")
struct ReachabilityTests {
    private let absentPeer = String(repeating: "b", count: 64)

    @Test func relayConnectedButPeerAbsent_throwsPeerKeysNotPublished() async throws {
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [EmptyRelay(status: .connected)])
        await #expect(throws: PQRCError.peerKeysNotPublished) {
            _ = try await alice.messenger.fetchVerifiedPeer(
                nostrPubkeyHex: absentPeer, timeout: .milliseconds(300))
        }
    }

    @Test func relayDisconnected_throwsRelayUnreachable() async throws {
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [EmptyRelay(status: .disconnected)])
        await #expect(throws: PQRCError.relayUnreachable) {
            _ = try await alice.messenger.fetchVerifiedPeer(
                nostrPubkeyHex: absentPeer, timeout: .milliseconds(300))
        }
    }

    @Test func oneConnectedRelay_amongDown_stillReportsPeerNotPublished() async throws {
        // If ANY relay is reachable, "peer hasn't published" is the honest
        // answer — only when every relay is down do we say "unreachable".
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1,
            transports: [EmptyRelay(status: .disconnected), EmptyRelay(status: .connected)])
        await #expect(throws: PQRCError.peerKeysNotPublished) {
            _ = try await alice.messenger.fetchVerifiedPeer(
                nostrPubkeyHex: absentPeer, timeout: .milliseconds(300))
        }
    }

    @Test func fetchSucceeds_whenPeerHasPublished() async throws {
        // Sanity: against a shared relay where the peer announced, the fetch
        // returns the verified contact (no reachability error).
        let relay = await LocalRelaySimulator(url: "local://relay").connect()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [relay])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b2", seed: 2, transports: [relay])
        try await bob.messenger.announce(relayURLs: ["local"])
        let (contact, _) = try await alice.messenger.fetchVerifiedPeer(
            nostrPubkeyHex: bob.nostrKeypair.publicKeyHex, timeout: .seconds(2))
        #expect(contact.nostrPubkeyHex == bob.nostrKeypair.publicKeyHex)
    }
}
