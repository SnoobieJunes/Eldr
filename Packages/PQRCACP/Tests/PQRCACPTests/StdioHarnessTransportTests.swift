#if os(macOS)
import Foundation
import Testing

@testable import PQRCACP

// macOS-only: prove the `StdioHarnessTransport` SPAWN mechanism and the `runHarness` factory's
// `.stdioSpawn` dispatch — WITHOUT a real external ACP binary. The mechanism (spawn the
// descriptor's command, map child stdout → `inboundLines()`, `send(_:)` → child stdin,
// `close()` terminates, child-exit/broken-pipe finish the stream cleanly) is identical
// whether the child is a real harness or a stub system binary, so a tiny shell echo-loop
// stands in for the harness. This is the seam Phase-2 integrations will exercise with a real
// tool; here we only prove the plumbing.

@Suite("StdioHarnessTransport spawn mechanism + runHarness stdio dispatch (macOS)")
struct StdioHarnessTransportTests {

    /// A descriptor that spawns a per-line echo loop with AUTOFLUSH (`$|=1`): read a line on
    /// stdin, print it on stdout, flushing each line so it arrives on `inboundLines()`
    /// immediately (a shell `printf` loop block-buffers a pipe and would never deliver until
    /// EOF — `perl`'s autoflush avoids that). Stands in for "a process whose stdout feeds
    /// `inboundLines()` and whose stdin is `send`." Not provisional — `/usr/bin/perl` ships on
    /// macOS; this is a deterministic local stub, not a real ACP binary.
    private func echoDescriptor() -> HarnessDescriptor {
        HarnessDescriptor(
            id: "stub-echo",
            displayName: "Stub Echo",
            kind: .stdioSpawn,
            command: "/usr/bin/perl",
            args: ["-e", "$|=1; while (my $line = <STDIN>) { print $line }"])
    }

    /// Read the next non-empty line from a transport's inbound stream, bounded so a missing
    /// echo fails the test rather than hanging the suite.
    private func nextLine(
        _ transport: any ACPTransport, timeout seconds: Double = 5
    ) async throws -> String {
        try await withTimeout(seconds) {
            for await line in transport.inboundLines() where !line.isEmpty { return line }
            throw StubError.streamEnded
        }
    }

    enum StubError: Error { case streamEnded }

    // 1 ─ stdout → inboundLines() AND send() → stdin. Spawn the echo loop; a line we `send`
    // must come back on `inboundLines()` — proving both pipe directions of the transport.
    @Test func sendReachesStdinAndStdoutBecomesInbound() async throws {
        try await withTimeout(15) {
            let transport = StdioHarnessTransport(descriptor: echoDescriptor())
            try transport.start()
            defer { transport.close() }

            transport.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
            let echoed = try await nextLine(transport)
            #expect(echoed == #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)

            // A second line proves the child stays attached, not one-shot.
            transport.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
            let echoed2 = try await nextLine(transport)
            #expect(echoed2 == #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        }
    }

    // 2 ─ Child exit finishes inboundLines() cleanly (no crash, no hang). `/usr/bin/true`
    // exits immediately and closes its stdout; the inbound stream MUST finish.
    @Test func childExitFinishesInboundStream() async throws {
        try await withTimeout(15) {
            let transport = StdioHarnessTransport(
                descriptor: HarnessDescriptor(
                    id: "stub-true", displayName: "true", kind: .stdioSpawn,
                    command: "/usr/bin/true"))
            try transport.start()
            defer { transport.close() }

            // The stream finishes (loop exits) because the child exited — not a timeout.
            let finished = Task {
                for await _ in transport.inboundLines() {}
                return true
            }
            #expect(await finished.value == true)
        }
    }

    // 3 ─ close() terminates the child and finishes the stream even for a long-lived process.
    // The echo loop would run forever; close() must end it.
    @Test func closeTerminatesChildAndFinishesStream() async throws {
        try await withTimeout(15) {
            let transport = StdioHarnessTransport(descriptor: echoDescriptor())
            try transport.start()

            let finished = Task {
                for await _ in transport.inboundLines() {}
                return true
            }
            transport.close()
            #expect(await finished.value == true)
        }
    }

    // 4 ─ A broken pipe (writing after the child exited) is swallowed, never a crash. Spawn
    // `true` (exits at once), wait for the inbound stream to finish, THEN send — the write to
    // the dead child's stdin must not crash the process.
    @Test func sendAfterChildExitIsSwallowed() async throws {
        try await withTimeout(15) {
            let transport = StdioHarnessTransport(
                descriptor: HarnessDescriptor(
                    id: "stub-true", displayName: "true", kind: .stdioSpawn,
                    command: "/usr/bin/true"))
            try transport.start()
            defer { transport.close() }
            for await _ in transport.inboundLines() {}  // wait until the child is gone
            transport.send("late line after exit")  // must not crash
            #expect(Bool(true))
        }
    }

    // 5 ─ Wrong kind: starting a `.builtIn` descriptor as a stdio transport throws (built-in
    // goes through runACPAgent, not a spawn).
    @Test func startingBuiltInDescriptorThrows() {
        let transport = StdioHarnessTransport(descriptor: .builtIn)
        #expect(throws: StdioHarnessTransport.SpawnError.notStdioSpawn) {
            try transport.start()
        }
    }

    // 6 ─ runHarness `.stdioSpawn` dispatch end-to-end: a real `ACPClient` drives the echo stub
    // THROUGH runHarness (which spawns the StdioHarnessTransport and runACPProxy internally).
    // The stub isn't a real ACP agent, so `start()` won't complete a handshake — instead prove
    // the proxy wired stdin↔stdout by sending a raw line on the phone transport and seeing the
    // stub echo it back through the proxy to the phone. This is the single seam the node calls.
    @Test func runHarnessStdioSpawnPipesThroughTheEchoStub() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let runTask = Task {
                await runHarness(
                    descriptor: echoDescriptor(), client: clientSide, llm: EchoLLMClient())
            }
            defer { runTask.cancel() }

            phone.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
            // The stub echoes it; runHarness's internal proxy forwards it back to the phone.
            let echoed = try await withTimeout(5) { () -> String in
                for await line in phone.inboundLines() where !line.isEmpty { return line }
                throw StubError.streamEnded
            }
            #expect(echoed == #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)

            // Closing the phone side tears down the proxy + child (runHarness returns).
            phone.close()
            await runTask.value
        }
    }

    // 7 ─ runHarness `.stdioSpawn` launch failure closes the client cleanly (no hang). A
    // descriptor pointing at a non-existent absolute path can't spawn; the phone's inbound must
    // FINISH (client closed) rather than wedge.
    @Test func runHarnessClosesClientWhenSpawnFails() async throws {
        try await withTimeout(15) {
            let (phone, clientSide) = InMemoryACPTransport.makePair()
            let bogus = HarnessDescriptor(
                id: "bogus", displayName: "bogus", kind: .stdioSpawn,
                command: "/nonexistent/path/to/no/such/harness-binary")
            let runTask = Task {
                await runHarness(descriptor: bogus, client: clientSide, llm: EchoLLMClient())
            }
            defer { runTask.cancel() }

            // Client side closed by runHarness ⇒ the phone's inbound finishes.
            let finished = Task {
                for await _ in phone.inboundLines() {}
                return true
            }
            #expect(await finished.value == true)
            await runTask.value  // runHarness returned after the failed launch
        }
    }
}
#endif  // os(macOS)
