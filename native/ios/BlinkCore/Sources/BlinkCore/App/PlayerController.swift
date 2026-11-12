import Foundation

/// Что видит экран: текущий трек, состояние и позиция. Всё остальное знает контроллер.
public struct PlayerUi: Equatable, Sendable {
    public var track: Track?
    public var playing: Bool
    public var buffering: Bool
    public var positionMs: Int64
    public var durationMs: Int64
    public var hasNext: Bool
    public var hasPrevious: Bool
    /// Сколько треков осталось в очереди после текущего.
    public var queueLeft: Int
    /// Номер текущего трека в очереди.
    public var index: Int
    /// Перемешано ли то, что осталось в очереди.
    public var shuffle: Bool
    public var repeatMode: RepeatMode

    public init(
        track: Track? = nil,
        playing: Bool = false,
        buffering: Bool = false,
        positionMs: Int64 = 0,
        durationMs: Int64 = 0,
        hasNext: Bool = false,
        hasPrevious: Bool = false,
        queueLeft: Int = 0,
        index: Int = 0,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off
    ) {
        self.track = track
        self.playing = playing
        self.buffering = buffering
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
        self.queueLeft = queueLeft
        self.index = index
        self.shuffle = shuffle
        self.repeatMode = repeatMode
    }
}

/// Повтор, как на сайте: выключен, вся очередь, один трек.
public enum RepeatMode: String, Equatable, Sendable {
    case off, all, one

    public var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Звуковой движок платформы: играет один источник за раз. На iOS это AVPlayer, в тестах двойник.
/// Вызывать методы можно с любого потока: движок сам переходит туда, где ему можно работать.
public protocol PlaybackEngine: AnyObject, Sendable {
    var delegate: PlaybackEngineDelegate? { get set }
    /// Заменяет текущий источник. `autoplay == false` значит «подготовить и ждать».
    func load(_ source: PlaySource, autoplay: Bool)
    func setPlaying(_ playing: Bool)
    func seek(toMs ms: Int64)
    /// Останавливает звук и отпускает источник.
    func stop()
}

/// События движка. Позиция приходит часто (раз в полсекунды), пока играет.
public protocol PlaybackEngineDelegate: AnyObject, Sendable {
    func engine(playing: Bool, buffering: Bool, positionMs: Int64, durationMs: Int64)
    func engineEnded()
    func engineFailed(_ message: String)
}

/// То, что нужно действиям (`Actions`) от плеера.
public protocol PlayerControl: AnyObject, Sendable {
    func play(_ tracks: [Track], at index: Int)
}

/// Очередь и состояние проигрывания. Решает, что играть дальше, что делать при отказе и как не запутаться,
/// когда человек быстро листает треки (устаревший ответ сервера выбрасывается). Звук отдаёт движку.
public final class PlayerController: PlayerControl, PlaybackEngineDelegate, @unchecked Sendable {
    private enum Phase {
        case idle
        case resolving
        case loaded
        case failed
    }

    /// Дальше этой отметки «Назад» перематывает в начало текущего трека, а не к предыдущему.
    public static let restartAfterMs: Int64 = 3_000

    private let audio: PlaybackEngine
    private let source: PlaySourceProvider
    private let saved: SavedAudio
    private let toasts: Toasts
    private let nav: Nav
    private let openPlus: @Sendable () -> Void

    private let lock = NSLock()
    private let state = Observable(PlayerUi())
    private var queue: [Track] = []
    private var index = -1
    /// Очередь до перемешивания: к ней возвращаемся, когда перемешивание выключают.
    private var unshuffled: [Track]?
    private var repeatMode: RepeatMode = .off
    private var generation = 0
    private var phase: Phase = .idle
    private var wantPlay = false
    private var ended = false
    private var loadTask: Task<Void, Never>?
    /// Куда встать, когда трек загрузится (так комната подгоняет позицию при смене трека).
    private var pendingSeekMs: Int64?

    public init(
        engine: PlaybackEngine,
        source: PlaySourceProvider,
        saved: SavedAudio,
        toasts: Toasts,
        nav: Nav,
        openPlus: @escaping @Sendable () -> Void
    ) {
        self.audio = engine
        self.source = source
        self.saved = saved
        self.toasts = toasts
        self.nav = nav
        self.openPlus = openPlus
        audio.delegate = self
    }

    public var current: PlayerUi { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (PlayerUi) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    // ---------- команды ----------

    public func play(_ tracks: [Track], at start: Int) {
        if tracks.isEmpty { return }
        lock.lock()
        queue = tracks
        unshuffled = nil
        pendingSeekMs = nil
        lock.unlock()
        startTrack(min(max(0, start), tracks.count - 1), autoplay: true)
    }

    /// Очередь целиком с места `positionMs`; `autoplay == false` оставляет на паузе (так нужно комнате).
    public func play(_ tracks: [Track], at start: Int, positionMs: Int64, autoplay: Bool) {
        if tracks.isEmpty { return }
        lock.lock()
        queue = tracks
        unshuffled = nil
        pendingSeekMs = positionMs > 0 ? positionMs : nil
        lock.unlock()
        startTrack(min(max(0, start), tracks.count - 1), autoplay: autoplay)
    }

    /// Очередь и номер текущего трека (для комнаты).
    public func queueSnapshot() -> (tracks: [Track], index: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (queue, max(0, index))
    }

    /// Тот же трек: встать на `ms`, затем играть или встать на паузу (команда комнаты).
    public func setPlaying(_ playing: Bool, atMs ms: Int64) {
        lock.lock()
        let ph = phase
        let hasTrack = index >= 0 && index < queue.count
        if ph == .resolving { pendingSeekMs = ms > 0 ? ms : nil; wantPlay = playing }
        if ph == .loaded { ended = false; wantPlay = playing }
        lock.unlock()
        if !hasTrack { return }
        switch ph {
        case .resolving:
            state.update { $0.playing = playing }
        case .loaded:
            audio.seek(toMs: max(0, ms))
            audio.setPlaying(playing)
            state.update {
                $0.playing = playing
                $0.positionMs = max(0, ms)
            }
        case .idle, .failed:
            lock.lock()
            pendingSeekMs = ms > 0 ? ms : nil
            lock.unlock()
            startTrack(currentIndex(), autoplay: playing)
        }
    }

    /// Дописать треки в конец очереди (Вспышка подкладывает новые, пока играет текущий).
    public func append(_ tracks: [Track]) {
        if tracks.isEmpty { return }
        lock.lock()
        queue.append(contentsOf: tracks)
        unshuffled?.append(contentsOf: tracks)
        let left = index >= 0 ? queue.count - index - 1 : 0
        let loops = repeatMode == .all
        lock.unlock()
        state.update {
            $0.hasNext = left > 0 || loops
            $0.queueLeft = left
        }
    }

    public func toggle() {
        lock.lock()
        let hasTrack = index >= 0 && index < queue.count
        let ph = phase
        let finished = ended
        let playingNow = state.current.playing
        lock.unlock()
        if !hasTrack { return }
        switch ph {
        case .idle, .failed:
            startTrack(currentIndex(), autoplay: true)
        case .resolving:
            // человек нажал паузу, пока ищем ссылку: когда найдём, не начинаем играть
            lock.lock()
            wantPlay.toggle()
            let want = wantPlay
            lock.unlock()
            state.update { $0.playing = want }
        case .loaded:
            if finished {
                lock.lock()
                ended = false
                lock.unlock()
                audio.seek(toMs: 0)
                audio.setPlaying(true)
                state.update {
                    $0.playing = true
                    $0.positionMs = 0
                }
            } else {
                lock.lock()
                wantPlay = !playingNow
                lock.unlock()
                audio.setPlaying(!playingNow)
                state.update { $0.playing = !playingNow }
            }
        }
    }

    public func seek(toMs ms: Int64) {
        lock.lock()
        let ready = phase == .loaded
        let duration = state.current.durationMs
        if ready { ended = false }
        lock.unlock()
        if !ready { return }
        let target = duration > 0 ? min(max(0, ms), duration) : max(0, ms)
        audio.seek(toMs: target)
        state.update { $0.positionMs = target }
    }

    public func next() {
        lock.lock()
        let i = index
        let count = queue.count
        let loop = repeatMode == .all
        lock.unlock()
        if i + 1 < count {
            startTrack(i + 1, autoplay: true)
        } else if loop && count > 0 {
            startTrack(0, autoplay: true)
        }
    }

    /// Включить трек из очереди по номеру (панель «Очередь»).
    public func jump(to i: Int) {
        startTrack(i, autoplay: true)
    }

    /// Повтор по кругу: выключен → вся очередь → один трек → выключен.
    public func cycleRepeat() {
        lock.lock()
        repeatMode = repeatMode.next
        let mode = repeatMode
        let i = index
        let count = queue.count
        lock.unlock()
        state.update {
            $0.repeatMode = mode
            $0.hasNext = i + 1 < count || (mode == .all && count > 0)
        }
    }

    /// Перемешать то, что осталось после текущего трека, или вернуть прежний порядок.
    public func toggleShuffle() {
        lock.lock()
        var on = false
        if let original = unshuffled {
            let current = index >= 0 && index < queue.count ? queue[index] : nil
            queue = original
            unshuffled = nil
            if let c = current, let at = queue.firstIndex(where: { $0.id == c.id }) { index = at }
        } else if index >= 0 && index < queue.count {
            unshuffled = queue
            let head = Array(queue[0...index])
            queue = head + queue[(index + 1)...].shuffled()
            on = true
        }
        let i = index
        let count = queue.count
        let loop = repeatMode == .all
        lock.unlock()
        state.update {
            $0.shuffle = on
            $0.index = max(0, i)
            $0.hasNext = i + 1 < count || (loop && count > 0)
            $0.hasPrevious = i > 0
            $0.queueLeft = max(0, count - i - 1)
        }
    }

    /// Как в системных плеерах: после трёх секунд «Назад» возвращает в начало, раньше трёх уходит к предыдущему.
    public func previous() {
        lock.lock()
        let i = index
        let ph = phase
        lock.unlock()
        let position = state.current.positionMs
        if i <= 0 || position > PlayerController.restartAfterMs {
            if ph == .loaded {
                lock.lock()
                ended = false
                lock.unlock()
                audio.seek(toMs: 0)
                audio.setPlaying(true)
                state.update {
                    $0.positionMs = 0
                    $0.playing = true
                }
            } else if i >= 0 {
                startTrack(i, autoplay: true)
            }
            return
        }
        startTrack(i - 1, autoplay: true)
    }

    // ---------- события движка ----------

    public func engine(playing: Bool, buffering: Bool, positionMs: Int64, durationMs: Int64) {
        lock.lock()
        let ready = phase == .loaded && !ended
        let want = wantPlay
        lock.unlock()
        if !ready { return }
        state.update {
            $0.playing = playing || (want && buffering)
            $0.buffering = buffering
            $0.positionMs = max(0, positionMs)
            if durationMs > 0 { $0.durationMs = durationMs }
        }
    }

    public func engineEnded() {
        lock.lock()
        let ready = phase == .loaded && !ended
        let i = index
        let count = queue.count
        let mode = repeatMode
        lock.unlock()
        if !ready { return }
        if mode == .one {
            audio.seek(toMs: 0)
            audio.setPlaying(true)
            state.update { $0.positionMs = 0 }
            return
        }
        if i + 1 < count {
            startTrack(i + 1, autoplay: true)
            return
        }
        if mode == .all && count > 0 {
            startTrack(0, autoplay: true)
            return
        }
        lock.lock()
        ended = true
        wantPlay = false
        lock.unlock()
        state.update {
            $0.playing = false
            $0.buffering = false
            if $0.durationMs > 0 { $0.positionMs = $0.durationMs }
        }
    }

    public func engineFailed(_ message: String) {
        lock.lock()
        let ready = phase == .loaded
        lock.unlock()
        if !ready { return }
        toasts.show(message.isEmpty ? "Не получилось проиграть трек" : message)
        advanceOrStop()
    }

    // ---------- внутренности ----------

    private func currentIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return max(0, index)
    }

    private func isSaved(_ track: Track) -> Bool {
        guard let key = OfflinePolicy.keyOf(track) else { return false }
        return saved.isSaved(key)
    }

    private func startTrack(_ i: Int, autoplay: Bool) {
        lock.lock()
        if i < 0 || i >= queue.count {
            lock.unlock()
            return
        }
        generation += 1
        let gen = generation
        index = i
        let track = queue[i]
        let hasNext = i + 1 < queue.count || (repeatMode == .all && !queue.isEmpty)
        let hasPrevious = i > 0
        let left = queue.count - i - 1
        phase = .resolving
        wantPlay = autoplay
        ended = false
        loadTask?.cancel()
        lock.unlock()

        audio.stop()
        state.update {
            $0.track = track
            $0.playing = autoplay
            $0.buffering = true
            $0.positionMs = 0
            $0.durationMs = Int64(max(0, track.duration)) * 1000
            $0.hasNext = hasNext
            $0.hasPrevious = hasPrevious
            $0.queueLeft = left
            $0.index = i
        }
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.resolveAndLoad(track, gen: gen)
        }
        lock.lock()
        if generation == gen { loadTask = task }
        lock.unlock()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen
    }

    private func resolveAndLoad(_ track: Track, gen: Int) async {
        do {
            let src = try await source.source(for: track)
            lock.lock()
            let current = generation == gen
            let want = wantPlay
            if current { phase = .loaded }
            lock.unlock()
            if !current { return }
            lock.lock()
            let seekTo = pendingSeekMs
            pendingSeekMs = nil
            lock.unlock()
            audio.load(src, autoplay: want)
            if let ms = seekTo { audio.seek(toMs: ms) }
        } catch is CancellationError {
            return
        } catch let failure as PlayFailure {
            if !isCurrent(gen) { return }
            handle(failure)
        } catch {
            if !isCurrent(gen) { return }
            handle(PlayFailure(.network, "Не получилось проиграть трек"))
        }
    }

    private func handle(_ failure: PlayFailure) {
        lock.lock()
        phase = .failed
        lock.unlock()
        switch failure.kind {
        case .needsNetwork:
            skipToSaved()
        case .plusRequired:
            let open = openPlus
            toasts.show(failure.message.isEmpty ? "Нужен Blink+" : failure.message, action: "Открыть Blink+") { open() }
            stopUi()
        case .needSignIn:
            let nav = self.nav
            toasts.show(failure.message.isEmpty ? "Войдите в аккаунт" : failure.message, action: "Войти") { nav.go(.account) }
            stopUi()
        case .network:
            toasts.show(failure.message)
            stopUi()
        case .notFound, .unavailable:
            toasts.show(failure.message.isEmpty ? "Не получилось проиграть трек" : failure.message)
            advanceOrStop()
        }
    }

    private func stopUi() {
        audio.stop()
        lock.lock()
        wantPlay = false
        lock.unlock()
        state.update {
            $0.playing = false
            $0.buffering = false
        }
    }

    private func advanceOrStop() {
        lock.lock()
        let i = index
        let count = queue.count
        lock.unlock()
        if i + 1 < count {
            startTrack(i + 1, autoplay: true)
        } else {
            stopUi()
        }
    }

    /// Без сети перескакиваем к ближайшему сохранённому треку. Один тост на всю пачку пропущенных.
    private func skipToSaved() {
        lock.lock()
        let i = index
        let list = queue
        lock.unlock()
        var skipped = 1
        var j = i + 1
        while j < list.count {
            if isSaved(list[j]) {
                startTrack(j, autoplay: true)
                toasts.show(QueueFilter.skippedText(skipped))
                return
            }
            skipped += 1
            j += 1
        }
        toasts.show("Нет интернета. Дальше в очереди нет сохранённых треков")
        stopUi()
    }
}
