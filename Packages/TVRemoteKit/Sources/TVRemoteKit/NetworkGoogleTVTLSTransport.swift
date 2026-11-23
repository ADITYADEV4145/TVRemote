#if canImport(Network) && canImport(Security)
import Foundation
import Network
import Security

public actor NetworkGoogleTVTLSTransport: GoogleTVTLSTransport {
    private static let queue = DispatchQueue(label: "TVRemoteKit.googleTV.tls")
    private var probeIdentity: GoogleTVClientIdentity?

    public init() {}

    public func makeClientIdentity() throws -> GoogleTVClientIdentity {
        try GoogleTVClientCertificate.create()
    }

    public func open(_ endpoint: TVEndpoint, mode: GoogleTVTLSMode) async throws -> GoogleTVTLSConnection {
        guard !endpoint.host.isEmpty, let port = NWEndpoint.Port(rawValue: endpoint.port) else { throw TVError.invalidAddress }
        let identity: GoogleTVClientIdentity
        let expectedPeer: GoogleTVPublicKey?
        switch mode {
        case .probe:
            if let probeIdentity {
                identity = probeIdentity
            } else {
                identity = try makeClientIdentity()
                probeIdentity = identity
            }
            expectedPeer = nil
        case .pairing(let presented):
            identity = presented
            expectedPeer = nil
        case .control(let presented, let peer):
            identity = presented
            expectedPeer = peer
        }
        guard let localIdentity = sec_identity_create(try GoogleTVClientCertificate.identity(from: identity)) else {
            throw TVError.credentialRejected
        }
        let observation = PeerObservation()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_local_identity(options, localIdentity)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let result = Result {
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first else {
                    throw TVError.invalidResponse
                }
                let publicKey = try GoogleTVClientCertificate.publicKey(of: leaf)
                if let expectedPeer, expectedPeer != publicKey { throw TVError.identityMismatch }
                let subject = SecCertificateCopySubjectSummary(leaf) as String?
                return PeerObservation.Peer(publicKey: publicKey, name: Self.friendlyName(subject))
            }
            observation.set(result)
            complete((try? result.get()) != nil)
        }, Self.queue)
        let host = endpoint.host.hasPrefix("[") && endpoint.host.hasSuffix("]")
            ? String(endpoint.host.dropFirst().dropLast()) : endpoint.host
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        )
        do {
            try await Self.waitUntilReady(connection)
            try Task.checkCancellation()
            let peer = try observation.get()
            return GoogleTVTLSConnection(stream: NetworkTLSStream(connection), peer: peer.publicKey, deviceName: peer.name)
        } catch {
            connection.cancel()
            if let observedError = observation.error { throw observedError }
            throw error
        }
    }

    private static func waitUntilReady(_ connection: NWConnection) async throws {
        let events = AsyncThrowingStream<Void, any Error> { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield(())
                    continuation.finish()
                case .waiting(let error), .failed(let error): continuation.finish(throwing: networkError(error))
                case .cancelled: continuation.finish(throwing: CancellationError())
                default: break
                }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { continuation.finish(throwing: TVError.timedOut) }
            }
            continuation.onTermination = { _ in timer.cancel() }
            connection.start(queue: queue)
        }
        defer { connection.stateUpdateHandler = nil }
        for try await _ in events { return }
        try Task.checkCancellation()
        throw TVError.unreachable
    }

    private static func friendlyName(_ subject: String?) -> String? {
        guard let subject, !subject.isEmpty else { return nil }
        let components = subject.split(separator: "/")
        guard components.first == "atvremote" else { return subject }
        if components.count > 2 { return String(components[components.count - 2]) }
        return nil
    }
}

private final class PeerObservation: @unchecked Sendable {
    struct Peer {
        let publicKey: GoogleTVPublicKey
        let name: String?
    }

    private let lock = NSLock()
    private var result: Result<Peer, any Error>?

    func set(_ result: Result<Peer, any Error>) { lock.withLock { self.result = result } }

    func get() throws -> Peer {
        try lock.withLock {
            guard let result else { throw TVError.invalidResponse }
            return try result.get()
        }
    }

    var error: (any Error)? {
        lock.withLock {
            if case .failure(let error) = result { return error }
            return nil
        }
    }
}

private final class NetworkTLSStream: TLSByteStream {
    private let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    deinit { connection.cancel() }

    func close() async { connection.cancel() }

    func write(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: networkError(error)) }
                    else { continuation.resume() }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func read(maxBytes: Int) async throws -> Data {
        guard maxBytes > 0 else { return Data() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: maxBytes) { data, _, _, error in
                    if let error { continuation.resume(throwing: networkError(error)) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

private func networkError(_ error: NWError) -> TVError {
    switch error {
    case .tls(let status)
        where [errSSLPeerBadCert, errSSLPeerUnsupportedCert, errSSLPeerCertUnknown, errSSLPeerUnknownCA,
               errSSLPeerAccessDenied, errSSLCertificateRequired].contains(status):
        return .credentialRejected
    case .posix(.ETIMEDOUT):
        return .timedOut
    default:
        return .unreachable
    }
}
#endif
