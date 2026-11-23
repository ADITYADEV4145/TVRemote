import Foundation
import Observation
import TVDriverKit

@MainActor
@Observable
final class ConnectionManager {
    private(set) var state: ConnectionState = .idle
    private(set) var devices: [TVDevice] = []
    private(set) var savedDevices: [TVDevice] = []
    private(set) var currentDevice: TVDevice?
    private(set) var pairingDevice: TVDevice?
    private(set) var isDiscovering = false
    private(set) var isConnecting = false
    private(set) var feedback: String?
    private(set) var error: String?

    let isDemo: Bool
    private let driver: any TVDriver
    private var credentials: [TVDevice.ID: Credential] = [:]
    @ObservationIgnored private var stateTask: Task<Void, Never>?

    init(driver: any TVDriver, isDemo: Bool = false) {
        self.driver = driver
        self.isDemo = isDemo
        let updates = driver.state
        stateTask = Task { [weak self] in
            for await update in updates { self?.state = update }
        }
    }

    deinit { stateTask?.cancel() }

    var canControl: Bool { state == .ready && currentDevice != nil && !isConnecting }
    var canPower: Bool { !isConnecting && currentDevice != nil && (state == .ready || state == .asleep) }
    var supportsPointer: Bool { currentDevice?.supportsPointer == true && driver is any PointerDriver }
    var supportsManualAddress: Bool { driver is any ManualAddressDriver }

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        for await device in driver.discover() {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                devices[index] = device
            } else {
                devices.append(device)
            }
        }
    }

    func find(address: String) async -> Bool {
        guard let lookup = driver as? any ManualAddressDriver, !isConnecting else { return false }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return false }
        error = nil
        let device: TVDevice
        isConnecting = true
        do {
            device = try await lookup.device(at: address)
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
        pairingDevice = nil
        error = nil
        if device.requiresPairingCode, credentials[device.id] == nil,
           driver is any PairingCodeDriver {
            pairingDevice = device
            return false
        }
        return await connect(device, code: nil)
    }

    func submit(code: String) async -> Bool {
        guard let device = pairingDevice, !isConnecting else { return false }
        return await connect(device, code: code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func cancelPairing() {
        guard !isConnecting else { return }
        pairingDevice = nil
        error = nil
    }

    func reconnect() async -> Bool {
        guard let device = currentDevice else { return false }
        if state == .needsRepair { credentials.removeValue(forKey: device.id) }
        return await select(devices.first(where: { $0.id == device.id }) ?? device)
    }

    func send(_ key: RemoteKey) async {
        if key == .power, state == .asleep, !isConnecting, let device = currentDevice {
            await perform("Waking \(device.name)") { try await driver.wake(device) }
        } else if canControl {
            await perform(nil) { try await driver.send(key) }
        }
    }

    func launch(_ app: AppID, name: String) async {
        guard canControl else { return }
        await perform("Opening \(name)") { try await driver.launch(app) }
    }

    func search(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canControl, !query.isEmpty else { return }
        await perform("Search sent to TV") { try await driver.search(query) }
    }

    func movePointer(x: Double, y: Double) async {
        guard canControl, supportsPointer, let pointer = driver as? any PointerDriver else { return }
        await perform(nil) { try await pointer.movePointer(x: x, y: y) }
    }

    private func connect(_ device: TVDevice, code: String?) async -> Bool {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        do {
            let credential: Credential
            if let saved = credentials[device.id] {
                credential = saved
            } else if let code, let pairing = driver as? any PairingCodeDriver {
                credential = try await pairing.pair(device, code: code)
            } else {
                credential = try await driver.pair(device)
            }
            try await driver.connect(device, credential)
            credentials[device.id] = credential
            currentDevice = device
            if let index = savedDevices.firstIndex(where: { $0.id == device.id }) {
                savedDevices[index] = device
            } else {
                savedDevices.append(device)
            }
            pairingDevice = nil
            feedback = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func perform(_ message: String?, action: () async throws -> Void) async {
        error = nil
        do {
            try await action()
            feedback = message
        } catch {
            feedback = nil
            self.error = error.localizedDescription
        }
    }
}
