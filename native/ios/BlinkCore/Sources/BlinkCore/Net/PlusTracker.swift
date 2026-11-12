import Foundation

/// Маленькое хранилище строк. На iOS это UserDefaults.
public protocol KeyValue: AnyObject, Sendable {
    func get(_ key: String) -> String?
    func put(_ key: String, _ value: String?)
}

/// Последнее, что известно про Blink+. Без сети живём по сохранённой дате.
public struct PlusInfo: Equatable, Sendable {
    public var active: Bool
    public var untilMs: Int64?
    public var checkedAtMs: Int64

    public init(active: Bool = false, untilMs: Int64? = nil, checkedAtMs: Int64 = 0) {
        self.active = active
        self.untilMs = untilMs
        self.checkedAtMs = checkedAtMs
    }

    /// Активна ли подписка прямо сейчас по последней известной дате.
    public func activeAt(_ nowMs: Int64) -> Bool {
        guard active else { return false }
        guard let until = untilMs else { return true }
        return until > nowMs
    }

    /// Дата для `OfflinePolicy.canPlaySaved`: бессрочной подписке даём «бесконечность».
    public func offlineUntilMs() -> Int64? {
        if !active { return nil }
        return untilMs ?? Int64.max
    }
}

/// Состояние Blink+ с кэшем на диске. `refresh` ходит на сервер; при сбое остаётся прежнее значение
/// (важно в самолёте: сохранённые треки должны играть по последней известной дате).
public final class PlusTracker: @unchecked Sendable {
    private static let kActive = "plus.active"
    private static let kUntil = "plus.until"
    private static let kChecked = "plus.checked"

    private let fetch: @Sendable () async throws -> PlusStatus?
    private let store: KeyValue
    private let now: @Sendable () -> Int64
    private let state: Observable<PlusInfo>

    public init(
        fetch: @escaping @Sendable () async throws -> PlusStatus?,
        store: KeyValue,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.fetch = fetch
        self.store = store
        self.now = now
        let active = store.get(PlusTracker.kActive) == "1"
        let until = store.get(PlusTracker.kUntil).flatMap { Int64($0) }
        let checked = store.get(PlusTracker.kChecked).flatMap { Int64($0) } ?? 0
        self.state = Observable(PlusInfo(active: active, untilMs: until, checkedAtMs: checked))
    }

    public var info: PlusInfo { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (PlusInfo) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    /// Возвращает true, если сервер ответил (даже «подписки нет»).
    public func refresh() async -> Bool {
        let status: PlusStatus?
        do {
            status = try await fetch()
        } catch {
            return false
        }
        guard let s = status else { return false }
        let next = PlusInfo(active: s.active, untilMs: s.untilMs, checkedAtMs: now())
        store.put(PlusTracker.kActive, next.active ? "1" : "0")
        store.put(PlusTracker.kUntil, next.untilMs.map { String($0) })
        store.put(PlusTracker.kChecked, String(next.checkedAtMs))
        state.update { $0 = next }
        return true
    }

    /// При выходе из аккаунта: подписка принадлежит аккаунту.
    public func clear() {
        store.put(PlusTracker.kActive, nil)
        store.put(PlusTracker.kUntil, nil)
        store.put(PlusTracker.kChecked, nil)
        state.update { $0 = PlusInfo() }
    }
}
