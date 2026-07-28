// SPDX-License-Identifier: Apache-2.0
#if canImport(Network)
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// A LIVE probe of the WS-BM workspace path against a real Buzz relay, using
/// Eldr's own code (`NIP98`, `BuzzInviteClient`, `BuzzWorkspaceClient`).
///
/// Companion to `LiveBuzzRelayProbeTests`, which probes the *agent* plane. This
/// one answers the question that decides whether WS-BM1/BM2 are real:
/// **does Block's own verifier accept the credential Eldr produces?**
///
/// The trick that makes this answerable with no invite and no membership: POST a
/// **deliberately invalid** invite code. Buzz's handler authenticates the NIP-98
/// header FIRST and only then checks the code (`api/invites.rs::claim_invite`),
/// so the two failures are distinguishable:
///
/// - `invite_invalid` / `invite_expired` → the signature was **accepted**; we got
///   all the way to the code check. This is the proof.
/// - an auth-shaped 401/403 → our NIP-98 is malformed and nothing else matters.
///
/// Opt-in (never runs in the normal suite — it touches the real network):
///   BUZZ_LIVE_RELAY=wss://auston.communities.buzz.xyz \
///   [BUZZ_LIVE_INVITE=https://…/invite/<code>]   # enables the full join loop
///   swift test --package-path Packages/PQRCNostr --filter LiveBuzzWorkspaceProbe
@Suite("Live Buzz workspace probe", .serialized)
struct LiveBuzzWorkspaceProbeTests {

    private static var relayURL: String { ProcessInfo.processInfo.environment["BUZZ_LIVE_RELAY"] ?? "" }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_LIVE_RELAY"] != nil))
    func live_nip11AndJoinPolicy() async throws {
        func log(_ s: String) { print("WSPROBE: \(s)") }
        let client = BuzzInviteClient(
            relayURL: Self.relayURL, randomSource: SystemRandomSource())

        // The join policy is public — no auth, no membership. If this decodes,
        // our model of their REST surface is right.
        let policy = try await client.joinPolicy()
        if let policy {
            log("join policy: version=\(policy.version) ageRequired=\(policy.ageAttestationRequired)")
            log("  terms present=\(policy.termsMarkdown != nil) privacy present=\(policy.privacyMarkdown != nil)")
            #expect(!policy.version.isEmpty)
        } else {
            log("join policy: none configured (claims need no receipt)")
        }
    }

    /// THE proof. A fresh throwaway key, a bogus code: if the relay answers with
    /// a code-level error we know our NIP-98 credential cleared its verifier.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_LIVE_RELAY"] != nil))
    func live_nip98CredentialIsAccepted() async throws {
        func log(_ s: String) { print("WSPROBE: \(s)") }
        // A fresh key so this never spends the owner's claim-rate allowance.
        let keypair = try NostrKeypair(randomSource: SystemRandomSource())
        log("throwaway claimant = \(keypair.publicKeyHex.prefix(16))…")
        let client = BuzzInviteClient(
            relayURL: Self.relayURL, randomSource: SystemRandomSource())

        // A syntactically plausible but non-existent code.
        let bogus = "eldrprobe000000000000000.0000000000000000000000000000000000000000"
        do {
            let result = try await client.claim(code: bogus, keypair: keypair)
            log("UNEXPECTED: a bogus code was accepted?! \(result)")
            Issue.record("a bogus invite code must not be claimable")
        } catch BuzzInviteError.invalid {
            log("RESULT: invite_invalid → NIP-98 credential ACCEPTED by Buzz's verifier ✅")
        } catch BuzzInviteError.expired {
            log("RESULT: invite_expired → NIP-98 credential ACCEPTED by Buzz's verifier ✅")
        } catch BuzzInviteError.joinPolicyRequired {
            // Also proof: the policy gate is checked AFTER authenticate().
            log("RESULT: join_policy_required → NIP-98 ACCEPTED; this workspace needs a policy receipt ✅")
        } catch BuzzInviteError.rateLimited {
            // The rate limiter is keyed on the AUTHENTICATED pubkey, so reaching
            // it also proves the signature was verified.
            log("RESULT: rate limited → NIP-98 ACCEPTED (the limiter keys on the authed pubkey) ✅")
        } catch let BuzzInviteError.http(status, message) {
            log("RESULT: HTTP \(status) — \(message)")
            Issue.record(
                "NIP-98 was NOT accepted (HTTP \(status): \(message)). The credential is wrong.")
        } catch {
            log("RESULT: transport error — \(error)")
            throw error
        }
    }

    /// The full loop, when the owner supplies a real invite link: claim → AUTH →
    /// discover channels → read one. Sending is deliberately NOT automatic —
    /// posting into a real workspace is the owner's call, gated on
    /// BUZZ_LIVE_SEND.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BUZZ_LIVE_INVITE"] != nil))
    func live_joinAndRead() async throws {
        func log(_ s: String) { print("WSJOIN: \(s)") }
        let env = ProcessInfo.processInfo.environment
        let link = try #require(BuzzInviteLink.parse(env["BUZZ_LIVE_INVITE"] ?? ""))
        log("invite → relay=\(link.relayURL) code=\(link.code.prefix(12))…")

        let random = SystemRandomSource()
        let keypair = try NostrKeypair(randomSource: random)
        log("fresh per-workspace key = \(keypair.publicKeyHex.prefix(16))…")

        let invites = BuzzInviteClient(relayURL: link.relayURL, randomSource: random)
        let claim = try await invites.claim(link: link, keypair: keypair, ageConfirmed: true)
        log("CLAIM: status=\(claim.status) community=\(claim.communityID) role=\(claim.role) ✅")

        let url = try #require(URL(string: link.relayURL))
        let transport = NostrWebSocketTransport(url: url, responseTimeout: .seconds(12))
        let workspace = BuzzWorkspaceClient(
            transport: await transport.connect(), keypair: keypair, randomSource: random,
            configuration: .init(relayURL: link.relayURL, storedEventTimeout: .seconds(15)))
        try await workspace.connect()
        log("AUTH: NIP-42 accepted for the newly-claimed member ✅")

        let channels = try await workspace.channels()
        log("CHANNELS: \(channels.count) visible — \(channels.prefix(8).map(\.name))")

        if let first = channels.first {
            let history = try await workspace.history(channelID: first.id, limit: 20)
            log("HISTORY #\(first.name): \(history.count) messages")
            for message in history.suffix(3) {
                log("  [\(message.authorPubkey.prefix(8))] \(message.content.prefix(80))")
            }
            let roster = try await workspace.roster(channelID: first.id)
            log("ROSTER #\(first.name): \(roster.members.count) members, \(roster.admins.count) admins")

            if env["BUZZ_LIVE_SEND"] == "1" {
                let text = env["BUZZ_LIVE_SEND_TEXT"] ?? "Hello from Eldr on iPhone 👋"
                let sent = try await workspace.send(text, to: first.id)
                log("SENT: \(sent.id.prefix(16))… into #\(first.name) ✅ — look for it in Buzz")
            } else {
                log("SEND: skipped (set BUZZ_LIVE_SEND=1 to post into the real workspace)")
            }
        }
        await transport.disconnect()
    }
}
#endif
