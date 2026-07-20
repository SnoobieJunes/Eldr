// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCACP
import PQRCCore

/// A pass-through `LLMClient` decorator that records every model round-trip to
/// `DiagnosticsLog` for the Agent Inspector — without touching PQRCACP. It surfaces the
/// #1 self-hosted failure mode this project keeps hitting: a **reasoning/QAT model that
/// emits only a chain-of-thought channel and no final answer**, which the agent strips
/// to empty → a silent blank reply. The Inspector flags that explicitly with the fix.
///
/// Wrap the real client at its construction sites, e.g.
/// `InspectingLLMClient(wrapping: OpenAICompatibleLLMClient(config: c), model: c.model)`.
final class InspectingLLMClient: LLMClient {
    private let inner: any LLMClient
    private let modelLabel: String
    private let log: DiagnosticsLog

    init(wrapping inner: any LLMClient, model: String, log: DiagnosticsLog = .shared) {
        self.inner = inner
        self.modelLabel = model.isEmpty ? "model" : model
        self.log = log
    }

    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        log.post(.llm, .info, "→ request · \(modelLabel)", requestSummary(messages, tools))
        let start = Date()
        do {
            let r = try await inner.complete(messages: messages, tools: tools)
            record(r, since: start)
            return r
        } catch {
            log.post(.llm, .error, "✗ LLM error", String(describing: error))
            throw error
        }
    }

    func stream(
        messages: [LLMMessage], tools: [LLMTool], onDelta: @Sendable (String) async -> Void
    ) async throws -> LLMResponse {
        log.post(.llm, .info, "→ request (stream) · \(modelLabel)", requestSummary(messages, tools))
        let start = Date()
        do {
            let r = try await inner.stream(messages: messages, tools: tools, onDelta: onDelta)
            record(r, since: start)
            return r
        } catch {
            log.post(.llm, .error, "✗ LLM error", String(describing: error))
            throw error
        }
    }

    private func requestSummary(_ messages: [LLMMessage], _ tools: [LLMTool]) -> String {
        let base = "\(messages.count) msgs · \(tools.count) tools"
        #if DEBUG
            // Dev builds keep a prompt preview for debugging — but credential-scrubbed
            // so an echoed token/key never lands in the visible Inspector log.
            let lastUser = messages.last { $0.role == .user }?.content ?? ""
            let preview = CredentialRedactor.scrub(lastUser)
                .replacingOccurrences(of: "\n", with: " ").prefix(140)
            return preview.isEmpty ? base : "\(base) · last user: \(preview)"
        #else
            // Release (incl. the build that serves the owner's phone, whose prompts
            // can carry codename-redacted chat context): never surface prompt text in
            // the Inspector — report shape only. Cardinal privacy rule over convenience.
            return base
        #endif
    }

    private func record(_ r: LLMResponse, since start: Date) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        if !r.toolCalls.isEmpty {
            let names = r.toolCalls.map(\.name).joined(separator: ", ")
            log.post(.llm, .success, "← tool call · \(ms) ms", names)
            return
        }
        // `r.content` is ALREADY reasoning-stripped by the client (decode/StreamAssembler
        // both run strippingReasoningTrace). So an empty content here means the model
        // produced no final answer — almost always a reasoning model that emitted only
        // its private channel (e.g. <think>… or <|channel>thought…), which is stripped.
        if r.content.isEmpty {
            log.post(
                .llm, .error, "← EMPTY answer · \(ms) ms",
                "The model returned no final answer — only private reasoning, which is stripped "
                    + "from chat. This is the classic reasoning/QAT-model failure (e.g. a "
                    + "<|channel>thought… or <think>… trace with no final channel). Fixes: use an "
                    + "INSTRUCT model, disable the model's “thinking” mode, or check LM Studio's "
                    + "reasoning parser/template. (TEST-PLAN §14.4)")
        } else {
            #if DEBUG
                // Dev preview, credential-scrubbed (see requestSummary).
                log.post(
                    .llm, .success, "← answer · \(r.content.count) chars · \(ms) ms",
                    String(CredentialRedactor.scrub(r.content).prefix(200)))
            #else
                // Release: report shape, not content.
                log.post(.llm, .success, "← answer · \(r.content.count) chars · \(ms) ms")
            #endif
        }
    }
}
