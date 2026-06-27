import Foundation
import PQRCACP

/// Bridges the headless node's ACP agent loop to sybilclaw's own assistant by posing as the
/// model. `runACPAgent(llm:)` drives the full ACP surface (initialize / session lifecycle /
/// prompt) against this `LLMClient`; instead of calling a local OpenAI-compatible model, we
/// hand the user's turn to the sybilclaw Gateway and return its reply as the assistant
/// message — with NO tool calls, so the agent loop emits it as the final answer in one pass
/// (sybilclaw runs its own tools/agent behind the gateway; the node's tool loop stays out of
/// the way). This is how `--responder sybilclaw` reuses the proven ACP plumbing without a
/// second serve path.
///
/// ⚠️ Stage 2 (DEMO-SYBILCLAW.md): unverified against a live gateway. `--responder eldr-acp`
/// is the proven fallback.
struct SybilclawLLMClient: LLMClient {
    let gateway: SybilclawGatewayClient

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        // sybilclaw owns its own session memory, so the faithful payload is the latest user
        // turn — not the whole reconstructed transcript. Fall back to the last message's
        // content if no explicit user role is present.
        let prompt =
            messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""
        let reply = try await gateway.ask(prompt)
        return LLMResponse(content: reply, toolCalls: [])
    }
}
