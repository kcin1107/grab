import XCTest

@MainActor
final class ToolbarLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(width: Int) -> XCUIApplication {
        let app = XCUIApplication()
        // A DEBUG-only argument in the app sets the width of its window.
        app.launchArguments += ["-GrabUITestWindowWidth", "\(width)"]
        app.launch()
        app.activate()
        return app
    }

    private func check(width: Int, minimumFraction: Double, minimumWidth: Double) {
        let app = launch(width: width)
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "No window at \(width) pt")

        // The app resizes its window just after launch, and the toolbar then rebuilds the input
        // row: wait for the new width before looking at the toolbar, so the query sees the new row.
        let resized = expectation(for: NSPredicate { _, _ in abs(window.frame.width - Double(width)) < 2 },
                                  evaluatedWith: nil)
        wait(for: [resized], timeout: 10)
        Thread.sleep(forTimeInterval: 0.5)

        let field = window.textFields["linkField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Link field is missing at \(width) pt")
        XCTAssertTrue(field.isHittable, "Link field isn't hittable at \(width) pt")

        let windowWidth = window.frame.width
        XCTAssertEqual(windowWidth, Double(width), accuracy: 2, "The window wasn't resized")
        XCTAssertGreaterThanOrEqual(field.frame.width, max(minimumWidth, windowWidth * minimumFraction),
                                    "Link field is \(field.frame.width) pt wide in a \(windowWidth) pt window")
        XCTAssertTrue(app.buttons["submitButton"].exists, "Submit button missing at \(width) pt")
        saveScreenshot(of: window, name: "toolbar-\(width)")
    }

    /// Keeps what the active window looks like in the test results, for checking the design by eye
    /// (export with `xcrun xcresulttool export attachments`).
    private func saveScreenshot(of window: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNarrowWindow() { check(width: 640, minimumFraction: 0, minimumWidth: 200) }
    func testMediumWindow() { check(width: 900, minimumFraction: 0.45, minimumWidth: 0) }
    func testWideWindow() { check(width: 1600, minimumFraction: 0.45, minimumWidth: 0) }
}
