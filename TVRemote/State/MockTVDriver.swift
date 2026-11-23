import Foundation

final class MockTVDriver {
    enum Command: Equatable {
        case key(RemoteKey)
        case app(AppID)
        case search(String)
        case wake(String)
        case pointer(Double, Double)
    }

    enum Failure: LocalizedError {
        case notConnected, incorrectCode, unknownAddress

        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect to a TV before sending a command."
            case .incorrectCode: "That code didn’t match. Try 123456 for the demo TV."
            case .unknownAddress: "No demo TV uses that address. Try 192.0.2.10 or 192.0.2.11."
            }
        }
    }

    static let demoCode = "123456"
    static let devices = [
        TVDevice(id: "living-room", name: "Living Room", platform: "Roku TV", address: "192.0.2.10"),
        TVDevice(id: "bedroom", name: "Bedroom", platform: "Google TV", address: "192.0.2.11",
                 requiresPairingCode: true, supportsPointer: true)
    ]

    let state: AsyncStream<ConnectionState>
    private let updates: AsyncStream<ConnectionState>.Continuation
    private let lock = NSLock()
    private var connectedDevice: TVDevice?
    private var log: [Command] = []

    var commands: [Command] { lock.withLock { log } }

    init() {
        (state, updates) = AsyncStream.makeStream()
    }

    deinit { updates.finish() }

    func discover() -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            for device in Self.devices { continuation.yield(device) }
            continuation.finish()
        }
    }

    func pair(_ tv: TVDevice) async throws -> String {
        guard !tv.requiresPairingCode else { throw Failure.incorrectCode }
        return tv.id
    }

    func pair(_ tv: TVDevice, code: String) async throws -> String {
        guard code == Self.demoCode else { throw Failure.incorrectCode }
        return tv.id
    }

    func connect(_ tv: TVDevice, _ cred: String) async throws {
        guard cred == tv.id else { throw Failure.incorrectCode }
        lock.withLock {
            connectedDevice = tv
            updates.yield(.ready)
        }
    }

    func disconnect() async {
        lock.withLock {
            connectedDevice = nil
            updates.yield(.idle)
        }
    }

    func device(at address: String) async throws -> TVDevice {
        guard let device = Self.devices.first(where: { $0.address == address }) else {
            throw Failure.unknownAddress
        }
        return device
    }

    func send(_ key: RemoteKey) async throws {
        try lock.withLock {
            guard connectedDevice != nil else { throw Failure.notConnected }
            log.append(.key(key))
            if key == .power {
                connectedDevice = nil
                updates.yield(.asleep)
            }
        }
    }

    func launch(_ app: AppID) async throws { try record(.app(app)) }
    func search(_ query: String) async throws { try record(.search(query)) }
    func movePointer(x: Double, y: Double) async throws { try record(.pointer(x, y)) }

    func wake(_ tv: TVDevice) async throws {
        lock.withLock {
            log.append(.wake(tv.id))
            connectedDevice = tv
            updates.yield(.ready)
        }
    }

    private func record(_ command: Command) throws {
        try lock.withLock {
            guard connectedDevice != nil else { throw Failure.notConnected }
            log.append(command)
        }
    }
}
