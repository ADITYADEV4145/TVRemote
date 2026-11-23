import Foundation

public struct TVDriverFactory: Sendable {
    public let platform: TVPlatform
    private let create: @Sendable () -> any TVDriver

    public init(platform: TVPlatform, make: @escaping @Sendable () -> any TVDriver) {
        self.platform = platform
        self.create = make
    }

    public func makeDriver() -> any TVDriver { create() }
}

public actor ConnectionManager {
    private let factories: [TVPlatform: TVDriverFactory]
    private let credentials: any CredentialStore
    private let clock: any ConnectionClock
    private let retryDelays: [Duration]
    private nonisolated let states = StateFeed()
    private var phase: ConnectionState = .idle
    private var activeBrowses = 0
    private var generation = UUID()
    private var driver: (any TVDriver)?
    private var commandInFlight = false

    public private(set) var currentDevice: TVDevice?
    public nonisolated var state: AsyncStream<ConnectionState> { states.subscribe() }
    public nonisolated var currentState: ConnectionState { states.latest }

    public init(
        drivers: [TVDriverFactory],
        credentials: any CredentialStore,
        clock: any ConnectionClock = SystemConnectionClock(),
        retryDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2)]
    ) {
        self.factories = Dictionary(drivers.map { ($0.platform, $0) }, uniquingKeysWith: { first, _ in first })
        self.credentials = credentials
        self.clock = clock
        self.retryDelays = retryDelays
    }

    public nonisolated func discover() -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let task = Task {
                await browse(into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func probe(_ endpoint: TVEndpoint, platform: TVPlatform) async throws -> TVDevice {
        try await factory(for: platform).makeDriver().probe(endpoint)
    }

    public func pair(
        _ tv: TVDevice,
        prompt: PairingPromptHandler = { _ in throw TVError.pairingRequired }
    ) async throws {
        let factory = try factory(for: tv.id.platform)
        let token = begin(tv: tv)
        do {
            let pairingDriver = factory.makeDriver()
            let credential = try await pairingDriver.pair(tv, prompt: prompt)
            try ensureCurrent(token)
            if credential != .none { try await credentials.save(credential, for: tv.id) }
            try ensureCurrent(token)
            try await pairingDriver.connect(tv, credential)
            let confirmed = await pairingDriver.connectedDevice()
            try ensureCurrent(token)
            markReady(driver: pairingDriver, tv: confirmed?.id == tv.id ? confirmed ?? tv : tv)
        } catch {
            fail(error, token: token)
            throw error
        }
    }

    public func connect(_ tv: TVDevice, allowWake: Bool = true) async throws {
        let factory = try factory(for: tv.id.platform)
        let token = begin(tv: tv)
        do {
            let credential = try await loadCredential(for: tv)
            try ensureCurrent(token)
            do {
                try await open(tv, credential: credential, factory: factory, token: token)
            } catch {
                guard Self.isRecoverable(error) else { throw error }
                try ensureCurrent(token)
                transition(.degraded)
                try await recover(tv, credential: credential, factory: factory, token: token,
                                  attemptWake: allowWake, initialError: error)
            }
        } catch {
            fail(error, token: token)
            throw error
        }
    }

    public func reconnect() async throws {
        guard let currentDevice else { throw TVError.notConnected }
        try await connect(currentDevice)
    }

    public func disconnect() {
        generation = UUID()
        driver = nil
        currentDevice = nil
        commandInFlight = false
        transition(activeBrowses > 0 ? .discovering : .idle)
    }

    public func send(_ key: RemoteKey) async throws {
        let replay: Bool
        if case .text = key { replay = false } else { replay = true }
        try await perform(replay: replay, standbyIsSuccess: key == .powerOff) { try await $0.send(key) }
    }

    public func launch(_ app: AppID) async throws {
        try await perform { try await $0.launch(app) }
    }

    public func search(_ query: String) async throws {
        try await perform { try await $0.search(query) }
    }

    public func checkConnection() async throws {
        try await perform { try await $0.keepAlive() }
    }

    public func inputs() async throws -> [TVInput] {
        try await read { try await $0.inputs() }
    }

    public func apps() async throws -> [TVApp] {
        try await read { try await $0.apps() }
    }

    public func selectInput(_ input: TVInput) async throws {
        try await perform { try await $0.selectInput(input) }
    }

    private func read<T: Sendable>(_ operation: @Sendable (any TVDriver) async throws -> T) async throws -> T {
        guard phase == .ready, let driver else { throw TVError.notConnected }
        guard !commandInFlight else { throw TVError.busy }
        let token = generation
        commandInFlight = true
        defer { if generation == token { commandInFlight = false } }
        let value = try await operation(driver)
        try ensureCurrent(token)
        return value
    }

    public func wake() async throws {
        guard let tv = currentDevice else { throw TVError.notConnected }
        if tv.capabilities.contains(.controlWake), !tv.capabilities.contains(.networkWake) {
            let token = generation
            if phase == .connecting || phase == .recovering {
                for await _ in state {
                    try ensureCurrent(token)
                    if phase != .connecting && phase != .recovering { break }
                }
                try ensureCurrent(token)
                switch phase {
                case .ready: break
                case .needsRepair: throw TVError.pairingRequired
                case .asleep: throw TVError.asleep
                default: throw TVError.unreachable
                }
            }
            try await send(.powerOn)
            return
        }
        guard tv.capabilities.contains(.networkWake) else { throw TVError.notSupported }
        let factory = try factory(for: tv.id.platform)
        let isReconnecting = phase == .connecting || phase == .recovering
        if isReconnecting {
            let token = generation
            try await factory.makeDriver().wake(tv)
            try ensureCurrent(token)
            guard phase == .asleep || phase == .degraded else { return }
        }
        let token = begin(tv: tv)
        do {
            let credential = try await loadCredential(for: tv)
            try ensureCurrent(token)
            if !isReconnecting {
                try await factory.makeDriver().wake(tv)
                try ensureCurrent(token)
            }
            try await recover(tv, credential: credential, factory: factory, token: token, attemptWake: false)
        } catch {
            fail(error, token: token, fallback: .asleep)
            throw error
        }
    }

    private func browse(into continuation: AsyncStream<TVDevice>.Continuation) async {
        activeBrowses += 1
        if phase == .idle { transition(.discovering) }
        defer {
            activeBrowses -= 1
            if activeBrowses == 0 && phase == .discovering { transition(.idle) }
        }

        await withTaskGroup(of: Void.self) { group in
            for factory in factories.values {
                group.addTask {
                    for await tv in factory.makeDriver().discover() {
                        guard !Task.isCancelled else { break }
                        continuation.yield(tv)
                    }
                }
            }
        }
    }

    private func perform(
        replay: Bool = true, standbyIsSuccess: Bool = false,
        _ operation: @Sendable (any TVDriver) async throws -> Void
    ) async throws {
        guard let selected = currentDevice else { throw TVError.notConnected }
        guard !commandInFlight, phase != .connecting, phase != .recovering else { throw TVError.busy }
        if phase == .needsRepair && !standbyIsSuccess { throw TVError.pairingRequired }
        let token = generation
        commandInFlight = true
        defer {
            if generation == token { commandInFlight = false }
        }

        if phase != .ready {
            transition(.connecting)
            do {
                let factory = try factory(for: selected.id.platform)
                let credential = try await loadCredential(for: selected)
                try ensureCurrent(token)
                try await open(selected, credential: credential, factory: factory, token: token)
            } catch {
                fail(error, token: token)
                try ensureCurrent(token)
                if standbyIsSuccess && error as? TVError == .asleep { return }
                throw error
            }
        }

        guard let tv = currentDevice, let driver else { throw TVError.notConnected }
        do {
            try await operation(driver)
            try ensureCurrent(token)
        } catch {
            try ensureCurrent(token)
            if error as? TVError == .asleep {
                fail(error, token: token)
                if standbyIsSuccess { return }
                throw error
            }
            guard Self.isRecoverable(error) else {
                if error as? TVError == .credentialRejected || error as? TVError == .pairingRequired {
                    fail(error, token: token)
                }
                throw error
            }
            transition(.degraded)
            self.driver = nil
            do {
                let factory = try factory(for: tv.id.platform)
                let credential = try await loadCredential(for: tv)
                try ensureCurrent(token)
                guard replay else {
                    try await recover(
                        tv, credential: credential, factory: factory, token: token, attemptWake: false, initialError: error
                    )
                    throw error
                }
                do {
                    let fresh = factory.makeDriver()
                    try await fresh.connect(tv, credential)
                    let confirmed = await fresh.connectedDevice()
                    let device = confirmed?.id == tv.id ? confirmed ?? tv : tv
                    try ensureCurrent(token)
                    do {
                        try await operation(fresh)
                        try ensureCurrent(token)
                        markReady(driver: fresh, tv: device)
                    } catch {
                        if let failure = error as? TVError, !Self.isRecoverable(failure),
                           failure != .credentialRejected, failure != .pairingRequired {
                            try ensureCurrent(token)
                            markReady(driver: fresh, tv: device)
                        }
                        throw error
                    }
                } catch {
                    guard Self.isRecoverable(error), error as? TVError != .asleep else { throw error }
                    try ensureCurrent(token)
                    try await recover(
                        tv, credential: credential, factory: factory, token: token, attemptWake: false, initialError: error
                    )
                    throw error
                }
            } catch {
                if phase != .ready { fail(error, token: token) }
                if standbyIsSuccess && error as? TVError == .asleep { return }
                throw error
            }
        }
    }

    private func recover(
        _ tv: TVDevice, credential: Credential, factory: TVDriverFactory, token: UUID,
        attemptWake: Bool = true, initialError: any Error = TVError.unreachable
    ) async throws {
        try ensureCurrent(token)
        transition(.recovering)
        let wakeTarget = currentDevice ?? tv
        if attemptWake && wakeTarget.capabilities.contains(.networkWake) {
            let wakeDriver = factory.makeDriver()
            _ = try? await wakeDriver.wake(wakeTarget)
            try ensureCurrent(token)
        }

        var lastError = initialError
        var foundAsleep = initialError as? TVError == .asleep
        for delay in retryDelays {
            try await clock.sleep(for: delay)
            try ensureCurrent(token)
            do {
                try await open(currentDevice ?? tv, credential: credential, factory: factory, token: token)
                return
            } catch {
                guard Self.isRecoverable(error) else { throw error }
                try ensureCurrent(token)
                if error as? TVError == .asleep { foundAsleep = true }
                lastError = error
            }
        }
        if foundAsleep { throw TVError.asleep }
        throw lastError
    }

    private func open(
        _ tv: TVDevice, credential: Credential, factory: TVDriverFactory, token: UUID
    ) async throws {
        let (outcome, standby) = await withTaskGroup(of: Attempt.self) { group in
            group.addTask { await Self.attempt(tv, credential: credential, factory: factory) }
            group.addTask {
                let browser = factory.makeDriver()
                var standby: TVDevice?
                for await candidate in browser.discover() {
                    if Task.isCancelled { break }
                    guard candidate.id == tv.id, candidate.endpoint != tv.endpoint else { continue }
                    let attempt = await Self.attempt(candidate, credential: credential, factory: factory)
                    switch attempt {
                    case .standby(let device): standby = device
                    case .failure(let error) where Self.isRecoverable(error): continue
                    default: return attempt
                    }
                }
                return standby.map(Attempt.standby) ?? .noCandidate
            }

            var failure: any Error = TVError.unreachable
            var standby: TVDevice?
            for await attempt in group {
                switch attempt {
                case .ready:
                    group.cancelAll()
                    return (attempt, standby)
                case .standby(let device):
                    if standby == nil || device.endpoint != tv.endpoint { standby = device }
                    if Self.failurePriority(failure) < Self.failurePriority(TVError.asleep) { failure = TVError.asleep }
                case .failure(let error):
                    if Self.failurePriority(error) >= Self.failurePriority(failure) { failure = error }
                case .noCandidate:
                    break
                }
            }
            return (Attempt.failure(failure), standby)
        }
        try ensureCurrent(token)
        switch outcome {
        case .ready(let driver, let device): markReady(driver: driver, tv: device)
        case .failure(let error):
            if let standby { currentDevice = standby }
            throw error
        case .standby, .noCandidate: throw TVError.unreachable
        }
    }

    private enum Attempt: Sendable {
        case ready(any TVDriver, TVDevice)
        case standby(TVDevice)
        case failure(any Error)
        case noCandidate
    }

    private nonisolated static func attempt(
        _ tv: TVDevice, credential: Credential, factory: TVDriverFactory
    ) async -> Attempt {
        let driver = factory.makeDriver()
        do {
            try await driver.connect(tv, credential)
            let confirmed = await driver.connectedDevice()
            try Task.checkCancellation()
            return .ready(driver, confirmed?.id == tv.id ? confirmed ?? tv : tv)
        } catch {
            if error as? TVError == .asleep { return .standby(tv) }
            return .failure(error)
        }
    }

    private nonisolated static func failurePriority(_ error: any Error) -> Int {
        switch error as? TVError {
        case .credentialRejected, .pairingRequired: 3
        case .asleep: 2
        default: 1
        }
    }

    private nonisolated static func isRecoverable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let error = error as? TVError else { return true }
        switch error {
        case .timedOut, .unreachable, .asleep, .identityMismatch, .notConnected, .invalidResponse:
            return true
        case .requestFailed(let status):
            return status >= 500
        default:
            return false
        }
    }

    private func loadCredential(for tv: TVDevice) async throws -> Credential {
        if tv.id.platform == .roku { return .none }
        if let credential = try await credentials.load(for: tv.id) { return credential }
        throw TVError.pairingRequired
    }

    private func factory(for platform: TVPlatform) throws -> TVDriverFactory {
        guard let factory = factories[platform] else { throw TVError.notSupported }
        return factory
    }

    private func begin(tv: TVDevice) -> UUID {
        generation = UUID()
        currentDevice = tv
        driver = nil
        commandInFlight = false
        transition(.connecting)
        return generation
    }

    private func ensureCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func markReady(driver: any TVDriver, tv: TVDevice) {
        self.driver = driver
        currentDevice = tv
        transition(.ready)
    }

    private func fail(_ error: any Error, token: UUID, fallback: ConnectionState = .degraded) {
        guard generation == token else { return }
        driver = nil
        switch error as? TVError {
        case .credentialRejected, .pairingRequired: transition(.needsRepair)
        case .asleep: transition(.asleep)
        default:
            transition(error is CancellationError ? .idle : fallback)
        }
    }

    private func transition(_ state: ConnectionState) {
        phase = state
        states.publish(state)
    }
}
