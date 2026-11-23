import Foundation
import Testing
import TVRemoteKit

private actor SocketTranscript: WebSocketConnection {
    nonisolated let peerCertificate: Data?
    private var inbound: [WebSocketMessage]
    private let receiveGate: AsyncStream<Void>?
    private let endReceive: AsyncStream<Void>.Continuation?
    private(set) var sent: [WebSocketMessage] = []
    private(set) var closed = false

    init(_ frames: [String], certificate: Data? = nil, waitForClose: Bool = false) {
        self.inbound = frames.map(WebSocketMessage.text)
        self.peerCertificate = certificate
        let pending = waitForClose ? AsyncStream<Void>.makeStream() : nil
        self.receiveGate = pending?.stream
        self.endReceive = pending?.continuation
    }

    func send(_ message: WebSocketMessage) { sent.append(message) }
    func receive() async throws -> WebSocketMessage {
        if inbound.isEmpty, let receiveGate {
            for await _ in receiveGate {}
            throw CancellationError()
        }
        guard !inbound.isEmpty else { throw TVError.unreachable }
        return inbound.removeFirst()
    }
    func ping() {}
    func close() {
        closed = true
        endReceive?.finish()
    }

    func outbound() throws -> [SocketJSON] {
        try sent.map {
            guard case .text(let text) = $0 else { throw TVError.invalidResponse }
            return try JSONDecoder().decode(SocketJSON.self, from: Data(text.utf8))
        }
    }
}

private actor SocketScript: WebSocketTransport {
    struct Attempt: Equatable {
        let url: URL
        let trust: TLSPeerTrust
    }

    private var queue: [Result<SocketTranscript, TVError>]
    private(set) var attempts: [Attempt] = []

    init(_ queue: [Result<SocketTranscript, TVError>]) { self.queue = queue }

    func open(_ url: URL, trust: TLSPeerTrust) throws -> any WebSocketConnection {
        attempts.append(Attempt(url: url, trust: trust))
        guard !queue.isEmpty else { throw TVError.unreachable }
        return try queue.removeFirst().get()
    }
}

private actor SamsungDeviceInfo: HTTPTransport {
    private(set) var requests: [HTTPRequest] = []
    let port: Int?
    let mac: String

    init(port: Int? = 8002, mac: String = "02:11:22:33:44:55") {
        self.port = port
        self.mac = mac
    }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        if let port, request.url.port != port { throw TVError.unreachable }
        return HTTPResponse(status: 200, body: Data("""
            {"device":{"duid":"uuid:samsung-1","name":"Living Room","wifiMac":"\(mac)"}}
            """.utf8))
    }
}

private actor DatagramTranscript: UDPDatagramTransport {
    private(set) var data: Data?
    private(set) var target: TVEndpoint?

    func send(_ datagram: Data, to endpoint: TVEndpoint) {
        data = datagram
        target = endpoint
    }
}

private struct SocketDiscovery: DiscoverySource {
    let endpoint: TVEndpoint

    func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate> {
        AsyncStream {
            $0.yield(DiscoveryCandidate(platform: platform, endpoint: endpoint))
            $0.yield(DiscoveryCandidate(platform: platform, endpoint: endpoint))
            $0.finish()
        }
    }
}

@Test func samsungDiscoveryApprovalTokenAndReconnect() async throws {
    let pin = Data([0x42])
    let allowed = #"{"event":"ms.channel.connect","data":{"token":"abc+1"}}"#
    let pairing = SocketTranscript([allowed], certificate: pin)
    let control = SocketTranscript([allowed], certificate: pin)
    let reconnect = SocketTranscript([allowed], certificate: pin)
    let sockets = SocketScript([.success(pairing), .success(control), .success(reconnect)])
    let http = SamsungDeviceInfo()
    let datagram = DatagramTranscript()
    let wake = WakeOnLAN(transport: datagram)
    let discovery = SocketDiscovery(endpoint: TVEndpoint(host: "tv.local", port: 8002))
    let driver = SamsungTizenDriver(http: http, sockets: sockets, discovery: discovery, wake: wake)
    var results = [TVDevice]()
    for await device in driver.discover() { results.append(device) }
    #expect(results.count == 1)
    let tv = try #require(results.first)
    #expect(tv.id.identifier == "uuid:samsung-1")
    #expect(tv.capabilities.contains(.networkWake))

    let store = MemoryCredentialStore()
    let manager = ConnectionManager(drivers: [TVDriverFactory(platform: .samsung) {
        SamsungTizenDriver(http: http, sockets: sockets, wake: wake)
    }], credentials: store)
    try await manager.pair(tv) { prompt in
        #expect(prompt == .approveOnTV)
        return .acknowledged
    }
    #expect(await store.load(for: tv.id) == .samsungToken("abc+1", certificate: pin))
    try await manager.send(.home)
    try await manager.reconnect()
    try await manager.send(.powerOff)
    try await driver.wake(tv)
    #expect(await datagram.data == tv.wakeAddress?.magicPacket)
    #expect(await pairing.closed)
    let attempts = await sockets.attempts
    #expect(attempts.map(\.trust) == [.pairing, .pinned(pin), .pinned(pin)])
    #expect(attempts.allSatisfy { $0.url.port == 8002 && $0.url.scheme == "wss" })
    #expect(attempts[1].url.absoluteString.contains("token=abc%2B1"))
    let sent = try await control.outbound()
    #expect(sent.first?["method"].string == "ms.remote.control")
    #expect(sent.first?["params"]["DataOfCmd"].string == "KEY_HOME")
    let off = try await reconnect.outbound()
    #expect(off.first?["params"]["DataOfCmd"].string == "KEY_POWEROFF")
}

@Test func samsungSecureProbeDoesNotDowngradeAndExplicitPlainRejectsUnauthorizedToken() async throws {
    let http = SamsungDeviceInfo(port: 8001)
    let unauthorized = SocketTranscript([#"{"event":"ms.channel.unauthorized"}"#])
    let sockets = SocketScript([.success(unauthorized)])
    let driver = SamsungTizenDriver(http: http, sockets: sockets)
    await #expect(throws: TVError.unreachable) {
        try await driver.probe(TVEndpoint(host: "tv.local", port: 8002))
    }
    #expect(await http.requests.map { $0.url.port } == [8002])
    let tv = try await driver.probe(TVEndpoint(host: "tv.local", port: 8001))
    #expect(tv.endpoint.port == 8001)
    await #expect(throws: TVError.credentialRejected) { try await driver.connect(tv, .token("old")) }
    #expect(await unauthorized.closed)
    #expect(await sockets.attempts.first?.url.scheme == "ws")
}

@Test func samsungReconnectUsesPlainPairedPortAfterSecureDiscovery() async throws {
    let http = SamsungDeviceInfo(port: nil)
    let accepted = SocketTranscript([#"{"event":"ms.channel.connect"}"#])
    let sockets = SocketScript([.success(accepted)])
    let discovery = SocketDiscovery(endpoint: TVEndpoint(host: "new.local", port: 8002))
    let driver: any TVDriver = SamsungTizenDriver(http: http, sockets: sockets, discovery: discovery)
    var devices: [TVDevice] = []
    for await tv in driver.discover() { devices.append(tv) }
    let tv = try #require(devices.first)
    #expect(tv.endpoint.port == 8002)

    try await driver.connect(tv, .samsungToken("paired-token", certificate: nil))
    #expect(await http.requests.map { $0.url.port } == [8002, 8001])
    let attempt = try #require(await sockets.attempts.first)
    #expect(attempt.url.scheme == "ws")
    #expect(attempt.url.host == "new.local")
    #expect(attempt.url.port == 8001)
    #expect(await driver.connectedDevice()?.endpoint.port == 8001)
}

@Test func samsungReconnectPreservesRestoredWakeAddressWhenDeviceInfoHasNoUsableMAC() async throws {
    let pin = Data([0x42])
    let http = SamsungDeviceInfo(mac: "00:00:00:00:00:00")
    let sockets = SocketScript([.success(SocketTranscript([#"{"event":"ms.channel.connect"}"#], certificate: pin))])
    let datagram = DatagramTranscript()
    let wake = WakeOnLAN(transport: datagram)
    let store = MemoryCredentialStore()
    let identity = TVIdentity(platform: .samsung, identifier: "uuid:samsung-1")
    let address = try #require(MACAddress(rawValue: "02:11:22:33:44:55"))
    let restored = TVDevice(id: identity, name: "Saved TV", endpoint: TVEndpoint(host: "tv.local", port: 8002),
                            capabilities: .remoteKeys, wakeAddress: address)
    await store.save(.samsungToken("token", certificate: pin), for: identity)
    let driver = SamsungTizenDriver(http: http, sockets: sockets, wake: wake)
    let manager = ConnectionManager(drivers: [TVDriverFactory(platform: .samsung) { driver }], credentials: store)

    try await manager.connect(restored)
    let connected = try #require(await manager.currentDevice)
    #expect(connected.wakeAddress == address)
    #expect(connected.capabilities.contains(.networkWake))
    try await driver.wake(connected)
    #expect(await datagram.data == address.magicPacket)
}

@Test func lgRegistrationCommandsAndCredentialReuse() async throws {
    let webOSPin = Data([9, 8])
    let identity = #"{"id":"hello","type":"hello","payload":{"deviceUUID":"webos-test-tv","deviceName":"Bedroom"}}"#
    let hello = #"{"id":"register","type":"response","payload":{"pairingType":"PROMPT","returnValue":true}}"#
    let registered = #"{"id":"register","type":"registered","payload":{"client-key":"webos-key"}}"#
    let network = #"{"id":"request-1","type":"response","payload":{"wired":{"state":"connected","macAddress":"02:11:22:33:44:55"}}}"#
    let volume = #"{"id":"request-2","type":"response","payload":{"returnValue":true}}"#
    let pointerPath = #"{"id":"request-3","type":"response","payload":{"socketPath":"ws://tv.local:3000/resources/pointer"}}"#
    let launched = #"{"id":"request-1","type":"response","payload":{"returnValue":true}}"#
    let probe = SocketTranscript([identity], certificate: webOSPin)
    let pairing = SocketTranscript([identity, hello, registered], certificate: webOSPin)
    let active = SocketTranscript([identity, registered, network, volume, pointerPath], certificate: webOSPin)
    let pointer = SocketTranscript([], certificate: webOSPin)
    let restored = SocketTranscript([identity, registered, launched], certificate: webOSPin)
    let sockets = SocketScript([.success(probe), .success(pairing), .success(active), .success(pointer), .success(restored)])
    let datagram = DatagramTranscript()
    let wake = WakeOnLAN(transport: datagram)
    let store = MemoryCredentialStore()
    let manager = ConnectionManager(drivers: [TVDriverFactory(platform: .lg) {
        LGWebOSDriver(sockets: sockets, wake: wake)
    }], credentials: store)
    let tv = try await manager.probe(TVEndpoint(host: "tv.local", port: 3001), platform: .lg)
    #expect(tv.id.identifier == "webos-test-tv")
    #expect(tv.name == "Bedroom")
    try await manager.pair(tv) { prompt in
        #expect(prompt == .approveOnTV)
        return .acknowledged
    }
    #expect(await store.load(for: tv.id) == .webOSClientKey("webos-key", certificate: webOSPin))
    #expect(await manager.currentDevice?.capabilities.contains(.networkWake) == true)
    try await manager.send(.volumeUp)
    try await manager.send(.up)
    let activeDevice = try #require(await manager.currentDevice)
    try await LGWebOSDriver(sockets: sockets, wake: wake).wake(activeDevice)
    try await manager.reconnect()
    try await manager.launch(AppID(rawValue: "netflix"))
    #expect(await datagram.data?.count == 102)
    #expect(await pointer.sent == [.text("type:button\nname:UP\n\n")])
    #expect(await sockets.attempts[3].url.absoluteString == "wss://tv.local:3001/resources/pointer")
    #expect(await sockets.attempts.map(\.trust) == [.pairing, .pairing, .pinned(webOSPin), .pinned(webOSPin), .pinned(webOSPin)])
    let sent = try await active.outbound()
    #expect(sent[1]["payload"]["client-key"].string == "webos-key")
    #expect(sent[1]["payload"]["manifest"]["manifestVersion"].string == "1")
    #expect(sent[3]["uri"].string == "ssap://audio/volumeUp")
    let resume = try await restored.outbound()
    #expect(resume[2]["uri"].string == "ssap://system.launcher/launch")
    #expect(resume[2]["payload"]["id"].string == "netflix")
}

@Test func lgSecureDiscoveryDoesNotDowngradeAndExplicitPlainRejectsExpiredClientKey() async throws {
    let identity = #"{"id":"hello","type":"hello","payload":{"deviceUUID":"original"}}"#
    let probe = SocketTranscript([identity])
    let invalid = SocketTranscript([identity, #"{"id":"register","type":"error","error":"403 forbidden"}"#])
    let sockets = SocketScript([.failure(.unreachable), .failure(.unreachable), .success(probe), .success(invalid)])
    let discovery = SocketDiscovery(endpoint: TVEndpoint(host: "tv.local", port: 3001))
    let driver = LGWebOSDriver(sockets: sockets, discovery: discovery)
    var devices: [TVDevice] = []
    for await device in driver.discover() { devices.append(device) }
    #expect(devices.isEmpty)
    #expect(await sockets.attempts.map { $0.url.port } == [3001, 3001])
    let tv = try await driver.probe(TVEndpoint(host: "tv.local", port: 3000))
    #expect(tv.endpoint.port == 3000)
    await #expect(throws: TVError.credentialRejected) {
        try await driver.connect(tv, .webOSPlainClientKey("expired", deviceUUID: "original"))
    }
    #expect(await invalid.closed)
    #expect(await sockets.attempts.map { $0.url.port } == [3001, 3001, 3000, 3000])
}

@Test func lgRejectsReplacementIdentityBeforeSendingClientKey() async throws {
    let identity = #"{"id":"hello","type":"hello","payload":{"deviceUUID":"replacement"}}"#
    let control = SocketTranscript([identity])
    let sockets = SocketScript([.success(control)])
    let driver = LGWebOSDriver(sockets: sockets)
    let tv = TVDevice(id: TVIdentity(platform: .lg, identifier: "original"), name: "LG",
                      endpoint: TVEndpoint(host: "tv.local", port: 3000), capabilities: .remoteKeys)
    await #expect(throws: TVError.identityMismatch) {
        try await driver.connect(tv, .webOSPlainClientKey("old-key", deviceUUID: "original"))
    }
    #expect(try await control.outbound().map { $0["type"].string } == ["hello"])
    #expect(await control.closed)
}

@Test func lgDoesNotSendStoredPlainKeyWhenHelloOmitsDeviceIdentity() async throws {
    let noIdentity = #"{"id":"hello","type":"hello","payload":{}}"#
    let control = SocketTranscript([noIdentity])
    let sockets = SocketScript([.success(control)])
    let driver = LGWebOSDriver(sockets: sockets)
    let tv = TVDevice(id: TVIdentity(platform: .lg, identifier: "tv.local"), name: "LG",
                      endpoint: TVEndpoint(host: "tv.local", port: 3000), capabilities: .remoteKeys)
    await #expect(throws: TVError.pairingRequired) {
        try await driver.connect(tv, .webOSClientKey("legacy-key", certificate: nil))
    }
    #expect(await sockets.attempts.isEmpty)
    await #expect(throws: TVError.pairingRequired) {
        try await driver.connect(tv, .webOSPlainClientKey("paired-key", deviceUUID: "original"))
    }
    #expect(try await control.outbound().map { $0["type"].string } == ["hello"])
    #expect(await control.closed)
}

@Test(arguments: [true, false])
func lgPlainReconnectRecoversAfterHelloTimeoutOrTransportFailure(_ waitForClose: Bool) async throws {
    let identity = #"{"id":"hello","type":"hello","payload":{"deviceUUID":"original"}}"#
    let registered = #"{"id":"register","type":"registered","payload":{"client-key":"paired-key"}}"#
    let unavailable = SocketTranscript([], waitForClose: waitForClose)
    let restored = SocketTranscript([identity, registered])
    let sockets = SocketScript([.success(unavailable), .success(restored)])
    let tv = TVDevice(id: TVIdentity(platform: .lg, identifier: "original"), name: "LG",
                      endpoint: TVEndpoint(host: "tv.local", port: 3000), capabilities: .remoteKeys)
    let credentials = MemoryCredentialStore()
    await credentials.save(.webOSPlainClientKey("paired-key", deviceUUID: "original"), for: tv.id)
    let manager = ConnectionManager(drivers: [TVDriverFactory(platform: .lg) {
        LGWebOSDriver(sockets: sockets)
    }], credentials: credentials, retryDelays: [.zero])
    var states = manager.state.makeAsyncIterator()

    try await manager.connect(tv)
    #expect(await states.next() == .idle)
    #expect(await states.next() == .connecting)
    #expect(await states.next() == .degraded)
    #expect(await states.next() == .recovering)
    #expect(await states.next() == .ready)
    #expect(await unavailable.closed)
    #expect(try await unavailable.outbound().map { $0["type"].string } == ["hello"])
    let requests = try await restored.outbound()
    #expect(requests.map { $0["type"].string } == ["hello", "register"])
    #expect(requests.last?["payload"]["client-key"].string == "paired-key")
}

@Test func wakeOnLANSendsStandardBroadcastPacket() async throws {
    let address = try #require(MACAddress(rawValue: "02-11-22-33-44-55"))
    let transport = DatagramTranscript()
    try await WakeOnLAN(transport: transport).send(to: address)
    let packet = try #require(await transport.data)
    #expect(packet == Data(Array(repeating: UInt8(0xff), count: 6)
        + Array(repeating: [UInt8(2), 0x11, 0x22, 0x33, 0x44, 0x55], count: 16).flatMap { $0 }))
    #expect(await transport.target == TVEndpoint(host: "255.255.255.255", port: 9))
    #expect(MACAddress(rawValue: "01:00:5e:00:00:01") == nil)
    #expect(MACAddress(rawValue: "00:00:00:00:00:00") == nil)
}
