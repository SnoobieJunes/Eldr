// SPDX-License-Identifier: Apache-2.0
import Foundation

// TownWall — a pure, deterministic model of goosetown's Town Wall (`./gtwall`),
// generalized to span TOWNS instead of one machine's delegates (GOOSEWORLD §1, §6
// WS-G3).
//
// **Provenance of the semantics below (important — this is verified, not assumed).**
// The behavior modeled here was read out of the actual `gtwall` bash script at
// https://raw.githubusercontent.com/aaif-goose/goosetown/main/gtwall (11,950 bytes,
// 401 lines, fetched 2026-07-20). GOOSEWORLD §6 warned "its internals are unspecified
// in the docs fetched today; don't design blind" — the spike closed that gap, so the
// following are FACTS about gtwall, each with the mirroring decision we made:
//
// | gtwall (verified) | TownWall (here) | Why the difference |
// |---|---|---|
// | Wall is an append-only text file, one post per line, `HH:MM:SS\|sender\|message` | Append-only array of structured `WallPost` | Structured fields cannot be forged by post CONTENT (see `UntrustedDataEnvelope`) |
// | Newlines in a post are flattened to spaces; `\|` escaped | Post text kept verbatim; the RENDERER quotes every line | Flattening destroys code/findings; quoting is the stronger containment |
// | Per-reader position = a LINE NUMBER in `<wall>.positions/<id>.pos` | Per-reader cursor = a monotonic SEQUENCE number | Line numbers move backward when the file is truncated (see below) |
// | Read emits lines `(pos+1)…wc -l`, then **unconditionally** sets pos = `wc -l` | Cursor advances to the highest sequence actually RETURNED | gtwall has no read limit; we do, and advancing past unreturned posts loses them silently |
// | Reader id validated `^[A-Za-z0-9_-]+$` ("Bad: ../hack") | Same charset, same rationale, plus a length cap | The real bridge will key persistent state by this id |
// | Missing/corrupt position file → 0 (replay everything) | Unknown reader → cursor 0, plus an explicit eviction-gap notice | Same failure posture, but honest about what it can no longer see |
// | `--reset <id>` deletes the position file | `fromStart:` on `read` | Keeps the tool count at the four GOOSEWORLD names |
// | `--clear` truncates the wall AND deletes every position | No truncation primitive; bounded eviction instead | See "Why bounded" |
// | **No retention limit at all — the log grows forever** | Hard cap on retained posts + per-post bytes | See "Why bounded" |
//
// **The truncation hazard we deliberately do not inherit.** gtwall's cursor is a line
// number and its wall is a file. If the file is truncated without clearing positions
// (crash, log rotation, a second `--clear` racing a reader) every reader's position
// silently points past the end, `read` returns nothing, and the position is then moved
// BACKWARD to the new line count — after which old posts replay as if new. Sequences
// here are drawn from a counter that only ever increases and is never reset by
// eviction, so a cursor can never be invalidated by the wall shrinking, and a cursor
// is never moved backward.
//
// **Why bounded (this is a security property, not tidiness).** This model lives in a
// long-lived daemon that accepts posts from OTHER PEOPLE'S MACHINES. An unbounded
// append-only log fed by remote peers is a memory exhaustion primitive: a hostile or
// merely buggy town posts until the node dies, taking the owner's messenger with it.
// So: `maxPostBytes` bounds one post, `maxRetainedPosts` bounds the log, and
// `maxReadBytes` bounds one read's output (which is also the model's context window —
// an unbounded read is a context-flooding attack that pushes the operator's own
// instructions out of the window). Eviction is oldest-first; a reader whose cursor was
// evicted past gets a COUNTED, VISIBLE gap (`missedPosts`), never a silent skip.
//
// **No clocks.** Nothing here reads the wall clock. `append` takes the timestamp as a
// parameter (CLAUDE.md engineering conventions: no unit test touches the real clock),
// and timestamps are metadata only — they are never inputs to ordering, which is
// governed solely by the sequence counter.

/// Who wrote a post. Both halves are STAMPED BY THE NODE, never chosen by the agent
/// that called `world_wall_post` — an agent cannot pick its own name on the wall, which
/// is what keeps GOOSEWORLD §4.3 (sybil towns / impersonation) from being a one-line
/// forgery. Both are constrained to gtwall's identifier charset so they can never
/// contain the envelope's structural characters.
public struct WallAuthor: Sendable, Codable, Equatable {
    /// The town the post came from (a local pairing label, never an identity key).
    public let town: String
    /// The agent/delegate within that town (gtwall's `<id>`).
    public let agent: String
    public init(town: String, agent: String) {
        self.town = town
        self.agent = agent
    }
}

/// One immutable post. Never mutated, never deleted except by bounded eviction.
///
/// `targets` and `priorityForHuman` are STRUCTURED METADATA held outside `text`. That
/// separation is load-bearing: a remote post whose body reads
/// `priority-for-human: yes` cannot raise its own priority, because the renderer only
/// ever prints the struct field, and the body only ever appears quoted inside the
/// untrusted-data block. In gtwall both of these are conventions carried *inside* the
/// message text (`@name` written by hand, "from sender `user`" meaning human-priority),
/// which is exactly the forgeable shape we are refusing to reproduce.
public struct WallPost: Sendable, Codable, Equatable {
    /// 1-based, strictly increasing, never reused, never reset by eviction.
    public let sequence: UInt64
    public let author: WallAuthor
    /// The post body, VERBATIM. Treat as hostile: it is remote input. Never render it
    /// except through `UntrustedDataEnvelope`.
    public let text: String
    /// `@name` targets: parsed from `text` plus any explicit targets, normalized to
    /// lowercase, deduplicated, order-preserving, bounded.
    public let targets: [String]
    /// gtwall's "prioritize above all other wall traffic" flag. Advisory metadata only —
    /// it grants no authority, and nothing in this package acts on it.
    public let priorityForHuman: Bool
    /// Unix seconds, supplied by the caller's clock seam. Metadata only: ordering is by
    /// `sequence`, never by time.
    public let postedAt: Int64

    public init(
        sequence: UInt64, author: WallAuthor, text: String, targets: [String],
        priorityForHuman: Bool, postedAt: Int64
    ) {
        self.sequence = sequence
        self.author = author
        self.text = text
        self.targets = targets
        self.priorityForHuman = priorityForHuman
        self.postedAt = postedAt
    }
}

/// Why a post or read was refused. Typed, exhaustive, and surfaced to the caller as a
/// tool ERROR — nothing here is ever swallowed (GOOSEWORLD §4: a dropped refusal is how
/// an agent concludes it succeeded).
public enum TownWallError: Error, Equatable, Sendable {
    /// Empty or whitespace-only body. gtwall refuses these too ("Message cannot be empty").
    case emptyText
    /// Body exceeds `Limits.maxPostBytes`. We refuse rather than truncate: silently
    /// cutting attacker-influenced text changes its meaning and hides the boundary.
    case textTooLarge(bytes: Int, limit: Int)
    /// An identifier (town, agent, reader, or target) is outside `[A-Za-z0-9_-]{1,limit}`.
    /// gtwall rejects the same shapes for the same reason (its ids become file paths;
    /// its own help text calls out `../hack`).
    case invalidIdentifier(String)
    /// More `@`-targets than `Limits.maxTargets`.
    case tooManyTargets(count: Int, limit: Int)
}

/// The result of one `read`. Everything a caller needs to explain, exactly, what the
/// reader saw and what it can never see again.
public struct WallReadResult: Sendable, Equatable {
    /// The town this node belongs to, so the renderer can mark foreign posts.
    public let localTown: String
    /// Posts returned, oldest first. Bounded by `limit` and by the read byte budget.
    public let posts: [WallPost]
    /// Cursor before the read (the highest sequence this reader had already consumed).
    public let cursorBefore: UInt64
    /// Cursor after the read. Advances to the highest sequence RETURNED — never past a
    /// post the caller did not receive.
    public let cursorAfter: UInt64
    /// Posts that were evicted before this reader reached them. Permanently lost; the
    /// renderer states this in plain language rather than pretending the wall is whole.
    public let missedPosts: Int
    /// Unread posts still on the wall after this read (limit/byte budget hit). The caller
    /// gets them by reading again — the cursor did not skip them.
    public let unreadRemaining: Int

    public init(
        localTown: String, posts: [WallPost], cursorBefore: UInt64, cursorAfter: UInt64,
        missedPosts: Int, unreadRemaining: Int
    ) {
        self.localTown = localTown
        self.posts = posts
        self.cursorBefore = cursorBefore
        self.cursorAfter = cursorAfter
        self.missedPosts = missedPosts
        self.unreadRemaining = unreadRemaining
    }
}

/// `@name` parsing, specified rather than "whatever the regex did".
///
/// The recognized name charset is exactly gtwall's own id charset (`[A-Za-z0-9_-]`), so
/// a name that parses here is a name that could actually be a delegate id there.
public enum WallMentions {
    /// Scalars that may appear in a name.
    static func isNameScalar(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || (s >= "0" && s <= "9") || s == "_"
            || s == "-"
    }

    /// Scalars which, immediately BEFORE an `@`, mean "this is not a mention". Covers
    /// the email shapes (`me@x.com`, `a.b@x`, `a+tag@x`) and `@@`, which would otherwise
    /// let a post manufacture mentions out of ordinary prose.
    private static func suppressesMention(_ s: Unicode.Scalar) -> Bool {
        isNameScalar(s) || s == "." || s == "+" || s == "@"
    }

    /// Parse `@name` mentions from post text.
    ///
    /// Rules, all tested:
    /// - An `@` counts only at the start of the text or after a scalar that is not a
    ///   name scalar, `.`, `+`, or `@`. So `foo@bar` and `me@x.com` yield nothing.
    /// - The name is the following run of `[A-Za-z0-9_-]`; punctuation ends it, so
    ///   `@bob,` and `@bob.` both mention `bob`.
    /// - Trailing `-`/`_` are trimmed (`@bob--` → `bob`); a name that is empty after
    ///   trimming is discarded, which is how a bare `@` and `@@bob` yield nothing.
    /// - Names are lowercased and deduplicated, keeping first-occurrence order.
    /// - Non-ASCII names are not recognized at all (`@Ω` yields nothing) — the charset
    ///   is the interop constraint, and accepting confusable Unicode names into a
    ///   routing field is a spoofing surface we decline to open.
    /// - `@example.com` mentions `example`; the domain tail is not consulted.
    /// - At most `limit` distinct names survive; the rest are dropped (bounded routing).
    public static func parse(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "@" else {
                i += 1
                continue
            }
            if i > 0, suppressesMention(scalars[i - 1]) {
                i += 1
                continue
            }
            var j = i + 1
            var name = String.UnicodeScalarView()
            while j < scalars.count, isNameScalar(scalars[j]) {
                name.append(scalars[j])
                j += 1
            }
            var candidate = String(name)
            while let last = candidate.last, last == "-" || last == "_" {
                candidate.removeLast()
            }
            if !candidate.isEmpty {
                let normalized = candidate.lowercased()
                if !seen.contains(normalized), out.count < limit {
                    seen.insert(normalized)
                    out.append(normalized)
                }
            }
            // Resume AFTER the consumed run so `@a@b` can't be re-scanned into `@b`
            // twice; `@` at j (if any) is handled by the suppression rule anyway.
            i = max(j, i + 1)
        }
        return out
    }
}

/// The append-only, per-reader-positioned, BOUNDED cross-town wall.
///
/// A value type on purpose: it holds no clock, no I/O, no randomness and no identity,
/// so every behavior in it is reproducible from its inputs. The node wraps it in an
/// actor (see `DemoGooseworldBridge`) to own the mutation.
public struct TownWall: Sendable, Equatable {
    /// Every bound in one place, so the DoS surface is auditable at a glance.
    public struct Limits: Sendable, Equatable {
        /// Posts retained before oldest-first eviction begins.
        public var maxRetainedPosts: Int
        /// UTF-8 bytes in one post body. 4 KiB is roughly gtwall's practical line size
        /// and comfortably below the 64 KiB inline ceiling the product enforces
        /// everywhere else (CLAUDE.md invariant 4 — big text chunks, never inlines).
        public var maxPostBytes: Int
        /// Distinct `@`-targets retained on a post.
        public var maxTargets: Int
        /// Length of any identifier (town, agent, reader, target).
        public var maxIdentifierLength: Int
        /// UTF-8 bytes of post BODY returned by one `read`, before framing overhead.
        /// This is the model's context budget as much as it is a transfer budget.
        public var maxReadBytes: Int
        /// Posts returned by one `read` when the caller does not ask for fewer.
        public var defaultReadLimit: Int
        /// Ceiling on the caller's requested read limit.
        public var maxReadLimit: Int

        public init(
            maxRetainedPosts: Int = 512, maxPostBytes: Int = 4096, maxTargets: Int = 32,
            maxIdentifierLength: Int = 64, maxReadBytes: Int = 64 * 1024,
            defaultReadLimit: Int = 50, maxReadLimit: Int = 200
        ) {
            self.maxRetainedPosts = max(1, maxRetainedPosts)
            self.maxPostBytes = max(1, maxPostBytes)
            self.maxTargets = max(1, maxTargets)
            self.maxIdentifierLength = max(1, maxIdentifierLength)
            self.maxReadBytes = max(maxPostBytes, maxReadBytes)
            self.defaultReadLimit = max(1, defaultReadLimit)
            self.maxReadLimit = max(1, maxReadLimit)
        }
    }

    /// This node's own town label; posts from any other town render as REMOTE.
    public let localTown: String
    public let limits: Limits

    /// Retained posts, oldest first.
    public private(set) var posts: [WallPost] = []
    /// Total posts evicted over the wall's lifetime (monitoring + gap accounting).
    public private(set) var evictedCount: Int = 0
    /// Next sequence to hand out. Monotonic; eviction never rewinds it.
    private var nextSequence: UInt64 = 1
    /// Per-reader positions — gtwall's defining feature. Value = highest sequence that
    /// reader has consumed. Absent = 0 = "has seen nothing".
    private var cursors: [String: UInt64] = [:]

    public init(localTown: String, limits: Limits = Limits()) {
        self.localTown = Self.isValidIdentifier(localTown, max: limits.maxIdentifierLength)
            ? localTown : "unknown-town"
        self.limits = limits
    }

    // MARK: - Identifiers

    /// gtwall's `validate_id`, verbatim in intent: `^[A-Za-z0-9_-]+$`, plus a length cap.
    /// Rejecting here is what guarantees no identifier can ever contain a newline, a
    /// pipe, or the envelope's marker characters — the renderer re-checks anyway
    /// (defense in depth), but this is where it is supposed to be caught.
    public static func isValidIdentifier(_ id: String, max: Int) -> Bool {
        guard !id.isEmpty, id.utf8.count <= max else { return false }
        for scalar in id.unicodeScalars where !WallMentions.isNameScalar(scalar) { return false }
        return true
    }

    private func requireIdentifier(_ id: String) throws {
        guard Self.isValidIdentifier(id, max: limits.maxIdentifierLength) else {
            throw TownWallError.invalidIdentifier(id)
        }
    }

    // MARK: - Append (never mutate, never delete except by bounded eviction)

    /// Append one post and return it.
    ///
    /// - Parameters:
    ///   - text: the body, kept verbatim (see `WallPost.text`).
    ///   - author: STAMPED BY THE CALLER (the node), not by the posting agent.
    ///   - explicitTargets: targets supplied out-of-band, unioned with the `@names`
    ///     parsed from `text`. Each must be a valid identifier — an invalid one is
    ///     refused rather than dropped, so a caller never believes it addressed someone
    ///     it did not.
    ///   - priorityForHuman: gtwall's human-priority flag. Advisory.
    ///   - at: Unix seconds from the caller's clock seam. Never read from the system.
    @discardableResult
    public mutating func append(
        text: String, author: WallAuthor, explicitTargets: [String] = [],
        priorityForHuman: Bool = false, at postedAt: Int64
    ) throws -> WallPost {
        try requireIdentifier(author.town)
        try requireIdentifier(author.agent)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TownWallError.emptyText
        }
        let bytes = text.utf8.count
        guard bytes <= limits.maxPostBytes else {
            throw TownWallError.textTooLarge(bytes: bytes, limit: limits.maxPostBytes)
        }
        for target in explicitTargets { try requireIdentifier(target) }

        var targets: [String] = []
        var seen = Set<String>()
        for target in explicitTargets.map({ $0.lowercased() }) + WallMentions.parse(
            text, limit: limits.maxTargets)
        where !seen.contains(target) {
            seen.insert(target)
            targets.append(target)
        }
        guard targets.count <= limits.maxTargets else {
            throw TownWallError.tooManyTargets(count: targets.count, limit: limits.maxTargets)
        }

        let post = WallPost(
            sequence: nextSequence, author: author, text: text, targets: targets,
            priorityForHuman: priorityForHuman, postedAt: postedAt)
        nextSequence += 1
        posts.append(post)
        evictIfNeeded()
        return post
    }

    /// Append a post while SKIPPING identifier validation, keeping sequencing, byte
    /// bounds and eviction intact.
    ///
    /// This exists for one reason: `UntrustedDataEnvelope`'s defenses must be provable
    /// on their own. `append` refuses a hostile town/agent/target id, so without this
    /// hatch a test could never reach the renderer with one, and layer 4 would be an
    /// untested comment. It is `internal` — no MCP tool, and nothing outside this
    /// module, can reach it.
    @discardableResult
    mutating func appendUnvalidated(
        text: String, author: WallAuthor, targets: [String], priorityForHuman: Bool,
        at postedAt: Int64
    ) -> WallPost {
        let post = WallPost(
            sequence: nextSequence, author: author, text: text,
            targets: Array(targets.prefix(limits.maxTargets)), priorityForHuman: priorityForHuman,
            postedAt: postedAt)
        nextSequence += 1
        posts.append(post)
        evictIfNeeded()
        return post
    }

    /// Oldest-first eviction. The sequence counter is untouched, so no cursor is ever
    /// invalidated — a cursor that falls behind the retained window produces a counted
    /// gap in `read`, which is a defined, reportable outcome rather than a crash or a
    /// silent hole.
    private mutating func evictIfNeeded() {
        guard posts.count > limits.maxRetainedPosts else { return }
        let excess = posts.count - limits.maxRetainedPosts
        posts.removeFirst(excess)
        evictedCount += excess
    }

    // MARK: - Read (per-reader cursors)

    /// The reader's current position, 0 if it has never read. Pure; does not create the
    /// reader. Returns nil for an invalid reader id rather than inventing a cursor.
    public func cursor(for reader: String) -> UInt64? {
        guard Self.isValidIdentifier(reader, max: limits.maxIdentifierLength) else { return nil }
        return cursors[reader] ?? 0
    }

    /// Highest sequence ever assigned (0 on an empty, never-posted wall).
    public var highestSequence: UInt64 { nextSequence - 1 }

    /// Restore a persisted position, as gtwall does by reading `<id>.pos` off disk on
    /// every invocation. The production bridge needs this so a node restart does not
    /// replay the whole retained wall to every delegate.
    ///
    /// It is deliberately allowed to set a position ABOVE `highestSequence`: that is
    /// what a restored cursor looks like when the wall was rebuilt smaller (gtwall's
    /// truncation case), and `read` must treat it as inert rather than crash or replay.
    /// It is deliberately NOT allowed to move a cursor backward implicitly — callers
    /// that want a replay ask for it by name via `read(fromStart:)`.
    public mutating func restoreCursor(reader: String, to position: UInt64) throws {
        try requireIdentifier(reader)
        cursors[reader] = max(cursors[reader] ?? 0, position)
    }

    /// Read what `reader` has not seen and advance its cursor.
    ///
    /// Cursor rules, all tested:
    /// - Advances to the highest sequence **actually returned**. If `limit` or the byte
    ///   budget cut the read short, the remainder stays unread — unlike gtwall, which
    ///   jumps the position to the end of the file on every read.
    /// - Never moves backward. A cursor "from the future" (higher than any sequence that
    ///   exists — the shape gtwall produces after a truncation) returns nothing, keeps
    ///   its value, and reports no gap. It is inert, not fatal.
    /// - `fromStart` is gtwall's `--reset`: read from sequence 0 for this reader only.
    /// - A cursor behind the retained window reports `missedPosts` and then resumes from
    ///   the oldest retained post. The gap is reported exactly once, because the cursor
    ///   moves past it.
    public mutating func read(reader: String, limit: Int? = nil, fromStart: Bool = false) throws
        -> WallReadResult
    {
        try requireIdentifier(reader)
        let before = fromStart ? 0 : (cursors[reader] ?? 0)
        let effectiveLimit = max(1, min(limit ?? limits.defaultReadLimit, limits.maxReadLimit))

        let candidates = posts.filter { $0.sequence > before }
        // Eviction gap: posts numbered (before+1) ..< (oldest retained) are gone forever.
        // Written to avoid `before + 1`, which overflows for a restored cursor of
        // UInt64.max — a value a corrupted or hostile position store can supply.
        var missed = 0
        if let oldest = posts.first?.sequence, oldest > before, oldest - before > 1 {
            missed = Int(min(oldest - before - 1, UInt64(Int.max)))
        }
        // (`posts.isEmpty && evictedCount > 0` is unreachable: eviction always retains at
        // least `maxRetainedPosts >= 1` posts, so an empty wall has never been posted to.)

        var returned: [WallPost] = []
        var budget = limits.maxReadBytes
        for post in candidates {
            if returned.count >= effectiveLimit { break }
            let cost = post.text.utf8.count
            // Always yield at least one post so a reader cannot wedge; a single post is
            // capped at maxPostBytes <= maxReadBytes, so this can never blow the budget.
            if !returned.isEmpty, cost > budget { break }
            returned.append(post)
            budget -= min(cost, budget)
        }

        // The cursor advances past the (unrecoverable) gap even when nothing is returned,
        // so a reader that missed everything is told once and then moves on.
        var after = before
        if let last = returned.last { after = max(after, last.sequence) }
        if missed > 0, returned.isEmpty, let oldest = posts.first?.sequence {
            after = max(after, oldest - 1)
        }
        cursors[reader] = after

        return WallReadResult(
            localTown: localTown, posts: returned, cursorBefore: before, cursorAfter: after,
            missedPosts: missed, unreadRemaining: candidates.count - returned.count)
    }
}
