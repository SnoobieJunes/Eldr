// SPDX-License-Identifier: Apache-2.0
import Foundation

// VENDORED from PQRCAgent/ReasoningTrace.swift. Copied (not imported) on purpose:
// depending on PQRCAgent would pull PQRCCore + PQRCNostr and thus swift-crypto +
// swift-secp256k1 (a heavy C build) into this otherwise-dependency-free CLI agent,
// just for a ~40-line string helper. Keep these two copies in sync if the upstream
// stripper changes. (See DEVIATIONS: PQRCACP vendoring decision.)

extension String {
    /// Strips a reasoning model's chain-of-thought scratchpad from a completion so
    /// it never lands in a chat bubble. Reasoning models (qwen3, DeepSeek-R1, …)
    /// wrap their private thinking in `<think>…</think>` (and a few spell it
    /// `<thinking>` / `<reasoning>`); EldrChat only wants the final answer.
    ///
    /// Handles three cases:
    ///  - a well-formed `<think>…</think>` block (removed, keeping any real answer
    ///    before or after it);
    ///  - an UNCLOSED `<think>` left by a length-truncated response — everything
    ///    from the tag onward is dropped (the model never reached its answer);
    ///  - no tag at all (returned trimmed, unchanged).
    func strippingReasoningTrace() -> String {
        var s = self
        for tag in ["think", "thinking", "reasoning"] {
            let open = "<\(tag)>"
            let close = "</\(tag)>"
            while let openRange = s.range(of: open, options: .caseInsensitive) {
                if let closeRange = s.range(
                    of: close, options: .caseInsensitive,
                    range: openRange.upperBound..<s.endIndex)
                {
                    s.removeSubrange(openRange.lowerBound..<closeRange.upperBound)
                } else {
                    // Unclosed (truncated mid-thought): nothing usable follows.
                    s.removeSubrange(openRange.lowerBound..<s.endIndex)
                }
            }
        }
        // (2) Harmony / channel-tagged reasoning (gpt-oss; some Gemma QAT builds
        //     emit "<|channel>thought … <channel|> ANSWER"; real Harmony uses
        //     "<|channel|>final<|message|> ANSWER"). Keep only the final channel.
        s = s.keepingFinalChannelOnly()
        // (3) Strip any stray channel/control tokens that survived.
        for token in [
            "<|channel|>", "<|channel>", "<channel|>", "<|message|>", "<|start|>",
            "<|end|>", "<|return|>",
        ] {
            s = s.replacingOccurrences(of: token, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Harmony / channel-tagged reasoning: the private reasoning sits in a
    /// "thought"/"analysis" channel that precedes the answer's final channel. If a
    /// channel marker is present, keep only the text after the final-answer
    /// transition; if the only channel is an unfinished thought (no final
    /// transition), there's no usable answer, so return empty.
    private func keepingFinalChannelOnly() -> String {
        guard contains("channel"), contains("<"), contains("|") else { return self }
        if let r = range(of: "final<|message|>", options: [.caseInsensitive, .backwards]) {
            return String(self[r.upperBound...])
        }
        if let r = range(of: "<channel|>", options: [.caseInsensitive, .backwards]) {
            return String(self[r.upperBound...])
        }
        // One-pipe variant some quants emit: the opener is "<|channel>thought" /
        // "<|channel>analysis" and the ANSWER rides a "final" channel spelled the same
        // one-pipe way ("<|channel>final[<|message|>] ANSWER"). Without this the next
        // line would treat the whole reply as thought-only and return "" — silently
        // dropping a real answer. Keep what follows the LAST final marker.
        for marker in ["<|channel>final", "<channel>final"] {
            if let r = range(of: marker, options: [.caseInsensitive, .backwards]) {
                var tail = String(self[r.upperBound...])
                for lead in ["<|message|>", "<message>"] where tail.hasPrefix(lead) {
                    tail = String(tail.dropFirst(lead.count))
                }
                if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return tail }
            }
        }
        if range(of: "<|channel", options: .caseInsensitive) != nil { return "" }
        return self
    }
}
