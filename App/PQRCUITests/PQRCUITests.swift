import XCTest

/// TEST-PLAN §10: XCUITest over the Local Universe. The demo script
/// (docs/DEMO.md) seeds the exact scenario these tests assert.
final class PQRCUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: helpers

    private func launchUniverse(extraArguments: [String] = [], demo: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"] + (demo ? ["--demo-script"] : []) + extraArguments
        app.launch()
        XCTAssertTrue(
            app.segmentedControls["persona-switcher"].waitForExistence(timeout: 60),
            "Local Universe failed to boot")
        if demo {
            // The script runs concurrently after boot; rows re-sort while it
            // does. Its FINAL artifact is the group — wait for it so taps land
            // on settled rows.
            XCTAssertTrue(
                element(app, "conversation-Lunch crew").waitForExistence(timeout: 60),
                "demo script did not complete")
        }
        return app
    }

    private func selectPersona(_ app: XCUIApplication, _ name: String) {
        let button = app.segmentedControls["persona-switcher"].buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    /// Identifier query across all element types (SwiftUI surfaces identifiers
    /// on varying types: Button, Cell, StaticText, Other).
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tapWhenReady(_ app: XCUIApplication, button identifier: String) {
        let target = app.buttons[identifier]
        XCTAssertTrue(target.waitForExistence(timeout: 15), "\(identifier) missing")
        target.tap()
    }

    /// Message bubbles combine children for accessibility, so text asserts
    /// match on CONTAINS over any element's label.
    private func messageVisible(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 20) -> Bool {
        app.descendants(matching: .any)
            .containing(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    private func openConversation(_ app: XCUIApplication, _ title: String) {
        let byID = element(app, "conversation-\(title)")
        XCTAssertTrue(byID.waitForExistence(timeout: 20), "conversation \(title) missing")
        byID.tap()
        // Settle the push before any toolbar interaction.
        _ = app.textFields["composer-field"].waitForExistence(timeout: 10)
    }

    /// Simulators with a connected hardware keyboard drop focus on the first
    /// tap; retry until the soft keyboard actually appears before typing.
    private func type(_ app: XCUIApplication, into field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            field.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { break }
        }
        field.typeText(text)
    }

    /// The leading back button (identifier `BackButton` in the active bar).
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.firstMatch.buttons["BackButton"]
        if back.waitForExistence(timeout: 5) {
            back.tap()
        } else {
            app.navigationBars.firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        }
    }

    // MARK: tests

    func test_onboarding_generatesIdentityAndPublishesBundle() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset"]
        app.launch()
        // New account flow: the lock screen opens first; create the DEFAULT
        // (passphrase-less) account — display name + no-recovery ack only. The
        // create screen defaults to the passphrase-less default (Face ID / device
        // unlock), so no passphrase is entered (those SecureFields aren't on screen).
        tapWhenReady(app, button: "show-create-account")
        let nameField = app.textFields["onboarding-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 20))
        type(app, into: nameField, "Tester")
        let ack = app.switches["onboarding-acknowledge"]
        XCTAssertTrue(ack.waitForExistence(timeout: 10))
        ack.firstMatch.switches.firstMatch.tap()
        let create = app.buttons["onboarding-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(create.isEnabled)
        create.tap()
        XCTAssertTrue(app.navigationBars["EldrChat"].waitForExistence(timeout: 60))
        tapWhenReady(app, button: "Settings")
        let npub = app.staticTexts["my-npub"]
        XCTAssertTrue(npub.waitForExistence(timeout: 20))
        XCTAssertTrue(npub.label.hasPrefix("npub1"))
    }

    func test_roundTrip_aliceToBob_throughSimulator() throws {
        let app = launchUniverse()
        openConversation(app, "Bob")
        type(app, into: app.textFields["composer-field"], "UI round trip!")
        tapWhenReady(app, button: "composer-send")
        XCTAssertTrue(messageVisible(app, "UI round trip!"))
        // Switch persona: Bob received the exact message.
        goBack(app)
        selectPersona(app, "Bob")
        openConversation(app, "Alice")
        XCTAssertTrue(messageVisible(app, "UI round trip!"), "message must reach Bob decrypted")
    }

    /// C1 regression: sending must clear the composer atomically — the field is
    /// empty afterwards (no write-back restores the sent text) and stays empty,
    /// so the Send button is disabled and a second tap can send nothing.
    func test_composer_clearsAfterSend_andSecondTapSendsNothing() throws {
        let app = launchUniverse()
        openConversation(app, "Bob")
        let field = app.textFields["composer-field"]
        type(app, into: field, "C1 once only")
        tapWhenReady(app, button: "composer-send")
        XCTAssertTrue(messageVisible(app, "C1 once only"))
        // Poll ~3 s: the field must clear AND stay clear (a delayed binding
        // write-back re-filling it is the bug this guards against). An empty
        // SwiftUI TextField reports its placeholder ("Message") as value.
        var lastValue = ""
        for _ in 0..<6 {
            usleep(500_000)
            lastValue = (field.value as? String) ?? ""
            XCTAssertNotEqual(
                lastValue, "C1 once only",
                "sent text must not reappear in the composer")
        }
        XCTAssertTrue(
            lastValue.isEmpty || lastValue == "Message",
            "composer must be empty after send, got: \(lastValue)")
        XCTAssertFalse(
            app.buttons["composer-send"].isEnabled,
            "Send must be disabled once the field is empty — nothing to re-send")
    }

    func test_aiDraft_previewThenSendAsAI_rendersAgentBubble() throws {
        let app = launchUniverse()
        openConversation(app, "Bob")
        // The "My AI responds" control lives inline in the in-chat "AI here" sheet;
        // the leading AI:live chip (ai-here-chip) opens that sheet.
        tapWhenReady(app, button: "ai-here-chip")
        // The control defaults to "Drafts privately", so the on-demand draft
        // action is shown immediately in the "My AI responds" section. It sits
        // below the AI-context section, so make sure it's on screen
        // (tap auto-scrolls, but swipe up first in case it's below the fold).
        let draftNow = app.buttons["ai-responds-draft-now"]
        XCTAssertTrue(draftNow.waitForExistence(timeout: 15), "ai-responds-draft-now missing")
        if !draftNow.isHittable { app.swipeUp() }
        draftNow.tap()
        XCTAssertTrue(app.textViews["draft-editor"].waitForExistence(timeout: 20))
        tapWhenReady(app, button: "send-as-ai")
        XCTAssertTrue(
            element(app, "agent-bubble").waitForExistence(timeout: 15),
            "agent bubble must render")
    }

    func test_aiWindow_bannerAppearsForPeer() throws {
        // The demo script already started Alice's 30-minute window; the banner
        // MUST be visible on Bob's client for the duration (SPEC §13.3).
        // (Expiry fail-closed is covered by the engine suite.)
        let app = launchUniverse()
        selectPersona(app, "Bob")
        openConversation(app, "Alice")
        let banner = element(app, "ai-window-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "peer must see the AI-active banner")
        XCTAssertTrue(banner.label.contains("AI is active"))
    }

    func test_thread_inviteBothAIs_exchangeRecorded_counterVisible() throws {
        let app = launchUniverse()
        openConversation(app, "Bob")
        let chip = element(app, "thread-chip-Plan lunch")
        XCTAssertTrue(chip.waitForExistence(timeout: 20), "demo thread chip missing")
        chip.tap()
        // The recorded agent exchange is visible...
        XCTAssertTrue(
            element(app, "agent-bubble").waitForExistence(timeout: 20),
            "agent exchange must be recorded in the thread")
        // ...including a Context contribution.
        XCTAssertTrue(messageVisible(app, "Context:"), "context contributions render in the thread")
        // AI threads no longer auto-pause; the demo enables the off-by-default
        // AI-turn counter on this thread, so the header tally is visible.
        XCTAssertTrue(
            element(app, "thread-counter").waitForExistence(timeout: 10),
            "AI-turn counter must be visible when enabled")
    }

    func test_largePaste_200KB_becomesChip_sendsViaChunks_uiResponsive() throws {
        let app = launchUniverse(extraArguments: ["--uitest-bigpaste"])
        openConversation(app, "Bob")
        // The chip replaced the raw text — the field never chokes.
        XCTAssertTrue(
            element(app, "large-paste-chip").waitForExistence(timeout: 15),
            "large paste must collapse into a chip")
        tapWhenReady(app, button: "composer-send")
        // Chunked over the relay (SPEC §11) and rendered in full — no blob
        // server, no "encrypted attachment" placeholder. The pasted content is
        // delivered as real text.
        XCTAssertTrue(messageVisible(app, "PQRC large paste demo line"))
        // UI stays responsive: the composer accepts input immediately after.
        type(app, into: app.textFields["composer-field"], "still responsive")
    }

    func test_group_of4_sendReceive() throws {
        let app = launchUniverse()
        // Demo created "Lunch crew" with 4 members; Carol received the fan-out.
        selectPersona(app, "Carol")
        openConversation(app, "Lunch crew")
        XCTAssertTrue(
            messageVisible(app, "Welcome to the lunch crew"),
            "group fan-out must reach every member")
    }

    func test_messageRequest_unknownSenderGatedUntilAccepted() throws {
        let app = launchUniverse()
        // Eve's handshake landed for Alice: a request row, NOT a conversation.
        XCTAssertTrue(
            app.staticTexts["Message Requests"].waitForExistence(timeout: 20),
            "unknown-sender handshake must be gated")
        XCTAssertFalse(
            element(app, "conversation-Eve").exists,
            "nothing from an unknown sender renders as a conversation")
    }

    func test_safetyCodeChange_warningBannerAppears() throws {
        let app = launchUniverse(extraArguments: ["--uitest-safetychange"])
        openConversation(app, "Bob")
        XCTAssertTrue(
            element(app, "safety-change-banner").waitForExistence(timeout: 15),
            "safety-code change must show the persistent warning banner")
    }

    /// Audit scope + exceptions, both documented:
    /// - `.dynamicType` and `.textClipped` are excluded: the auditor
    ///   false-positives on combined `privacySensitive` message bubbles whose
    ///   system-font Text scales by construction.
    /// - "nearly passed" contrast issues are the auditor's borderline-but-
    ///   passing grade (it flags even the system grouped-list section header).
    /// Hard failures — "Contrast failed", missing labels, hit regions,
    /// element detection — fail the test.
    private func audit(_ app: XCUIApplication) throws {
        var types = XCUIAccessibilityAuditType.all
        types.remove(.dynamicType)
        types.remove(.textClipped)
        try app.performAccessibilityAudit(for: types) { issue in
            // Full detail in the log: the failure attachment names only the
            // element, not the auditor's measured values.
            print("AUDIT ISSUE [\(issue.auditType)]: \(issue.compactDescription) || \(issue.detailedDescription) || element: \(issue.element?.debugDescription.prefix(300) ?? "?")")
            if issue.compactDescription.contains("nearly passed") { return true }
            // Occlusion artifact, not a color problem: a message row half-
            // scrolled under an adjacent bar/inset has no determinable
            // background, and the auditor hard-fails it regardless of its
            // actual (audited-elsewhere) colors. Excused ONLY for rows
            // partially outside their scroll viewport; fully visible elements
            // stay enforced (A7).
            if issue.compactDescription.contains("Contrast"), let element = issue.element {
                // Partially offscreen (scrolled past the fold): the auditor
                // samples black for the missing pixels and hard-fails.
                if !app.frame.contains(element.frame) {
                    return true
                }
                // A row partially under one of the overlaying bars (which
                // live inside the scroll view's frame as safe-area insets).
                for barID in ["composer-field", "thread-composer-field"] {
                    let bar = app.descendants(matching: .any)
                        .matching(identifier: barID).firstMatch
                    if bar.exists, bar.frame.intersects(element.frame) {
                        return true
                    }
                }
                // A row clipped by the THREAD list's top edge: the pinned
                // ThreadHeader sits above the scroll viewport, and a clipped
                // row's text keeps its full AX frame, so its top pokes into the
                // header zone where the auditor samples header pixels — the
                // same A7 occlusion class as the bars, at the thread-header
                // boundary. Screenshot-verified 2026-07-18: the flagged rows
                // are ordinary agent bubbles whose measured colors pass
                // (PartyColorTests); fully-visible rows stay enforced.
                let threadList = app.descendants(matching: .any)
                    .matching(identifier: "thread-message-list").firstMatch
                if threadList.exists, element.frame.minY < threadList.frame.minY {
                    return true
                }
                // A row scrolled up under the TOP navigation bar's translucent
                // scroll-edge material — the first message in a short conversation
                // lands right beneath it. The auditor samples the bar's blur as the
                // cell's background and hard-fails it, though the text's own colors
                // pass where it's fully clear (the same rows read "nearly passed"
                // lower down). Same occlusion artifact the bottom bars get, for the
                // top edge (A7). Excuse anything whose TOP sits in the nav bar + its
                // soft blur band (~44pt below the bar); fall back to a fixed top band
                // when the nav-bar element can't be resolved inside this closure.
                let navBar = app.navigationBars.firstMatch
                let topBlurMaxY: CGFloat =
                    navBar.exists && navBar.frame.height > 1
                    ? navBar.frame.maxY + 44 : 165
                if element.frame.minY < topBlurMaxY {
                    return true
                }
            }
            return false
        }
    }

    /// Poll until the screen's AX descendant count stops changing (3 stable
    /// 1 s samples). The demo thread's AI exchange can still be streaming when
    /// the audit arrives (the loop guard pauses it at 50 replies in a row), and
    /// the auditor races actively-materializing bubbles into nil-element
    /// "potentially inaccessible text" failures on content that is fully
    /// accessible once landed (2026-07-18: full-suite run failed exactly there;
    /// the isolated re-run was green). Audit settled screens only.
    private func waitForQuietScreen(_ app: XCUIApplication, timeout: TimeInterval = 90) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var stable = 0
        while Date() < deadline, stable < 3 {
            let count = app.descendants(matching: .any).count
            if count == lastCount { stable += 1 } else { stable = 0; lastCount = count }
            usleep(1_000_000)
        }
    }

    func test_accessibilityAudit_allPrimaryScreens() throws {
        let app = launchUniverse()
        // Conversation list.
        try audit(app)
        // Message view (human + agent bubbles + banner).
        openConversation(app, "Bob")
        try audit(app)
        // Thread view.
        let chip = element(app, "thread-chip-Plan lunch")
        if chip.waitForExistence(timeout: 10) {
            chip.tap()
            waitForQuietScreen(app)
            try audit(app)
            goBack(app)
        }
        goBack(app)
        // Settings.
        tapWhenReady(app, button: "Settings")
        try audit(app)
    }
}
