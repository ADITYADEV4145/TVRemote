import XCTest
@testable import TVRemote

@MainActor
final class ConnectionManagerTests: XCTestCase {
    func testDiscoveryAndManualAddressUseStableDeviceIdentity() async {
        let connection = RemoteViewModel(driver: MockTVDriver())
        await connection.discover()
        await connection.discover()
        XCTAssertEqual(connection.devices, MockTVDriver.devices)

        let didConnect = await connection.find(address: " 192.0.2.10 ")
        XCTAssertTrue(didConnect)
        XCTAssertEqual(connection.currentDevice, MockTVDriver.devices[0])
        XCTAssertEqual(connection.savedDevices, [MockTVDriver.devices[0]])

        let addressFound = await connection.find(address: "192.0.2.99")
        XCTAssertFalse(addressFound)
        XCTAssertNotNil(connection.error)
        XCTAssertEqual(connection.currentDevice, MockTVDriver.devices[0])
    }

    func testPairingCodeIsRequiredOnceAndInvalidCodeLeavesPairingOpen() async {
        let connection = RemoteViewModel(driver: MockTVDriver())
        let livingRoom = MockTVDriver.devices[0]
        let bedroom = MockTVDriver.devices[1]

        let didConnectWithoutCode = await connection.select(bedroom)
        XCTAssertFalse(didConnectWithoutCode)
        XCTAssertEqual(connection.pairingDevice, bedroom)
        XCTAssertNil(connection.currentDevice)

        let didConnectWithWrongCode = await connection.submit(code: "000000")
        XCTAssertFalse(didConnectWithWrongCode)
        XCTAssertNotNil(connection.error)
        XCTAssertEqual(connection.pairingDevice, bedroom)

        let didPair = await connection.submit(code: MockTVDriver.demoCode)
        XCTAssertTrue(didPair)
        XCTAssertNil(connection.pairingDevice)
        XCTAssertTrue(connection.supportsPointer)

        let didSwitch = await connection.select(livingRoom)
        XCTAssertTrue(didSwitch)
        XCTAssertFalse(connection.supportsPointer)
        let didReconnect = await connection.select(bedroom)
        XCTAssertTrue(didReconnect)
        XCTAssertEqual(connection.currentDevice, bedroom)
        XCTAssertEqual(connection.savedDevices, [bedroom, livingRoom])
    }

    func testCommandsOnlyReachDriverWhenSupportedAndConnected() async {
        let driver = MockTVDriver()
        let connection = RemoteViewModel(driver: driver)
        let app = AppID(rawValue: "netflix")

        await connection.send(.home)
        await connection.launch(app, name: "Netflix")
        await connection.search("Movie night")
        XCTAssertTrue(driver.commands.isEmpty)

        _ = await connection.select(MockTVDriver.devices[0])
        await waitForState(.ready, on: connection)
        await connection.send(.home)
        await connection.launch(app, name: "Netflix")
        await connection.search("  Movie night ")
        await connection.search(" ")
        await connection.movePointer(x: 3, y: -2)
        XCTAssertEqual(driver.commands, [.key(.home), .app(app), .search("Movie night")])
        XCTAssertEqual(connection.recentCommands.map(\.title), ["TV search", "Open Netflix", "Home"])
        let timestamps = connection.recentCommands.map(\.timestamp)
        XCTAssertEqual(timestamps, timestamps.sorted(by: >))

        _ = await connection.select(MockTVDriver.devices[1])
        _ = await connection.submit(code: MockTVDriver.demoCode)
        await waitForState(.ready, on: connection)
        await connection.movePointer(x: 3, y: -2)
        XCTAssertEqual(driver.commands.last, .pointer(3, -2))
        XCTAssertEqual(connection.recentCommands.first?.deviceID, MockTVDriver.devices[1].id)
        XCTAssertTrue(connection.recentCommands.dropFirst().allSatisfy { $0.deviceID == MockTVDriver.devices[0].id })
    }

    func testPowerSleepsAndWakesTheSelectedDevice() async {
        let driver = MockTVDriver()
        let connection = RemoteViewModel(driver: driver)
        let device = MockTVDriver.devices[0]

        _ = await connection.select(device)
        await waitForState(.ready, on: connection)
        await connection.send(.power)
        await waitForState(.asleep, on: connection)
        XCTAssertFalse(connection.canControl)
        XCTAssertTrue(connection.canPower)
        await connection.send(.volumeUp)
        await connection.send(.power)
        await waitForState(.ready, on: connection)
        XCTAssertTrue(connection.canControl)
        XCTAssertEqual(driver.commands, [.key(.power), .wake(device.id)])
    }

    func testForgettingTheActiveTVDisconnectsAndRequiresPairingAgain() async {
        let driver = MockTVDriver()
        let connection = RemoteViewModel(driver: driver)
        let bedroom = MockTVDriver.devices[1]

        _ = await connection.select(bedroom)
        _ = await connection.submit(code: MockTVDriver.demoCode)
        await waitForState(.ready, on: connection)
        await connection.forget(bedroom)

        XCTAssertNil(connection.currentDevice)
        XCTAssertTrue(connection.savedDevices.isEmpty)
        XCTAssertEqual(connection.state, .idle)
        do {
            try await driver.send(.home)
            XCTFail("The driver must disconnect when its active TV is forgotten.")
        } catch MockTVDriver.Failure.notConnected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let didConnect = await connection.select(bedroom)
        XCTAssertFalse(didConnect)
        XCTAssertEqual(connection.pairingDevice, bedroom)
    }

    func testClearingMessagesLeavesTheCommandHistoryIntact() async {
        let connection = RemoteViewModel(driver: MockTVDriver())
        _ = await connection.select(MockTVDriver.devices[0])
        await waitForState(.ready, on: connection)
        await connection.search("Movie night")
        XCTAssertNotNil(connection.feedback)

        connection.clearMessages()

        XCTAssertNil(connection.feedback)
        XCTAssertNil(connection.error)
        XCTAssertEqual(connection.recentCommands.map(\.title), ["TV search"])
    }

    private func waitForState(_ state: ConnectionState, on connection: RemoteViewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while connection.state != state && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.state, state)
    }
}
