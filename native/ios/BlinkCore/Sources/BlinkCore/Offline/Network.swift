import Foundation

/// Подписка на сеть. Снимается вызовом `cancel()`.
public final class NetworkObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (() -> Void)?

    public init(_ onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        let f = onCancel
        onCancel = nil
        lock.unlock()
        f?()
    }
}

/// Есть ли сеть. На iOS это NWPathMonitor, на Android ConnectivityManager, в тестах переключатель.
public protocol NetworkMonitor: AnyObject, Sendable {
    var isOnline: Bool { get }

    /// Вызывается при смене состояния (не при подписке).
    func observe(_ handler: @escaping @Sendable (Bool) -> Void) -> NetworkObservation
}

public final class StaticNetwork: NetworkMonitor, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    private var handlers: [Int: @Sendable (Bool) -> Void] = [:]
    private var nextId = 0

    public init(_ initial: Bool = true) {
        self.value = initial
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func set(_ online: Bool) {
        lock.lock()
        let changed = value != online
        value = online
        let list = Array(handlers.values)
        lock.unlock()
        if changed {
            for h in list { h(online) }
        }
    }

    public func observe(_ handler: @escaping @Sendable (Bool) -> Void) -> NetworkObservation {
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
}
