import Foundation
import BlinkCore

/// Набор id, который трогают из разных потоков.
private final class IdSet: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }

    func add(_ more: [String]) {
        lock.lock()
        ids.formUnion(more)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        ids.removeAll()
        lock.unlock()
    }
}

/// Замок «идёт загрузка партии»: одновременно собирается только одна.
private final class Busy: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if on { return false }
        on = true
        return true
    }

    func end() {
        lock.lock()
        on = false
        lock.unlock()
    }
}

/// Вспышка на телефоне: запускает поток, подкладывает новые треки, пока играет текущий, и пересказывает
/// движку, что слушали, что пропустили и что «не моё». Сам алгоритм живёт в ядре (`WaveEngine`).
/// Порт flash/FlashController.kt. Все `@Published` меняются на главном потоке.
final class FlashController: ObservableObject, @unchecked Sendable {
    @Published private(set) var active = false
    @Published private(set) var loading = false
    @Published private(set) var mode: WaveMode
    @Published private(set) var likes: [Track] = []

    private let engine: WaveEngine
    private let library: LibraryStore
    private let player: PlayerController
    private let actions: Actions
    private let api: BlinkApi
    private let toasts: Toasts
    private let network: NetworkMonitor
    private let settings: WaveSettingsBox

    private let queued = IdSet()
    private let busy = Busy()
    private var last: PlayerUi?
    private var tokens: [NetworkObservation] = []

    private static let batchSize = 16
    private static let refillAt = 3
    private static let skipMs: Int64 = 12_000

    init(
        engine: WaveEngine,
        library: LibraryStore,
        player: PlayerController,
        actions: Actions,
        api: BlinkApi,
        toasts: Toasts,
        network: NetworkMonitor,
        settings: WaveSettingsBox
    ) {
        self.engine = engine
        self.library = library
        self.player = player
        self.actions = actions
        self.api = api
        self.toasts = toasts
        self.network = network
        self.settings = settings
        self.mode = settings.value.mode
    }

    /// Подписка на плеер и библиотеку. Зовётся один раз из Graph.
    func attach() {
        onMain { [self] in likes = library.likes }
        tokens.append(library.observe { [weak self] _ in
            self?.onMain { self?.likes = self?.library.likes ?? [] }
        })
        tokens.append(player.observe { [weak self] ui in
            self?.onMain { self?.playerChanged(ui) }
        })
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    private func playerChanged(_ ui: PlayerUi) {
        let before = last
        last = ui
        let now = ui.track
        let prev = before?.track
        if let now = now, now.id != prev?.id {
            library.noteRecent(now)
            if let before = before, let prev = prev, active {
                // Ушли с трека: дослушали или нажали «дальше» в первые секунды.
                let fraction = before.durationMs > 0 ? Double(before.positionMs) / Double(before.durationMs) : 0
                let engine = self.engine
                if fraction >= 0.7 {
                    Task { await engine.noteListen(prev, fraction: fraction) }
                } else if before.positionMs < FlashController.skipMs {
                    Task { await engine.noteSkip(prev) }
                }
            }
        }
        if active && now != nil && ui.queueLeft <= FlashController.refillAt { refill() }
    }

    func start() {
        if !busy.begin() { return }
        active = true
        loading = true
        queued.clear()
        Task { [self] in
            let quick = await engine.quickStart()
            if !quick.isEmpty {
                queued.add(quick.map { $0.id })
                actions.play(quick, at: 0)
            }
            let more = await fresh()
            if quick.isEmpty {
                if more.isEmpty {
                    toasts.show("Не получилось собрать Вспышку. Проверьте интернет и попробуйте ещё раз")
                    onMain { self.active = false }
                } else {
                    actions.play(more, at: 0)
                }
            } else if !more.isEmpty && network.isOnline {
                player.append(more)
            }
            busy.end()
            onMain { self.loading = false }
        }
    }

    func stop() {
        active = false
    }

    private func refill() {
        if !busy.begin() { return }
        onMain { self.loading = true }
        Task { [self] in
            let more = await fresh()
            if !more.isEmpty && active { player.append(more) }
            busy.end()
            onMain { self.loading = false }
        }
    }

    /// Свежая партия от движка; если сервер молчит, то чарт и лайки, чтобы музыка не обрывалась.
    private func fresh() async -> [Track] {
        var batch = await engine.batch(FlashController.batchSize, exclude: queued.snapshot())
        if batch.isEmpty {
            let chart = (try? await api.chart(limit: 30)) ?? []
            let have = queued.snapshot()
            var seen = Set<String>()
            for t in library.likes.shuffled() + chart.shuffled() where !have.contains(t.id) && seen.insert(t.id).inserted {
                batch.append(t)
                if batch.count >= FlashController.batchSize { break }
            }
        }
        queued.add(batch.map { $0.id })
        return batch
    }

    func setMode(_ next: WaveMode) {
        settings.setMode(next)
        mode = next
    }

    /// «Не моё»: запомнить и сразу перейти к следующему.
    func dislike(_ track: Track) {
        let engine = self.engine
        Task { await engine.dislike(track) }
        toasts.show("Больше такого не будет")
        player.next()
    }

    func isLiked(_ track: Track) -> Bool {
        return likes.contains { $0.id == track.id }
    }

    func toggleLike(_ track: Track) {
        let liked = library.toggleLike(track)
        toasts.show(liked ? "Добавлено в понравившееся" : "Убрано из понравившегося")
    }
}
