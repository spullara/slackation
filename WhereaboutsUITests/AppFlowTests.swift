import XCTest

final class AppFlowTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testSaveValidationAndPersistence() {
        app.tabBars.buttons["Geofences"].tap()
        app.buttons["Add geofence"].tap()
        XCTAssertTrue(app.textFields["placeName"].waitForExistence(timeout: 5))
        app.maps.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap()
        app.swipeUp()
        let status = app.textFields["statusText"]
        status.tap()
        status.typeText("At work")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Enter a name to save this geofence."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.swipeDown()
        let name = app.textFields["placeName"]
        name.tap()
        name.typeText("Save reproduction")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].tap()
        let row = app.buttons.containing(.staticText, identifier: "Save reproduction").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.tabBars.buttons["Geofences"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let editName = app.textFields["placeName"]
        editName.tap()
        editName.typeText(" edited")
        app.buttons["Save"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Geofences"].tap()
        let edited = app.buttons.containing(.staticText, identifier: "Save reproduction edited").firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        edited.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(edited.exists)
    }

    func testScreensAndPlaceEditing() {
        app.tabBars.buttons["Destinations"].tap()
        XCTAssertTrue(app.switches["Send status"].exists)
        capture("destinations")
        let enabled = app.switches["Send status"]
        if enabled.value as? String == "0" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(enabled.value as? String, "1")
        app.buttons["Slack"].tap()
        XCTAssertTrue(app.secureTextFields["Paste token"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Test and save"].isEnabled)
        capture("slack-setup")
        app.tabBars.buttons["Geofences"].tap()
        addPlace(name: "Office", status: "At work")
        addPlace(name: "Cafe", status: "Coffee break")
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Office").firstMatch.exists)
        capture("geofence-list")
        app.buttons.containing(.staticText, identifier: "Cafe").firstMatch.tap()
        XCTAssertTrue(app.textFields["placeName"].waitForExistence(timeout: 5))
        capture("geofence-editor")
        app.buttons["Cancel"].tap()
        addPlace(name: "Temporary test place", status: "Test")
        let temporary = app.buttons.containing(.staticText, identifier: "Temporary test place").firstMatch
        temporary.tap()
        let name = app.textFields["placeName"]
        name.tap()
        name.typeText(" edited")
        app.buttons["Save"].tap()
        let edited = app.buttons.containing(.staticText, identifier: "Temporary test place edited").firstMatch
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        edited.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(edited.exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts["currentLocation"].exists)
        capture("home")
    }

    // Run separately after simctl location sets the device coordinate.
    func testLocationInside() throws {
        guard ProcessInfo.processInfo.environment["RUN_LOCATION_CHECKS"] == "1" else {
            throw XCTSkip("Run with the simulator location check workflow.")
        }
        let location = app.staticTexts["currentLocation"]
        let inside = NSPredicate(format: "label == 'Office' OR label == 'Cafe'")
        expectation(for: inside, evaluatedWith: location)
        waitForExpectations(timeout: 30)
        capture("home-inside")
    }

    func testLocationOutside() throws {
        guard ProcessInfo.processInfo.environment["RUN_LOCATION_CHECKS"] == "1" else {
            throw XCTSkip("Run with the simulator location check workflow.")
        }
        let location = app.staticTexts["currentLocation"]
        expectation(for: NSPredicate(format: "label == 'Other'"), evaluatedWith: location)
        waitForExpectations(timeout: 30)
        capture("home-outside")
    }

    private func addPlace(name: String, status: String) {
        if app.buttons.containing(.staticText, identifier: name).firstMatch.exists { return }
        app.buttons["Add geofence"].tap()
        let field = app.textFields["placeName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name)
        app.swipeUp()
        let statusField = app.textFields["statusText"]
        statusField.tap(); statusField.typeText(status)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Geofences"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
