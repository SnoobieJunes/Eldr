import Foundation
import Testing

@testable import Huginn

// Locks the sybilclaw gateway REPLY selection (audit finding A2). The assistant text is the
// cumulative agent-stream snapshot (`event:agent` `data.text`, accumulated into `assembled`).
// The terminal `chat:final` frame's `message` field is NOT guaranteed to be that text — the
// fork can put an echo of the prompt, a routing note, or a status string there — so the client
// MUST prefer the streamed text and use the chat `message` only as a last-resort fallback when
// nothing streamed. A prior version returned `finalMessage ?? assembled`, which surfaced the
// echo/status instead of the real reply. This suite guards that regression.
//
// (A3 — returning the assembled text when the gateway closes the socket without a terminal
// `chat:final` — is control-flow in `runTurn` around `receive()`; it's covered by the build +
// a live-gateway smoke test, not this pure-function suite.)

@Suite("Gateway reply selection (A2)")
struct GatewayReplyTests {
    @Test func prefersAgentStreamOverChatEcho() {
        // The streamed assistant text wins even when the chat:final frame carries a non-empty
        // `message` (here, an echo of the user's prompt).
        let reply = SybilclawGatewayClient.chooseReply(
            assembled: "The capital of France is Paris.",
            chatMessage: "you said: what's the capital of France?")
        #expect(reply == "The capital of France is Paris.")
    }

    @Test func agentStreamOnlyWhenNoChatMessage() {
        let reply = SybilclawGatewayClient.chooseReply(assembled: "hello world", chatMessage: nil)
        #expect(reply == "hello world")
    }

    @Test func fallsBackToChatMessageWhenNothingStreamed() {
        // A gateway variant that never emits `agent` frames: the chat `message` is all we have.
        let reply = SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: "fallback text")
        #expect(reply == "fallback text")
    }

    @Test func placeholderWhenBothEmpty() {
        #expect(SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: nil)
            == "(sybilclaw returned no text)")
        #expect(SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: "")
            == "(sybilclaw returned no text)")
    }
}
