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
/// WS-B5 (session scoping): `ACPAgent` can serve MULTIPLE `session/new` conversations
/// (distinct projects/threads) against one running `eldr-node` process, all sharing this
/// SAME `LLMClient` instance (`EldrNodeCore.serve` builds one `llm` and passes it through
/// once). A single gateway session key for the whole process would bleed one conversation's
/// context into another's the moment the owner had two sessions live at once — so this
/// conforms to `SessionScopedLLMClient`: `ACPAgent.runModelCall` calls the `sessionId`-taking
/// overload below, and each ACP session gets its OWN gateway session key, derived
/// deterministically from that session id (stable for the session's lifetime, distinct
/// across sessions). The plain `complete(messages:tools:)` (the base `LLMClient`
/// requirement) is kept only as a fallback for a caller that doesn't know about
/// `SessionScopedLLMClient` — it uses a fixed, unscoped key, so avoid it when more than one
/// conversation might be live; `ACPAgent` never takes this path today.
struct SybilclawLLMClient: LLMClient, SessionScopedLLMClient {
    let gateway: SybilclawGatewayClient

    /// Unscoped fallback (base `LLMClient` conformance). Only reachable from a caller that
    /// doesn't check for `SessionScopedLLMClient` — `ACPAgent` always does, so in practice
    /// every real turn goes through `complete(messages:tools:sessionId:)` below.
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        try await complete(messages: messages, tools: tools, sessionId: "default")
    }

    func complete(messages: [LLMMessage], tools: [LLMTool], sessionId: String) async throws
        -> LLMResponse
    {
        // sybilclaw owns its own session memory, so the faithful payload is the latest user
        // turn — not the whole reconstructed transcript. Fall back to the last message's
        // content if no explicit user role is present.
        let prompt =
            messages.last(where: { $0.role == .user })?.content
            ?? messages.last?.content
            ?? ""
        let reply = try await gateway.ask(prompt, sessionKey: Self.gatewaySessionKey(for: sessionId))
        return LLMResponse(content: reply, toolCalls: [])
    }

    /// Deterministic per-ACP-session gateway session key: stable across turns of the SAME
    /// session (so sybilclaw keeps that conversation's memory), distinct across DIFFERENT
    /// sessions (so two live conversations never bleed into each other — WS-B5). `sessionId`
    /// is already process-unique (`ACPAgent`'s `"eldr-session-\(counter)"`), so no extra
    /// salting is needed here (unlike Huginn's `gatewaySessionKey`, which hashes a
    /// long-lived peer/thread id and so salts it against exposing that id in the gateway's
    /// on-disk session files — an ACP session id carries no such identity).
    static func gatewaySessionKey(for sessionId: String) -> String {
        "eldr-node-\(sessionId)"
    }
}
