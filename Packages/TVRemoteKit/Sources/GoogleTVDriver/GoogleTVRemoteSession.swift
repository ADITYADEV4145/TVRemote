import TVRemoteCore

actor GoogleTVRemoteSession {
    private enum Feature {
        static let key: UInt64 = 1 << 1
        static let link: UInt64 = 1 << 9
        static let supported: UInt64 = 1 | key | (1 << 5) | (1 << 6) | link
    }

    private let wire: GoogleTVWire
    private var features: UInt64 = 0
    private var loss: (any Error)?

    init(wire: GoogleTVWire) {
        self.wire = wire
    }

    func start() async throws {
        var configured = false
        for _ in 0..<24 {
            let message = try await wire.read()
            if let config = try message.message(1), let mask = config.number(1) {
                configured = true
                features = mask & Feature.supported
                let device = Proto([
                    (3, .number(1)), (4, Proto.string("1")),
                    (5, Proto.string("atvremote")), (6, Proto.string("1.0.0"))
                ])
                try await send(1, Proto([(1, .number(features)), (2, Proto.message(device))]))
            } else if try message.message(2) != nil {
                guard configured else { throw TVError.invalidResponse }
                try await send(2, Proto([(1, .number(features))]))
            } else if try message.message(40) != nil {
                guard configured else { throw TVError.invalidResponse }
                return
            } else if try message.message(3) != nil {
                throw TVError.invalidResponse
            } else {
                try await answerPing(message)
            }
        }
        throw TVError.invalidResponse
    }

    func listen(states: StateFeed) async {
        do {
            while !Task.isCancelled {
                let message = try await wire.read(timeout: .seconds(16))
                try await answerPing(message)
            }
        } catch {
            if !Task.isCancelled {
                loss = error
                states.publish(.degraded)
            }
        }
        await wire.stream.close()
    }

    func checkConnection() throws {
        if let loss { throw loss }
    }

    func sendKey(_ code: UInt64) async throws {
        try checkConnection()
        guard features & Feature.key != 0 else { throw TVError.notSupported }
        try await send(10, Proto([(1, .number(code)), (2, .number(3))]))
    }

    func launch(_ link: String) async throws {
        try checkConnection()
        guard features & Feature.link != 0 else { throw TVError.notSupported }
        try await send(90, Proto([(1, Proto.string(link))]))
    }

    private func answerPing(_ message: Proto) async throws {
        guard let ping = try message.message(8) else { return }
        try await send(9, Proto([(1, .number(ping.number(1) ?? 0))]))
    }

    private func send(_ field: Int, _ message: Proto) async throws {
        try await wire.send(Proto([(field, Proto.message(message))]))
    }
}
