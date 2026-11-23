import XCTest

final class RemoteKeyTests: XCTestCase {
    func testPrimaryActionsClearTheTabBar() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Close"].tap()
        assertAboveTabBar(app.buttons["Talk to your TV"], in: app)
        assertAboveTabBar(app.buttons["Find a TV"], in: app)
        app.tabBars.buttons["My TVs"].tap()
        assertAboveTabBar(app.buttons["Add a TV"], in: app)
    }

    func testUnsupportedTouchpadKeepsDirectionalControls() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        select("Living Room", in: app)
        app.buttons["Open remote"].tap()
        XCTAssertTrue(app.buttons["Touchpad"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Touchpad"].isEnabled)
        XCTAssertTrue(app.buttons["OK"].isEnabled)
        XCTAssertTrue(app.buttons["Up"].isEnabled)
        XCTAssertFalse(app.staticTexts["Keep using Buttons"].exists)
    }

    func testRemoteModeRespondsAcrossTheWholeSegment() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        select("Bedroom", in: app)
        let code = app.textFields["pairingCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("123456")
        app.buttons["Pair TV"].tap()
        XCTAssertTrue(app.buttons["Open remote"].waitForExistence(timeout: 5))
        app.buttons["Open remote"].tap()
        app.buttons["Touchpad"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Swipe to move"].waitForExistence(timeout: 5))
        app.buttons["Buttons"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 5))
    }

    private func assertAboveTabBar(_ button: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(button.isHittable, file: file, line: line)
        XCTAssertLessThanOrEqual(button.frame.maxY, app.tabBars.firstMatch.frame.minY,
                                 "The entire action must remain above the floating tab bar.", file: file, line: line)
    }

    func testDiscoveryBackReturnsToNetworkThenWelcome() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        XCTAssertTrue(app.staticTexts["Find your TV"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Find TVs"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Find my TV"].waitForExistence(timeout: 5))
    }

    func testPowerRespondsOutsideTheIcon() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        select("Living Room", in: app)
        app.buttons["Open remote"].tap()

        let power = app.buttons["Power"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))
        // The edge of the visible 56-point key, well away from the centered symbol.
        power.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["TV asleep"].waitForExistence(timeout: 3))
        power.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 3))
    }

    func testAddingAnotherTVStartsAtDiscovery() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        select("Living Room", in: app)
        app.buttons["Open remote"].tap()
        app.tabBars.buttons["My TVs"].tap()
        app.buttons["Add a TV"].tap()
        XCTAssertTrue(app.staticTexts["Find your TV"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Find my TV"].exists)
        app.navigationBars.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Add a TV"].waitForExistence(timeout: 5))
    }

    func testPairingPreservesWrongCodeAndLandsOnFreeRemote() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        select("Bedroom", in: app)
        let code = app.textFields["pairingCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 5))
        code.tap()
        code.typeText("000000")
        app.buttons["Pair TV"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "didn’t match")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(code.value as? String, "000000")
        code.tap()
        code.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "123456")
        app.buttons["Pair TV"].tap()
        XCTAssertTrue(app.buttons["Open remote"].waitForExistence(timeout: 5))
        app.buttons["Open remote"].tap()
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["TV Remote Plus"].exists)
    }

    func testUnsupportedInputExplainsCapabilityWithoutPaywall() {
        continueAfterFailure = false
        let app = launchSetup()
        app.buttons["Close"].tap()
        app.buttons["Input"].tap()
        XCTAssertTrue(app.staticTexts["Not available for this connection"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Back to remote"].exists)
        XCTAssertFalse(app.staticTexts["TV Remote Plus"].exists)
    }

    private func launchSetup() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-hasSeenWelcome", "NO", "-appearance", "Light", "-largeControls", "NO"]
        app.launch()
        return app
    }

    private func select(_ name: String, in app: XCUIApplication) {
        let tv = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(tv.waitForExistence(timeout: 5))
        tv.tap()
    }
}
