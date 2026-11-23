import Foundation
import TVRemoteCore

public actor SamsungTizenDriver: TVDriver {
    private let http: any HTTPTransport
    private let sockets: any WebSocketTransport
    private let discovery: any DiscoverySource
    private let wakeService: WakeOnLAN?
    private var connection: (any WebSocketConnection)?
    private var device: TVDevice?
    private let updates: AsyncStream<ConnectionState>.Continuation
    public nonisolated let state: AsyncStream<ConnectionState>

    public init(
        http: any HTTPTransport, sockets: any WebSocketTransport,
        discovery: any DiscoverySource = EmptyDiscoverySource(), wake: WakeOnLAN? = nil
    ) {
        self.http = http
        self.sockets = sockets
        self.discovery = discovery
        self.wakeService = wake
        (state, updates) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        updates.yield(.idle)
    }

    public nonisolated func discover() -> AsyncStream<TVDevice> {
        discoverSocketDevices(using: discovery, platform: .samsung, probe: probe)
    }

    public func probe(_ endpoint: TVEndpoint) async throws -> TVDevice {
        try await inspect(endpoint)
    }

    public func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential {
        let live = try await inspect(tv.endpoint)
        guard live.id == tv.id else { throw TVError.identityMismatch }
        let secure = live.endpoint.port == 8002
        let socket = try await open(live, token: nil, trust: secure ? .pairing : .system)
        do {
            guard try await prompt(.approveOnTV) == .acknowledged else { throw TVError.invalidCommand }
            let token = try await authorize(socket, timeout: .seconds(60))
            let certificate = socket.peerCertificate
            guard !secure || certificate != nil else { throw TVError.invalidResponse }
            await socket.close()
            return .samsungToken(token, certificate: certificate)
        } catch {
            await socket.close()
            throw error
        }
    }

    public func connect(_ tv: TVDevice, _ cred: Credential) async throws {
        let token: String?
        let certificate: Data?
        switch cred {
        case .samsungToken(let saved, let pin): (token, certificate) = (saved, pin)
        case .token(let saved): (token, certificate) = (saved, nil)
        default: throw TVError.pairingRequired
        }
        await connection?.close()
        connection = nil
        device = nil
        updates.yield(.connecting)
        do {
            let pairedPort: UInt16 = certificate == nil ? 8001 : 8002
            let live = try await inspect(tv.endpoint, pairedPort: pairedPort, certificate: certificate)
            guard live.id == tv.id else { throw TVError.identityMismatch }
            let socket = try await open(live, token: token, trust: certificate.map(TLSPeerTrust.pinned) ?? .system)
            do {
                _ = try await authorize(socket, timeout: .seconds(3))
            } catch {
                await socket.close()
                throw error
            }
            connection = socket
            let address = live.wakeAddress ?? tv.wakeAddress
            var capabilities = live.capabilities
            if address != nil && wakeService != nil { capabilities.insert(.networkWake) }
            device = TVDevice(id: live.id, name: live.name, endpoint: live.endpoint,
                              capabilities: capabilities, wakeAddress: address)
            updates.yield(.ready)
        } catch {
            updates.yield(error as? TVError == .credentialRejected ? .needsRepair : .degraded)
            throw error
        }
    }

    public func connectedDevice() -> TVDevice? { device }

    public func send(_ key: RemoteKey) async throws {
        let code: String
        switch key {
        case .up: code = "KEY_UP"
        case .down: code = "KEY_DOWN"
        case .left: code = "KEY_LEFT"
        case .right: code = "KEY_RIGHT"
        case .ok: code = "KEY_ENTER"
        case .back: code = "KEY_RETURN"
        case .home: code = "KEY_HOME"
        case .options: code = "KEY_MENU"
        case .inputMenu: code = "KEY_SOURCE"
        case .volumeUp: code = "KEY_VOLUP"
        case .volumeDown: code = "KEY_VOLDOWN"
        case .mute: code = "KEY_MUTE"
        case .channelUp: code = "KEY_CHUP"
        case .channelDown: code = "KEY_CHDOWN"
        case .power: code = "KEY_POWER"
        case .powerOn: code = "KEY_POWERON"
        case .powerOff: code = "KEY_POWEROFF"
        case .playPause: code = "KEY_PLAYPAUSE"
        case .play: code = "KEY_PLAY"
        case .pause: code = "KEY_PAUSE"
        case .stop: code = "KEY_STOP"
        case .rewind: code = "KEY_REWIND"
        case .fastForward: code = "KEY_FF"
        case .digit(let digit) where digit <= 9: code = "KEY_\(digit)"
        case .digit: throw TVError.invalidCommand
        case .text, .delete: throw TVError.notSupported
        }
        guard let connection else { throw TVError.notConnected }
        try await connection.sendJSON([
            "method": .string("ms.remote.control"),
            "params": .object([
                "Cmd": .string("Click"), "DataOfCmd": .string(code),
                "Option": .string("false"), "TypeOfRemote": .string("SendRemoteKey")
            ])
        ])
    }

    public func launch(_ app: AppID) async throws {
        guard !app.rawValue.isEmpty else { throw TVError.invalidCommand }
        guard let connection else { throw TVError.notConnected }
        try await connection.sendJSON([
            "method": .string("ms.channel.emit"),
            "params": .object([
                "event": .string("ed.apps.launch"), "to": .string("host"),
                "data": .object(["appId": .string(app.rawValue), "action_type": .string("DEEP_LINK")])
            ])
        ])
    }

    public func apps() async throws -> [TVApp] {
        guard let connection else { throw TVError.notConnected }
        try await connection.sendJSON([
            "method": .string("ms.channel.emit"),
            "params": .object(["event": .string("ed.installedApp.get"), "to": .string("host")])
        ])
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let reply = try await connection.receiveJSON(timeout: ContinuousClock.now.duration(to: deadline))
            if reply["event"].string == "ms.error" { throw TVError.notSupported }
            guard reply["event"].string == "ed.installedApp.get" else { continue }
            guard case .array(let apps) = reply["data"]["data"] else { throw TVError.invalidResponse }
            return apps.compactMap {
                guard let id = $0["appId"].string, let name = $0["name"].string else { return nil }
                return TVApp(id: AppID(rawValue: id), name: name)
            }
        }
        throw TVError.timedOut
    }
    public func search(_ query: String) async throws { throw TVError.notSupported }

    public func wake(_ tv: TVDevice) async throws {
        guard let wakeService, let address = tv.wakeAddress else { throw TVError.notSupported }
        try await wakeService.send(to: address)
    }

    public func keepAlive() async throws {
        guard let connection else { throw TVError.notConnected }
        try await connection.ping()
    }

    private func inspect(
        _ endpoint: TVEndpoint, pairedPort: UInt16? = nil, certificate: Data? = nil
    ) async throws -> TVDevice {
        let ports: [UInt16] = pairedPort.map { [$0] } ?? (endpoint.port == 8001 ? [8001, 8002] : [8002])
        var last: any Error = TVError.unreachable
        for port in ports {
            do {
                let secure = port == 8002
                let url = try socketURL(host: endpoint.host, port: port, scheme: secure ? "https" : "http", path: "/api/v2/")
                let trust: TLSPeerTrust = certificate.map(TLSPeerTrust.pinned) ?? (secure ? .pairing : .system)
                let response = try await http.request(HTTPRequest(.get, url: url, trust: trust))
                guard (200..<300).contains(response.status),
                      let json = try? JSONDecoder().decode(SocketJSON.self, from: response.body) else {
                    throw TVError.invalidResponse
                }
                let info = json["device"]
                guard let id = (info["duid"].string ?? info["id"].string ?? json["id"].string)?.lowercased() else {
                    throw TVError.invalidResponse
                }
                let address = (info["wifiMac"].string ?? info["mac"].string).flatMap(MACAddress.init(rawValue:))
                var capabilities: TVCapabilities = [.remoteKeys, .inputMenu, .launch, .appList]
                if address != nil && wakeService != nil { capabilities.insert(.networkWake) }
                return TVDevice(id: TVIdentity(platform: .samsung, identifier: id),
                                name: info["name"].string ?? json["name"].string ?? "Samsung TV",
                                endpoint: TVEndpoint(host: endpoint.host, port: port),
                                capabilities: capabilities, wakeAddress: address)
            } catch {
                if error is CancellationError || error as? TVError == .identityMismatch { throw error }
                last = error
            }
        }
        throw last
    }

    private func open(_ tv: TVDevice, token: String?, trust: TLSPeerTrust) async throws -> any WebSocketConnection {
        var query = [URLQueryItem(name: "name", value: Data("TVRemote".utf8).base64EncodedString())]
        if let token { query.append(URLQueryItem(name: "token", value: token)) }
        let url = try socketURL(host: tv.endpoint.host, port: tv.endpoint.port,
                                scheme: tv.endpoint.port == 8002 ? "wss" : "ws",
                                path: "/api/v2/channels/samsung.remote.control", query: query)
        return try await sockets.open(url, trust: trust)
    }

    private func authorize(_ socket: any WebSocketConnection, timeout: Duration) async throws -> String? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let json = try await socket.receiveJSON(timeout: ContinuousClock.now.duration(to: deadline))
            switch json["event"].string {
            case "ms.channel.connect": return json["data"]["token"].string
            case "ms.channel.unauthorized", "ms.channel.timeOut": throw TVError.credentialRejected
            default: continue
            }
        }
        throw TVError.timedOut
    }
}
