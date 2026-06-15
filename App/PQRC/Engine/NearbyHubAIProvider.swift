import Foundation
import PQRCAgent
import PQRCNostr

/// The COMPANION side of "share your AI over Multipeer" (Tier 2). An
/// `AgentProvider` that runs inference on a nearby HOST device: it sends the
/// rendered transcript over the relay link (`MultipeerRelayClient.requestAI`),
/// and the host answers with its own on-device model. No cloud, no API key —
/// you borrow the host's Apple Intelligence over the radio.
///
/// Used when this device's relay is `nearby` (joined a host) and an AI is set to
/// the "Nearby host's AI" backend. If no host is sharing an AI, the call returns
/// nil and we surface a clear, actionable error instead of silence.
struct NearbyHubAIProvider: AgentProvider {
    let client: MultipeerRelayClient

    func draftReply(context: AgentContext) async throws -> Draft {
        let reply = await client.requestAI(
            system: context.draftSystemPrompt(),
            prompt: FoundationModelsAgentProvider.renderTranscript(context))
        guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentProviderError.unavailable(
                "No nearby host is sharing an AI right now. Make sure a companion is hosting (Settings ▸ Servers ▸ host) and in range.")
        }
        return Draft(text: reply)
    }

    func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        let reply = await client.requestAI(
            system: context.turnSystemPrompt(),
            prompt: FoundationModelsAgentProvider.renderTranscript(context))
        let trimmed = reply?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty, trimmed != "PASS" else { return nil }
        return AgentTurn(messages: [AgentMessage(text: trimmed)])
    }
}
