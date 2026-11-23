import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public struct URLSessionWebSocketTransport: WebSocketTransport {
    public init() {}

    public func open(_ url: URL, trust: TLSPeerTrust) async throws -> any WebSocketConnection {
        let delegate = TVSessionDelegate(trust: trust)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 524_288
        let connection = SessionWebSocket(session: session, socket: socket, delegate: delegate)
        socket.resume()
        do {
            try await connection.ping()
            return connection
        } catch {
            await connection.close()
            throw error
        }
    }
}

private final class SessionWebSocket: WebSocketConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let delegate: TVSessionDelegate

    init(session: URLSession, socket: URLSessionWebSocketTask, delegate: TVSessionDelegate) {
        self.session = session
        self.socket = socket
        self.delegate = delegate
    }

    deinit { session.invalidateAndCancel() }

    var peerCertificate: Data? { delegate.peerCertificate }

    func send(_ message: WebSocketMessage) async throws {
        try await socketOperation {
            do {
                switch message {
                case .text(let text): try await self.socket.send(.string(text))
                case .data(let bytes): try await self.socket.send(.data(bytes))
                }
            } catch { throw self.delegate.map(error) }
        }
    }

    func receive() async throws -> WebSocketMessage {
        try await withTaskCancellationHandler {
            do {
                switch try await socket.receive() {
                case .string(let text): return .text(text)
                case .data(let data): return .data(data)
                @unknown default: throw TVError.invalidResponse
                }
            } catch { throw delegate.map(error) }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func ping() async throws {
        try await socketOperation {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.socket.sendPing { error in
                    if let error { continuation.resume(throwing: self.delegate.map(error)) }
                    else { continuation.resume() }
                }
            }
        }
    }

    func close() async {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

final class TVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trust: TLSPeerTrust
    private let lock = NSLock()
    private var certificate: Data?
    private var rejected = false

    init(trust: TLSPeerTrust) { self.trust = trust }

    var peerCertificate: Data? { lock.withLock { certificate } }

    func map(_ error: any Error) -> any Error {
        if lock.withLock({ rejected }) { return TVError.identityMismatch }
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return TVError.timedOut
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
             .secureConnectionFailed, .badServerResponse:
            return TVError.unreachable
        default: return error
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }

    #if canImport(Security)
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard trust != .system, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let bytes = SecCertificateCopyData(leaf) as Data
        if case .pinned(let expected) = trust, bytes != expected {
            lock.withLock { rejected = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        lock.withLock { certificate = bytes }
        return (.useCredential, URLCredential(trust: serverTrust))
    }
    #endif
}
