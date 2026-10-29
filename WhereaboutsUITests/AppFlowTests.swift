import XCTest

final class AppFlowTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    func testWebhookEditingAndValidation() {
        app.tabBars.buttons["Destinations"].tap()
        let old = app.buttons["Example webhook"]
        if old.exists { old.swipeLeft(); app.buttons["Delete"].tap() }
        let oldEdited = app.buttons["Example webhook edited"]
        if oldEdited.exists { oldEdited.swipeLeft(); app.buttons["Delete"].tap() }
        app.buttons["Add webhook"].tap()
        let name = app.textFields["webhookName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Example webhook")
        let url = app.textFields["webhookURL"]
        url.tap(); url.typeText("http://example.com/hook")
        // Leave the fixture disabled so the UI test never sends a real request.
        let toggle = app.switches["webhookEnabled"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Enter an HTTPS URL without a username, password, or fragment."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["Add webhook"].tap()
        name.tap(); name.typeText("Example webhook")
        url.tap(); url.typeText("https://example.com/hook")
        app.switches["webhookEnabled"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Example webhook"].waitForExistence(timeout: 5))
        capture("webhook-destinations")
        app.terminate(); app.launch()
        app.tabBars.buttons["Destinations"].tap()
        app.buttons["Example webhook"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(url.value as? String, "https://example.com/hook")
        capture("webhook-editor")
        name.tap(); name.typeText(" edited")
        app.buttons["Save"].tap()
        let edited = app.buttons["Example webhook edited"]
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        edited.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(edited.exists)
        app.terminate(); app.launch()
        app.tabBars.buttons["Destinations"].tap()
        XCTAssertFalse(app.buttons["Example webhook edited"].exists)
    }

    func testDrivingSettingsAndHome() {
        app.terminate()
        app.launchArguments = ["--preview-driving"]
        app.launch()
        XCTAssertEqual(app.staticTexts["currentLocation"].label, "Driving")
        capture("home-driving")
        app.buttons["Driving"].tap()
        XCTAssertTrue(app.switches["Detect driving"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["emojiPickerButton"].label.contains("🚗"))
        capture("driving-settings")
        let toggle = app.switches["Detect driving"]
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Save"].tap()
        XCTAssertNotEqual(app.staticTexts["currentLocation"].label, "Driving")
        app.buttons["Driving"].tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.buttons["Save"].tap()
        app.terminate()
        app.launchArguments = []
    }

    func testSaveValidationAndPersistence() {
        app.tabBars.buttons["Geofences"].tap()
        app.buttons["Add geofence"].tap()
        XCTAssertTrue(app.textFields["placeName"].waitForExistence(timeout: 5))
        app.maps.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).tap()
        let status = app.textFields["statusText"]
        scrollTo(status)
        status.tap()
        status.typeText("At work\n")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.alerts.staticTexts["Enter a name to save this geofence."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        let name = app.textFields["placeName"]
        scrollTo(name, down: true)
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

    func testEmojiPickerAndCustomShortcode() {
        app.tabBars.buttons["Geofences"].tap()
        let oldRow = app.buttons.containing(.staticText, identifier: "Emoji test place").firstMatch
        if oldRow.exists { oldRow.swipeLeft(); app.buttons["Delete"].tap() }
        app.buttons["Add geofence"].tap()
        let name = app.textFields["placeName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Emoji test place\n")
        scrollTo(app.buttons["emojiPickerButton"])
        app.buttons["emojiPickerButton"].tap()
        let search = app.searchFields["Search emoji"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("coffee")
        app.buttons[":coffee:"].firstMatch.tap()
        XCTAssertTrue(app.buttons["emojiPickerButton"].label.contains("☕"))
        app.buttons["Save"].tap()
        let row = app.buttons.containing(.staticText, identifier: "Emoji test place").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        scrollTo(app.buttons["emojiPickerButton"])
        app.buttons["emojiPickerButton"].tap()
        XCTAssertTrue(app.staticTexts["Recent"].waitForExistence(timeout: 5))
        capture("emoji-picker")
        app.disclosureTriangles["Custom workspace emoji"].tap()
        let custom = app.textFields["customEmoji"]
        custom.tap()
        custom.typeText(":my-team:")
        app.buttons["Use custom emoji"].tap()
        XCTAssertTrue(app.buttons["emojiPickerButton"].label.contains(":my-team:"))
        app.buttons["Save"].tap()
        app.terminate()
        app.launch()
        app.tabBars.buttons["Geofences"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains(":my-team:"))
        row.swipeLeft()
        app.buttons["Delete"].tap()
        app.tabBars.buttons["Home"].tap()
        app.swipeUp()
        app.buttons["Other status"].tap()
        app.buttons["emojiPickerButton"].tap()
        search.tap()
        search.typeText("globe_with_meridians")
        app.buttons[":globe_with_meridians:"].firstMatch.tap()
        XCTAssertTrue(app.buttons["emojiPickerButton"].label.contains("🌐"))
        app.buttons["Save"].tap()
        app.buttons["Other status"].tap()
        XCTAssertTrue(app.buttons["emojiPickerButton"].label.contains("🌐"))
    }

    func testLocationDenied() throws {
        guard ProcessInfo.processInfo.environment["EXPECT_LOCATION_DENIED"] == "1" else {
            throw XCTSkip("Run after simctl privacy denies location.")
        }
        app.tabBars.buttons["Geofences"].tap()
        app.buttons["Add geofence"].tap()
        app.buttons["Use current location"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Location access is disabled. Choose a point on the map or allow access in Settings."].exists)
        app.buttons["Cancel"].tap()
    }

    func testUseCurrentLocation() throws {
        guard let expected = ProcessInfo.processInfo.environment["EXPECTED_COORDINATES"] else {
            throw XCTSkip("Set EXPECTED_COORDINATES after simctl location.")
        }
        app.tabBars.buttons["Geofences"].tap()
        app.buttons["Add geofence"].tap()
        let coordinates = app.staticTexts["geofenceCoordinates"]
        expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: coordinates)
        waitForExpectations(timeout: 15)
        app.maps.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).tap()
        XCTAssertNotEqual(coordinates.label, expected)
        app.buttons["Use current location"].tap()
        expectation(for: NSPredicate(format: "label == %@", expected), evaluatedWith: coordinates)
        waitForExpectations(timeout: 15)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.staticTexts["Get current location"])
        waitForExpectations(timeout: 15)
        capture("editor-current-location")
        app.buttons["Cancel"].tap()
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

    private func scrollTo(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: down ? 0.25 : 0.75))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: down ? 0.75 : 0.25)))
        }
    }

    private func addPlace(name: String, status: String) {
        if app.buttons.containing(.staticText, identifier: name).firstMatch.exists { return }
        app.buttons["Add geofence"].tap()
        let field = app.textFields["placeName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name + "\n")
        let statusField = app.textFields["statusText"]
        scrollTo(statusField)
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
