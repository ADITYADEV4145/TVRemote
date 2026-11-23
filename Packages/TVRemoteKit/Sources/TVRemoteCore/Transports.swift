import Foundation

public struct HTTPRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public let method: Method
    public let url: URL

    public init(_ method: Method, url: URL) {
        self.method = method
        self.url = url
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func request(_ request: HTTPRequest) async throws -> HTTPResponse
}

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public protocol WebSocketConnection: Sendable {
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func close() async
}

public protocol WebSocketTransport: Sendable {
    func open(_ url: URL) async throws -> any WebSocketConnection
}

public protocol TLSByteStream: Sendable {
    func write(_ data: Data) async throws
    func read(maxBytes: Int) async throws -> Data
    func close() async
}

public protocol CredentialStore: Sendable {
    func load(for identity: TVIdentity) async throws -> Credential?
    func save(_ credential: Credential, for identity: TVIdentity) async throws
    func remove(for identity: TVIdentity) async throws
}

public actor MemoryCredentialStore: CredentialStore {
    private var credentials: [TVIdentity: Credential] = [:]

    public init() {}

    public func load(for identity: TVIdentity) -> Credential? { credentials[identity] }

    public func save(_ credential: Credential, for identity: TVIdentity) {
        credentials[identity] = credential
    }

    public func remove(for identity: TVIdentity) {
        credentials.removeValue(forKey: identity)
    }
}

public protocol ConnectionClock: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemConnectionClock: ConnectionClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

public struct DiscoveryCandidate: Sendable, Hashable {
    public let platform: TVPlatform
    public let endpoint: TVEndpoint

    public init(platform: TVPlatform, endpoint: TVEndpoint) {
        self.platform = platform
        self.endpoint = endpoint
    }
}

public protocol DiscoverySource: Sendable {
    func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate>
}

public struct EmptyDiscoverySource: DiscoverySource {
    public init() {}

    public func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate> {
        AsyncStream { $0.finish() }
    }
}
