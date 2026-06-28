import Foundation
import PQRCCore
import PQRCACP  // for ContextBudget

/// Turns an owner-side decrypted transcript (`[StoredMessage]`) into a single,
/// model-injectable "prior context" string for the owner's own tethered AI.
///
/// Pure value code: no actor, no IO, no clock, no randomness, and — critically —
/// **no logging**. The transcript it assembles is owner-side plaintext (the
/// owner's own decrypted messages, deliberately handed to the owner's own
/// model); it never rides the wire (SPEC §0) and is never written to disk in
/// cleartext or emitted to a log. Because this type performs zero IO it cannot
/// breach invariant 12 (no payload/conversation-derived bytes in logs or at
/// rest) by construction — the caller owns whatever it does with the returned
/// string, and persistence of anything derived from it must go through the
/// app-layer `EncryptedStore` (SPEC §3.4, D9).
///
/// Labels are honest to `participant_type` (CLAUDE.md invariant 8, SPEC §8.2/
/// §13.4): a `.human` turn renders as `User:`, a `.agent` turn as `Assistant:`.
/// `message.text` is used verbatim — this is the raw owner-side transcript, not
/// a redacted or re-encoded view.
enum ConversationTranscriptRenderer {

    /// Header that precedes the transcript so the model reads it as background
    /// rather than as a fresh instruction.
    private static let header = "## Earlier in this conversation (for your context)"

    /// Blank-line separator between the header and each labeled turn.
    private static let separator = "\n\n"

    /// UTF-8 byte cost of one `separator`, used by the byte-budget accounting in
    /// `renderCapped` so it never has to materialize a candidate string to know
    /// its size.
    private static let separatorBytes = separator.utf8.count

    /// One labeled transcript line for a message, honest to its `participant_type`.
    private static func line(for message: StoredMessage) -> String {
        switch message.participantType {
        case .human:
            return "User: \(message.text)"
        case .agent:
            return "Assistant: \(message.text)"
        }
    }

    /// Renders the full transcript: the header followed by one labeled line per
    /// message, in chronological order, joined by blank lines. Returns `""` for
    /// an empty input (a lone header carries no context and would only waste
    /// budget).
    static func render(_ messages: [StoredMessage]) -> String {
        guard !messages.isEmpty else { return "" }
        var components: [String] = [header]
        components.append(contentsOf: messages.map(line(for:)))
        return components.joined(separator: separator)
    }

    /// Renders the most-recent turns that fit within `maxBytes` UTF-8 bytes,
    /// preserving chronological order in the output.
    ///
    /// Walks newest → oldest, accumulating the exact UTF-8 byte cost of the
    /// eventual rendered string (header + one labeled line per kept message,
    /// each joined by `separator`), and stops before the first older message
    /// that would push the total over `maxBytes`. The most recent turn is always
    /// kept; if that single turn alone exceeds the budget, the truncate backstop
    /// below trims it. As a final guard the assembled string is passed through
    /// `ContextBudget.truncate(_:maxBytes:)` so the result can never exceed the
    /// budget (head+tail elision on character boundaries). Returns `""` for an
    /// empty input.
    static func renderCapped(_ messages: [StoredMessage], maxBytes: Int) -> String {
        guard let lastIndex = messages.indices.last else { return "" }

        // Always include the most recent turn; an over-budget single turn is
        // handled by the truncate backstop, never by dropping it.
        var startIndex = lastIndex
        var total = header.utf8.count
            + line(for: messages[lastIndex]).utf8.count
            + separatorBytes

        var index = lastIndex - 1
        while index >= 0 {
            let next = total + line(for: messages[index]).utf8.count + separatorBytes
            if next > maxBytes { break }
            total = next
            startIndex = index
            index -= 1
        }

        let kept = Array(messages[startIndex...lastIndex])
        return ContextBudget.truncate(render(kept), maxBytes: maxBytes)
    }
}