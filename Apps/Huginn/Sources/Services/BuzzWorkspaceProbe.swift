// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCCore
import PQRCNostr

/// WS-I7 Step 1's "Test connection", and the Remove flow's signed retirement.
/// Both talk to a real Buzz relay, so both live behind small seams the wizard/row
/// call and the tests replace — no unit test in this suite opens a socket.

/// What a probe of a workspace relay found. Deliberately verbose: the point of the
/// button is that the user sees the workspace is REAL before typing anything else.
struct BuzzRelayProbeResult: Equatable, Sendable {
    var reachable: Bool
    /// The relay announced a NIP-42 AUTH challenge — i.e. it is membership-gated,
    /// which every Buzz workspace relay is.
    var membershipGated: Bool
    /// NIP-11 `name`/`description`, when the relay serves its info document.
    var relayName: String?
    var detail: String

    static func failure(_ detail: String) -> BuzzRelayProbeResult {
        BuzzRelayProbeResult(
            reachable: false, membershipGated: false, relayName: nil, detail: detail)
    }
}

/// Reachability + AUTH-challenge probe, using Eldr's OWN transport (the same code
/// path the gateway will use — a probe through a different client would prove
/// nothing about whether the gateway can connect).
enum BuzzRelayProbe {

    /// Connect, wait briefly for the relay's lifecycle events, and read NIP-11.
    /// Never authenticates: this must be safe to press before any key is minted.
    static func probe(urlString: String, timeout: Duration = .seconds(10)) async
        -> BuzzRelayProbeResult
    {
        switch ConfigurationStore.validateRelayOverride(urlString) {
        case .failure:
            return .failure("That isn't a usable relay URL (use wss://…).")
        case .success(let value):
            guard value != nil else { return .failure("Enter the workspace's relay URL.") }
        }
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return .failure("That isn't a usable relay URL.") }

        let transport = NostrWebSocketTransport(url: url, responseTimeout: timeout)
        var connected = false
        var challenged = false
        let events = await transport.transportEvents()
        _ = await transport.connect()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let collector = Task { () -> (Bool, Bool) in
            var sawConnect = false
            var sawChallenge = false
            for await event in events {
                if event == .connected { sawConnect = true }
                if event == .authChallenge { sawChallenge = true }
                if sawConnect && sawChallenge { break }
                if ContinuousClock.now >= deadline { break }
            }
            return (sawConnect, sawChallenge)
        }
        // A gated relay sends its challenge immediately after the socket opens;
        // give it a beat, then take whatever landed.
        try? await Task.sleep(for: .milliseconds(2500))
        collector.cancel()
        (connected, challenged) = await collector.value
        await transport.disconnect()

        let name = await nip11Name(for: url)
        guard connected else {
            return .failure(
                "Couldn't open a WebSocket to \(url.host ?? urlString). Check the URL, or whether the workspace is online."
            )
        }
        let detail: String
        if challenged {
            detail =
                "Reachable, and it asks members to authenticate (NIP-42) — that's a Buzz workspace relay."
        } else {
            detail = "Reachable. It didn't send an auth challenge, so it may be an open relay."
        }
        return BuzzRelayProbeResult(
            reachable: true, membershipGated: challenged, relayName: name, detail: detail)
    }

    /// The relay's NIP-11 `name` (best-effort; a relay may not serve one).
    private static func nip11Name(for url: URL) async -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (url.scheme == "ws") ? "http" : "https"
        guard let httpURL = components.url else { return nil }
        var request = URLRequest(url: httpURL)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["name"] as? String
    }
}

/// Publishes the agent-signed retirement + NIP-09 deletion request that WS-I7's
/// **Remove** promises, immediately before the agent key is destroyed. A protocol
/// so the UI can be driven in tests without a relay.
protocol BuzzRevoking: Sendable {
    /// Returns a human-readable outcome line; never throws — Remove must proceed
    /// even if the relay is unreachable (the local key deletion is the part that
    /// always holds).
    func retire(connection: BuzzConnection, keypair: NostrKeypair, reason: String) async -> String
}

/// The production revoker: connects to the workspace relay, authenticates as the
/// agent (carrying its NIP-OA attestation, exactly as the gateway does), and
/// publishes the two retirement events.
struct BuzzRevoker: BuzzRevoking {
    func retire(connection: BuzzConnection, keypair: NostrKeypair, reason: String) async -> String {
        guard let url = URL(string: connection.relayURL) else {
            return "No relay URL on this connection — key deleted locally only."
        }
        let random = SystemRandomSource()
        let transport = NostrWebSocketTransport(url: url, responseTimeout: .seconds(10))
        _ = await transport.connect()
        defer { Task { await transport.disconnect() } }
        var extraTags: [[String]] = []
        if let authTag = connection.authTagJSON, let parts = try? NIPOA.parseAuthTag(authTag) {
            extraTags = [parts]
        }
        do {
            try await transport.authenticate(
                keypair: keypair, randomSource: random, extraTags: extraTags)
        } catch {
            return
                "Couldn't authenticate to \(connection.relayHost) to announce the retirement (\(error)). The key was still destroyed on this Mac."
        }
        var landed: [String] = []
        let retirement = BuzzEvents.retirementProfile(
            pubkey: keypair.publicKeyHex, displayName: connection.displayName, reason: reason)
        if let signed = try? keypair.sign(retirement, randomSource: random),
            let ack = try? await transport.publish(signed), ack.accepted
        {
            landed.append("retirement profile")
        }
        let deletion = BuzzEvents.profileDeletionRequest(
            pubkey: keypair.publicKeyHex, reason: reason)
        if let signed = try? keypair.sign(deletion, randomSource: random),
            let ack = try? await transport.publish(signed), ack.accepted
        {
            landed.append("deletion request")
        }
        if landed.isEmpty {
            return
                "The relay accepted neither retirement event (it may not allow them). The key was destroyed on this Mac."
        }
        return "Published the agent-signed \(landed.joined(separator: " + ")); key destroyed."
    }
}
