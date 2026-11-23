import Foundation
import TVRemoteCore

public actor GoogleTVRemoteDriver: TVDriver {
    public static let controlPort: UInt16 = 6466
    public static let pairingPort: UInt16 = 6467

    private let transport: any GoogleTVTLSTransport
    private nonisolated let discovery: any DiscoverySource
    private let digest: GoogleTVDigest
    private let clientName: String
    private nonisolated let states = StateFeed()
    private var session: GoogleTVRemoteSession?
    private var device: TVDevice?
    private var listener: Task<Void, Never>?
    private var generation = UUID()

    public init(
        transport: any GoogleTVTLSTransport,
        discovery: any DiscoverySource = EmptyDiscoverySource(),
        clientName: String = "TVRemote",
        sha256: @escaping GoogleTVDigest
    ) {
        self.transport = transport
        self.discovery = discovery
        self.clientName = clientName
        self.digest = sha256
    }

    deinit { listener?.cancel() }

    public nonisolated var state: AsyncStream<ConnectionState> { states.subscribe() }

    public nonisolated func discover() -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let task = Task {
                var seen: [TVIdentity: TVEndpoint] = [:]
                for await candidate in discovery.browse(for: .googleTV) {
                    guard !Task.isCancelled else { break }
                    guard candidate.platform == .googleTV,
                          let tv = try? await probe(candidate.endpoint),
                          seen[tv.id] != tv.endpoint else { continue }
                    seen[tv.id] = tv.endpoint
                    continuation.yield(tv)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func probe(_ endpoint: TVEndpoint) async throws -> TVDevice {
        let pairingEndpoint = try endpointFor(endpoint, port: Self.pairingPort)
        let connection = try await transport.open(pairingEndpoint, mode: .probe)
        await connection.stream.close()
        try Task.checkCancellation()
        return TVDevice(
            id: identity(for: connection.peer),
            name: connection.deviceName ?? "Google TV",
            endpoint: TVEndpoint(host: endpoint.host, port: Self.controlPort),
            capabilities: [.remoteKeys, .launch, .controlWake, .inputMenu]
        )
    }

    public func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential {
        guard tv.id.platform == .googleTV else { throw TVError.identityMismatch }
        let endpoint = try endpointFor(tv.endpoint, port: Self.pairingPort)
        let identity = try await transport.makeClientIdentity()
        // The on-screen challenge authenticates the peer before we persist its key.
        let connection = try await transport.open(endpoint, mode: .pairing(identity))
        do {
            guard self.identity(for: connection.peer) == tv.id else { throw TVError.identityMismatch }
            try Task.checkCancellation()
            let wire = GoogleTVWire(stream: connection.stream)
            try await GoogleTVPairing.exchange(
                wire: wire, clientName: clientName, identity: identity, peer: connection.peer,
                digest: digest, prompt: prompt
            )
            try Task.checkCancellation()
            let credential = try JSONEncoder().encode(GoogleTVPairingCredential(identity: identity, peer: connection.peer))
            await connection.stream.close()
            return .clientIdentity(credential)
        } catch {
            await connection.stream.close()
            throw error
        }
    }

    public func connect(_ tv: TVDevice, _ credential: Credential) async throws {
        guard tv.id.platform == .googleTV else { throw TVError.identityMismatch }
        guard case .clientIdentity(let data) = credential,
              let paired = try? JSONDecoder().decode(GoogleTVPairingCredential.self, from: data),
              identity(for: paired.peer) == tv.id else { throw TVError.credentialRejected }

        let token = UUID()
        generation = token
        listener?.cancel()
        listener = nil
        session = nil
        device = nil
        states.publish(.connecting)

        do {
            let endpoint = try endpointFor(tv.endpoint, port: Self.controlPort)
            let connection = try await transport.open(endpoint, mode: .control(paired.identity, peer: paired.peer))
            do {
                guard connection.peer == paired.peer else { throw TVError.identityMismatch }
                let wire = GoogleTVWire(stream: connection.stream)
                let remote = GoogleTVRemoteSession(wire: wire)
                try await remote.start()
                var capabilities: TVCapabilities = [.remoteKeys, .launch, .controlWake, .inputMenu]
                if await remote.supportsText { capabilities.insert(.keyboard) }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                session = remote
                device = TVDevice(id: tv.id, name: tv.name, endpoint: endpoint, capabilities: capabilities)
                states.publish(.ready)
                listener = Task { [states] in await remote.listen(states: states) }
            } catch {
                await connection.stream.close()
                throw error
            }
        } catch {
            if generation == token {
                states.publish(error as? TVError == .credentialRejected ? .needsRepair : .degraded)
            }
            throw error
        }
    }

    public func send(_ key: RemoteKey) async throws {
        guard let session else { throw TVError.notConnected }
        if case .text(let text) = key { try await session.sendText(text) }
        else { try await session.sendKey(Self.keyCode(key)) }
    }

    public func connectedDevice() async -> TVDevice? { device }

    public func launch(_ app: AppID) async throws {
        guard let session else { throw TVError.notConnected }
        guard let url = URLComponents(string: app.rawValue), url.scheme != nil else { throw TVError.invalidCommand }
        try await session.launch(app.rawValue)
    }

    public func search(_ query: String) async throws { throw TVError.notSupported }

    public func wake(_ tv: TVDevice) async throws { throw TVError.notSupported }

    public func keepAlive() async throws {
        guard let session else { throw TVError.notConnected }
        try await session.checkConnection()
    }

    private func endpointFor(_ original: TVEndpoint, port: UInt16) throws -> TVEndpoint {
        guard !original.host.isEmpty else { throw TVError.invalidAddress }
        return TVEndpoint(host: original.host, port: port)
    }

    private func identity(for peer: GoogleTVPublicKey) -> TVIdentity {
        let encoded = Proto([(1, .bytes(peer.modulus)), (2, .bytes(peer.exponent))]).encoded()
        let fingerprint = digest(encoded).map { String(format: "%02x", $0) }.joined()
        return TVIdentity(platform: .googleTV, identifier: fingerprint)
    }

    private static func keyCode(_ key: RemoteKey) throws -> UInt64 {
        switch key {
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .ok: 23
        case .back: 4
        case .home: 3
        case .options: 82
        case .inputMenu: 178
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .channelUp: 166
        case .channelDown: 167
        case .power: 26
        case .powerOn: 224
        case .powerOff: 223
        case .playPause: 85
        case .play: 126
        case .pause: 127
        case .stop: 86
        case .rewind: 89
        case .fastForward: 90
        case .delete: 67
        case .digit(let value):
            if value < 10 { 7 + UInt64(value) } else { throw TVError.invalidCommand }
        case .text: throw TVError.notSupported
        }
    }
}
