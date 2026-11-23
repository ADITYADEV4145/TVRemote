import Foundation

package enum SocketJSON: Codable, Sendable {
    case object([String: SocketJSON])
    case array([SocketJSON])
    case string(String)
    case bool(Bool)
    case number(Int)
    case decimal(Double)
    case null

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode([String: Self].self) { self = .object(value) }
        else if let value = try? container.decode([Self].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .number(value) }
        else if let value = try? container.decode(Double.self) { self = .decimal(value) }
        else if container.decodeNil() { self = .null }
        else { throw TVError.invalidResponse }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    package subscript(_ key: String) -> Self {
        if case .object(let object) = self { object[key] ?? .null } else { .null }
    }

    package var string: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let value): String(value)
        default: nil
        }
    }

    package var bool: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): Bool(value.lowercased())
        default: nil
        }
    }
}

extension WebSocketConnection {
    package func sendJSON(_ fields: [String: SocketJSON]) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SocketJSON.object(fields))
        try await send(.text(String(decoding: data, as: UTF8.self)))
    }

    package func receiveJSON(timeout: Duration = .seconds(3)) async throws -> SocketJSON {
        var data: Data
        switch try await socketOperation(timeout: timeout, operation: { try await receive() }) {
        case .text(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        }
        guard data.count <= 524_288, let json = try? JSONDecoder().decode(SocketJSON.self, from: data) else {
            throw TVError.invalidResponse
        }
        return json
    }

    package func socketOperation<T: Sendable>(
        timeout: Duration = .seconds(3), operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: timeout)
                await close()
                throw TVError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TVError.unreachable }
            return result
        }
    }
}

package func socketURL(
    host: String, port: UInt16, scheme: String, path: String = "", query: [URLQueryItem] = []
) throws -> URL {
    guard !host.isEmpty, port != 0 else { throw TVError.invalidAddress }
    var parts = URLComponents()
    parts.scheme = scheme
    parts.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    parts.port = Int(port)
    parts.path = path
    if !query.isEmpty {
        parts.queryItems = query
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = parts.url, url.host != nil else { throw TVError.invalidAddress }
    return url
}

package func discoverSocketDevices(
    using discovery: any DiscoverySource, platform: TVPlatform,
    probe: @escaping @Sendable (TVEndpoint) async throws -> TVDevice
) -> AsyncStream<TVDevice> {
    AsyncStream { continuation in
        let task = Task {
            var seen = Set<TVDevice>()
            var verified = Set<TVEndpoint>()
            for await candidate in discovery.browse(for: platform) where candidate.platform == platform {
                guard !verified.contains(candidate.endpoint) else { continue }
                if let tv = try? await probe(candidate.endpoint) {
                    verified.insert(candidate.endpoint)
                    if seen.insert(tv).inserted { continuation.yield(tv) }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
