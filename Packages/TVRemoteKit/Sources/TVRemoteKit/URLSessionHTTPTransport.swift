import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 1.5) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: TVSessionDelegate(trust: .system), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func request(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = request.method.rawValue
        let delegate = TVSessionDelegate(trust: request.trust)
        let connection = request.trust == .system ? session
            : URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        defer { if connection !== session { connection.invalidateAndCancel() } }
        do {
            let (body, response) = try await connection.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else { throw TVError.invalidResponse }
            return HTTPResponse(status: response.statusCode, body: body)
        } catch {
            throw delegate.map(error)
        }
    }
}
