import TVRemoteCore

actor GoogleTVRemoteSession {
    private enum Feature {
        static let key: UInt64 = 1 << 1
        static let ime: UInt64 = 1 << 2
        static let link: UInt64 = 1 << 9
        static let supported: UInt64 = 1 | key | ime | (1 << 5) | (1 << 6) | link
    }

    private let wire: GoogleTVWire
    private let clock: any ConnectionClock
    private let now: @Sendable () -> ContinuousClock.Instant
    private var lastActivity: ContinuousClock.Instant
    private var features: UInt64 = 0
    private var loss: (any Error)?
    private var imeCounter: UInt64?
    private var fieldCounter: UInt64?

    var supportsText: Bool { features & Feature.ime != 0 }
    var supportsAppLinks: Bool { features & Feature.link != 0 }

    init(
        wire: GoogleTVWire, clock: any ConnectionClock = SystemConnectionClock(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.wire = wire
        self.clock = clock
        self.now = now
        lastActivity = now()
    }

    func start() async throws {
        var configured = false
        for _ in 0..<24 {
            let message = try await read()
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
                try await handle(message)
            }
        }
        throw TVError.invalidResponse
    }

    func listen(states: StateFeed) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receiveMessages() }
                group.addTask { try await self.monitorIdle() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch {
            if !Task.isCancelled {
                loss = error
                states.publish(.degraded)
            }
        }
        await wire.stream.close()
    }

    private func receiveMessages() async throws {
        while !Task.isCancelled {
            try await handle(read(timeout: nil))
        }
    }

    private func monitorIdle() async throws {
        while !Task.isCancelled {
            let remaining = now().duration(to: lastActivity + .seconds(16))
            guard remaining > .zero else { throw TVError.timedOut }
            try await clock.sleep(for: remaining)
        }
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
        guard supportsAppLinks else { throw TVError.notSupported }
        try await send(90, Proto([(1, Proto.string(link))]))
    }

    func sendText(_ text: String) async throws {
        try checkConnection()
        guard supportsText, let fieldCounter else { throw TVError.notSupported }
        guard !text.isEmpty else { throw TVError.invalidCommand }
        let length = UInt64(text.utf16.count)
        let status = Proto([(1, .number(length)), (2, .number(length)), (3, Proto.string(text))])
        let edit = Proto([(1, .number(1)), (2, Proto.message(status))])
        try await send(21, Proto([(1, .number(imeCounter ?? 0)), (2, .number(fieldCounter)), (3, Proto.message(edit))]))
    }

    private func handle(_ message: Proto) async throws {
        if let ping = try message.message(8) {
            try await send(9, Proto([(1, .number(ping.number(1) ?? 0))]))
        } else if let inject = try message.message(20) {
            imeCounter = try inject.message(1)?.number(1)
            fieldCounter = try inject.message(2)?.number(1)
        } else if let show = try message.message(22) {
            fieldCounter = try show.message(2)?.number(1)
        } else if let edit = try message.message(21) {
            if let counter = edit.number(1) { imeCounter = counter }
            if let counter = edit.number(2) { fieldCounter = counter }
        }
    }

    private func send(_ field: Int, _ message: Proto) async throws {
        try await wire.send(Proto([(field, Proto.message(message))]))
        lastActivity = now()
    }

    private func read(timeout: Duration? = .seconds(3)) async throws -> Proto {
        let message = try await wire.read(timeout: timeout)
        lastActivity = now()
        return message
    }
}
