import Foundation

public struct Failure: Equatable, Sendable {
    public let key: String
    public let title: String
    public let code: OfflineCode
    public let reason: String?

    public init(key: String, title: String, code: OfflineCode, reason: String?) {
        self.key = key
        self.title = title
        self.code = code
        self.reason = reason
    }

    public var text: OfflineText { return OfflineTexts.of(code, reason) }
}

public enum OfflineEvent: Equatable, Sendable {
    /// Итог пакета: «Сохранено 3 из 5. 2 не вышло: …».
    case batchDone(ok: Int, total: Int, failures: [Failure])
}

public struct JobView: Equatable, Sendable {
    public let key: String
    public let title: String
    public let artist: String
    public let cover: String
    public let stage: Stage
    public let have: Int64
    public let total: Int64?
    public let attempt: Int
    public let code: OfflineCode?
    public let reason: String?
    /// Когда ближайший автоповтор (мс эпохи), если ждёт его.
    public let retryAt: Int64?

    public var fraction: Double {
        guard let t = total, t > 0 else { return 0 }
        return min(1, max(0, Double(have) / Double(t)))
    }

    public var failed: Bool { return stage == .failed }
    public var text: OfflineText? { return code.map { OfflineTexts.of($0, reason) } }
}

public struct OfflineState: Equatable, Sendable {
    public var ready: Bool
    public var jobs: [JobView]
    public var saved: [ManifestEntry]
    public var paused: Bool
    public var online: Bool

    public init(ready: Bool = false, jobs: [JobView] = [], saved: [ManifestEntry] = [], paused: Bool = false, online: Bool = true) {
        self.ready = ready
        self.jobs = jobs
        self.saved = saved
        self.paused = paused
        self.online = online
    }

    public var savedKeys: Set<String> { return Set(saved.map { $0.key }) }
    public var usedBytes: Int64 { return saved.reduce(Int64(0)) { $0 + $1.bytes } }
    public var active: Bool { return jobs.contains { !$0.failed } }

    public func job(_ key: String) -> JobView? {
        return jobs.first { $0.key == key }
    }
}

public enum EnqueueResult: Equatable, Sendable {
    case queued
    case alreadySaved
    case alreadyQueued
    /// Отказ запомнен на 24 часа: источник не дёргаем. «Повторить» сбрасывает.
    case remembered(OfflineCode, String?)
    case rejected(OfflineCode, String?)
}

/// Очередь сохранений: FIFO, 2 загрузки параллельно, пауза глобальная, автоповторы 1/3/9/27 с,
/// без сети попытка не тратится и задача ждёт появления сети. Всё живёт на диске, переживает перезапуск.
public final class OfflineManager: @unchecked Sendable {
    public struct Config: Sendable {
        public var maxParallel: Int
        public var retryDelaysMs: [Int64]
        public var jitter: Double
        public var refusalMemoryMs: Int64
        public var random: @Sendable () -> Double

        public init(
            maxParallel: Int = 2,
            retryDelaysMs: [Int64] = [1_000, 3_000, 9_000, 27_000],
            jitter: Double = 0.2,
            refusalMemoryMs: Int64 = 24 * 60 * 60 * 1000,
            random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
        ) {
            self.maxParallel = maxParallel
            self.retryDelaysMs = retryDelaysMs
            self.jitter = jitter
            self.refusalMemoryMs = refusalMemoryMs
            self.random = random
        }
    }

    private final class Rt {
        var job: OfflineJob
        var stage: Stage = .queued
        var have: Int64 = 0
        var total: Int64?
        var runner: Task<Void, Never>?
        var retryAt: Int64 = 0
        var requeue = false
        var cancelled = false
        /// Длина .part в начале попытки: если к концу выросла, попытка шла не вхолостую (поправка 2, повторы).
        var haveAtStart: Int64 = 0
        /// Задача, поставленная самим менеджером (восстановление потерянного файла): без тостов про пакет.
        var silent = false

        init(_ job: OfflineJob) {
            self.job = job
            self.total = job.total
        }
    }

    private static let publishEveryMs: Int64 = 150

    private let storage: Storage
    private let downloader: Downloader
    private let network: NetworkMonitor
    private let config: Config
    private let now: @Sendable () -> Int64

    private let lock = NSRecursiveLock()
    private var jobs: [String: Rt] = [:]
    private var jobOrder: [String] = []
    private var saved: [String: ManifestEntry] = [:]
    private var savedOrder: [String] = []
    private var paused = false
    private var started = false
    private var lastPublish: Int64 = 0

    private var batchTotal = 0
    private var batchOk = 0
    private var batchFailures: [Failure] = []

    private var snapshot = OfflineState()
    private var stateHandlers: [Int: @Sendable (OfflineState) -> Void] = [:]
    private var eventHandlers: [Int: @Sendable (OfflineEvent) -> Void] = [:]
    private var nextHandlerId = 0
    private let callbackQueue = DispatchQueue(label: "app.blink.offline.callbacks")
    private var networkObservation: NetworkObservation?

    public init(
        storage: Storage,
        downloader: Downloader,
        network: NetworkMonitor,
        config: Config = Config(),
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.storage = storage
        self.downloader = downloader
        self.network = network
        self.config = config
        self.now = now
    }

    // ---------- наблюдение ----------

    public var state: OfflineState {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Подписка на состояние. Обработчик вызывается не под замком и по порядку; первое значение приходит сразу.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (OfflineState) -> Void) -> NetworkObservation {
        lock.lock()
        let id = nextHandlerId
        nextHandlerId += 1
        stateHandlers[id] = handler
        let current = snapshot
        callbackQueue.async { handler(current) }
        lock.unlock()
        return NetworkObservation { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.stateHandlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    @discardableResult
    public func observeEvents(_ handler: @escaping @Sendable (OfflineEvent) -> Void) -> NetworkObservation {
        lock.lock()
        let id = nextHandlerId
        nextHandlerId += 1
        eventHandlers[id] = handler
        lock.unlock()
        return NetworkObservation { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.eventHandlers.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    // ---------- запуск ----------

    /// Открывает хранилище, наводит порядок (reconcile) и продолжает незаконченное.
    public func start() async {
        lock.lock()
        let already = started
        lock.unlock()
        if already { return }
        await Task.detached(priority: .utility) { [self] in
            try? self.storage.open()
            self.lock.lock()
            self.reconcile()
            self.lock.unlock()
        }.value
        lock.lock()
        started = true
        lock.unlock()
        networkObservation = network.observe { [weak self] online in
            guard let self = self else { return }
            if online { self.pump() } else { self.interruptRunning() }
            self.publish()
        }
        publish()
        pump()
    }

    /// I6: сироты, задачи уже сохранённых, missing, старые отказы. Вызывается под замком.
    private func reconcile() {
        let t = now()
        var entries: [String: ManifestEntry] = [:]
        for key in storage.listMeta(.entry) {
            if let text = storage.getMeta(.entry, key), let e = ManifestEntry.decode(text), e.key == key {
                entries[key] = e
            } else {
                storage.delMeta(.entry, key)
            }
        }
        var onDisk: [String: OfflineJob] = [:]
        for key in storage.listMeta(.job) {
            if let text = storage.getMeta(.job, key), let j = OfflineJob.decode(text), j.key == key {
                onDisk[key] = j
            } else {
                storage.delMeta(.job, key)
                storage.deletePart(key)
            }
        }
        let audio = Set(storage.listAudio())

        // Запись без звука: файл пропал. Запись удаляем, а если у неё есть объект трека, тихо ставим скачивание заново
        // (поправка 2): человек сохранял этот трек и вправе ждать, что он снова будет на телефоне.
        var silentKeys = Set<String>()
        for key in Array(entries.keys) {
            if audio.contains(key) { continue }
            guard let lost = entries.removeValue(forKey: key) else { continue }
            storage.delMeta(.entry, key)
            if lost.track != nil && onDisk[key] == nil {
                let job = OfflineJob(
                    key: lost.key,
                    source: lost.source,
                    id: lost.id,
                    meta: JobMeta(
                        title: lost.title,
                        artist: lost.artist,
                        album: lost.album,
                        cover: lost.cover,
                        duration: lost.duration,
                        offlineAllowed: lost.offlineAllowed,
                        track: lost.track
                    ),
                    createdAt: t
                )
                try? storage.putMeta(.job, key, job.encode())
                onDisk[key] = job
                silentKeys.insert(key)
            }
        }
        // Звук без записи: упали между commit и манифестом (достраиваем из job, если размер сошёлся) либо сирота.
        for key in audio {
            if entries[key] != nil { continue }
            let size = storage.audioSize(key)
            if let j = onDisk[key], let total = j.total, total == size {
                let e = ManifestEntry(
                    key: j.key,
                    source: j.source,
                    id: j.id,
                    title: j.meta.title,
                    artist: j.meta.artist,
                    album: j.meta.album,
                    cover: j.meta.cover,
                    duration: j.meta.duration,
                    bytes: size,
                    mime: j.mime,
                    etag: j.etag,
                    savedAt: t,
                    offlineAllowed: j.meta.offlineAllowed,
                    track: j.meta.track
                )
                try? storage.putMeta(.entry, key, e.encode())
                entries[key] = e
            } else {
                storage.deleteAudio(key)
            }
        }
        // Задачи: у сохранённого не нужны; упавшие живут только как запомненный отказ моложе суток.
        let ordered = onDisk.values.sorted { $0.createdAt < $1.createdAt }
        for j in ordered {
            let key = j.key
            if entries[key] != nil {
                storage.delMeta(.job, key)
                storage.deletePart(key)
                continue
            }
            if j.stage == .failed {
                let fresh = j.failedAt.map { t - $0 < config.refusalMemoryMs } ?? false
                if (j.failure?.isRefusal ?? false) && fresh {
                    let rt = Rt(j)
                    rt.stage = .failed
                    addJob(key, rt)
                } else {
                    storage.delMeta(.job, key)
                    storage.deletePart(key)
                }
                continue
            }
            var queued = j
            queued.state = Stage.queued.rawValue
            let rt = Rt(queued)
            rt.have = storage.partSize(key)
            rt.silent = silentKeys.contains(key)
            addJob(key, rt)
        }
        for key in storage.listParts() where jobs[key] == nil {
            storage.deletePart(key)
        }

        saved = [:]
        savedOrder = []
        for e in entries.values.sorted(by: { $0.savedAt > $1.savedAt }) {
            saved[e.key] = e
            savedOrder.append(e.key)
        }
    }

    // ---------- команды ----------

    @discardableResult
    public func enqueue(_ candidates: [Candidate]) -> [String: EnqueueResult] {
        var out: [String: EnqueueResult] = [:]
        let t = now()
        lock.lock()
        for c in candidates {
            if saved[c.key] != nil {
                out[c.key] = .alreadySaved
                continue
            }
            if let existing = jobs[c.key] {
                if existing.stage != .failed {
                    out[c.key] = .alreadyQueued
                    continue
                }
                let code = existing.job.failure
                let fresh = existing.job.failedAt.map { t - $0 < config.refusalMemoryMs } ?? false
                if let code = code, code.isRefusal, fresh {
                    out[c.key] = .remembered(code, existing.job.reason)
                    continue
                }
                resetForRetry(existing)
                out[c.key] = .queued
                continue
            }
            let job = OfflineJob(key: c.key, source: c.source, id: c.id, meta: c.meta, createdAt: t)
            do {
                try storage.putMeta(.job, c.key, job.encode())
            } catch {
                let e = FileStorage.mapIo(error)
                out[c.key] = .rejected(e.code, e.reason)
                continue
            }
            addJob(c.key, Rt(job))
            batchTotal += 1
            out[c.key] = .queued
        }
        lock.unlock()
        publish()
        pump()
        return out
    }

    public func pause() {
        lock.lock()
        paused = true
        interruptRunningLocked()
        lock.unlock()
        publish()
    }

    public func resume() {
        lock.lock()
        paused = false
        lock.unlock()
        publish()
        pump()
    }

    /// «Повторить» по одному треку: сбрасывает и запомненный отказ.
    public func retry(_ key: String) {
        lock.lock()
        if let rt = jobs[key], rt.runner == nil, rt.stage == .failed { resetForRetry(rt) }
        lock.unlock()
        publish()
        pump()
    }

    public func retryAll() {
        lock.lock()
        for key in jobOrder {
            if let rt = jobs[key], rt.runner == nil, rt.stage == .failed { resetForRetry(rt) }
        }
        lock.unlock()
        publish()
        pump()
    }

    /// Убирает одну задачу из очереди (если качается, останавливает) вместе с `.part`.
    public func cancel(_ key: String) {
        lock.lock()
        guard let rt = removeJob(key) else {
            lock.unlock()
            return
        }
        rt.cancelled = true
        batchFailures.removeAll { $0.key == key }
        if let runner = rt.runner {
            runner.cancel()
        } else {
            storage.remove(key)
        }
        if batchTotal > 0 && rt.stage != .failed && !rt.silent { batchTotal -= 1 }
        checkBatchDone()
        lock.unlock()
        publish()
        pump()
    }

    public func cancelAll() {
        lock.lock()
        for key in jobOrder {
            guard let rt = jobs[key] else { continue }
            rt.cancelled = true
            if let runner = rt.runner {
                runner.cancel()
            } else {
                storage.remove(key)
            }
        }
        jobs = [:]
        jobOrder = []
        batchTotal = 0
        batchOk = 0
        batchFailures = []
        lock.unlock()
        publish()
    }

    /// Удаляет сохранённый трек: сначала запись, потом звук (I2).
    public func remove(_ key: String) {
        lock.lock()
        if removeSaved(key) != nil {
            storage.remove(key)
        }
        lock.unlock()
        publish()
    }

    /// «Очистить всё» в настройках.
    public func clearAll() {
        cancelAll()
        lock.lock()
        saved = [:]
        savedOrder = []
        storage.clear()
        lock.unlock()
        publish()
    }

    public func markPlayed(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var e = saved[key] else { return }
        e.lastPlayedAt = now()
        saved[key] = e
        try? storage.putMeta(.entry, key, e.encode())
    }

    // ---------- чтение ----------

    public func isSaved(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saved[key] != nil
    }

    /// Путь к готовому файлу для плеера, если трек сохранён.
    public func audioPath(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return saved[key] != nil ? storage.audioPath(key) : nil
    }

    public func usage() -> Usage {
        return storage.usage()
    }

    // ---------- внутренности ----------

    private func addJob(_ key: String, _ rt: Rt) {
        if jobs[key] == nil { jobOrder.append(key) }
        jobs[key] = rt
    }

    @discardableResult
    private func removeJob(_ key: String) -> Rt? {
        guard let rt = jobs.removeValue(forKey: key) else { return nil }
        jobOrder.removeAll { $0 == key }
        return rt
    }

    private func putSaved(_ key: String, _ entry: ManifestEntry) {
        if saved[key] == nil { savedOrder.append(key) }
        saved[key] = entry
    }

    @discardableResult
    private func removeSaved(_ key: String) -> ManifestEntry? {
        guard let e = saved.removeValue(forKey: key) else { return nil }
        savedOrder.removeAll { $0 == key }
        return e
    }

    private func resetForRetry(_ rt: Rt) {
        rt.job.state = Stage.queued.rawValue
        rt.job.attempts = 0
        rt.job.code = nil
        rt.job.reason = nil
        rt.job.failedAt = nil
        rt.stage = .queued
        rt.retryAt = 0
        rt.silent = false // человек сам нажал «Повторить»: итог пакета ему положен
        batchFailures.removeAll { $0.key == rt.job.key }
        batchTotal += 1
        persistJob(rt)
    }

    private func interruptRunning() {
        lock.lock()
        interruptRunningLocked()
        lock.unlock()
    }

    private func interruptRunningLocked() {
        for key in jobOrder {
            guard let rt = jobs[key], let runner = rt.runner else { continue }
            rt.requeue = true
            runner.cancel()
        }
    }

    private func pump() {
        lock.lock()
        if !started || paused || !network.isOnline {
            lock.unlock()
            return
        }
        let t = now()
        var running = jobOrder.reduce(0) { $0 + ((jobs[$1]?.runner != nil) ? 1 : 0) }
        for key in jobOrder {
            if running >= config.maxParallel { break }
            guard let rt = jobs[key] else { continue }
            if rt.runner == nil && rt.stage == .queued && rt.retryAt <= t {
                rt.requeue = false
                rt.stage = .resolving
                rt.haveAtStart = rt.have
                rt.runner = Task.detached(priority: .utility) { [self] in
                    await self.work(rt)
                }
                running += 1
            }
        }
        lock.unlock()
        publish()
    }

    private func work(_ rt: Rt) async {
        var entry: ManifestEntry?
        var failure: OfflineError?
        let job = rt.job
        do {
            entry = try await downloader.download(job, hooks: hooksFor(rt))
        } catch is CancellationError {
            // пауза, пропала сеть, отмена пользователем или остановка приложения: разбирается finish
        } catch let e as OfflineError {
            failure = e
        } catch {
            failure = OfflineError(.sourceError, "unexpected", detail: String(describing: error))
        }
        if entry == nil && Task.isCancelled { failure = nil }
        let retryIn = finish(rt, entry, failure)
        publish()
        if let delay = retryIn {
            Task.detached(priority: .utility) { [self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay)) * 1_000_000)
                self.pump()
            }
        } else {
            pump()
        }
    }

    private func hooksFor(_ rt: Rt) -> DownloadHooks {
        return DownloadHooks(
            onStage: { [self] stage in
                self.lock.lock()
                rt.stage = stage
                self.lock.unlock()
                self.publish()
            },
            onProgress: { [self] have, total in
                self.lock.lock()
                rt.have = have
                if let t = total { rt.total = t }
                self.lock.unlock()
                self.publishThrottled()
            },
            onMeta: { [self] etag, total, mime in
                self.lock.lock()
                if let t = total { rt.total = t }
                rt.job.etag = etag
                rt.job.total = total
                rt.job.mime = mime
                self.persistJob(rt)
                self.lock.unlock()
            }
        )
    }

    /// Разбор итога работы. Возвращает задержку автоповтора, если он нужен.
    private func finish(_ rt: Rt, _ entry: ManifestEntry?, _ failure: OfflineError?) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        rt.runner = nil
        if rt.cancelled {
            storage.remove(rt.job.key)
            return nil
        }
        if let entry = entry { return complete(rt, entry) }
        if let failure = failure { return fail(rt, failure) }
        rt.stage = .queued // прервали паузой, потерей сети или остановкой
        rt.requeue = false
        rt.have = storage.partSize(rt.job.key)
        return nil
    }

    private func complete(_ rt: Rt, _ entry: ManifestEntry) -> Int64? {
        let key = rt.job.key
        do {
            try storage.putMeta(.entry, key, entry.encode()) // I2: запись после звука
            storage.delMeta(.job, key) // I5: задача уходит только после записи
            removeJob(key)
            putSaved(key, entry)
            if !rt.silent { batchOk += 1 }
            checkBatchDone()
            return nil
        } catch {
            storage.deleteAudio(key)
            return fail(rt, FileStorage.mapIo(error))
        }
    }

    private func fail(_ rt: Rt, _ e: OfflineError) -> Int64? {
        let job = rt.job
        if e.code == .noNetwork {
            rt.stage = .queued // попытка не тратится, продолжим по событию «сеть появилась»
            rt.have = storage.partSize(job.key)
            return nil
        }
        // Считаем сбои подряд без прогресса: если в упавшей попытке байты шли, счёт начинается заново.
        let streak = storage.partSize(job.key) > rt.haveAtStart ? 0 : job.attempts
        if e.code.retryable && streak < config.retryDelaysMs.count {
            let attempts = streak + 1
            rt.job.attempts = attempts
            persistJob(rt)
            rt.stage = .queued
            rt.have = storage.partSize(job.key)
            let base = Double(config.retryDelaysMs[attempts - 1])
            let k = 1.0 + (config.random() * 2.0 - 1.0) * config.jitter
            let delay = max(0, Int64(base * k))
            rt.retryAt = now() + delay
            return delay
        }
        if e.code == .badContent || e.code == .notAllowed || e.code == .notDownloadable {
            storage.deletePart(job.key)
            rt.have = 0
        }
        rt.job.state = Stage.failed.rawValue
        rt.job.code = e.code.rawValue
        rt.job.reason = e.reason
        rt.job.failedAt = now()
        persistJob(rt)
        rt.stage = .failed
        if !rt.silent { batchFailures.append(Failure(key: job.key, title: job.meta.title, code: e.code, reason: e.reason)) }
        checkBatchDone()
        return nil
    }

    private func persistJob(_ rt: Rt) {
        try? storage.putMeta(.job, rt.job.key, rt.job.encode())
    }

    /// Когда в очереди не осталось ничего живого, отдаём итог пакета. Вызывается под замком.
    private func checkBatchDone() {
        if batchTotal == 0 && batchFailures.isEmpty { return }
        if jobs.values.contains(where: { $0.stage != .failed }) { return }
        let total = max(batchTotal, batchOk + batchFailures.count)
        let ev = OfflineEvent.batchDone(ok: batchOk, total: total, failures: batchFailures)
        batchTotal = 0
        batchOk = 0
        batchFailures = []
        let handlers = Array(eventHandlers.values)
        callbackQueue.async {
            for h in handlers { h(ev) }
        }
    }

    private func publishThrottled() {
        let t = now()
        lock.lock()
        let due = t - lastPublish >= OfflineManager.publishEveryMs
        if due { lastPublish = t }
        lock.unlock()
        if due { publish() }
    }

    private func publish() {
        lock.lock()
        let t = now()
        var views: [JobView] = []
        for key in jobOrder {
            guard let rt = jobs[key] else { continue }
            let failed = rt.stage == .failed
            views.append(
                JobView(
                    key: rt.job.key,
                    title: rt.job.meta.title,
                    artist: rt.job.meta.artist,
                    cover: rt.job.meta.cover,
                    stage: rt.stage,
                    have: rt.have,
                    total: rt.total ?? rt.job.total,
                    attempt: rt.job.attempts,
                    code: failed ? rt.job.failure : nil,
                    reason: failed ? rt.job.reason : nil,
                    retryAt: (rt.retryAt > t && rt.stage == .queued) ? rt.retryAt : nil
                )
            )
        }
        let state = OfflineState(
            ready: started,
            jobs: views,
            saved: savedOrder.compactMap { saved[$0] },
            paused: paused,
            online: network.isOnline
        )
        snapshot = state
        let handlers = Array(stateHandlers.values)
        callbackQueue.async {
            for h in handlers { h(state) }
        }
        lock.unlock()
    }
}
