import XCTest

/// The input bar (link field, format menu, Download) must fill the window at every width, also when the
/// window is resized while Grab runs.
@MainActor
final class InputBarLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func check(width: Int, minimumFraction: Double, minimumWidth: Double) {
        let app = XCUIApplication()
        // A debug-only launch argument makes Grab resize its window just after launch.
        app.launchArguments += ["-GrabUITestWindowWidth", "\(width)"]
        app.launch()
        app.activate()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "No window at \(width) pt")

        // Wait for the resize to land before checking the layout.
        let resized = expectation(for: NSPredicate { _, _ in abs(window.frame.width - Double(width)) < 2 },
                                  evaluatedWith: nil)
        wait(for: [resized], timeout: 10)

        let field = window.textFields["linkField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Link field is missing at \(width) pt")
        XCTAssertTrue(field.isHittable, "Link field isn't hittable at \(width) pt")
        XCTAssertGreaterThanOrEqual(field.frame.width, max(minimumWidth, window.frame.width * minimumFraction),
                                    "Link field is \(field.frame.width) pt wide in a \(window.frame.width) pt window")
        XCTAssertTrue(window.buttons["submitButton"].isHittable, "Download isn't visible at \(width) pt")
    }

    // Widths that fit on a laptop screen: a window wider than its screen puts Download off-screen.
    func testNarrowWindow() { check(width: 640, minimumFraction: 0, minimumWidth: 200) }
    func testMediumWindow() { check(width: 900, minimumFraction: 0.45, minimumWidth: 0) }
    func testWideWindow() { check(width: 1400, minimumFraction: 0.45, minimumWidth: 0) }
}
