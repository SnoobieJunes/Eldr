// SPDX-License-Identifier: Apache-2.0
#if !canImport(os)
import Foundation
import Testing

@testable import PQRCAgent

/// Invariant 12 on Linux: the OSLog shim must redact every interpolation that is not
/// explicitly `.public`, so payload plaintext can never reach stderr/journald.
@Suite("Linux log canary (OSLog shim)")
struct LinuxLogCanaryTests {
    @Test func privateAndDefaultInterpolations_areRedacted() {
        let canary = "CANARY-plaintext-7f3a"
        let m1: PQRCLogMessage = "msg \(canary)"
        let m2: PQRCLogMessage = "msg \(canary, privacy: .private)"
        let m3: PQRCLogMessage = "thread \("t1", privacy: .public)"
        #expect(!m1.rendered.contains(canary))
        #expect(!m2.rendered.contains(canary))
        #expect(m1.rendered == "msg <private>")
        #expect(m3.rendered == "thread t1")
    }
}
#endif
