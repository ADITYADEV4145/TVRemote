import Foundation
import TVRemoteCore

public actor LGWebOSDriver: TVDriver {
    private let sockets: any WebSocketTransport
    private let discovery: any DiscoverySource
    private let wakeService: WakeOnLAN?
    private var connection: (any WebSocketConnection)?
    private var pointer: (any WebSocketConnection)?
    private var device: TVDevice?
    private var trust: TLSPeerTrust = .system
    private var sequence = 0
    private let updates: AsyncStream<ConnectionState>.Continuation
    public nonisolated let state: AsyncStream<ConnectionState>

    public init(
        sockets: any WebSocketTransport, discovery: any DiscoverySource = EmptyDiscoverySource(), wake: WakeOnLAN? = nil
    ) {
        self.sockets = sockets
        self.discovery = discovery
        self.wakeService = wake
        (state, updates) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        updates.yield(.idle)
    }

    public nonisolated func discover() -> AsyncStream<TVDevice> {
        discoverSocketDevices(using: discovery, platform: .lg, probe: probe)
    }

    public func probe(_ endpoint: TVEndpoint) async throws -> TVDevice {
        let (live, socket) = try await open(endpoint)
        await socket.close()
        return live
    }

    public func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential {
        let (live, socket) = try await open(tv.endpoint)
        do {
            guard live.id == tv.id else { throw TVError.identityMismatch }
            let key = try await register(socket, key: nil, prompt: prompt)
            let certificate = socket.peerCertificate
            guard live.endpoint.port != 3001 || certificate != nil else { throw TVError.invalidResponse }
            await socket.close()
            return .webOSClientKey(key, certificate: certificate)
        } catch {
            await socket.close()
            throw error
        }
    }

    public func connect(_ tv: TVDevice, _ cred: Credential) async throws {
        let key: String
        let certificate: Data?
        switch cred {
        case .webOSClientKey(let saved, let pin): (key, certificate) = (saved, pin)
        case .clientKey(let saved): (key, certificate) = (saved, nil)
        default: throw TVError.pairingRequired
        }
        let savedAddress = device?.id == tv.id ? device?.wakeAddress : nil
        await pointer?.close()
        await connection?.close()
        pointer = nil
        connection = nil
        device = nil
        updates.yield(.connecting)
        do {
            let (live, socket) = try await open(tv.endpoint, credentialed: true, certificate: certificate)
            do {
                guard live.id == tv.id else { throw TVError.identityMismatch }
                _ = try await register(socket, key: key)
                let address = live.wakeAddress ?? tv.wakeAddress ?? savedAddress
                let network = address == nil && wakeService != nil
                    ? try await networkAddress(socket) : nil
                let wakeAddress = address ?? network
                var capabilities = live.capabilities
                if wakeAddress != nil && wakeService != nil { capabilities.insert(.networkWake) }
                device = TVDevice(id: live.id, name: live.name, endpoint: live.endpoint,
                                  capabilities: capabilities, wakeAddress: wakeAddress)
            } catch {
                await socket.close()
                throw error
            }
            connection = socket
            trust = certificate.map(TLSPeerTrust.pinned) ?? .system
            updates.yield(.ready)
        } catch {
            updates.yield(error as? TVError == .credentialRejected ? .needsRepair : .degraded)
            throw error
        }
    }

    public func connectedDevice() -> TVDevice? { device }

    public func send(_ key: RemoteKey) async throws {
        switch key {
        case .up: try await button("UP")
        case .down: try await button("DOWN")
        case .left: try await button("LEFT")
        case .right: try await button("RIGHT")
        case .ok: try await button("ENTER")
        case .back: try await button("BACK")
        case .home: try await button("HOME")
        case .options: try await button("MENU")
        case .volumeUp: _ = try await request("audio/volumeUp")
        case .volumeDown: _ = try await request("audio/volumeDown")
        case .mute:
            let status = try await request("audio/getVolume")
            guard let muted = status["volumeStatus"]["muteStatus"].bool ?? status["muted"].bool else {
                throw TVError.invalidResponse
            }
            _ = try await request("audio/setMute", ["mute": .bool(!muted)])
        case .channelUp: _ = try await request("tv/channelUp")
        case .channelDown: _ = try await request("tv/channelDown")
        case .power: try await button("POWER")
        case .powerOn: _ = try await request("system/turnOn")
        case .powerOff: _ = try await request("system/turnOff")
        case .playPause: try await button("PLAYPAUSE")
        case .play: _ = try await request("media.controls/play")
        case .pause: _ = try await request("media.controls/pause")
        case .stop: _ = try await request("media.controls/stop")
        case .rewind: _ = try await request("media.controls/rewind")
        case .fastForward: _ = try await request("media.controls/fastForward")
        case .digit(let digit) where digit <= 9: try await button(String(digit))
        case .digit: throw TVError.invalidCommand
        case .text(let text):
            _ = try await request("com.webos.service.ime/insertText", ["text": .string(text), "replace": .number(0)])
        case .delete:
            _ = try await request("com.webos.service.ime/deleteCharacters", ["count": .number(1)])
        }
    }

    public func launch(_ app: AppID) async throws {
        guard !app.rawValue.isEmpty else { throw TVError.invalidCommand }
        _ = try await request("system.launcher/launch", ["id": .string(app.rawValue)])
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

    private func open(
        _ endpoint: TVEndpoint, credentialed: Bool = false, certificate: Data? = nil
    ) async throws -> (TVDevice, any WebSocketConnection) {
        let ports: [UInt16] = credentialed ? [certificate == nil ? 3000 : 3001]
            : (endpoint.port == 3000 ? [3000, 3001] : [3001, 3000])
        var last: any Error = TVError.unreachable
        for port in ports {
            let secure = port == 3001
            do {
                let url = try socketURL(host: endpoint.host, port: port, scheme: secure ? "wss" : "ws")
                let policy: TLSPeerTrust = certificate.map(TLSPeerTrust.pinned) ?? (secure ? .pairing : .system)
                return try await identify(endpoint: TVEndpoint(host: endpoint.host, port: port), url: url, trust: policy)
            } catch {
                if error is CancellationError || error as? TVError == .identityMismatch { throw error }
                last = error
            }
        }
        throw last
    }

    private func identify(
        endpoint: TVEndpoint, url: URL, trust: TLSPeerTrust
    ) async throws -> (TVDevice, any WebSocketConnection) {
        var socket = try await sockets.open(url, trust: trust)
        var identifier = endpoint.host.lowercased()
        var name = "LG webOS TV"
        var address: MACAddress?
        do {
            try await socket.sendJSON(["id": .string("hello"), "type": .string("hello")])
            let reply = try await socket.receiveJSON(timeout: .seconds(1))
            if reply["type"].string == "hello", reply["id"].string == "hello" {
                let payload = reply["payload"]
                if let uuid = payload["deviceUUID"].string {
                    identifier = uuid.lowercased()
                    address = MACAddress(rawValue: uuid)
                }
                name = payload["deviceName"].string ?? name
            }
        } catch {
            await socket.close()
            if error is CancellationError { throw error }
            socket = try await sockets.open(url, trust: trust)
        }
        var capabilities: TVCapabilities = [.remoteKeys, .launch, .keyboard]
        if address != nil && wakeService != nil { capabilities.insert(.networkWake) }
        return (TVDevice(id: TVIdentity(platform: .lg, identifier: identifier), name: name,
                         endpoint: endpoint, capabilities: capabilities, wakeAddress: address), socket)
    }

    private func register(
        _ socket: any WebSocketConnection, key: String?,
        prompt: PairingPromptHandler = { _ in throw TVError.credentialRejected }
    ) async throws -> String {
        var payload: [String: SocketJSON] = [
            "pairingType": .string("PROMPT"), "forcePairing": .bool(false), "manifest": .object(Self.manifest)
        ]
        if let key { payload["client-key"] = .string(key) }
        try await socket.sendJSON(["id": .string("register"), "type": .string("register"), "payload": .object(payload)])
        var prompted = false
        let deadline = ContinuousClock.now + (key == nil ? .seconds(60) : .seconds(3))
        while ContinuousClock.now < deadline {
            let message = try await socket.receiveJSON(timeout: ContinuousClock.now.duration(to: deadline))
            guard message["id"].string == "register" else { continue }
            switch message["type"].string {
            case "registered":
                guard let registered = message["payload"]["client-key"].string ?? key else {
                    throw TVError.invalidResponse
                }
                return registered
            case "response" where message["payload"]["pairingType"].string == "PROMPT":
                guard key == nil else { throw TVError.credentialRejected }
                if !prompted {
                    guard try await prompt(.approveOnTV) == .acknowledged else { throw TVError.invalidCommand }
                    prompted = true
                }
            case "error": throw TVError.credentialRejected
            default: continue
            }
        }
        throw TVError.timedOut
    }

    private func request(_ uri: String, _ payload: [String: SocketJSON] = [:]) async throws -> SocketJSON {
        guard let connection else { throw TVError.notConnected }
        return try await request(uri, payload, on: connection)
    }

    private func request(
        _ uri: String, _ payload: [String: SocketJSON] = [:], on socket: any WebSocketConnection
    ) async throws -> SocketJSON {
        sequence += 1
        let id = "request-\(sequence)"
        var fields: [String: SocketJSON] = ["id": .string(id), "type": .string("request"), "uri": .string("ssap://\(uri)")]
        if !payload.isEmpty { fields["payload"] = .object(payload) }
        try await socket.sendJSON(fields)
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            let message = try await socket.receiveJSON(timeout: ContinuousClock.now.duration(to: deadline))
            guard message["id"].string == id else { continue }
            let result = message["payload"]
            if message["type"].string == "error" || result["returnValue"].bool == false {
                throw TVError.notSupported
            }
            guard message["type"].string == "response" else { throw TVError.invalidResponse }
            return result
        }
        throw TVError.timedOut
    }

    private func button(_ name: String) async throws {
        if pointer == nil {
            guard let tv = device else { throw TVError.notConnected }
            let result = try await request("com.webos.service.networkinput/getPointerInputSocket")
            guard let path = result["socketPath"].string, let url = URL(string: path),
                  url.user == nil, url.password == nil,
                  let expected = try? socketURL(host: tv.endpoint.host, port: tv.endpoint.port,
                                                scheme: tv.endpoint.port == 3001 ? "wss" : "ws"),
                  url.host?.lowercased() == expected.host?.lowercased() else { throw TVError.invalidResponse }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.scheme = expected.scheme
            parts?.port = Int(tv.endpoint.port)
            guard let pinnedURL = parts?.url else { throw TVError.invalidResponse }
            pointer = try await sockets.open(pinnedURL, trust: trust)
        }
        guard let pointer else { throw TVError.notConnected }
        do {
            try await pointer.send(.text("type:button\nname:\(name)\n\n"))
        } catch {
            self.pointer = nil
            await pointer.close()
            throw error
        }
    }

    private func networkAddress(_ socket: any WebSocketConnection) async throws -> MACAddress? {
        do {
            let status = try await request("com.webos.service.connectionmanager/getStatus", on: socket)
            for interface in ["wired", "wifi"] where status[interface]["state"].string != "disconnected" {
                if let address = (status[interface]["macAddress"].string ?? status[interface]["mac"].string)
                    .flatMap(MACAddress.init(rawValue:)) { return address }
            }
            return nil
        } catch TVError.notSupported {
            return nil
        }
    }

    private static let manifest: [String: SocketJSON] = [
        "manifestVersion": .number(1),
        "appVersion": .string("1.0"),
        "permissions": .array([
            "CONTROL_AUDIO", "CONTROL_INPUT_JOYSTICK", "CONTROL_INPUT_MEDIA_PLAYBACK", "CONTROL_INPUT_TV",
            "CONTROL_MOUSE_AND_KEYBOARD", "CONTROL_POWER", "LAUNCH", "READ_CURRENT_CHANNEL",
            "READ_NETWORK_STATE", "WRITE_NOTIFICATION_TOAST"
        ].map(SocketJSON.string)),
        "signed": .object([
            "appId": .string("com.tvremote.remote"),
            "vendorId": .string("com.tvremote"),
            "localizedAppNames": .object(["": .string("TVRemote")]),
            "permissions": .array(["TEST_SECURE", "CONTROL_INPUT_TEXT"].map(SocketJSON.string))
        ])
    ]
}
