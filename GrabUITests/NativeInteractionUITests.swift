import AppKit
import XCTest

@MainActor
final class NativeInteractionUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Save every representation, including copied files, rather than just the clipboard string.
    private func withClipboard(_ text: String, perform action: () -> Void) {
        let clipboard = NSPasteboard.general
        let saved = (clipboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        defer {
            clipboard.clearContents()
            let items = saved.map { representations in
                let item = NSPasteboardItem()
                for (type, data) in representations { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { clipboard.writeObjects(items) }
        }
        action()
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-autoUpdate", "NO", "-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    func testPasteButtonStagesQuery() throws {
        let app = launch()
        defer { app.terminate() }
        let window = app.windows["Grab"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.activate()
        let paste = window.buttons["pasteButton"]
        // An existing download history replaces the empty state. Keep that history intact.
        try XCTSkipUnless(paste.waitForExistence(timeout: 3), "The empty-state Paste button requires an empty queue")
        let field = window.searchFields.firstMatch
        withClipboard("ambient piano music") {
            paste.click()
            let populated = expectation(for: NSPredicate { _, _ in
                field.value as? String == "ambient piano music"
            }, evaluatedWith: nil)
            wait(for: [populated], timeout: 5)
            app.typeKey(.rightArrow, modifierFlags: [])
            app.typeText("!")
            XCTAssertEqual(field.value as? String, "ambient piano music!")
            XCTAssertTrue(paste.exists, "Paste should leave the empty queue in place")
            XCTAssertEqual(window.buttons["submitButton"].title, "Search")
        }
    }

    func testPasteOutsideFieldStagesLinkAndQuery() {
        let app = launch()
        defer { app.terminate() }
        let window = app.windows["Grab"]
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        app.activate()
        let field = window.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        func rowCount() -> Int {
            window.descendants(matching: .tableRow).count + window.descendants(matching: .outlineRow).count
        }
        let initialRows = rowCount()
        for text in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "ambient piano music"] {
            // Clicking the window's content leaves the input field, just as selecting the list does.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).click()
            let beforeTyping = field.value as? String
            app.typeText("x")
            XCTAssertEqual(field.value as? String, beforeTyping, "The test must exercise paste outside the link field")
            withClipboard(text) {
                app.typeKey("v", modifierFlags: .command)
                let populated = expectation(for: NSPredicate { _, _ in field.value as? String == text },
                                            evaluatedWith: nil)
                wait(for: [populated], timeout: 5)
                app.typeKey(.rightArrow, modifierFlags: [])
                app.typeText("!")
                XCTAssertEqual(field.value as? String, text + "!", "Paste should focus the input")
                XCTAssertEqual(rowCount(), initialRows, "Paste must not enqueue a download")
            }
        }
    }
}
