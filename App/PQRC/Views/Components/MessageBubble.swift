import PQRCCore
import SwiftUI
import UIKit

/// Bubble rendering (APP-SPEC §6.2). Agent messages are unmistakably distinct
/// — tinted outline + sparkles badge + caption — and the styling survives
/// grayscale (shape + badge, never color alone). A protocol violation renders
/// as a red system row, never as a message.
/// Per-message AI-context visibility for the eye badge (C5): how many tethered
/// AIs currently include this message in their context, and whether any of them
/// is a firewalled remote AI (so the bubble can show the redaction boundary).
struct AIMessageVisibility: Equatable {
    let count: Int
    let redacted: Bool
}

struct MessageBubble: View {
    let message: StoredMessage
    let isMine: Bool
    let senderName: String
    /// Friendly codename of the authoring AI (multi-AI tethering). When set, the
    /// agent bubble shows it instead of "<sender>'s AI" so several AIs in one
    /// conversation are distinguishable. Local-only, never from the wire.
    var agentName: String? = nil
    /// Per-party color coding (APP-SPEC §6.2 readability pass). When supplied,
    /// the HUMAN bubble fills with `palette.solid` and an AGENT bubble uses the
    /// matched tint + on-hue outline/label, so an AI reads as a faded cousin of
    /// its owner. nil keeps the original accent/purple styling (e.g. AI threads,
    /// which are AI-centric and don't color by party). Color is NEVER the sole
    /// signal — agent bubbles always carry the outline + sparkles glyph too
    /// (SPEC §8.2 / colorblind safety), regardless of palette.
    var palette: PartyColor.Palette? = nil
    /// Backend-type badge for an AGENT bubble — the same mark the Settings AI row
    /// shows (AITypeIcon): exactly one of an SF Symbol or an emoji glyph, or neither
    /// (a peer's AI, whose backend isn't broadcast). Display-only; resolved at the
    /// call site from the authoring AI's configured kind.
    var typeSymbol: String? = nil
    var typeGlyph: String? = nil
    /// Toggles the "Add to AI Context" marker (Feature 3). nil hides the action.
    var onToggleAIContext: (() -> Void)? = nil
    /// Opens this message's markdown/HTML in the full-screen reader. nil hides it.
    var onFullScreen: ((String) -> Void)? = nil
    /// Re-sends a message that failed to publish ("Not sent"). nil hides retry.
    var onRetry: (() -> Void)? = nil
    /// Asks the owner's AI to draft a reply to THIS specific message (guest messages
    /// only) → a preview / "Send as my AI" sheet. nil hides the action.
    var onAnswerWithAI: (() -> Void)? = nil

    /// Long-press entry to start a new AI thread anchored to THIS message.
    var onStartThread: (() -> Void)? = nil

    /// Long-press entry (inside a thread) to copy THIS message back into the parent
    /// conversation — "bring the answer back" (D4). nil hides it.
    var onPromoteToMain: (() -> Void)? = nil

    /// My tethered AIs (id, name) for the per-AI context submenu (feature 7). Empty
    /// hides the submenu.
    var myAIs: [(id: String, name: String)] = []
    /// Toggle THIS message in ONE specific AI's context (feature 7). nil hides it.
    var onMarkForAI: ((_ aiID: String, _ value: Bool) -> Void)? = nil

    /// How many tethered AIs currently include THIS message in their context
    /// (and whether any is a firewalled remote AI). nil = not computed. (C5)
    var aiVisibility: AIMessageVisibility? = nil
    /// Whether to show the RAW AgentSkills `⟡⟡ … ⟡⟡ end` protocol envelope in
    /// agent bubbles (per-silo "Show agent protocol envelope" toggle). Default
    /// `false` strips the header/footer at DISPLAY time and shows only the inner
    /// body — the stored record keeps every raw byte (§23). Read from
    /// `AppSession.showAgentEnvelope(siloID:)` at the call site so this stays a
    /// plain value type (no `@Environment` in the bubble). Only ever affects what
    /// is rendered; the stored `message.text` is never mutated.
    var showEnvelope: Bool = false

    /// The text to RENDER for this message. For an agent message with the toggle
    /// off, that's the envelope-stripped inner body; otherwise the raw text
    /// verbatim. Display-only — `message.text` (the stored record) is untouched.
    private var displayText: String {
        guard message.participantType == .agent, !showEnvelope else { return message.text }
        return Self.strippedEnvelopeBody(message.text)
    }

    /// Whether this message has document structure worth opening full screen.
    private var isRich: Bool { MessageContent.isRich(message.text) }

    /// Whether the body is large enough that `CollapsibleMessageContent` collapses
    /// it (and thus already shows its own "Show more" affordance). When true we
    /// suppress the small footer expand glyph so there's a single, clear control.
    private var isLargeContent: Bool { CollapsibleMessageContent.isLarge(message.text) }

    var body: some View {
        if message.localStatus == "violation" {
            violationRow
        } else if message.localStatus == "system" {
            // Window starts, group/thread creation, roster changes (APP-SPEC
            // §6.2): neutral centered rows, never message bubbles.
            SystemRow(text: "\(isMine ? "You" : senderName) \(message.text)")
                .id(message.id)
        } else if message.participantType == .agent {
            agentBubble.contextMenu { bubbleMenu }
        } else {
            humanBubble.contextMenu { bubbleMenu }
        }
    }

    /// Long-press / right-click menu: copy + full-screen (for rich content) +
    /// AI-context toggle. Copy is first so it's the obvious desktop affordance.
    @ViewBuilder private var bubbleMenu: some View {
        copyMenuItem
        fullScreenMenuItem
        aiContextMenuItem
        perAIContextMenuItem
        answerWithAIMenuItem
        startThreadMenuItem
        promoteToMainMenuItem
    }

    /// Per-AI context submenu (feature 7): add/remove THIS message from ONE specific
    /// AI's context — finer than the global "Add to AI Context" flag. A checkmark
    /// shows which AIs currently include it (a globally-marked message means "all my
    /// AIs" until refined per-AI).
    @ViewBuilder private var perAIContextMenuItem: some View {
        if let onMarkForAI, !myAIs.isEmpty {
            Menu {
                ForEach(myAIs, id: \.id) { ai in
                    let marked = effectiveMarks.contains(ai.id)
                    Button {
                        onMarkForAI(ai.id, !marked)
                    } label: {
                        Label(ai.name, systemImage: marked ? "checkmark" : "circle")
                    }
                }
            } label: {
                Label("Add to a specific AI", systemImage: "brain.head.profile")
            }
        }
    }

    /// The set of my AIs that currently see this message: the explicit per-AI marks
    /// if set, else "all my AIs" when globally marked, else none.
    private var effectiveMarks: Set<String> {
        if let marks = message.aiMarks { return Set(marks) }
        return message.aiContext ? Set(myAIs.map(\.id)) : []
    }

    /// Long-press entry (in a thread) to copy this message back into the main chat.
    @ViewBuilder private var promoteToMainMenuItem: some View {
        if let onPromoteToMain {
            Button {
                onPromoteToMain()
            } label: {
                Label("Copy to main chat", systemImage: "arrow.up.forward.square")
            }
        }
    }

    /// Copy the message text to the pasteboard — the right-click → Copy desktop
    /// users expect, and the only way to lift AI output off the screen short of
    /// the full-screen reader.
    private var copyMenuItem: some View {
        Button {
            UIPasteboard.general.string = message.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }

    /// "View full screen" — only for markdown/HTML messages.
    @ViewBuilder private var fullScreenMenuItem: some View {
        if isRich, let onFullScreen {
            Button {
                onFullScreen(message.text)
            } label: {
                Label("View full screen", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
    }

    /// Small expand glyph shown on rich bubbles for discoverability. Hidden for
    /// large bubbles — those already collapse with their own "Show more".
    @ViewBuilder private var expandButton: some View {
        if isRich, !isLargeContent, let onFullScreen {
            Button {
                // `displayText` == `message.text` for human bubbles; for an agent
                // bubble it's the envelope-stripped body, so the reader matches
                // what the bubble shows.
                onFullScreen(displayText)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View full screen")
            .accessibilityIdentifier("expand-message")
        }
    }

    /// Accessibility labels must stay short: a very large message (e.g. a
    /// chunked multi-hundred-KB paste) would otherwise put its entire body into
    /// the accessibility tree, making every VoiceOver/XCUITest traversal of the
    /// conversation crawl. The visual bubble still shows the full text; only the
    /// spoken/queried label is bounded.
    static func accessibleText(_ text: String, limit: Int = 240) -> String {
        guard text.count > limit else { return text }
        return text.prefix(limit) + "… (long message)"
    }

    /// The sentinel that frames an AgentSkills envelope (AgentSkills.envelope):
    /// the opening header line, the standalone separator, and the `⟡⟡ end …`
    /// footer all begin with this glyph pair.
    nonisolated static let envelopeMarker = "⟡⟡"

    /// DISPLAY-TIME envelope stripper. Agent thread messages are wrapped in the
    /// shared AgentSkills envelope (PQRCAgent `AgentSkills.envelope`):
    ///
    ///     ⟡⟡ <skill-name> · v<version>
    ///     from: <you>'s AI · <domain>
    ///     re:   <subject>
    ///     scope: thread:<thread-id>
    ///     ⟡⟡
    ///     <body — what the human actually wants to read>
    ///     ⟡⟡ end <skill-name>
    ///
    /// When `text` matches that shape we return ONLY the inner body (everything
    /// between the standalone `⟡⟡` separator line and the `⟡⟡ end …` footer).
    ///
    /// Parses DEFENSIVELY — the goal is to never hide a real message and never
    /// crash on a partial/streamed envelope:
    ///  - first non-empty line must be a header `⟡⟡ …` that is NOT itself the
    ///    standalone separator and NOT the `⟡⟡ end` footer;
    ///  - there must be a later line that is exactly `⟡⟡` (the separator);
    ///  - the body is taken from after that separator. A closing `⟡⟡ end …` is
    ///    honored when present but NOT required (a truncated/streaming envelope
    ///    still yields its body so far rather than the raw header noise);
    ///  - anything that doesn't match (plain text, a lone fragment, an envelope
    ///    missing its separator) is returned UNCHANGED.
    ///
    /// `nonisolated` + `static` (pure over its input) so it's callable off the
    /// main actor and unit-testable without building a view.
    nonisolated static func strippedEnvelopeBody(_ text: String) -> String {
        // Cheap reject: no marker at all ⇒ definitely not an envelope. (Avoids
        // splitting/scanning ordinary messages, which is the common case.)
        guard text.contains(envelopeMarker) else { return text }

        // Keep blank lines (the body may contain them); we index by line.
        let lines = text.components(separatedBy: "\n")

        // Find the first NON-EMPTY line — that's where a real header must be.
        guard let headerIdx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return text }

        // It must be an opening header: starts with "⟡⟡ " (marker + content),
        // and is neither the bare separator "⟡⟡" nor an "⟡⟡ end …" footer.
        let header = lines[headerIdx].trimmingCharacters(in: .whitespaces)
        guard header.hasPrefix(envelopeMarker + " "),
            !isSeparatorLine(header),
            !isEndLine(header)
        else { return text }

        // Find the standalone separator line (exactly "⟡⟡") AFTER the header.
        guard let sepIdx = lines[(headerIdx + 1)...].firstIndex(where: { isSeparatorLine($0) })
        else { return text }  // header but no separator ⇒ not (yet) a full envelope

        // Body = lines after the separator, up to the "⟡⟡ end …" footer if there
        // is one (else to the end — handles a truncated/streaming envelope).
        let afterSep = lines[(sepIdx + 1)...]
        let endIdx = afterSep.firstIndex(where: { isEndLine($0) })
        let bodyLines = afterSep[afterSep.startIndex..<(endIdx ?? afterSep.endIndex)]
        // Trim only leading/trailing blank lines introduced by the envelope frame
        // (the separator's newline and the line before the footer); inner blank
        // lines of the body are preserved.
        return bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// A line that is exactly the bare separator `⟡⟡` (ignoring surrounding space).
    nonisolated private static func isSeparatorLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == envelopeMarker
    }

    /// A line that opens the closing footer `⟡⟡ end …` (ignoring surrounding space).
    nonisolated private static func isEndLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(envelopeMarker + " end")
    }

    /// Long-press menu entry for marking a message as AI context.
    @ViewBuilder private var aiContextMenuItem: some View {
        if let onToggleAIContext {
            Button {
                onToggleAIContext()
            } label: {
                Label(
                    message.aiContext ? "Remove from AI Context" : "Add to AI Context",
                    systemImage: message.aiContext ? "brain.head.profile" : "brain")
            }
        }
    }

    /// Long-press entry to have the owner's AI draft a reply to THIS message — a
    /// user-initiated answer (no `ai_window` needed) shown in a preview/send sheet.
    @ViewBuilder private var answerWithAIMenuItem: some View {
        if let onAnswerWithAI {
            Button {
                onAnswerWithAI()
            } label: {
                Label("Have my AI answer this", systemImage: "sparkles")
            }
        }
    }

    /// Long-press entry to start a focused AI thread anchored to this message.
    @ViewBuilder private var startThreadMenuItem: some View {
        if let onStartThread {
            Button {
                onStartThread()
            } label: {
                Label("Start a thread from here", systemImage: "text.bubble")
            }
        }
    }

    /// Small marker shown on messages flagged for AI context.
    @ViewBuilder private var aiContextBadge: some View {
        if message.aiContext {
            Image(systemName: "brain")
                .font(.caption2)
                .foregroundStyle(.purple)
                .accessibilityLabel("Marked as AI context")
        }
    }

    /// Eye badge (C5): how many tethered AIs currently see this message as
    /// context. Shown only when ≥1 AI includes it (avoids clutter per the
    /// UI-overload feedback); a firewalled remote AI flips the glyph so the
    /// redaction boundary stays visible.
    @ViewBuilder private var aiVisibilityBadge: some View {
        if let v = aiVisibility, v.count > 0 {
            HStack(spacing: 2) {
                Image(systemName: v.redacted ? "eye.trianglebadge.exclamationmark" : "eye")
                Text("\(v.count)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                v.redacted
                    ? "Seen by \(v.count) AI\(v.count == 1 ? "" : "s"), redacted for a cloud AI"
                    : "Seen by \(v.count) AI\(v.count == 1 ? "" : "s")")
            .accessibilityIdentifier("ai-visibility-badge")
        }
    }

    /// iMessage-style bubble (iOS 26): continuous corners, gradient tint for
    /// outgoing. Backgrounds stay opaque — translucent materials under busy
    /// content fail the contrast audit.
    private var humanBubble: some View {
        // Party color (APP-SPEC §6.2): each human gets a deterministic SOLID
        // fill. With a palette we color BOTH sides (mine and the peer's) by
        // identity; white text reads on every solid here (≥ 5.8:1, PartyColor).
        // A FLAT opaque fill (not a gradient) is deliberate: the accessibility
        // auditor needs a determinable background, and a flat color is the most
        // unambiguous one. Without a palette we keep the original accent-for-mine
        // gradient / neutral-for-theirs scheme.
        let solidFill: AnyShapeStyle = {
            if let palette {
                return AnyShapeStyle(palette.solid)
            }
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.mix(with: .black, by: 0.18)],
                    startPoint: .top, endPoint: .bottom))
        }()
        // A palette colors the peer's bubble too (solid, white text); the old
        // path left incoming bubbles neutral with primary text.
        let isFilled = isMine || palette != nil
        return HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                CollapsibleMessageContent(text: message.text, onFullScreen: onFullScreen)
                    // Drag-to-select on Mac/iPad (with right-click → Copy above).
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        isFilled
                            // Opaque white-text-safe fill: the flat party solid
                            // (palette) or the accent gradient, which only ever
                            // runs darker than the white-safe accent asset (A7).
                            ? solidFill
                            : AnyShapeStyle(Color(.secondarySystemBackground)),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .foregroundStyle(isFilled ? .white : .primary)
                HStack(spacing: 6) {
                    aiContextBadge
                    aiVisibilityBadge
                    expandButton
                    if isMine {
                        // Local-only status; copy says "sent to relay", never "delivered" (D5).
                        // A publish that never reached the relay shows "Not sent ·
                        // Tap to retry" — a tappable recovery path, not a dead end.
                        if message.localStatus == "failed", let onRetry {
                            Button(action: onRetry) {
                                Label("Not sent · Tap to retry", systemImage: "arrow.clockwise")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("retry-message")
                        } else {
                            Text(message.localStatus == "queued" ? "Queued" : "Sent to relay")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(isMine ? "You" : senderName): \(Self.accessibleText(message.text))")
    }

    /// Agent OUTLINE accent (the colored border — a non-color AI signal). On-hue
    /// stroke with a palette; purple without (ThreadView).
    private var agentAccent: Color {
        palette?.aiStroke ?? Color.purple.mix(with: .primary, by: 0.45)
    }

    /// Agent LABEL / glyph color. The "⟡ name" caption sits on the light AI fill,
    /// so it needs near-`.primary` contrast: the palette supplies a high-contrast
    /// hue-tinted color; without one we keep the darkened purple (ThreadView).
    private var agentLabelColor: Color {
        palette?.aiLabel ?? Color.purple.mix(with: .primary, by: 0.45)
    }

    /// AI bubble FILL: the owner's faded tint when colored by party, else the
    /// original opaque purple wash. Opaque either way — translucent fills give
    /// the contrast auditor no determinable background over bars (A7).
    private var agentFill: Color {
        palette?.aiFill ?? Color.purple.mix(with: Color(.systemBackground), by: 0.94)
    }

    /// What the agent bubble's header reads: the AI's own friendly codename when
    /// known (a tethered AI's local codename always wins), otherwise "My AI" for
    /// the LOCAL user's own agent and "<sender>'s AI" for everyone else. The
    /// possessive is keyed off the real self signal (`isMine`, i.e.
    /// `senderIdentity == myIdentityHex` at the call site), NOT the displayed
    /// `senderName` — that's the configurable alias/persona ("Me" by default, but
    /// editable), so "<senderName>'s AI" rendered "Me's AI" for the owner.
    private var agentLabel: String {
        // A co-authored message (the human directed + approved their AI's draft)
        // names BOTH contributors — "made with the person and the AI" (user
        // request). It STILL renders as an AI bubble (⟡ + sparkles badge below),
        // so invariant 8 holds: this credits the human director, it does not
        // relabel an agent message as human-authored.
        if message.coauthored {
            return isMine ? "Made with you and your AI" : "Made with \(senderName) and their AI"
        }
        if let agentName { return agentName }
        return isMine ? "My AI" : "\(senderName)'s AI"
    }

    private var agentBubble: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // ⟡ + sparkles + label: the NON-color signal that this is an
                    // AI (holds in grayscale / for colorblind users, SPEC §8.2).
                    Label("⟡ \(agentLabel)", systemImage: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(agentLabelColor)
                    // Backend-type badge (Apple/phone/Mac-Tethered-AI/🦞/…): which
                    // KIND of AI this is, matching the Settings row. Only set for my
                    // own AIs (a peer's backend isn't broadcast).
                    AITypeBadgeView(
                        symbol: typeSymbol, glyph: typeGlyph, size: 11, tint: agentLabelColor)
                        .accessibilityHidden(true)
                    expandButton
                }
                HStack(alignment: .top, spacing: 6) {
                    if message.isContext {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(agentLabelColor)
                            .accessibilityLabel("Context contribution")
                    }
                    // Render the DISPLAY text (envelope stripped unless the
                    // "Show agent protocol envelope" toggle is on). The full-
                    // screen reader gets the same stripped body so it never shows
                    // the header/footer the bubble hid. Stored `message.text` is
                    // untouched — this is display-only.
                    CollapsibleMessageContent(text: displayText, onFullScreen: onFullScreen)
                        .textSelection(.enabled)
                    aiContextBadge
                    aiVisibilityBadge
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    agentFill,
                    in: RoundedRectangle(cornerRadius: 18))
                // Outline is load-bearing as a non-color AI signal: keep it
                // visible (on-hue with a palette, purple without). 1.5pt at the
                // party stroke / 0.6 purple both clear the audit.
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            palette != nil
                                ? AnyShapeStyle(agentAccent.opacity(0.85))
                                : AnyShapeStyle(.purple.opacity(0.6)),
                            lineWidth: 1.5))
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .id(message.id)
        .privacySensitive()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            message.coauthored
                ? "AI message, \(agentLabel): \(Self.accessibleText(displayText))"
                : "AI message from \(agentLabel): \(Self.accessibleText(displayText))")
        .accessibilityIdentifier("agent-bubble")
    }

    private var violationRow: some View {
        Label(message.text, systemImage: "exclamationmark.octagon.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .id(message.id)
            .accessibilityIdentifier("protocol-violation-row")
    }
}

/// Wraps message content so a LARGE block (long markdown / HTML / plain text)
/// collapses to a compact preview by default with a clear, HONEST affordance,
/// while small messages render unchanged (APP-SPEC §6.2 readability pass).
///
/// Affordance honesty (the fix): "Show more" expands the message **inline, in
/// place** — exactly what the words promise — instead of yanking the reader into
/// a separate screen. Expanded, a "Show less" folds it back, and a quiet "Open
/// full screen" remains for the landscape + pinch-zoom reader (the right home for
/// a genuinely huge document). Only content past a hard ceiling (a chunked multi-
/// hundred-KB paste, where inline layout would thrash) skips inline expansion and
/// goes straight to the reader — and there the button SAYS so.
///
/// "Large" is measured on the raw text length + line count (cheap and safe even
/// for a 200 KB paste). A modest threshold keeps ordinary multi-line replies
/// fully inline; only genuinely big blocks collapse.
struct CollapsibleMessageContent: View {
    let text: String
    /// Opens the full-screen reader. When nil (e.g. no reader wired up) large
    /// content still expands inline; only the optional "Open full screen" escape
    /// is hidden (and over-ceiling content stays a bounded preview).
    var onFullScreen: ((String) -> Void)? = nil

    /// Inline expand/collapse state. Defaults collapsed; the preview + "Show more"
    /// is what you see first, so a long paste never blows out the scroll on entry.
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A block is "large" past EITHER bound. Tuned so a normal paragraph or a
    /// short list stays inline, but a long document/code dump collapses.
    /// `nonisolated` so the `nonisolated` `isLarge(_:)` (callable off the main
    /// actor) can read them under Swift 6 strict concurrency.
    nonisolated private static let previewLineLimit = 10
    nonisolated private static let largeCharThreshold = 700
    nonisolated private static let largeLineThreshold = 14
    /// Above this, inline rendering would round-trip a huge block through the
    /// markdown pipeline every layout pass (pathological for a chunked paste), so
    /// we keep the cheap preview and route expansion to the purpose-built reader.
    nonisolated private static let inlineExpandCeiling = 20_000

    /// Whether `text` is large enough to collapse. Static + `nonisolated` so the
    /// bubble can ask the same question (to suppress its duplicate expand glyph)
    /// without building the view.
    ///
    /// Judged on the RAW text (length + newline count), NOT the markdown-stripped
    /// plain text: stripping round-trips through `AttributedString` per block and
    /// is pathological on a huge paste (a 200 KB block would re-parse every
    /// render — exactly the case that must collapse). Raw length is an upper
    /// bound on the stripped length, so everything worth collapsing is still
    /// caught, just faster and without the markdown cost.
    nonisolated static func isLarge(_ text: String) -> Bool {
        if text.count > largeCharThreshold { return true }
        var lines = 1
        for ch in text where ch == "\n" { lines += 1 }
        return lines > largeLineThreshold
    }

    /// True when this block is too big to render inline and must use the reader.
    private var exceedsInlineCeiling: Bool { text.count > Self.inlineExpandCeiling }

    var body: some View {
        if Self.isLarge(text) {
            VStack(alignment: .leading, spacing: 6) {
                if expanded && !exceedsInlineCeiling {
                    // Honest "Show more": the full, richly-rendered message, in
                    // place. Paid for only on demand (collapsed by default), and
                    // never for an over-ceiling paste (handled below).
                    MessageContent(text: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    preview
                }
                affordance
            }
            .accessibilityElement(children: .contain)
        } else {
            MessageContent(text: text)
        }
    }

    /// Faded plain-text preview. No per-block layout cost — and the input is
    /// bounded first so a multi-hundred-KB block never round-trips its whole
    /// length just to show the first lines.
    private var preview: some View {
        let plain = MessageContent.plain(String(text.prefix(2000)))
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(Self.previewLineLimit)
            .joined(separator: "\n")
        return Text(verbatim: lines)
            .lineLimit(Self.previewLineLimit)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Soft fade at the cut so it reads as "there's more below".
            .mask(
                LinearGradient(
                    colors: [.black, .black, .black.opacity(0.15)],
                    startPoint: .top, endPoint: .bottom))
    }

    /// The expand/collapse control — and, when relevant, the full-screen escape.
    @ViewBuilder private var affordance: some View {
        if exceedsInlineCeiling {
            // Too big to inline: the only honest action is the reader, so the
            // label says exactly that (no "Show more" promise we can't keep).
            if let onFullScreen {
                expandStyleButton(
                    title: "Open full screen · \(Self.sizeLabel(text.count))",
                    systemImage: "arrow.up.left.and.arrow.down.right",
                    a11y: "Open full message, \(text.count) characters, in the full-screen reader",
                    id: "expand-collapsed-content"
                ) { onFullScreen(text) }
            } else {
                Text("⋯ long message · \(Self.sizeLabel(text.count))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if expanded {
            HStack(spacing: 14) {
                expandStyleButton(
                    title: "Show less", systemImage: "chevron.up",
                    a11y: "Collapse message", id: "collapse-content"
                ) { setExpanded(false) }
                // Keep the reader available for landscape + pinch-zoom, but as a
                // clearly-secondary action now that the text is already in view.
                if let onFullScreen {
                    Button { onFullScreen(text) } label: {
                        Label("Open full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("open-fullscreen-content")
                    .accessibilityLabel("Open full message in the full-screen reader")
                }
            }
        } else {
            // Collapsed: "Show more" honestly expands inline (chevron, not the
            // expand-corner glyph that means "go full screen").
            expandStyleButton(
                title: "Show more · \(Self.sizeLabel(text.count))",
                systemImage: "chevron.down",
                a11y: "Show the full message inline, \(text.count) characters",
                id: "expand-collapsed-content"
            ) { setExpanded(true) }
        }
    }

    /// Shared styling for the primary expand/collapse buttons.
    private func expandStyleButton(
        title: String, systemImage: String, a11y: String, id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityLabel(a11y)
    }

    private func setExpanded(_ value: Bool) {
        if reduceMotion {
            expanded = value
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { expanded = value }
        }
    }

    /// Compact human-readable size for the affordance ("1.2k chars" / "740 chars").
    private static func sizeLabel(_ n: Int) -> String {
        n >= 1000
            ? String(format: "%.1fk chars", Double(n) / 1000)
            : "\(n) chars"
    }
}

/// Neutral centered system row (ai_window start/expiry, roster changes,
/// anchors). The opaque capsule is load-bearing for the accessibility audit:
/// bare text near the glass header gives the contrast auditor no determinable
/// background and it hard-fails regardless of the actual color (A7) — the
/// same opaque fill incoming bubbles use keeps it green in both schemes.
struct SystemRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.gray.mix(with: .primary, by: 0.6))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
    }
}
