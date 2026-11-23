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
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func request(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData)
        urlRequest.httpMethod = request.method.rawValue
        do {
            let (body, response) = try await session.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else { throw TVError.invalidResponse }
            return HTTPResponse(status: response.statusCode, body: body)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw TVError.timedOut
            case .cancelled: throw CancellationError()
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                throw TVError.unreachable
            default: throw error
            }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
