import Foundation

public struct MACAddress: Sendable, Hashable, Codable, RawRepresentable {
    public let rawValue: String
    private let bytes: [UInt8]

    public init?(rawValue: String) {
        let hex = rawValue.utf8.filter { $0 != 58 && $0 != 45 }
        guard hex.count == 12,
              hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let octets = stride(from: 0, to: hex.count, by: 2).compactMap {
            UInt8(String(decoding: hex[$0..<($0 + 2)], as: UTF8.self), radix: 16)
        }
        guard octets.count == 6, octets[0] & 1 == 0, octets.contains(where: { $0 != 0 }) else { return nil }
        bytes = octets
        self.rawValue = octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let address = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid unicast MAC address")
        }
        self = address
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var magicPacket: Data {
        var packet = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }
}

public protocol UDPDatagramTransport: Sendable {
    func send(_ datagram: Data, to endpoint: TVEndpoint) async throws
}

public struct WakeOnLAN: Sendable {
    private let transport: any UDPDatagramTransport
    private let broadcast: TVEndpoint

    public init(
        transport: any UDPDatagramTransport,
        broadcast: TVEndpoint = TVEndpoint(host: "255.255.255.255", port: 9)
    ) {
        self.transport = transport
        self.broadcast = broadcast
    }

    public func send(to address: MACAddress) async throws {
        try Task.checkCancellation()
        try await transport.send(address.magicPacket, to: broadcast)
    }
}
