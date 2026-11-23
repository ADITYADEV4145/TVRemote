#if canImport(Network) && canImport(Darwin)
import Darwin
import Foundation
import Network

enum AppleDiscovery {
    private static let queue = DispatchQueue(label: "TVRemoteKit.discovery", qos: .utility)

    static func browse(
        type: String, platform: TVPlatform, into output: AsyncStream<DiscoveryCandidate>.Continuation
    ) async {
        let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        let endpoints = AsyncStream<NWEndpoint>(bufferingPolicy: .bufferingNewest(32)) { continuation in
            browser.browseResultsChangedHandler = { _, changes in
                for change in changes {
                    switch change {
                    case .added(let result), .changed(_, let result, _): continuation.yield(result.endpoint)
                    default: break
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
                if case .cancelled = state { continuation.finish() }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { continuation.finish() }
            }
            continuation.onTermination = { _ in
                timer.cancel()
                browser.cancel()
            }
            browser.start(queue: queue)
        }

        await withTaskGroup(of: Void.self) { group in
            var seen: Set<NWEndpoint> = []
            for await endpoint in endpoints {
                guard !Task.isCancelled, seen.count < 32 else { break }
                guard seen.insert(endpoint).inserted else { continue }
                group.addTask {
                    if let resolved = await reachableEndpoint(endpoint, timeout: .seconds(1)) {
                        output.yield(DiscoveryCandidate(platform: platform, endpoint: resolved))
                    }
                }
            }
        }
    }

    static func ssdp(platform: TVPlatform, into output: AsyncStream<DiscoveryCandidate>.Continuation) async {
        let receiver = Task.detached(priority: .utility) {
            let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard socketFD >= 0 else { return }
            defer { close(socketFD) }

            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = UInt16(1900).bigEndian
            inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)

            let target = platform == .roku ? "roku:ecp" : "ssdp:all"
            let packet = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n".utf8)
            let sent = withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    packet.withUnsafeBytes {
                        sendto(socketFD, $0.baseAddress, $0.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { return }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            var buffer = [UInt8](repeating: 0, count: 8192)
            var seen: Set<DiscoveryCandidate> = []
            while !Task.isCancelled, clock.now < deadline, seen.count < 32 {
                let ready = poll(&descriptor, 1, 100)
                if ready < 0 { break }
                guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { continue }
                var source = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &source) { address in
                    address.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        buffer.withUnsafeMutableBytes {
                            recvfrom(socketFD, $0.baseAddress, $0.count, MSG_DONTWAIT, address, &size)
                        }
                    }
                }
                if count <= 0 { continue }
                let host = addressString(UInt32(bigEndian: source.sin_addr.s_addr))
                if let candidate = LocalDiscoverySource.ssdpCandidate(Data(buffer.prefix(count)), source: host, platform: platform),
                   seen.insert(candidate).inserted {
                    output.yield(candidate)
                }
            }
        }
        await withTaskCancellationHandler {
            await receiver.value
        } onCancel: {
            receiver.cancel()
        }
    }

    static func scanRokuSubnet(into output: AsyncStream<DiscoveryCandidate>.Continuation) async {
        guard let addresses = localSubnet() else { return }
        await withTaskGroup(of: Void.self) { group in
            for (index, host) in addresses.enumerated() {
                if Task.isCancelled { break }
                if index >= 16 { _ = await group.next() }
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: 8060)
                group.addTask {
                    if let reachable = await reachableEndpoint(endpoint, timeout: .milliseconds(300)) {
                        output.yield(DiscoveryCandidate(platform: .roku, endpoint: reachable))
                    }
                }
            }
        }
    }

    private static func reachableEndpoint(_ endpoint: NWEndpoint, timeout: Duration) async -> TVEndpoint? {
        guard !Task.isCancelled else { return nil }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let answers = AsyncStream<TVEndpoint> { continuation in
            connection.stateUpdateHandler = { [weak connection] state in
                switch state {
                case .ready:
                    let remote = connection?.currentPath?.remoteEndpoint ?? endpoint
                    if case .hostPort(let host, let port) = remote {
                        continuation.yield(TVEndpoint(host: host.debugDescription, port: port.rawValue))
                    }
                    continuation.finish()
                case .failed, .cancelled:
                    continuation.finish()
                default: break
                }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { continuation.finish() }
            }
            continuation.onTermination = { _ in
                timer.cancel()
                connection.cancel()
            }
            connection.start(queue: queue)
        }
        for await answer in answers { return answer }
        return nil
    }

    private static func localSubnet() -> [String]? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer?.pointee {
            pointer = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), entry.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == AF_INET,
                  let netmask = entry.ifa_netmask else { continue }
            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            } | 0xFFFF_FF00
            let network = local & mask
            let broadcast = network | ~mask
            guard broadcast - network > 1 else { continue }
            return ((network + 1)..<broadcast).lazy.filter { $0 != local }.map(addressString)
        }
        return nil
    }

    private static func addressString(_ address: UInt32) -> String {
        "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }
}
#endif
