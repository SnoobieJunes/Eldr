import Foundation
import Testing

@testable import PQRCACP

@Suite("ProjectMemoryDoc")
struct ProjectMemoryDocTests {

    @Test func roundTripsThroughMarkdown() {
        var doc = ProjectMemoryDoc()
        doc.addSession("2026-06-16: built the login screen (files: 3, build: green)")
        doc.addCorrection("Command failed (exit 1): swift build — missing import")
        let reparsed = ProjectMemoryDoc(parsing: doc.serialized())
        #expect(reparsed == doc)
        #expect(reparsed.sessionHistory.count == 1)
        #expect(reparsed.corrections.count == 1)
    }

    @Test func parsesBothSectionsAndIgnoresProse() {
        let text = """
            # eldr.md

            Some hand-written intro that isn't a bullet.

            ## Session History
            - first session
            - second session

            ## LLM Corrections
            - do not use force-unwrap here
            """
        let doc = ProjectMemoryDoc(parsing: text)
        #expect(doc.sessionHistory == ["first session", "second session"])
        #expect(doc.corrections == ["do not use force-unwrap here"])
    }

    @Test func sessionHistoryPrunesToMostRecent() {
        var doc = ProjectMemoryDoc()
        for i in 1...15 { doc.addSession("session \(i)", keepRecent: 10) }
        #expect(doc.sessionHistory.count == 10)
        #expect(doc.sessionHistory.first == "session 6")  // oldest pruned
        #expect(doc.sessionHistory.last == "session 15")
    }

    @Test func correctionDeduplicatesRecentRepeats() {
        var doc = ProjectMemoryDoc()
        doc.addCorrection("same note")
        doc.addCorrection("same note")
        doc.addCorrection("same note")
        #expect(doc.corrections == ["same note"])
    }

    @Test func capDropsHistoryBeforeCorrections() {
        var doc = ProjectMemoryDoc()
        // Many sessions + a few durable corrections.
        for i in 1...40 { doc.addSession("session entry number \(i) with some descriptive text", keepRecent: 100) }
        doc.addCorrection("KEEP-THIS-CORRECTION-1")
        doc.addCorrection("KEEP-THIS-CORRECTION-2")
        let before = doc.serialized().utf8.count
        #expect(before > 512)

        doc.cap(toBytes: 512)
        #expect(doc.serialized().utf8.count <= 512)
        // Corrections survive; history is sacrificed first.
        #expect(doc.corrections.contains("KEEP-THIS-CORRECTION-2"))
        #expect(doc.sessionHistory.count < 40)
    }

    @Test func emptyDocStillSerializesBothHeaders() {
        let doc = ProjectMemoryDoc()
        let text = doc.serialized()
        #expect(text.contains(ProjectMemoryDoc.historyHeader))
        #expect(text.contains(ProjectMemoryDoc.correctionsHeader))
        #expect(doc.isEmpty)
        // And an empty doc round-trips to empty.
        #expect(ProjectMemoryDoc(parsing: text) == doc)
    }
}
