import Foundation
import Testing
import TVRemoteKit

private func tv(
    _ host: String = "192.0.2.10",
    id: String = "living-room",
    platform: TVPlatform = .roku,
    capabilities: TVCapabilities = [.remoteKeys]
) -> TVDevice {
    TVDevice(
        id: TVIdentity(platform: platform, identifier: id),
        name: "Living Room",
        endpoint: TVEndpoint(host: host, port: 8060),
        capabilities: capabilities
    )
}

private actor FakeClock: ConnectionClock {
    private(set) var sleeps: [Duration] = []

    func sleep(for duration: Duration) throws {
        try Task.checkCancellation()
        sleeps.append(duration)
    }
}

private actor Scenario {
    let devices: [TVDevice]
    let pairingCredential: Credential
    let connectGate: AsyncStream<Void>?
    private var connectResults: [String: [TVError?]]
    private var sendResults: [TVError?]
    private(set) var connects: [TVEndpoint] = []
    private(set) var connectCredentials: [Credential] = []
    private(set) var commandSessions: [UUID] = []
    private(set) var wakes: [TVIdentity] = []

    init(
        discovery: [TVDevice] = [],
        connects: [String: [TVError?]] = [:],
        sends: [TVError?] = [],
        pairingCredential: Credential = .none,
        connectGate: AsyncStream<Void>? = nil
    ) {
        devices = discovery
        connectResults = connects
        sendResults = sends
        self.pairingCredential = pairingCredential
        self.connectGate = connectGate
    }

    func connect(_ tv: TVDevice, credential: Credential) async throws {
        connects.append(tv.endpoint)
        connectCredentials.append(credential)
        if var results = connectResults[tv.endpoint.host], !results.isEmpty {
            let result = results.removeFirst()
            connectResults[tv.endpoint.host] = results
            if let result { throw result }
        }
        if let connectGate, tv.endpoint.host == "192.0.2.10" {
            for await _ in connectGate { break }
            try Task.checkCancellation()
        }
    }

    func send(session: UUID) throws {
        commandSessions.append(session)
        if !sendResults.isEmpty, let error = sendResults.removeFirst() { throw error }
    }

    func wake(_ tv: TVDevice) { wakes.append(tv.id) }
}

private struct ScenarioDriver: TVDriver {
    let scenario: Scenario
    let session = UUID()

    var state: AsyncStream<ConnectionState> { AsyncStream { $0.finish() } }

    func discover() -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            for device in scenario.devices { continuation.yield(device) }
            continuation.finish()
        }
    }

    func probe(_ endpoint: TVEndpoint) async throws -> TVDevice { tv(endpoint.host) }
    func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential {
        if tv.id.platform != .roku {
            guard try await prompt(.enterCode(length: 6)) == .code("12A4BC") else {
                throw TVError.credentialRejected
            }
        }
        return scenario.pairingCredential
    }

    func connect(_ tv: TVDevice, _ cred: Credential) async throws {
        try await scenario.connect(tv, credential: cred)
    }
    func send(_ key: RemoteKey) async throws { try await scenario.send(session: session) }
    func launch(_ app: AppID) async throws { try await scenario.send(session: session) }
    func search(_ query: String) async throws { try await scenario.send(session: session) }
    func keepAlive() async throws { try await scenario.send(session: session) }
    func wake(_ tv: TVDevice) async throws { await scenario.wake(tv) }
}

private func manager(
    _ scenario: Scenario, platform: TVPlatform = .roku,
    clock: FakeClock = FakeClock(), credentials: MemoryCredentialStore = MemoryCredentialStore()
) -> ConnectionManager {
    ConnectionManager(
        drivers: [TVDriverFactory(platform: platform) { ScenarioDriver(scenario: scenario) }],
        credentials: credentials, clock: clock
    )
}

@Test func discoveryAndManualProbeExposeSetupStates() async throws {
    let m = manager(Scenario(discovery: [tv()]))
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .idle)
    var found: [TVDevice] = []
    for await device in m.discover() { found.append(device) }
    #expect(found == [tv()])
    #expect(await states.next() == .discovering)
    #expect(await states.next() == .idle)
    #expect(try await m.probe(tv().endpoint, platform: .roku) == tv())
}

@Test func reconnectFindsSameTVAtNewAddressAndCancelsOldAttempt() async throws {
    let new = tv("192.0.2.11")
    let different = tv("192.0.2.12", id: "different")
    let (gate, continuation) = AsyncStream.makeStream(of: Void.self)
    defer { continuation.finish() }
    let scenario = Scenario(discovery: [different, new], connectGate: gate)
    let clock = FakeClock()
    let m = manager(scenario, clock: clock)
    try await m.connect(tv())
    #expect(await m.currentDevice == new)
    #expect(await scenario.connects.contains(new.endpoint))
    #expect(await !scenario.connects.contains(different.endpoint))
    #expect(await clock.sleeps.isEmpty)
    try await m.reconnect()
    #expect(await m.currentDevice == new)
}

@Test func pairDeliversPromptPersistsCredentialAndReusesIt() async throws {
    let device = tv(platform: .googleTV)
    let store = MemoryCredentialStore()
    let credential = Credential.clientIdentity(Data([1, 2, 3]))
    let scenario = Scenario(pairingCredential: credential)
    let m = manager(scenario, platform: .googleTV, credentials: store)
    await #expect(throws: TVError.pairingRequired) { try await m.connect(device) }
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .needsRepair)
    try await m.pair(device) { prompt in
        #expect(prompt == .enterCode(length: 6))
        return .code("12A4BC")
    }
    #expect(await store.load(for: device.id) == credential)
    try await m.reconnect()
    #expect(await scenario.connectCredentials == [credential, credential])
}

@Test func commandRetriesOnceUsingFreshDriver() async throws {
    let scenario = Scenario(sends: [.unreachable, nil])
    let clock = FakeClock()
    let m = manager(scenario, clock: clock)
    try await m.connect(tv())
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .ready)
    try await m.send(.home)
    #expect(await states.next() == .degraded)
    #expect(await states.next() == .ready)
    #expect(await Set(scenario.commandSessions).count == 2)
    #expect(await clock.sleeps.isEmpty)
}

@Test func secondCommandFailureRecoversWithoutAnotherReplay() async throws {
    let scenario = Scenario(sends: [.unreachable, .timedOut])
    let clock = FakeClock()
    let m = manager(scenario, clock: clock)
    try await m.connect(tv())
    await #expect(throws: TVError.timedOut) { try await m.send(.volumeUp) }
    #expect(await scenario.commandSessions.count == 2)
    #expect(await clock.sleeps == [.milliseconds(250)])
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .ready)
}

@Test func backoffStopsAfterPlannedDelays() async {
    let clock = FakeClock()
    let scenario = Scenario(connects: [tv().endpoint.host: Array(repeating: .unreachable, count: 5)])
    let m = manager(scenario, clock: clock)
    await #expect(throws: TVError.unreachable) { try await m.connect(tv()) }
    #expect(await scenario.connects.count == 5)
    #expect(await clock.sleeps == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)])
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .degraded)
}

@Test func verifiedStandbyLeadsToAsleepAndAllowsExplicitWake() async throws {
    let tv = tv(capabilities: [.remoteKeys, .networkWake])
    let scenario = Scenario(connects: [tv.endpoint.host: [.asleep, .unreachable, .unreachable, .unreachable, .unreachable]])
    let m = manager(scenario)
    await #expect(throws: TVError.asleep) { try await m.connect(tv) }
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .asleep)
    #expect(await scenario.wakes == [tv.id])
    try await m.wake()
    #expect(await scenario.wakes == [tv.id, tv.id])
    #expect(await states.next() == .connecting)
    #expect(await states.next() == .recovering)
    #expect(await states.next() == .ready)
}

@Test func rejectedCredentialRequiresRepairWithoutRetry() async {
    let device = tv(platform: .googleTV)
    let clock = FakeClock()
    let store = MemoryCredentialStore()
    await store.save(.clientIdentity(Data([1])), for: device.id)
    let scenario = Scenario(connects: [device.endpoint.host: [.credentialRejected]])
    let m = manager(scenario, platform: .googleTV, clock: clock, credentials: store)
    await #expect(throws: TVError.credentialRejected) { try await m.connect(device) }
    #expect(await clock.sleeps.isEmpty)
    var states = m.state.makeAsyncIterator()
    #expect(await states.next() == .needsRepair)
}

@Test func missedKeepAliveRecoversAndDisconnectClearsSelection() async throws {
    let scenario = Scenario(sends: [.timedOut, nil])
    let m = manager(scenario)
    try await m.connect(tv())
    try await m.checkConnection()
    #expect(await Set(scenario.commandSessions).count == 2)
    await m.disconnect()
    await #expect(throws: TVError.notConnected) { try await m.reconnect() }
    #expect(await m.currentDevice == nil)
}
