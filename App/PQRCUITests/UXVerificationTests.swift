import XCTest

/// On-device runtime verification of the 5 findings in docs/UX-RECOMMENDATIONS.md.
/// These DRIVE the real app (taps, sheets, typing) and attach screenshots as
/// evidence — they assert the usability ISSUE actually manifests, not a fix.
/// Temporary: delete after the review is acted on.
final class UXVerificationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    // MARK: helpers (mirrors PQRCUITests.swift)

    private func launchUniverse(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.segmentedControls["persona-switcher"].waitForExistence(timeout: 60),
            "Local Universe failed to boot")
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func openConversation(_ app: XCUIApplication, _ title: String) {
        let row = element(app, "conversation-\(title)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "conversation \(title) missing")
        row.tap()
        _ = app.textFields["composer-field"].waitForExistence(timeout: 10)
    }

    private func type(_ app: XCUIApplication, into field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { break }
        }
        field.typeText(text)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        // Full-screen capture so system overlays (toolbar overflow menus,
        // popovers) are included — app.screenshot() omits them.
        let s = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        s.name = name
        s.lifetime = .keepAlways
        add(s)
    }

    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let t = XCTAttachment(string: app.debugDescription)
        t.name = name
        t.lifetime = .keepAlways
        add(t)
    }

    private func messageVisible(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    // MARK: Rec 1 — three overlapping AI controls (chip, sparkles button, Details)

    /// Tap a toolbar item that may be hidden behind the "More" overflow on
    /// compact widths. Looks up by accessibility identifier first, then label.
    /// Returns true once the item was tapped.
    @discardableResult
    private func tapToolbar(_ app: XCUIApplication, id: String? = nil, label: String,
                            screenshotTag: String? = nil) -> Bool {
        // Already directly on the bar?
        if let id, element(app, id).waitForExistence(timeout: 2), element(app, id).isHittable {
            element(app, id).tap(); return true
        }
        let direct = app.buttons[label]
        if direct.waitForExistence(timeout: 1), direct.isHittable { direct.tap(); return true }
        // Open the overflow menu.
        let more = app.buttons["OverflowBarButtonItem"]
        guard more.waitForExistence(timeout: 3) else { return false }
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        _ = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", label)).firstMatch.waitForExistence(timeout: 3)
        if let tag = screenshotTag {
            shot(app, tag)
            dumpTree(app, tag + "-tree")
        }
        var candidates: [XCUIElement] = []
        if let id { candidates.append(element(app, id)) }
        candidates += [app.menuItems[label], app.buttons[label],
                       app.collectionViews.buttons[label],
                       app.descendants(matching: .any).matching(
                        NSPredicate(format: "label == %@", label)).firstMatch]
        for q in candidates where q.waitForExistence(timeout: 2) {
            if q.isHittable { q.tap(); return true }
        }
        return false
    }

    func test_rec1_aiControlsOverlap() throws {
        let app = launchUniverse()
        openConversation(app, "Bob")

        // The leading AI chip is one affordance...
        let chip = element(app, "ai-here-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "leading AI chip missing")
        // The redundant SECOND AI entry point (the sparkles 'My AI' toolbar button)
        // has been REMOVED — the leading AI:live chip is now the single in-chat AI
        // control, so the toolbar no longer overflows from AI-button crowding.
        XCTAssertFalse(app.buttons["ai-window-button"].exists,
                       "the redundant 'My AI' sparkles button should be removed")
        shot(app, "rec1-01-single-ai-chip")

        // The CHIP opens the "AI here" sheet (context picker + My-AI-responds).
        chip.tap()
        XCTAssertTrue(app.navigationBars["AI here"].waitForExistence(timeout: 10),
                      "chip should open the 'AI here' sheet")
        XCTAssertTrue(element(app, "conversation-ai-mode").exists, "sheet has the AI-context picker")
        XCTAssertTrue(element(app, "ai-responds-mode").exists, "sheet has the My-AI-responds picker")
        shot(app, "rec1-02-chip-opens-AIHereSheet")
        app.buttons["Done"].firstMatch.tap()

        // Still the single AI entry point after rotating to landscape (no duplicate).
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(element(app, "ai-here-chip").waitForExistence(timeout: 10),
                      "the AI:live chip remains the single AI entry point in landscape")
        XCTAssertFalse(app.buttons["ai-window-button"].exists,
                       "no duplicate AI button in landscape either")
        shot(app, "rec1-03-single-ai-control-landscape")

        // Details hosts a THIRD copy of the same per-conversation AI-context control.
        let info = app.buttons["Conversation details"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "info button missing")
        info.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10),
                      "info button opens Details")
        // The Form lazily renders rows; scroll the AI picker into view. In
        // landscape the sheet is an inset card, so swipe its scroll container,
        // not the whole app.
        let scroller: XCUIElement = {
            for c in [app.scrollViews.firstMatch, app.collectionViews.firstMatch,
                      app.tables.firstMatch] where c.exists { return c }
            return app
        }()
        let aiMode = element(app, "conversation-ai-mode")
        var tries = 0
        while !aiMode.exists && tries < 8 {
            scroller.swipeUp(velocity: .fast); tries += 1
        }
        XCTAssertTrue(aiMode.exists,
                      "Details ALSO has the same 'AI context here' picker (3rd surface)")
        XCTAssertTrue(element(app, "conversation-firewall-mode").exists,
                      "Details also has the per-conversation egress-firewall override")
        shot(app, "rec1-04-Details-has-same-control")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(overflowed && sparklesHiddenInPortrait,
                      "documented: trailing toolbar overflowed on iPhone portrait — the sparkles 'My AI' button is pushed into the 'More' menu")
    }

    // MARK: Rec 4 — large-paste chip: non-interactive + typed text dropped on send

    func test_rec4_largePasteChip() throws {
        let app = launchUniverse(extraArguments: ["--uitest-bigpaste"])
        openConversation(app, "Bob")

        let chip = element(app, "large-paste-chip")
        XCTAssertTrue(chip.waitForExistence(timeout: 15), "large paste must collapse into a chip")
        // The ONLY action on the chip is discard — no view/edit affordance.
        XCTAssertTrue(app.buttons["Remove large text attachment"].exists,
                      "chip exposes a remove (discard) button")
        shot(app, "rec4-01-chip-only-discard")

        // Type a note alongside the paste, then send.
        type(app, into: app.textFields["composer-field"], "TYPEDNOTE12345")
        shot(app, "rec4-02-typed-note-with-chip-present")
        app.buttons["composer-send"].firstMatch.tap()

        // The paste is sent...
        XCTAssertTrue(messageVisible(app, "PQRC large paste demo line"),
                      "the pasted content is what actually sends")
        // ...but the typed note is SILENTLY DROPPED (largePaste ?? draftText).
        XCTAssertFalse(messageVisible(app, "TYPEDNOTE12345", timeout: 4),
                       "typed note is discarded when a large paste is present — silent data loss")
        shot(app, "rec4-03-typed-note-dropped")
    }

    // MARK: Rec 5 — irreversible hidden account accepts a 1-character passphrase

    func test_rec5_weakPassphraseAccepted() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset"]
        app.launch()

        app.buttons["show-create-account"].firstMatch.tap()
        let name = app.textFields["onboarding-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        type(app, into: name, "Tester")

        // Switch to the HIDDEN (passphrase-gated, NO RECOVERY) account path.
        let usePass = element(app, "onboarding-use-passphrase")
        XCTAssertTrue(usePass.waitForExistence(timeout: 10))
        usePass.switches.firstMatch.tap()

        // A single-character passphrase.
        type(app, into: app.secureTextFields["passphrase-field"], "a")
        type(app, into: app.secureTextFields["passphrase-confirm"], "a")
        let ack = element(app, "onboarding-acknowledge")
        XCTAssertTrue(ack.waitForExistence(timeout: 10))
        ack.switches.firstMatch.tap()

        let create = app.buttons["onboarding-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        shot(app, "rec5-01-create-form-no-strength-meter")
        // The gate ENABLES creation of a permanently-unrecoverable account
        // protected by one character — no strength floor, no guidance.
        XCTAssertTrue(create.isEnabled,
                      "create is enabled with a 1-char passphrase — no strength gate")
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'strength' OR label CONTAINS[c] 'weak' OR label CONTAINS[c] 'too short'"))
            .firstMatch.exists,
            "no strength/weakness indicator is shown")
    }
}
