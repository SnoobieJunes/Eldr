// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing

@testable import Huginn

// WS-B3: `ConnectionStatusProbe` used to treat ANY `URLError` other than the three
// most obvious "refused" codes as proof the peer was up — including `.timedOut`-
// adjacent conditions and genuine network failures (DNS, offline, cancelled). These
// tests exercise the extracted, pure `classify(_:notListening:)` directly (no socket,
// no real timeout) so the fix — and the false-positive class it closes — stays
// covered headlessly.
@Suite("WS-B3: ConnectionStatusProbe URLError classification")
struct ConnectionStatusProbeClassificationTests {

    @Test func timeoutIsDown() {
        let result = ConnectionStatusProbe.classify(.timedOut, notListening: "Nothing listening on :18789")
        #expect(result == .down("Nothing listening on :18789 (timed out)"))
    }

    @Test func connectionRefusedIsDown() {
        let result = ConnectionStatusProbe.classify(.cannotConnectToHost, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func dnsLookupFailureIsDown() {
        // The prior `default: .up` misclassified this — a DNS failure never proves a
        // peer answered.
        let result = ConnectionStatusProbe.classify(.dnsLookupFailed, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func notConnectedToInternetIsDown() {
        let result = ConnectionStatusProbe.classify(.notConnectedToInternet, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func resourceUnavailableIsDown() {
        let result = ConnectionStatusProbe.classify(.resourceUnavailable, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func cancelledIsDown() {
        let result = ConnectionStatusProbe.classify(.cancelled, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func unknownCodeIsDown() {
        // Fail toward "down" on anything not explicitly recognized as proof of life.
        let result = ConnectionStatusProbe.classify(.unknown, notListening: "x")
        #expect(result == .down("x"))
    }

    @Test func malformedOrNonHTTPReplyStillCountsAsUp() {
        // A reset / non-HTTP reply, or a TLS handshake that got far enough to fail on
        // the certificate, proves SOMETHING answered the connection — the one class of
        // URLError that legitimately still means "up".
        #expect(ConnectionStatusProbe.classify(.cannotParseResponse, notListening: "x") == .up)
        #expect(ConnectionStatusProbe.classify(.badServerResponse, notListening: "x") == .up)
        #expect(ConnectionStatusProbe.classify(.secureConnectionFailed, notListening: "x") == .up)
        #expect(ConnectionStatusProbe.classify(.serverCertificateUntrusted, notListening: "x") == .up)
    }
}

// WS-B3: the installed-CLI staleness check compares the installed binary's mtime to
// the newest Packages/PQRCACP/Sources file mtime. The comparison itself is pure —
// tested directly with synthetic dates rather than the real checkout, so it isn't
// sensitive to when this machine last built/installed the binary.
@Suite("WS-B3: installed-CLI staleness comparison")
struct InstallerServiceStalenessTests {
    @Test func olderInstalledBinaryIsStale() {
        let installed = Date(timeIntervalSince1970: 1000)
        let newestSource = Date(timeIntervalSince1970: 2000)
        #expect(InstallerService.isStale(installedDate: installed, newestSourceDate: newestSource))
    }

    @Test func newerInstalledBinaryIsNotStale() {
        let installed = Date(timeIntervalSince1970: 2000)
        let newestSource = Date(timeIntervalSince1970: 1000)
        #expect(!InstallerService.isStale(installedDate: installed, newestSourceDate: newestSource))
    }

    @Test func equalTimestampsAreNotStale() {
        let same = Date(timeIntervalSince1970: 1000)
        #expect(!InstallerService.isStale(installedDate: same, newestSourceDate: same))
    }
}
