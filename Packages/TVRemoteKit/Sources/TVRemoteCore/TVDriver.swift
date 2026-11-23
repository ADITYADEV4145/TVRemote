import Foundation

public enum TVPlatform: String, Sendable, Codable, CaseIterable {
    case roku, googleTV, samsung, lg
}

public struct TVIdentity: Sendable, Hashable, Codable {
    public let platform: TVPlatform
    public let identifier: String

    public init(platform: TVPlatform, identifier: String) {
        self.platform = platform
        self.identifier = identifier
    }
}

public struct TVEndpoint: Sendable, Hashable, Codable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct TVCapabilities: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let remoteKeys = Self(rawValue: 1 << 0)
    public static let launch = Self(rawValue: 1 << 1)
    public static let search = Self(rawValue: 1 << 2)
    public static let keyboard = Self(rawValue: 1 << 3)
    public static let networkWake = Self(rawValue: 1 << 4)
    public static let pointer = Self(rawValue: 1 << 5)
    public static let controlWake = Self(rawValue: 1 << 6)
    public static let inputMenu = Self(rawValue: 1 << 7)
    public static let inputSelection = Self(rawValue: 1 << 8)
    public static let appList = Self(rawValue: 1 << 9)
}

public struct TVDevice: Sendable, Hashable, Codable, Identifiable {
    public let id: TVIdentity
    public let name: String
    public let endpoint: TVEndpoint
    public let capabilities: TVCapabilities
    public let wakeAddress: MACAddress?

    public init(
        id: TVIdentity, name: String, endpoint: TVEndpoint, capabilities: TVCapabilities, wakeAddress: MACAddress? = nil
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.capabilities = capabilities
        self.wakeAddress = wakeAddress
    }
}

public enum Credential: Sendable, Equatable, Codable {
    case none
    case token(String)
    case clientKey(String)
    case clientIdentity(Data)
    case samsungToken(String?, certificate: Data?)
    case webOSClientKey(String, certificate: Data?)
    case webOSPlainClientKey(String, deviceUUID: String)
}

public enum PairingPrompt: Sendable, Equatable {
    case enterCode(length: Int)
    case approveOnTV
}

public enum PairingResponse: Sendable, Equatable {
    case code(String)
    case acknowledged
}

public typealias PairingPromptHandler = @Sendable (PairingPrompt) async throws -> PairingResponse

public enum RemoteKey: Sendable, Hashable, Codable {
    case up, down, left, right, ok, back, home, options
    case volumeUp, volumeDown, mute, channelUp, channelDown
    case power, powerOn, powerOff
    case playPause, play, pause, stop, rewind, fastForward
    case digit(UInt8)
    case text(String)
    case delete
    case inputMenu
}

public struct TVInput: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AppID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct TVApp: Identifiable, Sendable, Equatable {
    public let id: AppID
    public let name: String

    public init(id: AppID, name: String) {
        self.id = id
        self.name = name
    }
}

public enum ConnectionState: Sendable, Equatable {
    case idle, discovering, connecting, ready, degraded, asleep, recovering, needsRepair
}

public enum TVError: Error, Sendable, Equatable {
    case notConnected, notSupported, invalidAddress, invalidResponse
    case invalidCommand, busy, timedOut, unreachable, asleep, identityMismatch
    case credentialRejected, pairingRequired, pairingDeclined
    case requestFailed(status: Int)
    case credentialStoreFailure(status: Int)
}

public protocol TVDriver: Sendable {
    func discover() -> AsyncStream<TVDevice>
    func probe(_ endpoint: TVEndpoint) async throws -> TVDevice
    func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential
    func connect(_ tv: TVDevice, _ cred: Credential) async throws
    func connectedDevice() async -> TVDevice?
    func send(_ key: RemoteKey) async throws
    func launch(_ app: AppID) async throws
    func search(_ query: String) async throws
    func wake(_ tv: TVDevice) async throws
    func keepAlive() async throws
    func inputs() async throws -> [TVInput]
    func selectInput(_ input: TVInput) async throws
    func apps() async throws -> [TVApp]
    var state: AsyncStream<ConnectionState> { get }
}

extension TVDriver {
    public func connectedDevice() async -> TVDevice? { nil }

    public func pair(_ tv: TVDevice) async throws -> Credential {
        try await pair(tv) { _ in throw TVError.pairingRequired }
    }

    public func keepAlive() async throws {}
    public func inputs() async throws -> [TVInput] { throw TVError.notSupported }
    public func selectInput(_ input: TVInput) async throws { throw TVError.notSupported }
    public func apps() async throws -> [TVApp] { throw TVError.notSupported }
}
