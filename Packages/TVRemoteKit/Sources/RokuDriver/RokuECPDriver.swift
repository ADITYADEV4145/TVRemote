import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import TVRemoteCore

public actor RokuECPDriver: TVDriver {
    private let http: any HTTPTransport
    private nonisolated let discovery: any DiscoverySource
    private nonisolated let states = StateFeed()
    private var connected: TVDevice?

    public init(http: any HTTPTransport, discovery: any DiscoverySource = EmptyDiscoverySource()) {
        self.http = http
        self.discovery = discovery
    }

    public nonisolated var state: AsyncStream<ConnectionState> { states.subscribe() }

    public nonisolated func discover() -> AsyncStream<TVDevice> {
        AsyncStream { continuation in
            let task = Task {
                var seen: [TVIdentity: TVEndpoint] = [:]
                for await candidate in discovery.browse(for: .roku) {
                    guard !Task.isCancelled else { break }
                    guard candidate.platform == .roku,
                          let device = try? await probe(candidate.endpoint),
                          seen[device.id] != device.endpoint else { continue }
                    seen[device.id] = device.endpoint
                    continuation.yield(device)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func probe(_ endpoint: TVEndpoint) async throws -> TVDevice {
        try await snapshot(endpoint).device
    }

    public func pair(_ tv: TVDevice, prompt: PairingPromptHandler) async throws -> Credential {
        guard tv.id.platform == .roku else { throw TVError.identityMismatch }
        return .none
    }

    public func connect(_ tv: TVDevice, _ cred: Credential) async throws {
        guard tv.id.platform == .roku else { throw TVError.identityMismatch }
        guard cred == .none else { throw TVError.credentialRejected }
        connected = nil
        states.publish(.connecting)
        do {
            let found = try await snapshot(tv.endpoint)
            guard found.device.id == tv.id else { throw TVError.identityMismatch }
            guard !found.asleep else { throw TVError.asleep }
            connected = found.device
            states.publish(.ready)
        } catch {
            states.publish(error as? TVError == .asleep ? .asleep : .degraded)
            throw error
        }
    }

    public func send(_ key: RemoteKey) async throws {
        let keys = try Self.ecpKeys(key)
        guard !keys.isEmpty else { return }
        let endpoint: TVEndpoint
        do {
            endpoint = try await verifiedEndpoint()
        } catch TVError.asleep where key == .powerOff {
            return
        }
        for code in keys {
            _ = try await request(.post, endpoint: endpoint, path: "/keypress/" + Self.encodeSegment(code))
        }
    }

    public func launch(_ app: AppID) async throws {
        guard !app.rawValue.isEmpty, app.rawValue != ".", app.rawValue != ".." else {
            throw TVError.invalidCommand
        }
        try await command(path: "/launch/" + Self.encodeSegment(app.rawValue))
    }

    public func search(_ query: String) async throws {
        guard !query.isEmpty else { throw TVError.invalidCommand }
        try await command(path: "/search/browse", query: [URLQueryItem(name: "keyword", value: query)])
    }

    public func wake(_ tv: TVDevice) async throws {
        guard tv.id.platform == .roku else { throw TVError.identityMismatch }
        guard try await probe(tv.endpoint).id == tv.id else { throw TVError.identityMismatch }
        _ = try await request(.post, endpoint: tv.endpoint, path: "/keypress/PowerOn")
    }

    public func keepAlive() async throws {
        _ = try await verifiedEndpoint()
    }

    private func verifiedEndpoint() async throws -> TVEndpoint {
        guard let connected else { throw TVError.notConnected }
        let found = try await snapshot(connected.endpoint)
        guard self.connected == connected else { throw TVError.notConnected }
        guard found.device.id == connected.id else { throw TVError.identityMismatch }
        guard !found.asleep else { throw TVError.asleep }
        return connected.endpoint
    }

    private func snapshot(_ endpoint: TVEndpoint) async throws -> (device: TVDevice, asleep: Bool) {
        let body = try await request(.get, endpoint: endpoint, path: "/query/device-info")
        return try DeviceInfo.parse(body, endpoint: endpoint)
    }

    private func command(path: String, query: [URLQueryItem] = []) async throws {
        let endpoint = try await verifiedEndpoint()
        _ = try await request(.post, endpoint: endpoint, path: path, query: query)
    }

    private func request(
        _ method: HTTPRequest.Method, endpoint: TVEndpoint, path: String, query: [URLQueryItem] = []
    ) async throws -> Data {
        guard !endpoint.host.isEmpty, endpoint.port != 0 else { throw TVError.invalidAddress }
        var components = URLComponents()
        components.scheme = "http"
        let host = endpoint.host
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = Int(endpoint.port)
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw TVError.invalidAddress }
        let response = try await http.request(HTTPRequest(method, url: url))
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 { throw TVError.notSupported }
            throw TVError.requestFailed(status: response.status)
        }
        return response.body
    }

    private static func encodeSegment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func ecpKeys(_ key: RemoteKey) throws -> [String] {
        switch key {
        case .up: ["Up"]
        case .down: ["Down"]
        case .left: ["Left"]
        case .right: ["Right"]
        case .ok: ["Select"]
        case .back: ["Back"]
        case .home: ["Home"]
        case .options: ["Info"]
        case .volumeUp: ["VolumeUp"]
        case .volumeDown: ["VolumeDown"]
        case .mute: ["VolumeMute"]
        case .channelUp: ["ChannelUp"]
        case .channelDown: ["ChannelDown"]
        case .power: ["Power"]
        case .powerOn: ["PowerOn"]
        case .powerOff: ["PowerOff"]
        case .playPause: ["Play"]
        case .rewind: ["Rev"]
        case .fastForward: ["Fwd"]
        case .delete: ["Backspace"]
        case .digit(let digit):
            if digit < 10 { ["Lit_\(digit)"] } else { throw TVError.invalidCommand }
        case .text(let text): text.unicodeScalars.map { "Lit_" + String($0) }
        case .play, .pause, .stop: throw TVError.notSupported
        }
    }
}

private final class DeviceInfo: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var stack: [String] = []
    private var value = ""
    private var root: String?

    static func parse(_ data: Data, endpoint: TVEndpoint) throws -> (device: TVDevice, asleep: Bool) {
        let info = DeviceInfo()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = info
        guard parser.parse(), info.root == "device-info" else { throw TVError.invalidResponse }
        let identifier = info.first("udn", "serial-number", "device-id")
        guard let identifier else { throw TVError.invalidResponse }
        let name = info.first("friendly-device-name", "user-device-name", "default-device-name", "model-name") ?? "Roku"
        var capabilities: TVCapabilities = [.remoteKeys, .launch, .keyboard]
        if info.fields["search-enabled"] != "false" { capabilities.insert(.search) }
        if info.fields["is-tv"] == "true" { capabilities.insert(.networkWake) }
        let device = TVDevice(
            id: TVIdentity(platform: .roku, identifier: identifier.lowercased()),
            name: name, endpoint: endpoint, capabilities: capabilities
        )
        let powerMode = info.fields["power-mode"]?.lowercased()
        return (device, powerMode == "poweroff" || powerMode == "standby")
    }

    private func first(_ keys: String...) -> String? {
        keys.compactMap { fields[$0] }.first { !$0.isEmpty }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String]
    ) {
        if stack.isEmpty { root = elementName }
        stack.append(elementName)
        if stack.count == 2 { value = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if stack.count == 2 { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count == 2 { fields[elementName] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        _ = stack.popLast()
    }
}
