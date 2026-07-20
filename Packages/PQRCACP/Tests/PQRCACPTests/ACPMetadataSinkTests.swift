// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCACP

/// B2: proves the at-rest metadata SINKS (`events.jsonl` lines and the whole-file
/// `eldr.md`) are sealed when a key is present and fall back to cleartext — never crashing
/// or leaking — when it's absent. The framing is the ONE `ACPMetadataCrypto` both processes
/// (the agent that writes and Huginn's ContextLearner that reads) call, so it can't drift.
@Suite("ACP metadata sinks (events.jsonl / eldr.md at rest)")
struct ACPMetadataSinkTests {

    private func key(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }

    /// A fresh temp dir removed at the end of the test.
    private func withTempDir(_ body: (String) throws -> Void) rethrows {
        let dir = NSTemporaryDirectory() + "acp-metadata-sink-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try body(dir)
    }

    private func firstLine(ofFile path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return String(raw.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
    }

    // MARK: (a) events.jsonl — LINE-level sealing

    @Test func eventsLineSealedWithAKeyRoundTripsViaOpenLine() throws {
        try withTempDir { dir in
            let k = key(0x5A)
            let path = (dir as NSString).appendingPathComponent("events.jsonl")
            ACPEventLog.writeFile(
                path: "/proj/Sources/Foo.swift", session: "s1", cwd: "/proj",
                to: path, key: k)

            let line = try firstLine(ofFile: path)
            // Sealed → base64: a plaintext JSON line would start with `{`, this can't.
            #expect(!line.hasPrefix("{"))
            #expect(!line.contains("Foo.swift"))  // the path isn't on disk in the clear
            // A reader WITH the key recovers the JSON line.
            let opened = try #require(ACPMetadataCrypto.openLine(line, key: k))
            #expect(opened.hasPrefix("{"))
            #expect(opened.contains("write_file"))
            #expect(opened.contains("Foo.swift"))
        }
    }

    @Test func plaintextEventsLineIsDistinguishableFromSealed() throws {
        try withTempDir { dir in
            // No key ⇒ the line is written in cleartext (today's behavior).
            let path = (dir as NSString).appendingPathComponent("events.jsonl")
            ACPEventLog.shellResult(
                cmd: "swift build", exit: 0, summary: "ok", session: "s1", cwd: "/proj",
                to: path)  // key defaults to nil
            let line = try firstLine(ofFile: path)
            #expect(line.hasPrefix("{"))  // plaintext JSON
            // A keyed reader tries openLine; a legacy plaintext line isn't valid sealed
            // base64, so openLine returns nil and the reader KEEPS the raw line (`?? line`).
            #expect(ACPMetadataCrypto.openLine(line, key: key(0x22)) == nil)
        }
    }

    @Test func sealedEventsLineOpenedWithoutOrWrongKeyIsSkipped() throws {
        try withTempDir { dir in
            let k = key(0x33)
            let path = (dir as NSString).appendingPathComponent("events.jsonl")
            ACPEventLog.sessionEnd(
                cwd: "/proj", session: "s1", summary: "done", files: 2, build: "green",
                to: path, key: k)
            let line = try firstLine(ofFile: path)
            // WRONG key ⇒ nil (no leak, the line is skipped).
            #expect(ACPMetadataCrypto.openLine(line, key: key(0x99)) == nil)
            // NO key ⇒ the keyless reader never calls openLine; the raw base64 line is not
            // valid JSON, so it's skipped rather than mis-ingested.
            #expect(JSONValue.parse(line) == nil)
        }
    }

    // MARK: (b) eldr.md — WHOLE-file sealing with a magic header

    @Test func eldrMdSealForDiskRoundTrips() throws {
        let k = key(0x11)
        let md = "# eldr.md\n\n## Session History\n- built the thing\n\n## LLM Corrections\n- prefer edit_file"
        let sealed = try #require(ProjectContext.sealForDisk(md, key: k))
        // On-disk form starts with the ASCII magic header and hides the plaintext.
        #expect(sealed.starts(with: Data(ProjectContext.sealedHeader.utf8)))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Session History"))
        // A reader WITH the key recovers the exact markdown.
        #expect(ProjectContext.openFromDisk(sealed, key: k) == md)
    }

    @Test func legacyPlaintextEldrMdReturnedUnchangedWithAnyOrNoKey() {
        // A file WITHOUT the header is legacy plaintext markdown — used as today, and its
        // content is preserved regardless of whether a key is available.
        let md = "# eldr.md\n## Session History\n- legacy content"
        let legacy = Data(md.utf8)
        #expect(ProjectContext.openFromDisk(legacy, key: key(0x44)) == md)
        #expect(ProjectContext.openFromDisk(legacy, key: nil) == md)
    }

    @Test func sealedEldrMdWithoutOrWrongKeyIsSkippedNotGarbage() throws {
        let k = key(0x55)
        let md = "# eldr.md\nsecret project notes"
        let sealed = try #require(ProjectContext.sealForDisk(md, key: k))
        // No key ⇒ nil (SKIP — never render ciphertext as text).
        #expect(ProjectContext.openFromDisk(sealed, key: nil) == nil)
        // Wrong key ⇒ nil (no leak).
        #expect(ProjectContext.openFromDisk(sealed, key: key(0x56)) == nil)
    }

    @Test func readFileHandlesSealedAndLegacyEldrMd() throws {
        try withTempDir { dir in
            let k = key(0x77)
            let md = "# eldr.md\n## Session History\n- a session"

            // Sealed file: readable WITH the key, SKIPPED (nil) without it.
            let sealedPath = (dir as NSString).appendingPathComponent("sealed.md")
            let sealed = try #require(ProjectContext.sealForDisk(md, key: k))
            try sealed.write(to: URL(fileURLWithPath: sealedPath))
            #expect(ProjectContext.readFile(sealedPath, maxBytes: 4096, key: k) == md)
            #expect(ProjectContext.readFile(sealedPath, maxBytes: 4096, key: nil) == nil)

            // Legacy plaintext file: read as today with any/no key.
            let legacyPath = (dir as NSString).appendingPathComponent("legacy.md")
            try Data(md.utf8).write(to: URL(fileURLWithPath: legacyPath))
            #expect(ProjectContext.readFile(legacyPath, maxBytes: 4096, key: k) == md)
            #expect(ProjectContext.readFile(legacyPath, maxBytes: 4096, key: nil) == md)
        }
    }

    // MARK: (c) AgentConfig.fromEnvironment metadata-key parsing

    @Test func fromEnvironmentParsesA32ByteMetadataKey() {
        let raw = Data((0..<32).map { UInt8($0) })
        let cfg = AgentConfig.fromEnvironment(
            ["ELDR_ACP_METADATA_KEY": raw.base64EncodedString()], configDir: nil)
        #expect(cfg.metadataKey == raw)
    }

    @Test func fromEnvironmentRejectsNon32ByteMetadataKey() {
        // 16 bytes (valid base64, wrong length) ⇒ nil.
        let short = Data(repeating: 0x42, count: 16).base64EncodedString()
        #expect(AgentConfig.fromEnvironment(["ELDR_ACP_METADATA_KEY": short], configDir: nil).metadataKey == nil)
        // Not base64 ⇒ nil.
        #expect(AgentConfig.fromEnvironment(["ELDR_ACP_METADATA_KEY": "%%% not base64 %%%"], configDir: nil).metadataKey == nil)
        // Absent ⇒ nil (cleartext fallback).
        #expect(AgentConfig.fromEnvironment([:], configDir: nil).metadataKey == nil)
    }
}
