import XCTest

/// End-to-end proof of the type-to-recall workflow on iPhone SE (3rd gen).
/// Launch 1 verifies real list navigation (Loop -> tap verse -> tester).
/// Launch 2 (-UITestReview hook) drives the deterministic typing pass:
/// wrong letter buzzes + mistake count -> per-word accidental forgiveness
/// -> finish -> grade -> undo-grade.
/// Launch 3 captures Settings + Add verse.
/// Screenshots are written straight to the repo's recordings/ folder
/// (XCUITest runs on the host Mac, so direct file writes work).
final class VerseLoopUITests: XCTestCase {
    let shots = URL(fileURLWithPath: "/Users/paulshippy/Dev/verseloop-ios/recordings")
    let bundleID = "com.tpaulshippy.verseloop"

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
        // ---- Launch 1: real navigation Loop -> Review ----
        var app = XCUIApplication(bundleIdentifier: bundleID)
        app.launch()
        XCTAssertTrue(app.staticTexts["Today's Loop"].waitForExistence(timeout: 15))
        snap(app, "01-loop")
        let verseCell = app.staticTexts["Psalm 23:1 (demo · KJV)"]
        XCTAssertTrue(verseCell.waitForExistence(timeout: 10))
        verseCell.tap()
        let fieldProbe = app.textFields["first-letter-input"]
        XCTAssertTrue(fieldProbe.waitForExistence(timeout: 10))
        app.terminate()

        // ---- Launch 2: deterministic typing pass ----
        app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = ["-UITestReview"]
        app.launch()
        let field = app.textFields["first-letter-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()

        // Wrong first letter for "The" -> buzz + mistake count
        field.typeText("X")
        XCTAssertTrue(app.staticTexts["· 1 mistake"].waitForExistence(timeout: 5))
        snap(app, "02-review-mistake")

        // Forgive that exact mistake -> count back to zero
        app.buttons["Mark accidental: The"].tap()
        XCTAssertTrue(app.staticTexts["· 0 mistakes"].waitForExistence(timeout: 5))
        snap(app, "03-review-forgiven")

        // Type the rest correctly (LORD is my shepherd; I shall not want)
        field.tap()
        field.typeText("limsisnw")
        XCTAssertTrue(app.staticTexts["Suggested: Easy — but your grade decides, as always."].waitForExistence(timeout: 10))

        // Grade, undo the grade, re-grade, advance
        app.buttons["Good"].tap()
        XCTAssertTrue(app.buttons["Undo grade (8s)"].waitForExistence(timeout: 5))
        snap(app, "04-graded")
        app.buttons["Undo grade (8s)"].tap()
        XCTAssertTrue(app.buttons["Good"].waitForExistence(timeout: 5))
        app.buttons["Good"].tap()
        app.buttons["Next →"].tap()
        app.terminate()

        // ---- Launch 3: Settings + Add verse ----
        app = XCUIApplication(bundleIdentifier: bundleID)
        app.launchArguments = []
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        snap(app, "05-settings")
        app.tabBars.buttons["Verses"].tap()
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Add verse"].waitForExistence(timeout: 10))
        snap(app, "06-add-verse")
        app.buttons["Cancel"].tap()
    }
}
