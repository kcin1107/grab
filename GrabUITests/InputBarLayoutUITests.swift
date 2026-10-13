import XCTest

/// The native toolbar search field keeps a substantial share of the window alongside Format and Download,
/// also when the window is resized while Grab runs.
@MainActor
final class InputBarLayoutUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// isHittable also depends on whether macOS has made the test window active.
    private func assertVisible(_ element: XCUIElement, in window: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Toolbar control is missing: \(element.debugDescription)")
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.frame.minX)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.frame.maxX)
    }

    private func check(width: Int, minimumFraction: Double, minimumWidth: Double) {
        let app = XCUIApplication()
        // A debug-only launch argument makes Grab resize its window just after launch.
        app.launchArguments += ["-GrabUITestWindowWidth", "\(width)"]
        app.launch()
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "No window at \(width) pt")

        // Wait for the resize to land before checking the layout.
        let resized = expectation(for: NSPredicate { _, _ in abs(window.frame.width - Double(width)) < 2 },
                                  evaluatedWith: nil)
        wait(for: [resized], timeout: 10)
        app.activate()

        let toolbar = window.toolbars.firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 10), "No toolbar at \(width) pt")
        let field = toolbar.searchFields.firstMatch
        assertVisible(field, in: window)
        XCTAssertGreaterThanOrEqual(field.frame.width, max(minimumWidth, window.frame.width * minimumFraction),
                                    "Link field is \(field.frame.width) pt wide in a \(window.frame.width) pt window")
        let formatMenu = toolbar.descendants(matching: .any)["formatMenu"]
        assertVisible(formatMenu, in: window)
        assertVisible(toolbar.buttons["submitButton"], in: window)
    }

    // Widths that fit on a laptop screen: a window wider than its screen puts Download off-screen.
    func testNarrowWindow() { check(width: 720, minimumFraction: 0, minimumWidth: 200) }
    func testStandardWindow() { check(width: 820, minimumFraction: 0.40, minimumWidth: 0) }
    func testMediumWindow() { check(width: 900, minimumFraction: 0.40, minimumWidth: 0) }
    func testWideWindow() { check(width: 1400, minimumFraction: 0.40, minimumWidth: 0) }

    func testMinimumWindowWidthKeepsToolbarVisible() {
        let app = XCUIApplication()
        app.launchArguments += ["-GrabUITestWindowWidth", "640"]
        app.launch()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let clamped = expectation(for: NSPredicate { _, _ in abs(window.frame.width - 720) < 2 },
                                  evaluatedWith: nil)
        wait(for: [clamped], timeout: 10)
        app.activate()
        let toolbar = window.toolbars.firstMatch
        assertVisible(toolbar.searchFields.firstMatch, in: window)
        assertVisible(toolbar.descendants(matching: .any)["formatMenu"], in: window)
        assertVisible(toolbar.buttons["submitButton"], in: window)
    }
}
