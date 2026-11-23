#if canImport(Darwin)
import Darwin
import Foundation

public struct SocketUDPDatagramTransport: UDPDatagramTransport {
    public init() {}

    public func send(_ datagram: Data, to endpoint: TVEndpoint) async throws {
        try Task.checkCancellation()
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        guard endpoint.port != 0, inet_pton(AF_INET, endpoint.host, &address.sin_addr) == 1 else {
            throw TVError.invalidAddress
        }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw TVError.unreachable }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TVError.unreachable
        }

        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                datagram.withUnsafeBytes {
                    sendto(descriptor, $0.baseAddress, $0.count, 0, target, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == datagram.count else { throw TVError.unreachable }
    }
}
#endif
