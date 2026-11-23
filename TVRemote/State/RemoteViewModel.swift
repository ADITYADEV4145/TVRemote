import Foundation
import Observation
import TVRemoteKit

@MainActor
@Observable
final class RemoteViewModel {
    struct RecentCommand: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let title: String
        let deviceID: TVDevice.ID?
    }

    private(set) var state: ConnectionState = .idle
    private(set) var devices: [TVDevice] = []
    private(set) var savedDevices: [TVDevice] = []
    private(set) var currentDevice: TVDevice?
    private(set) var pairingDevice: TVDevice?
    private(set) var pairingPrompt: SetupPairing?
    private(set) var pairingCompletion = 0
    private(set) var isDiscovering = false
    private(set) var isConnecting = false
    private(set) var feedback: String?
    private(set) var error: String?
    private(set) var recentCommands: [RecentCommand] = []

    let isDemo: Bool
    private let driver: MockTVDriver?
    private let live: LiveTVSession?
    #if DEBUG
    var approvalResponseDelay: Duration?
    #endif
    private var demoCredentials: [TVDevice.ID: String] = [:]
    private var unavailableChannelTVs: Set<TVDevice.ID> = []
    private var keyboardDrafts: [TVDevice.ID: String] = [:]
    private var messageGeneration = 0
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var pairingTask: Task<Bool, Never>?
    @ObservationIgnored private var codeReply: CheckedContinuation<PairingResponse, any Error>?
    @ObservationIgnored private var pairingAttempt = UUID()
    @ObservationIgnored private var commandTail: Task<Void, Never>?
    @ObservationIgnored private var commandSequence = 0
    @ObservationIgnored private var selectionGeneration = 0
    @ObservationIgnored private var healthCheck: Task<Void, Never>?

    init(driver: MockTVDriver, isDemo: Bool = true) {
        self.driver = driver
        live = nil
        self.isDemo = isDemo
        let updates = driver.state
        stateTask = Task { [weak self] in
            for await update in updates { self?.state = update }
        }
    }

    init(live: LiveTVSession) {
        self.live = live
        driver = nil
        isDemo = false
        savedDevices = live.savedDevices
        let updates = live.state
        stateTask = Task { [weak self] in
            for await update in updates { self?.state = ConnectionState(update) }
        }
    }

    deinit { stateTask?.cancel() }

    var canControl: Bool { state == .ready && currentDevice != nil && !isConnecting }
    var canChangeChannel: Bool {
        canControl && currentDevice.map { !unavailableChannelTVs.contains($0.id) } == true
    }
    var supportsInputMenu: Bool { capabilities.contains(.inputMenu) }
    var supportsInputSelection: Bool { capabilities.contains(.inputSelection) }
    var supportsAppList: Bool { capabilities.contains(.appList) }
    var supportsAppLinks: Bool {
        capabilities.contains(.launch) && currentDevice.flatMap { live?.device($0.id)?.id.platform } == .googleTV
    }

    private var capabilities: TVCapabilities {
        guard let id = currentDevice?.id else { return [] }
        return live?.device(id)?.capabilities ?? []
    }
    var canSearch: Bool {
        canControl && supportsSearch
    }
    var supportsSearch: Bool { driver != nil || capabilities.contains(.search) }
    var supportsTyping: Bool { capabilities.contains(.keyboard) && !supportsSearch }
    var keyboardDraft: String {
        get { currentDevice.flatMap { keyboardDrafts[$0.id] } ?? "" }
        set { if let id = currentDevice?.id { keyboardDrafts[id] = newValue } }
    }
    var canPower: Bool { canControl || (!isConnecting && canWake) }
    private var canWake: Bool {
        guard let device = currentDevice else { return false }
        if live == nil { return state == .asleep }
        guard state == .asleep || state == .degraded else { return false }
        return live?.device(device.id)?.capabilities.intersection([.networkWake, .controlWake]).isEmpty == false
    }
    var supportsPointer: Bool { currentDevice?.supportsPointer == true && driver != nil }
    var supportsManualAddress: Bool { true }
    var awaitingTVApproval: Bool { pairingPrompt == .approval && isConnecting }

    func monitor(clock: any ConnectionClock = SystemConnectionClock()) async {
        guard let live else { return }
        while !Task.isCancelled {
            do { try await clock.sleep(for: .seconds(2)) } catch { return }
            guard currentDevice != nil, !isConnecting, state == .ready || state == .degraded,
                  commandTail == nil, healthCheck == nil else { continue }
            let check = Task {
                try? await live.manager.checkConnection()
                if let device = await live.manager.currentDevice, currentDevice != nil, !isConnecting {
                    currentDevice = live.save(device)
                    savedDevices = live.savedDevices
                }
            }
            healthCheck = check
            await check.value
            healthCheck = nil
        }
    }

    func clearMessages() {
        messageGeneration += 1
        feedback = nil
        error = nil
    }

    #if DEBUG
    // Explicit design fixtures, never compiled into a Release build.
    func prepareDesignPreview(state: ConnectionState = .ready, pairing: Bool = false) async {
        await discover()
        guard devices.count >= 2 else { return }
        _ = await select(devices[1])
        _ = await submit(code: MockTVDriver.demoCode)
        _ = await select(devices[0])
        if pairing {
            await forget(devices[1])
            _ = await select(devices[1])
        }
        // Let the driver's last connection notification drain before selecting a fixture state.
        await Task.yield()
        self.state = state
        clearMessages()
    }
    #endif

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        if let live {
            for await device in live.manager.discover() { show(live.remember(device)) }
        } else if let driver {
            for await device in driver.discover() { show(device) }
        }
    }

    private func show(_ device: TVDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
    }

    func find(address: String) async -> Bool {
        guard !isConnecting else { return false }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        error = nil
        let device: TVDevice
        isConnecting = true
        do {
            if let live { device = try await live.find(address) }
            else if let driver { device = try await driver.device(at: address) }
            else { return false }
        } catch {
            self.error = error.localizedDescription
            isConnecting = false
            return false
        }
        isConnecting = false
        return await select(device)
    }

    func select(_ device: TVDevice) async -> Bool {
        guard !isConnecting else { return false }
        selectionGeneration += 1
        cancelPairing()
        pairingDevice = nil
        error = nil
        if let live { return await selectLive(device, using: live) }
        if device.requiresPairingCode, demoCredentials[device.id] == nil {
            pairingDevice = device
            pairingPrompt = .code
            return false
        }
        return await connect(device, code: nil)
    }

    func submit(code: String) async -> Bool {
        guard let device = pairingDevice, !isConnecting else { return false }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let live, let selected = live.device(device.id) {
            guard let reply = codeReply else {
                startPairing(device, selected: selected, using: live)
                return false
            }
            codeReply = nil
            isConnecting = true
            reply.resume(returning: .code(code))
            return await pairingTask?.value ?? false
        }
        return await connect(device, code: code)
    }

    func cancelPairing() {
        if pairingTask != nil {
            pairingAttempt = UUID()
            pairingTask?.cancel()
            pairingTask = nil
            codeReply?.resume(throwing: CancellationError())
            codeReply = nil
            isConnecting = false
            if live != nil {
                currentDevice = nil
                state = .idle
            }
        }
        pairingDevice = nil
        pairingPrompt = nil
        error = nil
    }

    func reconnect() async -> Bool {
        guard let device = currentDevice else { return false }
        if state == .needsRepair { demoCredentials.removeValue(forKey: device.id) }
        return await select(devices.first(where: { $0.id == device.id }) ?? device)
    }

    func forget(_ device: TVDevice) async {
        keyboardDrafts.removeValue(forKey: device.id)
        guard !isConnecting else { return }
        if let live {
            do { try await live.forget(device.id) }
            catch { self.error = error.localizedDescription; return }
        }
        demoCredentials.removeValue(forKey: device.id)
        savedDevices.removeAll { $0.id == device.id }
        if pairingDevice?.id == device.id { cancelPairing() }
        guard currentDevice?.id == device.id else { return }

        selectionGeneration += 1
        isConnecting = true
        currentDevice = nil
        state = .idle
        clearMessages()
        if let live { await live.manager.disconnect() }
        else { await driver?.disconnect() }
        isConnecting = false
    }

    func send(_ key: RemoteKey) async {
        let changesChannel = key == .channelUp || key == .channelDown
        if changesChannel && !canChangeChannel { return }
        if key == .power, canWake, !isConnecting, let device = currentDevice {
            await perform("Wake TV", feedback: "Waking \(device.name)") { [self] in
                if let live {
                    if live.device(device.id)?.capabilities.contains(.controlWake) == true {
                        try await live.manager.send(.powerOn)
                    } else {
                        try await live.manager.wake()
                    }
                } else {
                    try await driver?.wake(device)
                }
            }
        } else if canControl {
            await perform(key.commandTitle) { [self] in
                guard !changesChannel || canChangeChannel else { throw TVError.notSupported }
                let deviceID = currentDevice?.id
                do {
                    if let live { try await live.manager.send(key.wireKey) }
                    else { try await driver?.send(key) }
                } catch TVError.notSupported where changesChannel {
                    if let deviceID { unavailableChannelTVs.insert(deviceID) }
                    throw TVError.notSupported
                }
            }
        }
    }

    func launch(_ app: AppID, name: String) async {
        guard canControl else { return }
        await perform(isDemo ? "Open \(name)" : "Open app", feedback: "Opening \(name)") { [self] in
            if let live { try await live.manager.launch(app) }
            else { try await driver?.launch(app) }
        }
    }

    func loadInputs() async throws -> [TVInput] {
        guard canControl, supportsInputSelection, let live else { throw TVError.notSupported }
        await healthCheck?.value
        return try await live.manager.inputs()
    }

    func loadApps() async throws -> [TVApp] {
        guard canControl, supportsAppList, let live else { throw TVError.notSupported }
        await healthCheck?.value
        return try await live.manager.apps()
    }

    func selectInput(_ input: TVInput) async {
        guard canControl, supportsInputSelection, let live else { return }
        await perform("Switch input") { try await live.manager.selectInput(input) }
    }

    func openTVInputMenu() async {
        guard canControl, supportsInputMenu, let live else { return }
        await perform("Open TV input menu") { try await live.manager.send(.inputMenu) }
    }

    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSearch, !query.isEmpty else { return }
        await perform("TV search", feedback: "Search sent to TV") { [self] in
            if let live { try await live.manager.search(query) }
            else { try await driver?.search(query) }
        }
    }

    func typeOnTV(_ text: String) async {
        guard canControl, supportsTyping, !text.isEmpty, let live else { return }
        await perform("Type on TV", feedback: "Text sent to TV") {
            try await live.manager.send(.text(text))
        }
    }

    func movePointer(x: Double, y: Double) async {
        guard canControl, supportsPointer, let pointer = driver else { return }
        await perform("Move pointer") { try await pointer.movePointer(x: x, y: y) }
    }

    private func connect(_ device: TVDevice, code: String?) async -> Bool {
        guard let driver else { return false }
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            let credential: String
            if let saved = demoCredentials[device.id] {
                credential = saved
            } else if let code {
                credential = try await driver.pair(device, code: code)
            } else {
                credential = try await driver.pair(device)
            }
            try await driver.connect(device, credential)
            demoCredentials[device.id] = credential
            currentDevice = device
            if let index = savedDevices.firstIndex(where: { $0.id == device.id }) {
                savedDevices[index] = device
            } else {
                savedDevices.append(device)
            }
            pairingDevice = nil
            pairingPrompt = nil
            feedback = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func selectLive(_ device: TVDevice, using live: LiveTVSession) async -> Bool {
        guard let selected = live.device(device.id) else { return false }
        isConnecting = true
        if currentDevice?.id != device.id { currentDevice = nil }
        do {
            try await live.manager.connect(selected)
            await didConnect(using: live)
            isConnecting = false
            return true
        } catch TVError.pairingRequired {
            startPairing(device, selected: selected, using: live)
        } catch TVError.credentialRejected {
            startPairing(device, selected: selected, using: live)
        } catch {
            self.error = Self.describe(error)
            isConnecting = false
        }
        return false
    }

    private func startPairing(_ device: TVDevice, selected: LiveTVSession.Device,
                              using live: LiveTVSession, message: String? = nil) {
        let attempt = UUID()
        pairingAttempt = attempt
        isConnecting = true
        pairingPrompt = nil
        error = message
        pairingTask = Task { [weak self] in
            do {
                try await live.manager.pair(selected) { [weak self] prompt in
                    guard let self else { throw CancellationError() }
                    return try await self.respond(to: prompt, device: device, attempt: attempt)
                }
                guard let self, self.pairingAttempt == attempt else { return false }
                let needsCompletionEvent = self.pairingPrompt != .code
                await self.didConnect(using: live)
                if needsCompletionEvent { self.pairingCompletion += 1 }
                self.isConnecting = false
                self.pairingTask = nil
                return true
            } catch {
                guard let self, self.pairingAttempt == attempt else { return false }
                self.isConnecting = false
                self.pairingTask = nil
                let failure = error as? TVError
                if self.pairingPrompt == .code, failure == .credentialRejected || failure == .invalidCommand {
                    self.startPairing(device, selected: selected, using: live,
                                      message: "That code didn’t match. Check the new code shown on your TV.")
                } else {
                    self.error = Self.describe(error)
                }
                return false
            }
        }
    }

    private func respond(to prompt: PairingPrompt, device: TVDevice, attempt: UUID) async throws -> PairingResponse {
        try Task.checkCancellation()
        guard pairingAttempt == attempt else { throw CancellationError() }
        pairingDevice = device
        switch prompt {
        case .approveOnTV:
            pairingPrompt = .approval
            #if DEBUG
            if let approvalResponseDelay { try await Task.sleep(for: approvalResponseDelay) }
            #endif
            return .acknowledged
        case .enterCode:
            pairingPrompt = .code
            isConnecting = false
            return try await withCheckedThrowingContinuation { codeReply = $0 }
        }
    }

    private func didConnect(using live: LiveTVSession) async {
        guard let connected = await live.manager.currentDevice else { return }
        currentDevice = live.save(connected)
        savedDevices = live.savedDevices
        state = .ready
        pairingDevice = nil
        pairingPrompt = nil
        feedback = nil
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? TVError {
        case .invalidCommand: "That code didn’t match. Check the code shown on your TV."
        case .timedOut, .unreachable: "The TV didn’t respond. Check that it is on and connected."
        case .notSupported: "This command isn’t available for this connection."
        case .credentialRejected, .pairingRequired: "Pair again with the TV to continue."
        default: error.localizedDescription
        }
    }

    private func perform(_ command: String, feedback message: String? = nil,
                         action: @escaping @MainActor () async throws -> Void) async {
        let previous = commandTail
        let selection = selectionGeneration
        commandSequence += 1
        let sequence = commandSequence
        let task = Task {
            await previous?.value
            guard selectionGeneration == selection else { return }
            await runCommand(command, feedback: message, action: action)
        }
        commandTail = task
        await task.value
        if commandSequence == sequence { commandTail = nil }
    }

    private func runCommand(_ command: String, feedback message: String?,
                            action: @MainActor () async throws -> Void) async {
        let selection = selectionGeneration
        await healthCheck?.value
        guard selectionGeneration == selection, !isConnecting else { return }
        let generation = messageGeneration
        let deviceID = currentDevice?.id
        error = nil
        do {
            try await action()
            recentCommands.insert(RecentCommand(title: command, deviceID: deviceID), at: 0)
            if recentCommands.count > 20 { recentCommands.removeLast() }
            if messageGeneration == generation { feedback = message }
        } catch {
            guard messageGeneration == generation else { return }
            feedback = nil
            self.error = Self.describe(error)
        }
    }
}

private extension RemoteKey {
    var commandTitle: String {
        switch self {
        case .select: "OK"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .channelUp: "Channel up"
        case .channelDown: "Channel down"
        case .playPause: "Play or pause"
        default: rawValue.capitalized
        }
    }
}
