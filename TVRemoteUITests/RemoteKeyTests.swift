import XCTest

final class RemoteKeyTests: XCTestCase {
    func testPowerRespondsOutsideTheIcon() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        app.buttons["Find a TV"].tap()
        app.buttons["Find TVs"].tap()
        let livingRoom = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Living Room")).firstMatch
        XCTAssertTrue(livingRoom.waitForExistence(timeout: 5))
        livingRoom.tap()

        let power = app.buttons["Power"]
        XCTAssertTrue(power.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 5))

        // The key ends at the screen gutter (20 pt) plus the panel inset (16 pt).
        let keyEdge = app.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
            .withOffset(CGVector(dx: -42, dy: power.frame.midY - app.frame.minY))
        keyEdge.tap()
        XCTAssertTrue(app.staticTexts["TV asleep"].waitForExistence(timeout: 3),
                      "A tap on the visible key beside the power icon must put the TV to sleep.")
    }
}
