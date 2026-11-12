import Foundation

/// Значение с подписчиками (аналог StateFlow): первое значение приходит сразу, изменения доходят по порядку
/// на отдельной последовательной очереди и не под замком, поэтому обработчик может звать модель обратно.
final class Observable<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    private var handlers: [Int: @Sendable (Value) -> Void] = [:]
    private var nextId = 0
    private let queue = DispatchQueue(label: "app.blink.observable")

    init(_ initial: Value) {
        self.value = initial
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Меняет значение под замком и рассылает новое. Возвращает его.
    @discardableResult
    func update(_ change: (inout Value) -> Void) -> Value {
        lock.lock()
        change(&value)
        let v = value
        let list = Array(handlers.values)
        queue.async {
            for h in list { h(v) }
        }
        lock.unlock()
        return v
    }

    func observe(_ handler: @escaping @Sendable (Value) -> Void) -> NetworkObservation {
        lock.lock()
        let id = nextId
        nextId += 1
        handlers[id] = handler
        let v = value
        queue.async { handler(v) }
        lock.unlock()
        return NetworkObservation { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.handlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }
}

/// Асинхронный замок по очереди (как Mutex у корутин): тот, кто ждёт, не занимает поток.
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
