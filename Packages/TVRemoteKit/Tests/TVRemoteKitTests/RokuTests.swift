import Foundation
import Testing
import TVRemoteKit

private let endpoint = TVEndpoint(host: "192.0.2.10", port: 8060)

private func deviceInfo(id: String = "roku:ABCD", power: String = "PowerOn") -> HTTPResponse {
    HTTPResponse(status: 200, body: Data("""
        <device-info>
            <udn>\(id)</udn>
            <friendly-device-name>Family &amp; Friends</friendly-device-name>
            <is-tv>true</is-tv>
            <power-mode>\(power)</power-mode>
        </device-info>
        """.utf8))
}

private struct CandidateSource: DiscoverySource {
    let candidates: [DiscoveryCandidate]

    func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate> {
        AsyncStream { continuation in
            for candidate in candidates { continuation.yield(candidate) }
            continuation.finish()
        }
    }
}

private actor Transcript: HTTPTransport {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(_ responses: [HTTPResponse]) { self.responses = responses }

    func request(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw TVError.invalidResponse }
        return responses.removeFirst()
    }
}

@Test func rokuManualProbePairConnectAndCommands() async throws {
    let transport = Transcript([deviceInfo(), deviceInfo()] + Array(repeating: HTTPResponse(status: 200), count: 8))
    let driver = RokuECPDriver(http: transport)
    let tv = try await driver.probe(endpoint)
    #expect(tv.id == TVIdentity(platform: .roku, identifier: "roku:abcd"))
    #expect(tv.name == "Family & Friends")
    #expect(tv.capabilities == [.remoteKeys, .launch, .search, .keyboard, .networkWake])
    let credential = try await driver.pair(tv) { _ in
        Issue.record("Roku must not prompt for pairing.")
        return .acknowledged
    }
    #expect(credential == .none)
    try await driver.connect(tv, credential)
    try await driver.send(.ok)
    try await driver.send(.mute)
    try await driver.send(.rewind)
    try await driver.send(.digit(3))
    try await driver.send(.text("é/"))
    try await driver.launch(AppID(rawValue: "12/3"))
    try await driver.search("A+B & C")

    let requests = await transport.requests
    #expect(requests.map(\.method) == [.get, .get] + Array(repeating: .post, count: 8))
    #expect(requests.map { $0.url.absoluteString } == [
        "/query/device-info", "/query/device-info", "/keypress/Select", "/keypress/VolumeMute",
        "/keypress/Rev", "/keypress/Lit_3", "/keypress/Lit_%C3%A9", "/keypress/Lit_%2F",
        "/launch/12%2F3", "/search/browse?keyword=A%2BB%20%26%20C"
    ].map { "http://192.0.2.10:8060" + $0 })
}

@Test func rokuDiscoveryConfirmsIdentityAndDeduplicatesAddresses() async {
    let changed = TVEndpoint(host: "192.0.2.11", port: 8060)
    let transport = Transcript([deviceInfo(), deviceInfo(), deviceInfo()])
    let driver = RokuECPDriver(http: transport, discovery: CandidateSource(candidates: [
        DiscoveryCandidate(platform: .samsung, endpoint: endpoint),
        DiscoveryCandidate(platform: .roku, endpoint: endpoint),
        DiscoveryCandidate(platform: .roku, endpoint: endpoint),
        DiscoveryCandidate(platform: .roku, endpoint: changed)
    ]))
    var found: [TVDevice] = []
    for await candidate in driver.discover() { found.append(candidate) }
    #expect(found.map(\.endpoint) == [endpoint, changed])
    #expect(Set(found.map(\.id)).count == 1)
}

@Test func rokuRejectsMalformedDeviceInfoAndWrongEndpointIdentity() async throws {
    let transport = Transcript([HTTPResponse(status: 200, body: Data("<html/>".utf8)), deviceInfo(), deviceInfo(id: "other")])
    let driver = RokuECPDriver(http: transport)
    await #expect(throws: TVError.invalidResponse) { try await driver.probe(endpoint) }
    let tv = try await driver.probe(endpoint)
    await #expect(throws: TVError.identityMismatch) { try await driver.connect(tv, .none) }
    await #expect(throws: TVError.notConnected) { try await driver.send(.home) }
}

@Test func rokuReportsStandbyAndSendsPowerOnlyToVerifiedDevice() async throws {
    let standby = deviceInfo(power: "PowerOff")
    let transport = Transcript([standby, standby, standby, HTTPResponse(status: 200)])
    let driver = RokuECPDriver(http: transport)
    let tv = try await driver.probe(endpoint)
    await #expect(throws: TVError.asleep) { try await driver.connect(tv, .none) }
    var states = driver.state.makeAsyncIterator()
    #expect(await states.next() == .asleep)
    try await driver.wake(tv)
    #expect(await transport.requests.last?.url.path == "/keypress/PowerOn")
}

@Test func rokuSurfacesUnsupportedCommandsAndNetworkControlDisabled() async throws {
    let transport = Transcript([deviceInfo(), deviceInfo(), HTTPResponse(status: 403)])
    let driver = RokuECPDriver(http: transport)
    let tv = try await driver.probe(endpoint)
    try await driver.connect(tv, .none)
    await #expect(throws: TVError.notSupported) { try await driver.send(.pause) }
    await #expect(throws: TVError.invalidCommand) { try await driver.send(.digit(10)) }
    await #expect(throws: TVError.notSupported) { try await driver.send(.home) }
    #expect(await transport.requests.count == 3)
}

@Test func ssdpRequiresMatchingSourceAndPlatformFingerprint() {
    func packet(_ host: String, target: String = "roku:ecp") -> Data {
        Data("HTTP/1.1 200 OK\r\nLocation: http://\(host):8060/\r\nST: \(target)\r\n\r\n".utf8)
    }
    let host = "192.0.2.10"
    #expect(LocalDiscoverySource.ssdpCandidate(packet(host), source: host, platform: .roku)
        == DiscoveryCandidate(platform: .roku, endpoint: endpoint))
    #expect(LocalDiscoverySource.ssdpCandidate(packet("192.0.2.11"), source: host, platform: .roku) == nil)
    #expect(LocalDiscoverySource.ssdpCandidate(packet(host, target: "upnp:rootdevice"), source: host, platform: .roku) == nil)
    #expect(LocalDiscoverySource.ssdpCandidate(packet(host), source: host, platform: .googleTV) == nil)
}
