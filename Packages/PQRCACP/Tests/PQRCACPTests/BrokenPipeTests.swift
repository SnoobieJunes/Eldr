// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

/// Regression: a client that closes our pipes (cancelled run, dead launcher, Huginn
/// relaunch mid-turn) must produce a quiet wind-down, NEVER a process abort. The
/// legacy `FileHandle.write(_:)` raised an uncatchable `NSFileHandleOperationException`
/// on EPIPE — `signal(SIGPIPE, SIG_IGN)` doesn't help, Foundation converts the errno
/// into an ObjC exception — which killed `eldr-acp` exactly as seen in the field:
/// once from the response write after `handle(line:)`, once from a mid-turn
/// `session/update` notify inside `runTurn`.
@Suite("Broken pipe survival")
struct BrokenPipeTests {

    /// The crash itself: writing to a pipe whose read end is gone. With the old
    /// sink this test run ABORTS (uncatchable ObjC exception); passing at all is
    /// the assertion. The second write checks the closed latch stays a no-op.
    @Test func sinkSurvivesClosedPipe() async {
        signal(SIGPIPE, SIG_IGN)  // mirror eldr-acp main.swift — EPIPE, not signal death
        let pipe = Pipe()
        let sink = FileHandleOutputSink(pipe.fileHandleForWriting)
        try? pipe.fileHandleForReading.close()

        await sink.write(line: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)  // hits EPIPE
        await sink.write(line: "dropped by the latch, still no crash")

        // Reaching this line IS the regression proof (old code never returns).
        try? pipe.fileHandleForWriting.close()
    }

    private actor NullSink: OutputSink {
        func write(line: String) async {}
    }

    /// A sink that signals once the request envelope was handed to it — by then the
    /// connection has parked the request's continuation, so the test can `failAll`
    /// deterministically against a genuinely pending wait (no sleeps).
    private actor SignallingSink: OutputSink {
        private var written: CheckedContinuation<Void, Never>?
        private var didWrite = false
        func write(line: String) async {
            didWrite = true
            written?.resume()
            written = nil
        }
        func awaitFirstWrite() async {
            if didWrite { return }
            await withCheckedContinuation { written = $0 }
        }
    }

    /// EOF mid-permission: the pending un-timed request (`ELDR_ACP_PERMISSION_TIMEOUT=0`)
    /// must resume with `failAll`'s error instead of parking its turn forever.
    @Test func failAllResumesPendingUntimedRequest() async throws {
        let sink = SignallingSink()
        let connection = ClientConnection(sink: sink)

        let waiter = Task<ClientConnection.ConnectionError?, Never> {
            do {
                _ = try await connection.request(
                    method: "session/request_permission", params: .object([:]), timeout: nil)
                return nil
            } catch {
                return error as? ClientConnection.ConnectionError
            }
        }
        await sink.awaitFirstWrite()  // continuation is parked now
        await connection.failAll(ClientConnection.ConnectionError.cancelled)
        #expect(await waiter.value == .cancelled)
    }

    /// The latch: once `failAll` ran (client gone / stdin EOF), a LATER request must
    /// fail immediately — not park a continuation no response can ever resume.
    @Test func requestAfterFailAllThrowsImmediately() async {
        let connection = ClientConnection(sink: NullSink())
        await connection.failAll(ClientConnection.ConnectionError.cancelled)

        await #expect(throws: ClientConnection.ConnectionError.cancelled) {
            _ = try await connection.request(
                method: "session/request_permission", params: .object([:]), timeout: nil)
        }
    }
}
