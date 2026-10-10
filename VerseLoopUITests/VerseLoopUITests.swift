import XCTest

/// End-to-end proof of the core workflow on iPhone SE (3rd gen):
/// Loop -> first-letter review -> peek -> Oops undo -> grade -> undo-grade.
/// Screenshots are written straight to the repo's recordings/ folder
/// (XCUITest runs on the host Mac, so direct file writes work).
final class VerseLoopUITests: XCTestCase {
    let shots = URL(fileURLWithPath: "/Users/paulshippy/Dev/verseloop-ios/recordings")

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
    }

    func snap(_ app: XCUIApplication, _ name: String) {
        let png = app.screenshot().pngRepresentation
        try? png.write(to: shots.appendingPathComponent("\(name).png"))
        XCTAttachment(screenshot: app.screenshot()).lifetime = .keepAlways
    }

    func testLoopFlow() throws {
        let app = XCUIApplication(bundleIdentifier: "com.tpaulshippy.verseloop")
        app.launch()

        // 1. Loop tab with seeded demo verses
        XCTAssertTrue(app.staticTexts["Today's Loop"].waitForExistence(timeout: 15))
        snap(app, "01-loop")

        // 2. Open the first verse -> first-letter grid
        app.staticTexts["Psalm 23:1 (demo · KJV)"].tap()
        XCTAssertTrue(app.staticTexts["How well did you recall it?"].waitForExistence(timeout: 10))
        snap(app, "02-review-first-letters")

        // 3. Peek two words
        app.buttons["Hidden word starting with T"].tap()
        app.buttons["Hidden word starting with L"].tap()
        snap(app, "03-review-peeked")

        // 4. Oops undoes the last tap (back to 1 peeked)
        app.buttons["Oops · undo tap"].tap()
        XCTAssertTrue(app.staticTexts["· 1 peeked"].waitForExistence(timeout: 5))

        // 5. Mark taps accidental, grade Good
        app.switches.firstMatch.tap()
        app.buttons["Good"].tap()
        XCTAssertTrue(app.buttons["Undo grade (8s)"].waitForExistence(timeout: 5))
        snap(app, "04-graded")

        // 6. Undo the grade, re-grade, advance
        app.buttons["Undo grade (8s)"].tap()
        XCTAssertTrue(app.buttons["Good"].waitForExistence(timeout: 5))
        app.buttons["Good"].tap()
        app.buttons["Next →"].tap()

        // 7. Settings tab (ESV key, Worker sync, export)
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        snap(app, "05-settings")

        // 8. Verses tab + Add sheet
        app.tabBars.buttons["Verses"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Add verse"].waitForExistence(timeout: 10))
        snap(app, "06-add-verse")
        app.buttons["Cancel"].tap()
    }
}
