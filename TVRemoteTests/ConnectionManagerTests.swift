import XCTest
@testable import TVRemote
import TVRemoteKit

private actor LiveFixtureDriver: TVDriver {
    nonisolated var state: AsyncStream<TVRemoteCore.ConnectionState> { AsyncStream { $0.finish() } }
    private var online = true
    private(set) var wakes = 0
    private(set) var keys: [TVRemoteCore.RemoteKey] = []
    private(set) var probedPorts: [UInt16] = []
    private var probeDevice: TVRemoteCore.TVDevice?
    private let firstSend = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    private var holdFirstSend = false

    func goOffline() { online = false }
    func holdNextSend() { holdFirstSend = true }
    func waitForSend() async { for await _ in firstSend.stream { break } }
    func releaseSend() { release.continuation.finish() }
    nonisolated func discover() -> AsyncStream<TVRemoteCore.TVDevice> { AsyncStream { $0.finish() } }
    func serveProbe(for device: TVRemoteCore.TVDevice) {
        probeDevice = device
        probedPorts = []
    }
    func probe(_ endpoint: TVEndpoint) async throws -> TVRemoteCore.TVDevice {
        probedPorts.append(endpoint.port)
        guard let probeDevice, probeDevice.endpoint == endpoint else { throw TVError.unreachable }
        return probeDevice
    }
    func pair(_ tv: TVRemoteCore.TVDevice, prompt: PairingPromptHandler) async throws -> Credential { .token("paired") }
    func connect(_ tv: TVRemoteCore.TVDevice, _ cred: Credential) async throws { try requireOnline() }
    func send(_ key: TVRemoteCore.RemoteKey) async throws {
        try requireOnline()
        keys.append(key)
        if holdFirstSend {
            holdFirstSend = false
            firstSend.continuation.yield(())
            for await _ in release.stream {}
        }
    }
    func launch(_ app: TVRemoteCore.AppID) async throws { throw TVError.notSupported }
    func search(_ query: String) async throws { throw TVError.notSupported }
    func wake(_ tv: TVRemoteCore.TVDevice) async {
        wakes += 1
        online = true
    }
    func keepAlive() async throws { try requireOnline() }
    private func requireOnline() throws { if !online { throw TVError.unreachable } }
}

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

    func testPowerWakesAnOfflineWakeCapableTV() async throws {
        for platform in [TVPlatform.samsung, .lg] {
            let (connection, session, device, driver) = try await liveFixture(platform: platform, [.remoteKeys, .networkWake])
            try await session.credentials.save(.token("paired"), for: device.id)
            let connected = await connection.select(session.remember(device))
            XCTAssertTrue(connected)
            await driver.goOffline()
            do {
                try await session.manager.checkConnection()
                XCTFail("The standby TV should not respond to its control connection.")
            } catch TVError.unreachable {}
            await waitForState(.degraded, on: connection)
            XCTAssertFalse(connection.canControl)
            XCTAssertTrue(connection.canPower)
            await connection.send(.power)
            await waitForState(.ready, on: connection)
            XCTAssertTrue(connection.canControl)
            let wakes = await driver.wakes
            XCTAssertEqual(wakes, 1)
        }
    }

    func testRapidRemoteCommandsAreDeliveredInOrder() async throws {
        let (connection, session, device, driver) = try await liveFixture([.remoteKeys])
        try await session.credentials.save(.token("paired"), for: device.id)
        let connected = await connection.select(session.remember(device))
        XCTAssertTrue(connected)
        await driver.holdNextSend()
        let first = Task { await connection.send(.volumeUp) }
        await driver.waitForSend()
        let second = Task { await connection.send(.left) }
        await Task.yield()
        let third = Task { await connection.send(.volumeDown) }
        await Task.yield()
        await driver.releaseSend()
        await first.value
        await second.value
        await third.value
        let keys = await driver.keys
        XCTAssertEqual(keys, [.volumeUp, .left, .volumeDown])
    }

    func testAutomaticPairingPublishesSetupCompletionWithoutPrompt() async throws {
        let (connection, session, device, _) = try await liveFixture([.remoteKeys])
        let selected = session.remember(device)
        let connectedSynchronously = await connection.select(selected)
        XCTAssertFalse(connectedSynchronously)
        for _ in 0..<100 where connection.isConnecting { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(connection.isConnecting)
        XCTAssertNil(connection.pairingPrompt)
        XCTAssertEqual(connection.currentDevice, selected)
        XCTAssertEqual(connection.pairingCompletion, 1)
    }

    func testBareIPProbesSecureBeforePlainAndExplicitSecureDoesNotFallBack() async throws {
        let host = "192.0.2.42"
        let endpoints: [(TVPlatform, UInt16, UInt16)] = [(.samsung, 8002, 8001), (.lg, 3001, 3000)]
        for (platform, secure, plain) in endpoints {
            let (_, session, device, driver) = try await liveFixture(platform: platform, [.remoteKeys])
            func endpointDevice(_ port: UInt16) -> TVRemoteCore.TVDevice {
                .init(id: device.id, name: device.name, endpoint: TVEndpoint(host: host, port: port),
                      capabilities: device.capabilities)
            }

            await driver.serveProbe(for: endpointDevice(plain))
            do {
                _ = try await session.find("\(host):\(secure)")
                XCTFail("An explicit secure port must not find a plain-only TV.")
            } catch LiveTVSession.Failure.notFound {}
            let explicitProbes = await driver.probedPorts
            XCTAssertEqual(explicitProbes, [secure])

            await driver.serveProbe(for: endpointDevice(plain))
            let plainMatch = try await session.find(host)
            XCTAssertEqual(session.device(plainMatch.id)?.endpoint.port, plain)
            let fallbackProbes = await driver.probedPorts
            XCTAssertEqual(fallbackProbes, [secure, plain])

            await driver.serveProbe(for: endpointDevice(secure))
            let secureMatch = try await session.find(host)
            XCTAssertEqual(session.device(secureMatch.id)?.endpoint.port, secure)
            let secureProbes = await driver.probedPorts
            XCTAssertEqual(secureProbes, [secure])
        }
    }

    func testBareIPDoesNotFindPlainLGWithoutAReportedUUID() async throws {
        let host = "192.0.2.42"
        let (_, session, _, driver) = try await liveFixture([.remoteKeys])
        let plainLG = TVRemoteCore.TVDevice(id: TVIdentity(platform: .lg, identifier: host),
                                          name: "LG TV", endpoint: TVEndpoint(host: host, port: 3000),
                                          capabilities: [.remoteKeys])
        await driver.serveProbe(for: plainLG)

        do {
            _ = try await session.find(host)
            XCTFail("A bare-IP lookup must not select a plain LG TV without a reported UUID.")
        } catch LiveTVSession.Failure.notFound {}
        let probes = await driver.probedPorts
        XCTAssertEqual(probes, [3001, 3000])
        XCTAssertNil(session.device("lg:\(host)"))
    }

    func testSearchRequiresAdvertisedCapability() async throws {
        for platform in [TVPlatform.googleTV, .samsung, .lg] {
            let (connection, session, device, _) = try await liveFixture(platform: platform, [.remoteKeys])
            try await session.credentials.save(.token("paired"), for: device.id)
            let connected = await connection.select(session.remember(device))
            XCTAssertTrue(connected)
            XCTAssertTrue(connection.canControl)
            XCTAssertFalse(connection.canSearch)
            await connection.search("Movie night")
            XCTAssertNil(connection.error)
            XCTAssertTrue(connection.recentCommands.isEmpty)
        }
    }

    private func liveFixture(platform: TVPlatform = .lg, _ capabilities: TVCapabilities) async throws
        -> (RemoteViewModel, LiveTVSession, LiveTVSession.Device, LiveFixtureDriver) {
        let device = LiveTVSession.Device(id: TVIdentity(platform: platform, identifier: "tv"),
                                          name: "TV", endpoint: TVEndpoint(host: "tv.local", port: 3001),
                                          capabilities: capabilities)
        let driver = LiveFixtureDriver()
        let credentials = MemoryCredentialStore()
        let manager = TVRemoteCore.ConnectionManager(
            drivers: [TVDriverFactory(platform: platform) { driver }], credentials: credentials,
            retryDelays: [.zero]
        )
        let suite = "TVRemoteTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let session = LiveTVSession(defaults: defaults, credentials: credentials, manager: manager)
        return (RemoteViewModel(live: session), session, device, driver)
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

    private func waitForState(_ state: TVRemote.ConnectionState, on connection: RemoteViewModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while connection.state != state && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.state, state)
    }
}
