import Foundation

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
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
