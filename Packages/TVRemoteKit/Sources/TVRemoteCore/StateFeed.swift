import Foundation

package final class StateFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ConnectionState = .idle
    private var listeners: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    package init() {}

    package func subscribe() -> AsyncStream<ConnectionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
            lock.withLock {
                listeners[id] = continuation
                continuation.yield(current)
            }
        }
    }

    package func publish(_ state: ConnectionState) {
        lock.withLock {
            guard current != state else { return }
            current = state
            for listener in listeners.values {
                listener.yield(state)
            }
        }
    }

    private func remove(_ id: UUID) {
        lock.withLock { _ = listeners.removeValue(forKey: id) }
    }

    deinit {
        for listener in listeners.values {
            listener.finish()
        }
    }
}
