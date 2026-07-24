// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

#if canImport(Network)
import EldrBuzzGateway

// eldr-buzz-agent — bridge a LOCAL model (Huginn / MLX / any OpenAI-compatible
// endpoint) into a Buzz workspace as a first-class agent member.
//
// Identity + relay (mirrors buzz-acp):
//   BUZZ_RELAY_URL        ws(s):// Buzz relay                (default ws://localhost:3000)
//   BUZZ_PRIVATE_KEY      agent key, hex or nsec1…          (REQUIRED)
//   BUZZ_AUTH_TAG         NIP-OA auth tag JSON              (optional; owner-attested)
//   BUZZ_CHANNEL_ID       one channel UUID                  (or ELDR_BUZZ_CHANNELS csv)
//
// Eldr-specific:
//   ELDR_BUZZ_CHANNELS            comma-separated channel UUIDs
//   ELDR_BUZZ_DISPLAY_NAME        kind:0 display name / mention trigger (default "Eldr")
//   ELDR_BUZZ_ABOUT               kind:0 about
//   ELDR_BUZZ_PICTURE             kind:0 avatar URL (https://…; a URL, not a data: blob)
//   ELDR_BUZZ_SYSTEM_PROMPT       persona / system prompt
//   ELDR_BUZZ_OWNER_PUBKEY        owner x-only pubkey hex (enables NIP-AM/AO)
//   ELDR_BUZZ_OWNER_PRIVATE_KEY   owner key (local demo: derives owner pubkey + auth tag)
//   ELDR_BUZZ_OA_CONDITIONS       NIP-OA conditions string (default "")
//   ELDR_BUZZ_MENTIONS_ONLY       "0" to answer every message (default: mentions only)
//   ELDR_BUZZ_EMIT_METRICS        "0" to disable NIP-AM (default on)
//   ELDR_BUZZ_EMIT_OBSERVER       "0" to disable NIP-AO (default on)
//   ELDR_BUZZ_REDACT              "0" to disable the outbound egress firewall
//                                 (default ON: replies are scrubbed of
//                                 secret-shaped content before they cross into
//                                 the signed-not-E2EE Buzz channel)
//
// The brain (mirrors eldr-acp):
//   ELDR_LLM_URL / ELDR_LLM_TOKEN / ELDR_LLM_MODEL   (default http://127.0.0.1:1337/v1)
//   ELDR_ACP_FAKE_LLM=1           built-in echo brain (smoke test, no server)

@main
struct EldrBuzzAgentMain {
    static func main() async {
        let env = ProcessInfo.processInfo.environment

        let log: @Sendable (String) -> Void = { message in
            FileHandle.standardError.write(Data("eldr-buzz-agent: \(message)\n".utf8))
        }

        let config: BuzzGatewayConfig
        let keypair: NostrKeypair
        do {
            (config, keypair) = try BuzzGatewayConfig.fromEnvironment(env)
        } catch {
            log("config error: \(error)")
            log(
                "Set at least BUZZ_RELAY_URL, BUZZ_PRIVATE_KEY, and ELDR_BUZZ_CHANNELS. "
                    + "See the header of this file for all options.")
            exit(2)
        }

        log("agent pubkey: \(keypair.publicKeyHex)")
        log("npub: \(keypair.npub)")
        log("relay: \(config.relayURL.absoluteString)")
        log("channels: \(config.channelIds.joined(separator: ", "))")

        let transport = NostrWebSocketTransport(url: config.relayURL)

        // One usage box shared between the LLM's usageObserver and the gateway,
        // so NIP-AM metrics carry the endpoint's REAL token counts.
        let usageBox = UsageBox()
        let llm: any LLMClient
        if env["ELDR_ACP_FAKE_LLM"] == "1" {
            llm = EchoLLMClient()
            log("brain: built-in echo (ELDR_ACP_FAKE_LLM=1)")
        } else {
            let llmConfig = LLMConfig.fromEnvironment(env)
            llm = OpenAICompatibleLLMClient(
                config: llmConfig, usageObserver: { usageBox.set($0) })
            log("brain: \(llmConfig.url) model=\(llmConfig.model)")
        }

        let gateway = BuzzGateway(
            transport: transport, keypair: keypair, llm: llm, config: config, usageBox: usageBox,
            log: log)

        do {
            try await gateway.run()
        } catch {
            log("gateway stopped: \(error)")
            exit(1)
        }
    }
}
#else
@main
struct EldrBuzzAgentMain {
    static func main() {
        FileHandle.standardError.write(
            Data("eldr-buzz-agent requires a platform with Network.framework (macOS).\n".utf8))
        exit(1)
    }
}
#endif
