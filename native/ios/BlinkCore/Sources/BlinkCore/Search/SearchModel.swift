import Foundation

public struct SearchState: Equatable, Sendable {
    public var loading: Bool
    /// Результаты относятся к введённому запросу (а не к пустой строке).
    public var searched: Bool
    public var results: [Track]
    /// Поиск не дошёл до сервера (сеть, сервер). Пустой результат без ошибки это «ничего не нашли».
    public var error: Bool
    public var newest: [Track]
    public var chart: [Track]
    public var homeLoading: Bool
    public var homeError: Bool

    public init(
        loading: Bool = false,
        searched: Bool = false,
        results: [Track] = [],
        error: Bool = false,
        newest: [Track] = [],
        chart: [Track] = [],
        homeLoading: Bool = false,
        homeError: Bool = false
    ) {
        self.loading = loading
        self.searched = searched
        self.results = results
        self.error = error
        self.newest = newest
        self.chart = chart
        self.homeLoading = homeLoading
        self.homeError = homeError
    }
}

/// Поиск с задержкой 350 мс и «побеждает последний запрос» плюс стартовая страница (новое в Blink и чарт).
/// Сеть приходит снаружи функциями, поэтому модель одинаково проверяется тестами без UI.
public final class SearchModel: @unchecked Sendable {
    public typealias SearchFn = @Sendable (String) async throws -> [Track]
    public typealias ListFn = @Sendable () async throws -> [Track]

    private let search: SearchFn
    private let newest: ListFn
    private let chart: ListFn
    private let debounceMs: Int64

    private let state = Observable(SearchState())
    private let lock = NSLock()
    private var generation = 0
    private var queryText = ""
    private var searchTask: Task<Void, Never>?
    private var homeTask: Task<Void, Never>?

    public init(
        search: @escaping SearchFn,
        newest: @escaping ListFn,
        chart: @escaping ListFn,
        debounceMs: Int64 = 350
    ) {
        self.search = search
        self.newest = newest
        self.chart = chart
        self.debounceMs = debounceMs
    }

    public var current: SearchState { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (SearchState) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    public func setQuery(_ text: String) {
        start(text, nonce: 0)
    }

    /// «Повторить» после ошибки: тот же запрос, без задержки.
    public func retry() {
        lock.lock()
        let text = queryText
        lock.unlock()
        start(text, nonce: 1)
    }

    /// Останавливает фоновые задачи (экран закрыт).
    public func stop() {
        lock.lock()
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        homeTask?.cancel()
        homeTask = nil
        lock.unlock()
    }

    private func start(_ text: String, nonce: Int) {
        lock.lock()
        generation += 1
        let gen = generation
        queryText = text
        searchTask?.cancel()
        searchTask = Task { [self] in
            await run(text, nonce: nonce, gen: gen)
        }
        lock.unlock()
    }

    /// Применяет изменение, только если запрос ещё актуален (побеждает последний).
    private func apply(_ gen: Int, _ change: (inout SearchState) -> Void) {
        lock.lock()
        let fresh = gen == generation
        lock.unlock()
        if fresh { state.update(change) }
    }

    private func run(_ raw: String, nonce: Int, gen: Int) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            apply(gen) { $0.loading = false; $0.searched = false; $0.results = []; $0.error = false }
            return
        }
        apply(gen) { $0.loading = true; $0.error = false }
        if nonce == 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, debounceMs)) * 1_000_000)
            } catch {
                return
            }
        }
        do {
            let found = try await search(text)
            if Task.isCancelled { return }
            apply(gen) { $0.loading = false; $0.searched = true; $0.results = found; $0.error = false }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            apply(gen) { $0.loading = false; $0.searched = true; $0.results = []; $0.error = true }
        }
    }

    /// Новое в Blink и чарт. Каждая часть живёт сама: упал чарт, новое всё равно покажется.
    public func refreshHome() {
        lock.lock()
        homeTask?.cancel()
        homeTask = Task { [self] in
            await loadHome()
        }
        lock.unlock()
    }

    private func loadHome() async {
        state.update { $0.homeLoading = true; $0.homeError = false }
        async let freshResult = capture(newest)
        async let topResult = capture(chart)
        let fresh = await freshResult
        let top = await topResult
        if Task.isCancelled { return }
        state.update { s in
            s.homeLoading = false
            if let list = try? fresh.get() { s.newest = list }
            if let list = try? top.get() { s.chart = list }
            var freshFailed = false
            if case .failure = fresh { freshFailed = true }
            var topFailed = false
            if case .failure = top { topFailed = true }
            s.homeError = freshFailed && topFailed && s.newest.isEmpty && s.chart.isEmpty
        }
    }

    private func capture(_ op: ListFn) async -> Result<[Track], Error> {
        do {
            return .success(try await op())
        } catch {
            return .failure(error)
        }
    }
}
