import Foundation
import TVRemoteKit

typealias AppID = TVRemoteCore.AppID

@MainActor
final class LiveTVSession {
    typealias Device = TVRemoteCore.TVDevice
    let manager: TVRemoteCore.ConnectionManager
    let credentials: any CredentialStore
    private var known: [String: Device] = [:]
    private let defaults: UserDefaults
    private let savedKey = "TVRemoteKit.savedDevices"

    init(defaults: UserDefaults = .standard,
         credentials: any CredentialStore = TVRemoteKit.defaultCredentialStore(),
         manager: TVRemoteCore.ConnectionManager? = nil) {
        self.defaults = defaults
        self.credentials = credentials
        self.manager = manager ?? TVRemoteKit.makeManager(
            discovery: LocalDiscoverySource(enableSubnetProbe: true),
            credentials: credentials
        )
        for device in stored { known[Self.id(device)] = device }
    }

    private var stored: [Device] {
        guard let data = defaults.data(forKey: savedKey) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    var savedDevices: [TVDevice] { stored.map(Self.presentation) }
    var state: AsyncStream<TVRemoteCore.ConnectionState> { manager.state }
    func device(_ id: String) -> Device? { known[id] }

    func remember(_ device: Device) -> TVDevice {
        known[Self.id(device)] = device
        return Self.presentation(device)
    }

    func save(_ device: Device) -> TVDevice {
        var devices = stored
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            guard devices[index] != device else { return remember(device) }
            devices[index] = device
        } else { devices.append(device) }
        defaults.set(try? JSONEncoder().encode(devices), forKey: savedKey)
        return remember(device)
    }

    func forget(_ id: String) async throws {
        guard let device = known[id] else { return }
        try await credentials.remove(for: device.id)
        defaults.set(try? JSONEncoder().encode(stored.filter { $0.id != device.id }), forKey: savedKey)
    }

    func find(_ address: String) async throws -> TVDevice {
        guard let parts = URLComponents(string: "http://\(address)"), let host = parts.host,
              !host.isEmpty, parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil else { throw Failure.address }
        let candidates: [(TVPlatform, UInt16)]
        if let port = parts.port {
            guard let value = UInt16(exactly: port),
                  let platform = switchPort(value) else { throw Failure.address }
            candidates = [(platform, value)]
        } else {
            candidates = [(.roku, 8060), (.googleTV, 6466), (.samsung, 8002), (.lg, 3001)]
        }
        let device = await withTaskGroup(of: Device?.self) { group -> Device? in
            for (platform, port) in candidates {
                group.addTask { [manager] in
                    try? await manager.probe(TVEndpoint(host: host, port: port), platform: platform)
                }
            }
            for await candidate in group {
                if let candidate { group.cancelAll(); return candidate }
            }
            return nil
        }
        guard let device else { throw Failure.notFound }
        return remember(device)
    }

    private func switchPort(_ port: UInt16) -> TVPlatform? {
        switch port {
        case 8060: .roku
        case 6466, 6467: .googleTV
        case 8001, 8002: .samsung
        case 3000, 3001: .lg
        default: nil
        }
    }

    private static func id(_ device: Device) -> String { "\(device.id.platform.rawValue):\(device.id.identifier)" }

    private static func presentation(_ device: Device) -> TVDevice {
        let platform: String
        switch device.id.platform {
        case .roku: platform = "Roku TV"
        case .googleTV: platform = "Google TV"
        case .samsung: platform = "Samsung TV"
        case .lg: platform = "LG webOS"
        }
        return TVDevice(id: id(device), name: device.name, platform: platform, address: device.endpoint.host,
                        requiresPairingCode: device.id.platform == .googleTV)
    }

    enum Failure: LocalizedError {
        case address, notFound

        var errorDescription: String? {
            switch self {
            case .address: "Enter a TV’s IP address, optionally followed by its control port."
            case .notFound: "No supported TV responded at that address. Check your network and try again."
            }
        }
    }
}

extension RemoteKey {
    var wireKey: TVRemoteCore.RemoteKey {
        switch self {
        case .power: .power
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .select: .ok
        case .back: .back
        case .home: .home
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        case .mute: .mute
        case .channelUp: .channelUp
        case .channelDown: .channelDown
        case .playPause: .playPause
        }
    }
}

extension ConnectionState {
    init(_ state: TVRemoteCore.ConnectionState) {
        switch state {
        case .idle: self = .idle
        case .discovering: self = .discovering
        case .connecting: self = .connecting
        case .ready: self = .ready
        case .degraded: self = .degraded
        case .asleep: self = .asleep
        case .recovering: self = .recovering
        case .needsRepair: self = .needsRepair
        }
    }
}
