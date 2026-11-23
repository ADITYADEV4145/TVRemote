import Foundation

public struct LocalDiscoverySource: DiscoverySource {
    public let enableSSDP: Bool
    public let enableSubnetProbe: Bool

    public init(enableSSDP: Bool = false, enableSubnetProbe: Bool = false) {
        self.enableSSDP = enableSSDP
        self.enableSubnetProbe = enableSubnetProbe
    }

    public static let bonjourServiceTypes: [TVPlatform: [String]] = [
        .roku: ["_roku-ecp._tcp"],
        .googleTV: ["_androidtvremote2._tcp"],
        .samsung: ["_samsungmsf._tcp"]
    ]

    public func browse(for platform: TVPlatform) -> AsyncStream<DiscoveryCandidate> {
        #if canImport(Network) && canImport(Darwin)
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for type in Self.bonjourServiceTypes[platform, default: []] {
                        group.addTask {
                            await AppleDiscovery.browse(type: type, platform: platform, into: continuation)
                        }
                    }
                    if enableSSDP, platform != .googleTV {
                        group.addTask {
                            await AppleDiscovery.ssdp(platform: platform, into: continuation)
                        }
                    }
                    if enableSubnetProbe, platform == .roku {
                        group.addTask {
                            await AppleDiscovery.scanRokuSubnet(into: continuation)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        AsyncStream { $0.finish() }
        #endif
    }

    package static func ssdpCandidate(
        _ data: Data, source: String, platform: TVPlatform
    ) -> DiscoveryCandidate? {
        guard let packet = String(data: data, encoding: .utf8) else { return nil }
        let lines = packet.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.1 200") else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let location = headers["location"], let url = URLComponents(string: location),
              url.scheme?.lowercased() == "http", url.host?.caseInsensitiveCompare(source) == .orderedSame else {
            return nil
        }
        let fingerprint = [headers["st"], headers["usn"], headers["server"]].compactMap { $0 }.joined(separator: " ").lowercased()
        let port: Int
        switch platform {
        case .roku:
            guard fingerprint.contains("roku:ecp") else { return nil }
            port = url.port ?? 8060
        case .samsung:
            guard fingerprint.contains("samsung") else { return nil }
            port = 8002
        case .lg:
            guard fingerprint.contains("webos") || fingerprint.contains("lge") else { return nil }
            port = 3001
        case .googleTV:
            return nil
        }
        guard let validPort = UInt16(exactly: port), validPort != 0 else { return nil }
        return DiscoveryCandidate(platform: platform, endpoint: TVEndpoint(host: source, port: validPort))
    }
}
