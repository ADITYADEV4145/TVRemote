import XCTest

/// Opt-in visual inventory; the normal TVRemote scheme does not run this suite.
final class DesignSnapshotTests: XCTestCase {
    func testLightDesignStates() { captureStates(appearance: "Light") }
    func testDarkDesignStates() { captureStates(appearance: "Dark") }

    private func captureStates(appearance: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        for index in 0..<55 {
            app.launchArguments = ["-design-screen", String(index), "-design-appearance", appearance,
                                   "-appearance", appearance, "-largeControls", "NO"]
            app.launch()
            let ready = app.descendants(matching: .any).matching(identifier: "designReady").firstMatch
            XCTAssertTrue(ready.waitForExistence(timeout: 10), "Design fixture \(index) failed to load")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = String(format: "%02d-%@", index, appearance.lowercased())
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }
}
