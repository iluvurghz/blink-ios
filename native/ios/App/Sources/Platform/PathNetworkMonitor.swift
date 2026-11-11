import Foundation
import Network
import BlinkCore

/// Есть ли сеть, по данным системы (NWPathMonitor). Поведение как у StaticNetwork в тестах ядра:
/// подписчикам приходит только смена состояния.
final class PathNetworkMonitor: NetworkMonitor, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.blink.network")
    private let lock = NSLock()
    private var online = true
    private var handlers: [Int: @Sendable (Bool) -> Void] = [:]
    private var nextId = 0

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    func observe(_ handler: @escaping @Sendable (Bool) -> Void) -> NetworkObservation {
        lock.lock()
        let id = nextId
        nextId += 1
        handlers[id] = handler
        lock.unlock()
        return NetworkObservation { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.handlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private func update(_ value: Bool) {
        lock.lock()
        let changed = online != value
        online = value
        let list = Array(handlers.values)
        lock.unlock()
        if changed {
            for handler in list { handler(value) }
        }
    }
}
