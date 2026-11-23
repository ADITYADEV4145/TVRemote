import Foundation
import Testing
@testable import TVRemoteKit
#if canImport(Security)
import Security
#endif

private let peer = GoogleTVPublicKey(modulus: hex("c3d4"), exponent: hex("010001"))
private let otherPeer = GoogleTVPublicKey(modulus: hex("d4c3"), exponent: hex("010001"))
private let client = GoogleTVClientIdentity(
    privateKey: hex("a0"), certificate: hex("b0"),
    publicKey: GoogleTVPublicKey(modulus: hex("a1b2"), exponent: hex("03"))
)
private let secret = "4a236918262a218b0d0c316883d1940efce3d1635e2629308714f6f2d496a757"
private let fingerprint = "923c5ea7fd873d2c739d0af976fd9b5bef51e41e81c28664e601a67a05528e32"
private let saved = TVEndpoint(host: "192.0.2.21", port: 6466)
private let pairingEndpoint = TVEndpoint(host: saved.host, port: 6467)
private let pairingReplies = hex("""
    07 080210c8015a00
    10 080210c801a201081204080310061802
    08 080210c801fa0100
    """)
private let remoteReady = hex("05 0a0308e704 04 12020800 05 c202020801")
private let initialRemoteWrites = [
    hex("1e 0a1c08e304121718012201312a0961747672656d6f74653205312e302e30"),
    hex("05 120308e304")
]

private func hex(_ text: String) -> Data {
    let digits = Array(text.utf8.filter { ![9, 10, 13, 32].contains($0) })
    precondition(digits.count.isMultiple(of: 2))
    return Data(stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(decoding: digits[$0...($0 + 1)], as: UTF8.self), radix: 16)!
    })
}

private func knownDigest(_ data: Data) -> Data {
    switch data {
    case hex("a1b203c3d40100011234"): hex(secret)
    case hex("0a02c3d41203010001"): hex(fingerprint)
    case hex("0a02d4c31203010001"): hex("502c917ee44faef2267edb0fe075c01ce841a03fcaba70fc7876903dc2ebd951")
    default: Data()
    }
}

private actor TranscriptTLSStream: TLSByteStream {
    private var input: Data
    private let gate: AsyncStream<Void>
    private let gateEnd: AsyncStream<Void>.Continuation
    private let output: AsyncStream<Data>.Continuation
    nonisolated let sent: AsyncStream<Data>
    private let fragmentSize: Int
    private(set) var writes: [Data] = []
    private(set) var closed = false

    init(_ input: Data = Data(), fragmentSize: Int = 2, ends: Bool = false) {
        self.input = input
        self.fragmentSize = fragmentSize
        (gate, gateEnd) = AsyncStream.makeStream()
        (sent, output) = AsyncStream.makeStream()
        if ends { gateEnd.finish() }
    }

    func write(_ data: Data) throws {
        guard !closed else { throw TVError.unreachable }
        writes.append(data)
        output.yield(data)
    }

    func read(maxBytes: Int) async throws -> Data {
        if input.isEmpty {
            for await _ in gate {}
            try Task.checkCancellation()
            return Data()
        }
        let size = min(fragmentSize, maxBytes, input.count)
        let bytes = Data(input.prefix(size))
        input.removeFirst(size)
        return bytes
    }

    func close() {
        closed = true
        gateEnd.finish()
        output.finish()
    }
}

private actor TranscriptGoogleTVTransport: GoogleTVTLSTransport {
    struct Opening: Sendable, Equatable {
        let endpoint: TVEndpoint
        let mode: GoogleTVTLSMode
    }

    private var connections: [GoogleTVTLSConnection]
    private(set) var openings: [Opening] = []

    init(_ connections: [GoogleTVTLSConnection]) { self.connections = connections }

    func makeClientIdentity() -> GoogleTVClientIdentity { client }

    func open(_ endpoint: TVEndpoint, mode: GoogleTVTLSMode) throws -> GoogleTVTLSConnection {
        openings.append(Opening(endpoint: endpoint, mode: mode))
        guard !connections.isEmpty else { throw TVError.invalidResponse }
        return connections.removeFirst()
    }
}

private struct GoogleTVTestDiscovery: DiscoverySource {
    let candidates: [DiscoveryCandidate]

    func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate> {
        #expect(platform == .googleTV)
        return AsyncStream { continuation in
            for candidate in candidates { continuation.yield(candidate) }
            continuation.finish()
        }
    }
}

private func connection(_ stream: TranscriptTLSStream, peer: GoogleTVPublicKey = peer) -> GoogleTVTLSConnection {
    GoogleTVTLSConnection(stream: stream, peer: peer, deviceName: "Living Room TV")
}

private func makeDriver(
    _ transport: TranscriptGoogleTVTransport,
    discovery: any DiscoverySource = EmptyDiscoverySource()
) -> GoogleTVRemoteDriver {
    GoogleTVRemoteDriver(transport: transport, discovery: discovery, sha256: knownDigest)
}

@Test func googleTVDeduplicatesBonjourResultsByPublicKeyAndTracksAddressMoves() async {
    let first = TranscriptTLSStream()
    let duplicate = TranscriptTLSStream()
    let moved = TranscriptTLSStream()
    let transport = TranscriptGoogleTVTransport([connection(first), connection(duplicate), connection(moved)])
    let newEndpoint = TVEndpoint(host: "192.0.2.22", port: 6466)
    let source = GoogleTVTestDiscovery(candidates: [
        DiscoveryCandidate(platform: .roku, endpoint: saved),
        DiscoveryCandidate(platform: .googleTV, endpoint: saved),
        DiscoveryCandidate(platform: .googleTV, endpoint: saved),
        DiscoveryCandidate(platform: .googleTV, endpoint: newEndpoint)
    ])
    let driver = makeDriver(transport, discovery: source)
    var results: [TVDevice] = []
    for await result in driver.discover() { results.append(result) }
    #expect(results.map(\.endpoint) == [saved, newEndpoint])
    #expect(results.map(\.id.identifier) == [fingerprint, fingerprint])
    #expect(results.first?.name == "Living Room TV")
    #expect(await first.closed)
    #expect(await duplicate.closed)
    #expect(await moved.closed)
    #expect(await transport.openings.map(\.endpoint.port) == [6467, 6467, 6467])
}

@Test func googleTVPairsWithHexChallengeAndRestoresThePinnedIdentityFromStore() async throws {
    let probe = TranscriptTLSStream()
    let pair = TranscriptTLSStream(pairingReplies + hex("2a 080210c801ca0222 0a20 " + secret))
    let longUnknown = hex("8401 a2068001") + Data(repeating: 0xa0, count: 128)
    let remote = TranscriptTLSStream(longUnknown + remoteReady + hex("07 420508ac021011"))
    let restored = TranscriptTLSStream(remoteReady)
    let transport = TranscriptGoogleTVTransport([connection(probe), connection(pair), connection(remote), connection(restored)])
    let store = MemoryCredentialStore()
    let factory = TVDriverFactory(platform: .googleTV) { makeDriver(transport) }
    let manager = ConnectionManager(drivers: [factory], credentials: store)

    let tv = try await manager.probe(saved, platform: .googleTV)
    #expect(tv.id.identifier == fingerprint)
    try await manager.pair(tv) { prompt in
        #expect(prompt == .enterCode(length: 6))
        return .code("4a1234")
    }

    #expect(await pair.writes == [
        hex("1c 080210c8015215 0a0961747672656d6f7465 1208545652656d6f7465"),
        hex("10 080210c801a20108 0a0408031006 1801"),
        hex("10 080210c801f20108 0a0408031006 1001"),
        hex("2a 080210c801c20222 0a20 " + secret)
    ])
    #expect(await pair.closed)

    try await manager.send(.home)
    try await manager.launch(AppID(rawValue: "app://test"))
    var frames = remote.sent.makeAsyncIterator()
    #expect(await frames.next() == initialRemoteWrites[0])
    #expect(await frames.next() == initialRemoteWrites[1])
    var output: [Data] = []
    for _ in 0..<3 {
        if let frame = await frames.next() { output.append(frame) }
    }
    #expect(Set(output) == [
        hex("05 4a0308ac02"),
        hex("06 520408031003"),
        hex("0f d2050c 0a0a6170703a2f2f74657374")
    ])
    await #expect(throws: TVError.notSupported) { try await manager.send(.text("hello")) }
    await #expect(throws: TVError.invalidCommand) { try await manager.launch(AppID(rawValue: "com.example")) }
    try await manager.checkConnection()

    await manager.disconnect()
    let reopened = ConnectionManager(drivers: [factory], credentials: store)
    try await reopened.connect(tv)
    #expect(await transport.openings.map(\.mode) == [
        .probe, .pairing(client), .control(client, peer: peer), .control(client, peer: peer)
    ])
    #expect(await transport.openings.map(\.endpoint) == [pairingEndpoint, pairingEndpoint, saved, saved])
}

@Test func googleTVRejectsInvalidCodeBeforeItSendsASecret() async throws {
    let pair = TranscriptTLSStream(pairingReplies)
    let transport = TranscriptGoogleTVTransport([connection(TranscriptTLSStream()), connection(pair)])
    let driver = makeDriver(transport)
    let tv = try await driver.probe(saved)
    await #expect(throws: TVError.credentialRejected) {
        try await driver.pair(tv) { _ in .code("001234") }
    }
    #expect(await pair.writes.count == 3)
    #expect(await pair.closed)
}

@Test func googleTVRejectsBadSecretAcknowledgementAndDoesNotStoreCredentials() async throws {
    let pair = TranscriptTLSStream(pairingReplies + hex("0b 080210c801ca0203 0a0100"))
    let transport = TranscriptGoogleTVTransport([connection(TranscriptTLSStream()), connection(pair)])
    let store = MemoryCredentialStore()
    let manager = ConnectionManager(
        drivers: [TVDriverFactory(platform: .googleTV) { makeDriver(transport) }], credentials: store
    )
    let tv = try await manager.probe(saved, platform: .googleTV)
    await #expect(throws: TVError.credentialRejected) {
        try await manager.pair(tv) { _ in .code("4A1234") }
    }
    #expect(await store.load(for: tv.id) == nil)
    var state = manager.state.makeAsyncIterator()
    #expect(await state.next() == .needsRepair)
}

@Test func googleTVRejectsAReplacementPeerBeforeSendingRemoteFrames() async throws {
    let pair = TranscriptTLSStream(pairingReplies + hex("2a 080210c801ca0222 0a20 " + secret))
    let replacement = TranscriptTLSStream()
    let transport = TranscriptGoogleTVTransport([
        connection(TranscriptTLSStream()), connection(pair), connection(replacement, peer: otherPeer)
    ])
    let driver = makeDriver(transport)
    let tv = try await driver.probe(saved)
    let cred = try await driver.pair(tv) { _ in .code("4A1234") }
    await #expect(throws: TVError.identityMismatch) { try await driver.connect(tv, cred) }
    #expect(await replacement.writes.isEmpty)
    #expect(await replacement.closed)
}

@Test func googleTVReadsServerPingsUntilEOFAndReportsLostKeepalive() async throws {
    let pair = TranscriptTLSStream(pairingReplies + hex("2a 080210c801ca0222 0a20 " + secret))
    let remote = TranscriptTLSStream(remoteReady + hex("07 420508ac021011"), ends: true)
    let transport = TranscriptGoogleTVTransport([connection(TranscriptTLSStream()), connection(pair), connection(remote)])
    let driver = makeDriver(transport)
    let tv = try await driver.probe(saved)
    let cred = try await driver.pair(tv) { _ in .code("4A1234") }
    var states = driver.state.makeAsyncIterator()
    #expect(await states.next() == .idle)
    try await driver.connect(tv, cred)
    #expect(await states.next() == .connecting)
    #expect(await states.next() == .ready)
    #expect(await states.next() == .degraded)
    #expect(await remote.writes == initialRemoteWrites + [hex("05 4a0308ac02")])
    await #expect(throws: TVError.unreachable) { try await driver.keepAlive() }
}

@Test func googleTVRejectsOversizedFramesBeforePrompting() async throws {
    let pair = TranscriptTLSStream(hex("818004"))
    let transport = TranscriptGoogleTVTransport([connection(TranscriptTLSStream()), connection(pair)])
    let driver = makeDriver(transport)
    let tv = try await driver.probe(saved)
    await #expect(throws: TVError.invalidResponse) {
        try await driver.pair(tv) { _ in
            Issue.record("Invalid frame must not reach the pairing prompt")
            return .acknowledged
        }
    }
    #expect(await pair.closed)
}

#if canImport(Network) && canImport(Security)
@Test func googleTVGeneratedClientCertificateCanReconstructItsSecurityIdentity() async throws {
    let transport = NetworkGoogleTVTLSTransport()
    let generated = try await transport.makeClientIdentity()
    let identity = try GoogleTVClientCertificate.identity(from: generated)
    var certificate: SecCertificate?
    #expect(SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess)
    let restored = try #require(certificate)
    #expect(SecCertificateCopyData(restored) as Data == generated.certificate)
    #expect(try GoogleTVClientCertificate.publicKey(of: restored) == generated.publicKey)
    #expect(generated.publicKey.modulus.count == 256)
}
#endif
