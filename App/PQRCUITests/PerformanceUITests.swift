// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

/// TEST-PLAN §11: launch + scroll performance. Baseline-relative on CI;
/// absolute budgets are soft on simulators.
final class PerformanceUITests: XCTestCase {
    /// Budget: cold launch → list interactive < 800 ms (device-honest numbers
    /// come from hardware runs; the simulator number is baseline-relative).
    func test_launchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--reset"]
            app.launch()
        }
    }

    /// Budget: 10k-message scroll hitch ratio < 5 ms/s; memory < 250 MB.
    func test_scroll10kMessages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--demo-script", "--uitest-10k"]
        app.launch()
        XCTAssertTrue(app.segmentedControls["persona-switcher"].waitForExistence(timeout: 60))
        // The 10k seed targets the Bob conversation; open exactly that row.
        let row = app.descendants(matching: .any).matching(identifier: "conversation-Bob").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        let list = app.scrollViews["message-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20))

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollDecelerationMetric,
                XCTMemoryMetric(application: app),
            ],
            options: options
        ) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
    }
}
