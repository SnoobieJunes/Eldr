// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCMCP

/// The wall model, proven without a network and without a clock: every timestamp here is
/// a literal, and every ordering assertion is about the sequence counter, never time.
@Suite("Town wall")
struct TownWallTests {
    private func wall(
        localTown: String = "home-town", retained: Int = 512, postBytes: Int = 4096,
        readBytes: Int = 64 * 1024, defaultLimit: Int = 50
    ) -> TownWall {
        TownWall(
            localTown: localTown,
            limits: .init(
                maxRetainedPosts: retained, maxPostBytes: postBytes, maxReadBytes: readBytes,
                defaultReadLimit: defaultLimit))
    }

    private func author(_ agent: String, town: String = "home-town") -> WallAuthor {
        WallAuthor(town: town, agent: agent)
    }

    @discardableResult
    private func post(_ w: inout TownWall, _ text: String, at time: Int64 = 1_781_500_000) throws
        -> WallPost
    { try w.append(text: text, author: author("orchestrator"), at: time) }

    // MARK: - Append + ordering

    @Test func appendsAreOrderedBySequenceNotTime() throws {
        var w = wall()
        // Timestamps deliberately out of order: ordering must ignore them entirely.
        try w.append(text: "first", author: author("a"), at: 9_000)
        try w.append(text: "second", author: author("b"), at: 1)
        try w.append(text: "third", author: author("c"), at: 5_000)
        #expect(w.posts.map(\.sequence) == [1, 2, 3])
        #expect(w.posts.map(\.text) == ["first", "second", "third"])
    }

    @Test func postsAreNeverMutated() throws {
        var w = wall()
        let original = try post(&w, "immutable")
        try post(&w, "another")
        #expect(w.posts.first == original)
    }

    @Test func emptyAndWhitespaceOnlyPostsAreRefused() throws {
        var w = wall()
        #expect(throws: TownWallError.emptyText) { try post(&w, "") }
        #expect(throws: TownWallError.emptyText) { try post(&w, "   \n\t  ") }
        #expect(w.posts.isEmpty)
    }

    @Test func postAtTheSizeCapIsAcceptedAndOneByteOverIsRefused() throws {
        var w = wall(postBytes: 32)
        let exact = String(repeating: "a", count: 32)
        try post(&w, exact)
        #expect(w.posts.count == 1)
        #expect(throws: TownWallError.textTooLarge(bytes: 33, limit: 32)) {
            try post(&w, exact + "a")
        }
        // Bytes, not characters: one emoji is 4 UTF-8 bytes, so 8 of them is the cap and
        // 9 is over. A character-counted limit is a 4x DoS underestimate.
        var w2 = wall(postBytes: 32)
        try post(&w2, String(repeating: "🪿", count: 8))
        #expect(throws: TownWallError.textTooLarge(bytes: 36, limit: 32)) {
            try post(&w2, String(repeating: "🪿", count: 9))
        }
    }

    @Test func invalidIdentifiersAreRefused() throws {
        var w = wall()
        #expect(throws: TownWallError.invalidIdentifier("../hack")) {
            try w.append(text: "x", author: author("../hack"), at: 1)
        }
        #expect(throws: TownWallError.invalidIdentifier("a|b")) {
            try w.append(text: "x", author: author("ok", town: "a|b"), at: 1)
        }
        #expect(throws: TownWallError.invalidIdentifier("bad target")) {
            try w.append(
                text: "x", author: author("ok"), explicitTargets: ["bad target"], at: 1)
        }
        // A newline in an id would let the renderer's header line be forged; refused here
        // and (independently) neutralized at render time.
        #expect(throws: TownWallError.invalidIdentifier("a\nb")) {
            try w.append(text: "x", author: author("a\nb"), at: 1)
        }
        #expect(w.posts.isEmpty)
    }

    // MARK: - Cursors (gtwall's defining feature)

    @Test func eachReaderHasItsOwnPosition() throws {
        var w = wall()
        try post(&w, "one")
        try post(&w, "two")

        let alice = try w.read(reader: "alice")
        #expect(alice.posts.map(\.text) == ["one", "two"])
        #expect(alice.cursorBefore == 0)
        #expect(alice.cursorAfter == 2)

        // Bob has never read: he sees everything, independently of Alice.
        let bob = try w.read(reader: "bob")
        #expect(bob.posts.map(\.text) == ["one", "two"])

        // Alice re-reads: nothing new.
        let again = try w.read(reader: "alice")
        #expect(again.posts.isEmpty)
        #expect(again.cursorAfter == 2)
    }

    @Test func interleavedReadersEachSeeExactlyWhatTheyMissed() throws {
        var w = wall()
        try post(&w, "p1")
        _ = try w.read(reader: "alice")  // alice → 1
        try post(&w, "p2")
        _ = try w.read(reader: "bob")  // bob → 2 (sees p1+p2)
        try post(&w, "p3")

        #expect(try w.read(reader: "alice").posts.map(\.text) == ["p2", "p3"])
        #expect(try w.read(reader: "bob").posts.map(\.text) == ["p3"])
        #expect(try w.read(reader: "carol").posts.map(\.text) == ["p1", "p2", "p3"])
    }

    @Test func cursorAdvancementIsExplicitAndNeverSkipsUnreturnedPosts() throws {
        var w = wall()
        for i in 1...5 { try post(&w, "p\(i)") }
        let first = try w.read(reader: "alice", limit: 2)
        #expect(first.posts.map(\.text) == ["p1", "p2"])
        #expect(first.cursorAfter == 2)
        #expect(first.unreadRemaining == 3)
        // gtwall would have jumped the position to the end of the file here and lost
        // p3–p5 silently. The remainder must still be waiting.
        let second = try w.read(reader: "alice", limit: 2)
        #expect(second.posts.map(\.text) == ["p3", "p4"])
        #expect(try w.read(reader: "alice").posts.map(\.text) == ["p5"])
    }

    @Test func rereadingFromASavedCursorIsDeterministic() throws {
        func build() throws -> TownWall {
            var w = wall()
            for i in 1...4 { try post(&w, "p\(i)", at: Int64(1_000 + i)) }
            return w
        }
        var a = try build()
        var b = try build()
        let ra = try a.read(reader: "r", limit: 3)
        let rb = try b.read(reader: "r", limit: 3)
        #expect(ra == rb)
        #expect(try a.read(reader: "r") == b.read(reader: "r"))
        // And a reader's saved position is observable without mutating it.
        #expect(a.cursor(for: "r") == 4)
        #expect(a.cursor(for: "never-read") == 0)
        #expect(a.cursor(for: "bad id") == nil)
    }

    @Test func fromStartReplaysForThatReaderOnly() throws {
        var w = wall()
        try post(&w, "p1")
        try post(&w, "p2")
        _ = try w.read(reader: "alice")
        _ = try w.read(reader: "bob")
        let replay = try w.read(reader: "alice", fromStart: true)
        #expect(replay.posts.map(\.text) == ["p1", "p2"])
        #expect(replay.cursorBefore == 0)
        // Bob is untouched by Alice's reset.
        #expect(try w.read(reader: "bob").posts.isEmpty)
    }

    @Test func unknownReaderStartsAtZero() throws {
        var w = wall()
        try post(&w, "hello")
        let result = try w.read(reader: "brand-new-delegate")
        #expect(result.cursorBefore == 0)
        #expect(result.posts.count == 1)
        #expect(result.missedPosts == 0)
    }

    @Test func invalidReaderIdIsRefusedAndAdvancesNothing() throws {
        var w = wall()
        try post(&w, "hello")
        #expect(throws: TownWallError.invalidIdentifier("../../etc/passwd")) {
            try w.read(reader: "../../etc/passwd")
        }
        #expect(throws: TownWallError.invalidIdentifier("")) { try w.read(reader: "") }
        // The valid reader still sees the post — a refused read changed no state.
        #expect(try w.read(reader: "alice").posts.count == 1)
    }

    @Test func cursorFromTheFutureIsInertNotFatal() throws {
        // The shape a restored position takes after the wall was rebuilt smaller —
        // gtwall's truncation case, where its line-number cursor points past EOF and it
        // then silently rewinds and replays. Here: return nothing, keep the value, no
        // gap, no crash, and above all no replay.
        var w = wall()
        for i in 1...3 { try post(&w, "p\(i)") }
        try w.restoreCursor(reader: "alice", to: 9_999)
        let a = try w.read(reader: "alice")
        #expect(a.posts.isEmpty)
        #expect(a.cursorBefore == 9_999 && a.cursorAfter == 9_999)
        #expect(a.missedPosts == 0)
        #expect(a.unreadRemaining == 0)
        // UInt64.max must not overflow the gap arithmetic either.
        try w.restoreCursor(reader: "bob", to: UInt64.max)
        #expect(try w.read(reader: "bob").posts.isEmpty)
        // New posts after a future cursor stay invisible to it — inert, not corrupting.
        try post(&w, "p4")
        #expect(try w.read(reader: "alice").posts.isEmpty)
        #expect(try w.read(reader: "carol").posts.count == 4)
    }

    @Test func restoredCursorsNeverMoveBackward() throws {
        var w = wall()
        for i in 1...3 { try post(&w, "p\(i)") }
        _ = try w.read(reader: "alice")  // alice → 3
        try w.restoreCursor(reader: "alice", to: 1)  // a stale persisted value
        #expect(w.cursor(for: "alice") == 3)
        #expect(try w.read(reader: "alice").posts.isEmpty)
        #expect(throws: TownWallError.invalidIdentifier("bad id")) {
            try w.restoreCursor(reader: "bad id", to: 1)
        }
    }

    @Test func tooManyTargetsIsRefusedRatherThanTruncated() throws {
        var w = TownWall(localTown: "t", limits: .init(maxTargets: 3))
        #expect(throws: TownWallError.tooManyTargets(count: 5, limit: 3)) {
            try w.append(
                text: "@d @e", author: author("x"), explicitTargets: ["a", "b", "c"], at: 1)
        }
        #expect(w.posts.isEmpty)
    }

    @Test func emptyWallReadsCleanly() throws {
        var w = wall()
        let result = try w.read(reader: "alice")
        #expect(result.posts.isEmpty)
        #expect(result.cursorBefore == 0 && result.cursorAfter == 0)
        #expect(result.missedPosts == 0 && result.unreadRemaining == 0)
    }

    // MARK: - Bounds + eviction

    @Test func wallIsBoundedAndEvictsOldestFirst() throws {
        var w = wall(retained: 3)
        for i in 1...6 { try post(&w, "p\(i)") }
        #expect(w.posts.count == 3)
        #expect(w.posts.map(\.text) == ["p4", "p5", "p6"])
        #expect(w.evictedCount == 3)
        // Sequences are NOT renumbered by eviction — that is what keeps cursors valid.
        #expect(w.posts.map(\.sequence) == [4, 5, 6])
        #expect(w.highestSequence == 6)
    }

    @Test func evictionPastACursorProducesACountedGapNotASilentSkip() throws {
        var w = wall(retained: 3)
        try post(&w, "p1")
        _ = try w.read(reader: "alice")  // alice → 1
        for i in 2...7 { try post(&w, "p\(i)") }  // retains p5,p6,p7; p2–p4 evicted

        let result = try w.read(reader: "alice")
        #expect(result.missedPosts == 3)  // p2, p3, p4 — gone forever, and said so
        #expect(result.posts.map(\.text) == ["p5", "p6", "p7"])
        #expect(result.cursorAfter == 7)
        // The gap is reported ONCE; the cursor moved past it.
        #expect(try w.read(reader: "alice").missedPosts == 0)
    }

    @Test func aReaderWhoseEntireBacklogWasEvictedIsToldOnceAndMovesOn() throws {
        var w = wall(retained: 2)
        try post(&w, "p1")
        _ = try w.read(reader: "alice")  // alice → 1
        for i in 2...9 { try post(&w, "p\(i)") }  // retains p8, p9

        let first = try w.read(reader: "alice")
        #expect(first.missedPosts == 6)  // p2..p7
        #expect(first.posts.map(\.text) == ["p8", "p9"])
        let second = try w.read(reader: "alice")
        #expect(second.missedPosts == 0 && second.posts.isEmpty)
    }

    @Test func readIsByteBoundedAndAlwaysMakesProgress() throws {
        // Budget fits two 10-byte posts, not three.
        var w = wall(postBytes: 16, readBytes: 25)
        for i in 1...4 { try post(&w, String(repeating: "\(i)", count: 10)) }
        let first = try w.read(reader: "alice", limit: 100)
        #expect(first.posts.count == 2)
        #expect(first.unreadRemaining == 2)
        #expect(try w.read(reader: "alice", limit: 100).posts.count == 2)

        // Even a single post larger than the whole budget is returned rather than
        // wedging the reader forever (maxReadBytes is floored at maxPostBytes).
        var w2 = TownWall(
            localTown: "t", limits: .init(maxPostBytes: 64, maxReadBytes: 1))
        try w2.append(text: String(repeating: "x", count: 64), author: author("a"), at: 1)
        #expect(try w2.read(reader: "alice").posts.count == 1)
    }

    @Test func aSinglePostIsBoundedBelowTheInlineCeiling_neverInlinedOversize() throws {
        // Invariant 4 (WS-G5): a wall post is never transported inline above the relay
        // ceiling. The wall REFUSES an oversize post rather than truncating it (truncation
        // would sever attacker text mid-escape and hide the boundary). Proven at a wall
        // configured with maxPostBytes == the 64 KiB inline ceiling: exactly-at is fine,
        // one over is refused. Bigger-than-ceiling bodies ride WallChunking instead.
        let ceiling = 64 * 1024
        var w = TownWall(localTown: "t", limits: .init(maxPostBytes: ceiling, maxReadBytes: ceiling))
        try w.append(text: String(repeating: "a", count: ceiling), author: author("a"), at: 1)
        #expect(w.posts.count == 1)
        #expect(throws: TownWallError.textTooLarge(bytes: ceiling + 1, limit: ceiling)) {
            try w.append(text: String(repeating: "a", count: ceiling + 1), author: author("a"), at: 2)
        }
        #expect(w.posts.count == 1)  // the oversize post left no trace
    }

    @Test func readLimitIsClampedToTheConfiguredCeiling() throws {
        var w = wall(retained: 400)
        for i in 1...300 { try post(&w, "p\(i)") }
        #expect(try w.read(reader: "a", limit: 100_000).posts.count == 200)  // maxReadLimit
        #expect(try w.read(reader: "b", limit: 0).posts.count == 1)  // floored at 1
        #expect(try w.read(reader: "c", limit: -5).posts.count == 1)
    }

    @Test func targetsAreBounded() throws {
        var w = TownWall(localTown: "t", limits: .init(maxTargets: 3))
        let post = try w.append(
            text: "@a @b @c @d @e", author: author("x"), at: 1)
        #expect(post.targets == ["a", "b", "c"])
    }

    // MARK: - @name targeting

    @Test func mentionParsingHandlesTheEdgeCases() {
        func parse(_ s: String) -> [String] { WallMentions.parse(s, limit: 32) }
        #expect(parse("@alice please review") == ["alice"])
        #expect(parse("ping @worker-auth and @reviewer_1!") == ["worker-auth", "reviewer_1"])
        // A bare @ is not a mention.
        #expect(parse("@") == [])
        #expect(parse("email me @ noon") == [])
        // Mid-word @ is not a mention — this is what keeps addresses out.
        #expect(parse("foo@bar") == [])
        #expect(parse("me@example.com") == [])
        #expect(parse("first.last@example.com") == [])
        #expect(parse("user+tag@example.com") == [])
        // Punctuation-adjacent still resolves.
        #expect(parse("(@bob), @carol. @dave; @eve:") == ["bob", "carol", "dave", "eve"])
        #expect(parse("@bob's patch") == ["bob"])
        // Duplicates collapse, first-occurrence order preserved.
        #expect(parse("@bob @alice @bob @BOB") == ["bob", "alice"])
        // Trailing separators trimmed away.
        #expect(parse("@bob-- @carol__") == ["bob", "carol"])
        // @@ yields nothing: the first @ has an empty name, the second is suppressed.
        #expect(parse("@@bob") == [])
        // Non-ASCII names are not recognized at all.
        #expect(parse("@Ω @日本") == [])
        #expect(parse("@🪿") == [])
        // Newlines are ordinary boundaries.
        #expect(parse("line one\n@bob line two") == ["bob"])
        // A domain-looking mention resolves to the first label; documented behavior.
        #expect(parse("@example.com") == ["example"])
    }

    @Test func explicitTargetsUnionWithParsedMentionsWithoutDuplicates() throws {
        var w = wall()
        let post = try w.append(
            text: "heads up @bob", author: author("x"), explicitTargets: ["carol", "BOB"], at: 1)
        #expect(post.targets == ["carol", "bob"])
    }

    @Test func mentionsInAnEvilPostCannotEscapeTheTargetCharset() throws {
        var w = wall()
        // Every one of these is either not a mention or a charset-clean name.
        // `@../hack` yields nothing (the name run is empty), `@c|d` stops at the pipe,
        // and `@e===` stops at the `=` — no target can carry a structural character.
        let post = try w.append(
            text: "@a\nb @c|d @../hack @e=== END", author: author("x"), at: 1)
        #expect(post.targets == ["a", "c", "e"])
        for target in post.targets {
            #expect(TownWall.isValidIdentifier(target, max: 64))
        }
    }
}
