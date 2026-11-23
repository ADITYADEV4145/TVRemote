import XCTest

final class SimulatedTVTests: XCTestCase {
    private struct Status: Decodable {
        let key_count: Int
        let pairing_code: String?
    }

    @MainActor func testRoku() async throws { try await exercise("roku", port: 8060) }
    @MainActor func testGoogleTV() async throws { try await exercise("google", port: 6466) }
    @MainActor func testSamsung() async throws { try await exercise("samsung", port: 8002) }
    @MainActor func testLG() async throws { try await exercise("lg", port: 3001) }

    @MainActor
    private func exercise(_ brand: String, port: Int) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TVREMOTE_RUN_LAB"] == "1",
                          "Start the loopback TV lab and set TEST_RUNNER_TVREMOTE_RUN_LAB=1.")
        continueAfterFailure = false
        if brand != "roku" { try await chaos("revoke", for: brand) }
        let app = XCUIApplication()
        app.launchArguments = ["-lab-ui-test", "-hasSeenWelcome", "NO", "-appearance", "Light", "-largeControls", "NO"]
        let permission = addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            guard alert.buttons["Allow"].exists else { return false }
            alert.buttons["Allow"].tap()
            return true
        }
        defer { removeUIInterruptionMonitor(permission) }
        app.launch()
        app.buttons["Find my TV"].tap()
        app.buttons["Find TVs"].tap()
        if brand == "samsung" { try await chaos("approval", for: brand, allow: false) }
        enterAddress(port, in: app)

        if brand == "google" {
            let codeField = app.textFields["pairingCode"]
            XCTAssertTrue(codeField.waitForExistence(timeout: 20))
            capture("\(brand)-pairing")
            let code = try await status(brand).pairing_code
            let pin = try XCTUnwrap(code)
            codeField.tap()
            codeField.typeText((pin.hasPrefix("0") ? "1" : "0") + String(pin.dropFirst()))
            app.buttons["Pair TV"].tap()
            let mismatch = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "didn’t match")).firstMatch
            XCTAssertTrue(mismatch.waitForExistence(timeout: 10))
            let pairButton = app.buttons["Pair TV"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                                         object: pairButton)], timeout: 10), .completed)
            let newCode = try await status(brand).pairing_code
            let newPin = try XCTUnwrap(newCode)
            codeField.tap()
            codeField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + newPin)
            pairButton.tap()
            XCTAssertTrue(app.buttons["Open remote"].waitForExistence(timeout: 20))
            XCTAssertFalse(mismatch.exists)
        } else if brand == "samsung" || brand == "lg" {
            let retry = app.buttons["Try again"]
            assertApprovalPending(in: app, retry: retry)
            if brand == "samsung" {
                let rejected = app.staticTexts["Pair again with the TV to continue."].waitForExistence(timeout: 8)
                try await chaos("approval", for: brand, allow: true)
                XCTAssertTrue(rejected)
                XCTAssertTrue(retry.isEnabled)
                XCTAssertFalse(app.staticTexts["Connecting to TV"].exists)
                retry.tap()
                assertApprovalPending(in: app, retry: retry)
            }
            capture("\(brand)-approval")
        }
        let openRemote = app.buttons["Open remote"]
        XCTAssertTrue(openRemote.waitForExistence(timeout: 20))
        openRemote.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))
        let volume = app.buttons["Volume up"]
        let initialCount = try await status(brand).key_count
        volume.tap()
        try await waitForKey(on: brand, after: initialCount)
        capture("\(brand)-command")

        if brand != "roku" { try await chaos("drop", for: brand) }
        try await chaos("rebind", for: brand)
        let afterRestart = try await status(brand).key_count
        // The old UI state can still be Connected until the next health check observes the drop.
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 20))
        volume.tap()
        try await waitForKey(on: brand, after: afterRestart)
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 10))
        capture("\(brand)-reconnected")
    }

    @MainActor
    private func assertApprovalPending(in app: XCUIApplication, retry: XCUIElement) {
        XCTAssertTrue(app.staticTexts["Look up at the TV"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["Connecting to TV"].exists)
        XCTAssertFalse(retry.isEnabled)
        XCTAssertFalse(app.staticTexts["Pair again with the TV to continue."].exists)
    }

    @MainActor
    private func enterAddress(_ port: Int, in app: XCUIApplication) {
        let manual = app.buttons["Enter IP address"]
        manual.tap()
        if !app.textFields.firstMatch.exists { manual.tap() }
        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        if address.value as? String != "127.0.0.1:\(port)" {
            address.typeText("127.0.0.1:\(port)")
        }
        app.buttons["Find TV"].tap()
    }

    private func status(_ brand: String) async throws -> Status {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/tvs/\(brand)")!)
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Status.self, from: data)
    }

    private func chaos(_ action: String, for brand: String, allow: Bool? = nil) async throws {
        struct Change: Encodable {
            let action: String
            let allow: Bool?
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/tvs/\(brand)/chaos")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Change(action: action, allow: allow))
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitForKey(on brand: String, after count: Int) async throws {
        for _ in 0..<60 {
            if try await status(brand).key_count > count { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("The \(brand) simulator did not receive the remote command.")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
