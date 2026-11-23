public protocol TVDriver {
    func discover() -> AsyncStream<TVDevice>
    func pair(_ tv: TVDevice) async throws -> Credential
    func connect(_ tv: TVDevice, _ cred: Credential) async throws
    func send(_ key: RemoteKey) async throws
    func launch(_ app: AppID) async throws
    func search(_ query: String) async throws
    func wake(_ tv: TVDevice) async throws
    var state: AsyncStream<ConnectionState> { get }
}

public struct TVDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let address: String
    public let requiresPairingCode: Bool
    public let supportsPointer: Bool

    public init(id: String, name: String, platform: String, address: String,
                requiresPairingCode: Bool = false, supportsPointer: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.address = address
        self.requiresPairingCode = requiresPairingCode
        self.supportsPointer = supportsPointer
    }
}

public struct Credential: Equatable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public enum RemoteKey: String, Equatable, Sendable {
    case power, up, down, left, right, select, back, home
    case volumeUp, volumeDown, mute, channelUp, channelDown, playPause
}

public struct AppID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ConnectionState: String, Equatable, Sendable {
    case idle = "Not connected"
    case discovering = "Finding TVs"
    case connecting = "Connecting"
    case ready = "Connected"
    case degraded = "Connection interrupted"
    case asleep = "TV asleep"
    case recovering = "Reconnecting"
    case needsRepair = "Pair again"
}

public protocol PairingCodeDriver {
    func pair(_ tv: TVDevice, code: String) async throws -> Credential
}

public protocol ManualAddressDriver {
    func device(at address: String) async throws -> TVDevice
}

public protocol PointerDriver {
    func movePointer(x: Double, y: Double) async throws
}

public protocol DisconnectingTVDriver {
    func disconnect() async
}
