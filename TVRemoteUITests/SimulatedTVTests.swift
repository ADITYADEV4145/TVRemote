import XCTest

final class SimulatedTVTests: XCTestCase {
    private struct Status: Decodable {
        let key_count: Int
        let pairing_code: String?
        let channel: String?
        let input: String?
        let app: String
        let text: String
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
        if brand == "samsung" || brand == "lg" { try await chaos("approval", for: brand, allow: false) }
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
            let declineMessage = "The TV declined the pairing request."
            if brand == "samsung" { try assertApprovalPendingOrFinished(in: app, outcome: declineMessage) }
            let rejected = app.staticTexts[declineMessage].waitForExistence(timeout: 8)
            try await chaos("approval", for: brand, allow: true)
            XCTAssertTrue(rejected)
            XCTAssertTrue(app.staticTexts["Look up at the TV"].exists)
            XCTAssertFalse(app.staticTexts["Add by IP address"].exists)
            XCTAssertTrue(retry.isEnabled)
            XCTAssertFalse(app.staticTexts["Connecting to TV"].exists)
            capture("\(brand)-approval")
            if brand == "lg" {
                try await chaos("approval", for: brand, allow: false)
                app.buttons["Choose another TV"].tap()
                XCTAssertTrue(app.staticTexts["Find your TV"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.staticTexts["The TV declined the pairing request."].exists)
                enterAddress(port, in: app)
                XCTAssertTrue(app.staticTexts["The TV declined the pairing request."].waitForExistence(timeout: 8))
                try await chaos("approval", for: brand, allow: true)
            }
            retry.tap()
            try assertApprovalPendingOrFinished(in: app, outcome: "Open remote")
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

        switch brand {
        case "roku":
            try await verifyInputs(in: app, brand: brand, firstID: "tvinput.hdmi1", secondID: "tvinput.hdmi2")
        case "lg":
            let initialChannel = try await status(brand).channel
            app.buttons["Channel up"].tap()
            try await waitForStatus(on: brand, "advance the channel") { $0.channel != initialChannel }
            app.buttons["Channel down"].tap()
            try await waitForStatus(on: brand, "return to the original channel") { $0.channel == initialChannel }
            try await verifyInputs(in: app, brand: brand, firstID: "HDMI_1", secondID: "HDMI_2")
            try await verifyChooseAnotherTVAfterAddressUpdate(in: app, lgPort: port)
        case "samsung":
            app.buttons["Home"].tap()
            try await waitForStatus(on: brand, "open Home") { $0.app == "home" }
            app.tabBars.buttons["Apps"].tap()
            let netflix = app.buttons["Netflix, Open on TV"]
            XCTAssertTrue(netflix.waitForExistence(timeout: 8))
            XCTAssertTrue(netflix.isEnabled)
            XCTAssertTrue(netflix.isHittable)
            netflix.tap()
            try await waitForStatus(on: brand, "launch the listed Netflix app") { $0.app == "11101200001" }
            capture("samsung-app-list")
            app.tabBars.buttons["Remote"].tap()
            let priorText = try await status(brand).text
            app.buttons["Keyboard"].tap()
            let draft = app.descendants(matching: .any)["searchDraft"].firstMatch
            XCTAssertTrue(draft.waitForExistence(timeout: 5))
            if try await !samsungAdvertisesKeyboard() {
                XCTAssertTrue(app.staticTexts["Keyboard unavailable"].exists)
                XCTAssertFalse(draft.isEnabled)
                capture("samsung-text-not-advertised")
                return
            }
            draft.tap()
            draft.typeText("Lab text")
            app.buttons["Send text"].tap()
            try await waitForStatus(on: brand, "receive base64 text entry") { $0.text == priorText + "Lab text" }
            capture("samsung-text-sent")
        case "google":
            try await verifyRevokedPairing(in: app, volume: volume)
        default:
            XCTFail("Missing feature check for \(brand).")
        }
    }

    @MainActor
    private func verifyInputs(in app: XCUIApplication, brand: String, firstID: String, secondID: String) async throws {
        app.buttons["Input"].tap()
        for (label, id) in [("HDMI 1", firstID), ("HDMI 2", secondID)] {
            let input = app.buttons.containing(.staticText, identifier: label).firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 8))
            input.tap()
            try await waitForStatus(on: brand, "switch to \(label)") { $0.input == id }
        }
        capture("\(brand)-inputs")
    }

    @MainActor
    private func verifyRevokedPairing(in app: XCUIApplication, volume: XCUIElement) async throws {
        try await chaos("revoke", for: "google")
        XCTAssertTrue(app.staticTexts["Pair again"].waitForExistence(timeout: 20))
        XCTAssertFalse(volume.isEnabled)
        app.buttons["Fix connection"].tap()
        let repair = app.buttons["Pair again"]
        XCTAssertTrue(repair.waitForExistence(timeout: 5))
        capture("google-revoked")
        repair.tap()
        let codeField = app.textFields["pairingCode"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 10))
        let code = try await status("google").pairing_code
        let pin = try XCTUnwrap(code)
        codeField.tap()
        codeField.typeText(pin)
        app.buttons["Pair TV"].tap()
        let openRemote = app.buttons["Open remote"]
        XCTAssertTrue(openRemote.waitForExistence(timeout: 15))
        openRemote.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 8))
        let count = try await status("google").key_count
        volume.tap()
        try await waitForKey(on: "google", after: count)
    }

    @MainActor
    private func assertApprovalPendingOrFinished(in app: XCUIApplication, outcome: String) throws {
        let approval = "Look up at the TV"
        let phase = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", [approval, outcome])).firstMatch
        XCTAssertTrue(phase.waitForExistence(timeout: 12))

        let snapshot = try app.snapshot()
        func find(_ label: String, in element: any XCUIElementSnapshot) -> (any XCUIElementSnapshot)? {
            if element.label == label { return element }
            return element.children.lazy.compactMap { find(label, in: $0) }.first
        }
        if find(outcome, in: snapshot) != nil { return }
        XCTAssertNotNil(find(approval, in: snapshot))
        XCTAssertNotNil(find("Connecting to TV", in: snapshot))
        XCTAssertFalse(try XCTUnwrap(find("Try again", in: snapshot)).isEnabled)
        XCTAssertNil(find("The TV declined the pairing request.", in: snapshot))
    }

    @MainActor
    private func verifyChooseAnotherTVAfterAddressUpdate(in app: XCUIApplication, lgPort: Int) async throws {
        app.buttons["Close"].tap()
        try await chaos("approval", for: "lg", allow: false)
        try await chaos("revoke", for: "lg")
        XCTAssertTrue(app.staticTexts["Pair again"].waitForExistence(timeout: 20))
        app.buttons["Fix connection"].tap()
        let update = app.buttons["Update TV address"]
        XCTAssertTrue(update.waitForExistence(timeout: 5))
        update.tap()
        XCTAssertTrue(app.staticTexts["Update TV address"].waitForExistence(timeout: 5))
        submitAddress(lgPort, in: app)
        let declined = app.staticTexts["The TV declined the pairing request."].waitForExistence(timeout: 8)
        try await chaos("approval", for: "lg", allow: true)
        XCTAssertTrue(declined)
        app.buttons["Choose another TV"].tap()
        XCTAssertTrue(app.staticTexts["Find your TV"].waitForExistence(timeout: 5))
        enterAddress(8060, in: app)
        let openRemote = app.buttons["Open remote"]
        let foundRoku = openRemote.waitForExistence(timeout: 10)
        capture("lg-address-update-choose-roku")
        XCTAssertTrue(foundRoku, "A different TV’s address should work after choosing another TV. Still updating: \(app.staticTexts["Update TV address"].exists).")
        openRemote.tap()
        XCTAssertTrue(app.staticTexts["Lab Roku"].waitForExistence(timeout: 5))
        let count = try await status("roku").key_count
        app.buttons["Volume up"].tap()
        try await waitForKey(on: "roku", after: count)
    }

    @MainActor
    private func enterAddress(_ port: Int, in app: XCUIApplication) {
        let manual = app.buttons["Enter IP address"]
        manual.tap()
        if !app.textFields.firstMatch.exists { manual.tap() }
        submitAddress(port, in: app)
    }

    @MainActor
    private func submitAddress(_ port: Int, in app: XCUIApplication) {
        let address = app.textFields.firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        let entered = address.value as? String
        let target = "127.0.0.1:\(port)"
        if entered != target {
            let deleteCount = entered == address.placeholderValue ? 0 : (entered?.count ?? 0)
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount) + target)
        }
        XCTAssertEqual(address.value as? String, target)
        app.buttons["Find TV"].tap()
    }

    private func status(_ brand: String) async throws -> Status {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8090/tvs/\(brand)")!)
        request.timeoutInterval = 3
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Status.self, from: data)
    }

    private func samsungAdvertisesKeyboard() async throws -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8001/api/v2/")!)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let device = try XCTUnwrap(info["device"] as? [String: Any])
        let advertised = device["ImeSyncedSupport"]
        return advertised as? Bool ?? ((advertised as? String)?.lowercased() == "true")
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
        try await waitForStatus(on: brand, "receive the remote command") { $0.key_count > count }
    }

    private func waitForStatus(on brand: String, _ effect: String, until matches: (Status) -> Bool) async throws {
        for _ in 0..<60 {
            if try await matches(status(brand)) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("The \(brand) simulator did not \(effect).")
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
