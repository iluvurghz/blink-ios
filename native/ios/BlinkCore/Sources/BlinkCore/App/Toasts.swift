import Foundation

/// Короткое сообщение внизу экрана. Кнопка в нём нужна для «Войти», «Открыть Blink+», «Повторить».
public struct Toast: Sendable {
    public let message: String
    public let action: String?
    public let onAction: (@Sendable () -> Void)?

    public init(message: String, action: String? = nil, onAction: (@Sendable () -> Void)? = nil) {
        self.message = message
        self.action = action
        self.onAction = onAction
    }
}

/// Общая шина тостов: их шлют и экраны, и плеер, и загрузки. Событие доходит только тем, кто подписан сейчас
/// (позднему подписчику старый тост не повторяем).
public final class Toasts: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [Int: @Sendable (Toast) -> Void] = [:]
    private var nextId = 0
    private let queue = DispatchQueue(label: "app.blink.toasts")

    public init() {}

    public func show(_ message: String, action: String? = nil, onAction: (@Sendable () -> Void)? = nil) {
        let toast = Toast(message: message, action: action, onAction: onAction)
        lock.lock()
        let list = Array(handlers.values)
        lock.unlock()
        queue.async {
            for h in list { h(toast) }
        }
    }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Toast) -> Void) -> NetworkObservation {
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
