import XCTest
@testable import BlinkCore

/// Очередь сохранений целиком: сервер и сеть в памяти, автоповторы по 20 мс вместо 1/3/9/27 с.
/// Порт `OfflineManagerTest.kt`: те же сценарии, те же ожидания.
final class OfflineManagerTests: XCTestCase {
    private var backend: FakeBackend!
    private var dir: URL!
    private var storage: FileStorage!
    private var network: StaticNetwork!
    private var made: [OfflineManager] = []

    private let fast = OfflineManager.Config(retryDelaysMs: [20, 20, 20, 20], jitter: 0)

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
        dir = tempDir()
        storage = FileStorage(root: dir)
        network = StaticNetwork(true)
        made = []
    }

    override func tearDown() {
        // Остановить всё, что ещё качается, и только потом убрать папку.
        for m in made { m.pause() }
        made = []
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // ---------- помощники ----------

    private func key(_ id: String) -> String {
        return Key.of("blink", id)
    }

    private func manager(
        storage st: Storage? = nil,
        resolver: TrackResolver? = nil,
        transport: Transport? = nil,
        now: (@Sendable () -> Int64)? = nil
    ) -> OfflineManager {
        let clock: @Sendable () -> Int64 = now ?? { Int64(Date().timeIntervalSince1970 * 1000) }
        let s: Storage = st ?? self.storage
        let dl = Downloader(
            storage: s,
            resolver: resolver ?? backend.resolver(),
            transport: transport ?? backend,
            network: network,
            now: clock
        )
        let m = OfflineManager(storage: s, downloader: dl, network: network, config: fast, now: clock)
        made.append(m)
        return m
    }

    private func ready(
        storage st: Storage? = nil,
        resolver: TrackResolver? = nil,
        transport: Transport? = nil,
        now: (@Sendable () -> Int64)? = nil
    ) async -> OfflineManager {
        let m = manager(storage: st, resolver: resolver, transport: transport, now: now)
        await m.start()
        return m
    }

    /// Ждёт, пока состояние менеджера подойдёт под условие, и возвращает его.
    @discardableResult
    private func until(
        _ m: OfflineManager,
        _ what: String = "нужное состояние",
        seconds: Double = 30,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ cond: (OfflineState) -> Bool
    ) async -> OfflineState {
        await waitUntil(seconds, what, file: file, line: line) { cond(m.state) }
        return m.state
    }

    private func events(of m: OfflineManager) -> Log<OfflineEvent> {
        let log = Log<OfflineEvent>()
        m.observeEvents { log.add($0) }
        return log
    }

    /// Свежий объект хранилища на той же папке: то, что увидело бы приложение после перезапуска.
    private func disk() -> FileStorage {
        return FileStorage(root: dir)
    }

    private func bytesOf(_ path: String?, file: StaticString = #filePath, line: UInt = #line) -> [UInt8] {
        guard let path = path, let data = FileManager.default.contents(atPath: path) else {
            XCTFail("нет готового файла", file: file, line: line)
            return []
        }
        return [UInt8](data)
    }

    private func names() -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func failed(_ s: OfflineState, _ id: String) -> Bool {
        return s.job(key(id))?.failed ?? false
    }

    // ---------- основной путь ----------

    func testSavesTracksPlaysFromDiskAndReportsTheBatch() async throws {
        let a = backend.add("a", 400_000, seed: 1)
        let b = backend.add("b", 500_000, seed: 2)
        let m = await ready()
        let ev = events(of: m)

        let res = m.enqueue([candidate("a", duration: 10, title: "Alpha"), candidate("b", duration: 10, title: "Beta")])
        XCTAssertEqual(res[key("a")], .queued)
        let s = await until(m, "обе записи") { $0.saved.count == 2 && $0.jobs.isEmpty }

        XCTAssertEqual(s.savedKeys, [key("a"), key("b")])
        XCTAssertEqual(bytesOf(m.audioPath(key("a"))), a.bytes)
        XCTAssertEqual(bytesOf(m.audioPath(key("b"))), b.bytes)
        let e = s.saved.first { $0.key == key("a") }
        XCTAssertEqual(e?.title, "Alpha")
        XCTAssertEqual(e?.bytes, 400_000)
        XCTAssertEqual(e?.schema, 1)
        XCTAssertEqual(e?.status, "saved")
        await waitUntil(5, "итог пакета") { ev.count >= 1 }
        XCTAssertEqual(ev.items, [.batchDone(ok: 2, total: 2, failures: [])])
        // на диске нет хвостов: только звук и записи манифеста
        let left = names()
        XCTAssertFalse(left.contains { $0.hasSuffix(".part") || $0.hasSuffix(".job.json") || $0.hasSuffix(".tmp") }, "\(left)")
    }

    func testBatchSummaryNamesEveryFailureWithItsReason() async throws {
        backend.add("a", 400_000)
        backend.add("b", 400_000)
        let m = await ready()
        let ev = events(of: m)
        m.enqueue([candidate("a"), candidate("ghost", title: "Призрак"), candidate("b")])
        await until(m, "два сохранены, призрак упал") { $0.saved.count == 2 && $0.jobs.count == 1 && ($0.jobs.first?.failed ?? false) }
        await waitUntil(5, "итог пакета") { ev.count >= 1 }

        guard case .batchDone(let ok, let total, let failures)? = ev.items.first else {
            return XCTFail("итога пакета нет")
        }
        XCTAssertEqual(ok, 2)
        XCTAssertEqual(total, 3)
        XCTAssertEqual(failures.count, 1)
        guard let f = failures.first else { return }
        XCTAssertEqual(f.key, key("ghost"))
        XCTAssertEqual(f.title, "Призрак")
        XCTAssertEqual(f.code, .notDownloadable)
        XCTAssertEqual(f.text.message, "Для этого трека нет файла")
        XCTAssertEqual(m.state.jobs.first?.text?.message, "Для этого трека нет файла")
    }

    func testTwoDownloadsAtATimeAndTheQueueIsFifo() async throws {
        for c in ["a", "b", "c", "d", "e"] { backend.add(c, 600_000) }
        backend.throttleChunk = 120_000
        let m = await ready()
        let most = Box<Int>(0)
        let watcher = m.observe { s in
            let n = s.jobs.filter { $0.stage == .downloading }.count
            if n > most.value { most.value = n }
        }
        m.enqueue(["a", "b", "c", "d", "e"].map { candidate($0) })
        await until(m, "пять записей") { $0.saved.count == 5 }
        watcher.cancel()
        XCTAssertEqual(most.value, 2, "одновременно качаются две, не больше")
        let firstTwo = Set(backend.fileRequests.prefix(2).map { $0.path })
        XCTAssertEqual(firstTwo, ["/media/a", "/media/b"])
    }

    func testSavingTheSameTrackAgainIsANoOp() async throws {
        backend.add("a", 400_000)
        backend.throttleChunk = 50_000
        let m = await ready()
        XCTAssertEqual(m.enqueue([candidate("a")])[key("a")], .queued)
        XCTAssertEqual(m.enqueue([candidate("a")])[key("a")], .alreadyQueued)
        await until(m, "сохранён") { $0.saved.count == 1 && $0.jobs.isEmpty }
        XCTAssertEqual(m.enqueue([candidate("a")])[key("a")], .alreadySaved)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(backend.fileRequests.count, 1)
    }

    // ---------- повторы ----------

    func testNetworkHiccupsRetryByThemselvesAndTheTrackGetsSaved() async throws {
        let f = backend.add("a", 400_000)
        backend.fileHook = { _, n in n <= 2 ? Reply(status: 503) : nil }
        let m = await ready()
        m.enqueue([candidate("a")])
        await until(m, "сохранён") { $0.saved.count == 1 }
        XCTAssertEqual(backend.fileRequests.count, 3)
        XCTAssertEqual(bytesOf(m.audioPath(key("a"))), f.bytes)
    }

    func testGivesUpAfterFourRetriesAndTheRetryButtonStartsOver() async throws {
        backend.add("a", 400_000)
        backend.fileHook = { _, _ in Reply(status: 500) }
        let m = await ready()
        m.enqueue([candidate("a")])
        let s = await until(m, "задача упала") { $0.jobs.count == 1 && ($0.jobs.first?.failed ?? false) }
        XCTAssertEqual(backend.fileRequests.count, 5, "первый запуск и четыре повтора")
        let j = s.jobs.first
        XCTAssertEqual(j?.code, .sourceError)
        XCTAssertEqual(j?.text?.message, "Сервер сейчас не отвечает")
        XCTAssertEqual(j?.text?.action, .retry)

        backend.fileHook = nil
        m.retry(key("a"))
        await until(m, "сохранён после «Повторить»") { $0.saved.count == 1 }
    }

    func testRetryCounterStartsOverWheneverAFailedAttemptMadeProgress() async throws {
        let f = backend.add("a", 3_000_000, duration: 60)
        let be: FakeBackend = backend
        // шесть обрывов подряд (больше четырёх повторов), но каждый после новых байт: это не «сбои без прогресса»
        backend.fileHook = { req, n in n <= 6 ? be.cutAt(f, req, 300_000) : nil }
        let m = await ready()
        m.enqueue([candidate("a", duration: 60)])
        await until(m, "сохранён") { $0.saved.count == 1 }
        XCTAssertEqual(backend.fileRequests.count, 7)
        XCTAssertEqual(bytesOf(m.audioPath(key("a"))), f.bytes)
        let ranges: [String?] = backend.fileRequests.map { $0.header("Range") }
        let expected: [String?] = [nil, "bytes=300000-", "bytes=600000-", "bytes=900000-", "bytes=1200000-", "bytes=1500000-", "bytes=1800000-"]
        XCTAssertEqual(ranges, expected)
    }

    func testFailuresWithoutProgressStillStopAfterFourRetriesAndTheKeptPartResumesOnRetry() async throws {
        let f = backend.add("a", 3_000_000, duration: 60)
        let be: FakeBackend = backend
        // первая попытка продвинулась, дальше сервер только отвечает 500: четыре повтора без прогресса и стоп
        backend.fileHook = { req, n in n == 1 ? be.cutAt(f, req, 300_000) : Reply(status: 500) }
        let m = await ready()
        m.enqueue([candidate("a", duration: 60)])
        let s = await until(m, "задача упала") { $0.jobs.count == 1 && ($0.jobs.first?.failed ?? false) }
        XCTAssertEqual(backend.fileRequests.count, 5, "один обрыв с прогрессом и четыре повтора без него")
        XCTAssertEqual(s.jobs.first?.code, .sourceError)
        XCTAssertEqual(disk().partSize(key("a")), 300_000, "накопленное не выброшено")

        backend.fileHook = nil
        m.retry(key("a"))
        await until(m, "сохранён после «Повторить»") { $0.saved.count == 1 }
        XCTAssertGreaterThan(backend.fileRequests.count, 5)
        XCTAssertEqual(backend.fileRequests[5].header("Range"), "bytes=300000-", "первый запрос после «Повторить» идёт с места обрыва")
        XCTAssertEqual(bytesOf(m.audioPath(key("a"))), f.bytes)
    }

    func testBadContentAndNoSpaceAreNotRetried() async throws {
        backend.add("a", 400_000) { $0.contentType = "text/html" }
        let m = await ready()
        m.enqueue([candidate("a")])
        let s = await until(m, "плохой файл") { $0.jobs.count == 1 && ($0.jobs.first?.failed ?? false) }
        XCTAssertEqual(s.jobs.first?.code, .badContent)
        XCTAssertEqual(backend.fileRequests.count, 1)
        XCTAssertEqual(disk().partSize(key("a")), 0)

        let full = FullStorage(root: dir)
        backend.add("b", 700_000)
        let m2 = await ready(storage: full)
        m2.enqueue([candidate("b")])
        let s2 = await until(m2, "нет места") { self.failed($0, "b") }
        XCTAssertEqual(s2.job(key("b"))?.code, .noSpace)
        XCTAssertEqual(s2.job(key("b"))?.text?.message, "Не хватает места на устройстве")
        XCTAssertEqual(backend.fileRequests.filter { $0.path.hasPrefix("/media/b") }.count, 1)
    }

    // ---------- сеть, пауза ----------

    func testWithoutNetworkTheJobWaitsAndDoesNotSpendAnAttemptThenGoesOnItsOwn() async throws {
        backend.add("a", 400_000)
        network.set(false)
        let m = await ready()
        m.enqueue([candidate("a")])
        try await Task.sleep(nanoseconds: 300_000_000)
        let waiting = m.state
        XCTAssertFalse(waiting.online)
        XCTAssertEqual(waiting.jobs.count, 1)
        XCTAssertEqual(waiting.jobs.first?.stage, .queued)
        XCTAssertEqual(waiting.jobs.first?.attempt, 0)
        XCTAssertTrue(backend.fileRequests.isEmpty && backend.resolveRequests.isEmpty)

        network.set(true)
        await until(m, "сохранён, когда сеть вернулась") { $0.saved.count == 1 }
    }

    func testLosingTheNetworkMidDownloadKeepsThePartAndResumesWithRange() async throws {
        let f = backend.add("a", 3_000_000, duration: 60)
        backend.throttleChunk = 100_000
        let m = await ready()
        m.enqueue([candidate("a", duration: 60)])
        await until(m, "пошли байты") { ($0.job(self.key("a"))?.have ?? 0) > 700_000 }
        network.set(false)
        let paused = await until(m, "задача ждёт сеть") { $0.job(self.key("a"))?.stage == .queued }
        XCTAssertEqual(paused.jobs.first?.attempt, 0, "попытка не потрачена")
        let kept = disk().partSize(key("a"))
        XCTAssertGreaterThan(kept, 0, "накопленное осталось")

        backend.throttleChunk = 0
        network.set(true)
        await until(m, "сохранён") { $0.saved.count == 1 }
        XCTAssertEqual(bytesOf(m.audioPath(key("a"))), f.bytes)
        XCTAssertEqual(backend.fileRequests.last?.header("Range"), "bytes=\(kept)-")
    }

    func testPauseStopsEverythingResumeFinishes() async throws {
        backend.add("a", 3_000_000)
        backend.add("b", 3_000_000)
        backend.throttleChunk = 150_000
        let m = await ready()
        m.enqueue([candidate("a", duration: 60), candidate("b", duration: 60)])
        await until(m, "пошли байты") { ($0.job(self.key("a"))?.have ?? 0) > 300_000 }
        m.pause()
        let p = await until(m, "всё на паузе") { $0.paused && $0.jobs.allSatisfy { $0.stage == .queued } }
        XCTAssertTrue(p.paused)
        let seen = backend.fileRequests.count
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(seen, backend.fileRequests.count, "на паузе новых запросов нет")

        backend.throttleChunk = 0
        m.resume()
        await until(m, "оба сохранены") { $0.saved.count == 2 }
    }

    func testCancelRemovesTheJobAndItsPart() async throws {
        backend.add("a", 3_000_000)
        backend.throttleChunk = 150_000
        let m = await ready()
        m.enqueue([candidate("a", duration: 60)])
        await until(m, "пошли байты") { ($0.job(self.key("a"))?.have ?? 0) > 300_000 }
        m.cancel(key("a"))
        await until(m, "очередь пуста") { $0.jobs.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(names().isEmpty, "ни .part, ни job, ни записи: \(names())")
        XCTAssertEqual(m.state.saved.count, 0)
    }

    // ---------- отказы запоминаются ----------

    func testRefusalsAreRememberedFor24HoursAndTheRetryButtonForgetsThem() async throws {
        backend.add("a", 400_000)
        let asked = Box<Int>(0)
        let refusing = ClosureResolver { _, _ in
            asked.value += 1
            throw OfflineError(.notAllowed, "plus")
        }
        let clock = Box<Int64>(1_000_000)
        let m = await ready(resolver: refusing, now: { clock.value })
        m.enqueue([candidate("a")])
        await until(m, "отказ") { self.failed($0, "a") }
        XCTAssertEqual(asked.value, 1)

        let again = m.enqueue([candidate("a")])[key("a")]
        XCTAssertEqual(again, .remembered(.notAllowed, "plus"))
        XCTAssertEqual(asked.value, 1, "источник не дёргали")

        clock.value += 23 * 3_600_000
        XCTAssertEqual(m.enqueue([candidate("a")])[key("a")], .remembered(.notAllowed, "plus"), "через 23 часа отказ ещё помним")

        m.retry(key("a"))
        await until(m, "второй отказ") { asked.value == 2 && self.failed($0, "a") }

        clock.value += 25 * 3_600_000
        XCTAssertEqual(m.enqueue([candidate("a")])[key("a")], .queued, "через сутки память стёрта")
        await until(m, "третий запрос к источнику") { _ in asked.value == 3 }
    }

    // ---------- перезапуск ----------

    func testAfterARestartTheQueueGoesOnWithRangeFromThePartLength() async throws {
        let f = backend.add("a", 3_000_000, duration: 60)
        backend.throttleChunk = 100_000
        let m1 = await ready(storage: FileStorage(root: dir))
        m1.enqueue([candidate("a", duration: 60)])
        await until(m1, "пошли байты") { ($0.job(self.key("a"))?.have ?? 0) > 800_000 }
        m1.pause() // процесс остановили
        await until(m1, "всё остановилось") { $0.jobs.allSatisfy { $0.stage == .queued } }
        let onDisk = disk().partSize(key("a"))
        XCTAssertTrue(onDisk > 0 && onDisk < 3_000_000, "на диске \(onDisk)")
        XCTAssertNotNil(disk().getMeta(.job, key("a")))

        backend.throttleChunk = 0
        let before = backend.fileRequests.count
        let m2 = await ready(storage: FileStorage(root: dir))
        XCTAssertEqual(m2.state.jobs.count, 1, "задача пережила перезапуск")
        await until(m2, "сохранён") { $0.saved.count == 1 }
        XCTAssertGreaterThan(backend.fileRequests.count, before)
        XCTAssertEqual(backend.fileRequests[before].header("Range"), "bytes=\(onDisk)-")
        XCTAssertEqual(bytesOf(m2.audioPath(key("a"))), f.bytes)
    }

    func testReconcileAtStartSortsOutOrphansHalfFinishedCommitsAndStaleJobs() async throws {
        let st = FileStorage(root: dir)
        try st.open()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func entry(_ id: String, _ size: Int64) -> ManifestEntry {
            return ManifestEntry(key: key(id), source: "blink", id: id, title: "T" + id, artist: "A", bytes: size, savedAt: now)
        }
        func putAudio(_ id: String, _ n: Int) throws {
            try st.appendPart(key(id), Data(Audio.bytes(n)))
            try st.commit(key(id))
        }
        func putPart(_ id: String, _ n: Int) throws {
            try st.appendPart(key(id), Data(Audio.bytes(n)))
        }
        func putJob(_ id: String, _ tweak: (inout OfflineJob) -> Void = { _ in }) throws {
            var j = job(id)
            tweak(&j)
            try st.putMeta(.job, key(id), j.encode())
        }

        // saved: нормальный
        try putAudio("ok", 1000)
        try st.putMeta(.entry, key("ok"), entry("ok", 1000).encode())
        // запись без звука
        try st.putMeta(.entry, key("missing"), entry("missing", 1000).encode())
        // битая запись
        try st.putMeta(.entry, key("garbage"), "{ не json")
        // сирота: звук без записи и без задачи
        try putAudio("orphan", 1000)
        // упали между commit и записью: размер звука равен total из job
        try putAudio("half", 2000)
        try putJob("half") { $0.total = 2000; $0.etag = "W/\"x\""; $0.mime = "audio/mpeg" }
        // звук не того размера
        try putAudio("wrongsize", 2000)
        try putJob("wrongsize") { $0.total = 9999 }
        // задача уже сохранённого
        try putJob("ok")
        try putPart("ok", 10)
        // .part без задачи
        try putPart("stray", 500)
        // живая задача с .part
        try putJob("live") { $0.total = 5000; $0.etag = "W/\"l\"" }
        try putPart("live", 700)
        // упавшие
        try putJob("srv") { $0.state = Stage.failed.rawValue; $0.code = "SOURCE_ERROR"; $0.failedAt = now }
        try putPart("srv", 300)
        try putJob("refused") { $0.state = Stage.failed.rawValue; $0.code = "NOT_ALLOWED"; $0.reason = "plus"; $0.failedAt = now - 3_600_000 }
        try putJob("oldrefusal") { $0.state = Stage.failed.rawValue; $0.code = "NOT_ALLOWED"; $0.reason = "plus"; $0.failedAt = now - 25 * 3_600_000 }
        try st.putMeta(.job, key("brokenjob"), "{")

        network.set(false) // чтобы живая задача не стартовала и её было видно
        let m = await ready(storage: st)
        let s = m.state

        XCTAssertEqual(s.savedKeys, [key("ok"), key("half")], "ok остаётся, half достроен из job")
        let half = s.saved.first { $0.key == key("half") }
        XCTAssertEqual(half?.bytes, 2000)
        XCTAssertEqual(half?.mime, "audio/mpeg")
        XCTAssertNil(st.getMeta(.job, key("half")), "I5: задача ушла после записи")
        XCTAssertNil(st.audioPath(key("orphan")))
        XCTAssertNil(st.audioPath(key("wrongsize")))
        XCTAssertNil(st.getMeta(.entry, key("missing")))
        XCTAssertNil(st.getMeta(.entry, key("garbage")))
        XCTAssertEqual(st.partSize(key("stray")), 0)
        XCTAssertNil(st.getMeta(.job, key("ok")))
        XCTAssertEqual(st.partSize(key("ok")), 0)

        var byKey: [String: JobView] = [:]
        for j in s.jobs { byKey[j.key] = j }
        XCTAssertEqual(byKey[key("live")]?.stage, .queued)
        XCTAssertEqual(byKey[key("wrongsize")]?.stage, .queued, "звук не того размера выброшен, а сама задача жива")
        XCTAssertEqual(byKey[key("live")]?.have, 700)
        XCTAssertEqual(byKey[key("refused")]?.stage, .failed)
        XCTAssertEqual(byKey[key("refused")]?.code, .notAllowed)
        XCTAssertNil(byKey[key("srv")], "упавшее на сетевой ошибке уходит вместе с .part")
        XCTAssertEqual(st.partSize(key("srv")), 0)
        XCTAssertNil(byKey[key("oldrefusal")])
        XCTAssertNil(st.getMeta(.job, key("brokenjob")))
        XCTAssertEqual(Set(s.jobs.map { $0.key }), [key("live"), key("wrongsize"), key("refused")])
    }

    // ---------- потерянный файл (поправка 2, I6) ----------

    private func lostEntry(_ id: String, withTrack: Bool) -> ManifestEntry {
        let track: JSONValue? = withTrack ? .object(["id": .string("b:" + id), "title": .string("Lost " + id)]) : nil
        return ManifestEntry(
            key: key(id),
            source: "blink",
            id: id,
            title: "Lost " + id,
            artist: "A",
            duration: 10,
            bytes: 400_000,
            savedAt: Int64(Date().timeIntervalSince1970 * 1000),
            track: track
        )
    }

    func testASavedTrackWhoseAudioVanishedIsRequeuedSilentlyOneWithoutATrackObjectIsJustForgotten() async throws {
        let f = backend.add("gone", 400_000)
        backend.add("bare", 400_000)
        let st = FileStorage(root: dir)
        try st.open()
        try st.putMeta(.entry, key("gone"), lostEntry("gone", withTrack: true).encode())
        try st.putMeta(.entry, key("bare"), lostEntry("bare", withTrack: false).encode())

        let m = manager(storage: st)
        let ev = events(of: m)
        await m.start()
        let s = await until(m, "восстановлен") { $0.saved.count == 1 && $0.jobs.isEmpty }

        XCTAssertEqual(s.savedKeys, [key("gone")])
        XCTAssertEqual(s.saved.first?.title, "Lost gone")
        XCTAssertNotNil(s.saved.first?.track, "объект трека пережил восстановление")
        XCTAssertEqual(bytesOf(m.audioPath(key("gone"))), f.bytes)
        XCTAssertNil(st.getMeta(.entry, key("bare")))
        XCTAssertTrue(backend.fileRequests.allSatisfy { !$0.path.hasPrefix("/media/bare") }, "без объекта трека ничего не качаем")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ev.items.isEmpty, "тихо: ни итога пакета, ни тоста, получили \(ev.items)")
    }

    func testASilentRequeueThatIsRefusedStaysAsAFailedCardWithoutAToastRetryTurnsItIntoANormalBatch() async throws {
        backend.add("gone", 400_000)
        let st = FileStorage(root: dir)
        try st.open()
        try st.putMeta(.entry, key("gone"), lostEntry("gone", withTrack: true).encode())
        let refuse = Box<Bool>(true)
        let be: FakeBackend = backend
        let resolver = ClosureResolver { source, id in
            if refuse.value { throw OfflineError(.notAllowed, "plus") }
            return try await be.resolver().resolve(source: source, id: id)
        }
        let m = manager(storage: st, resolver: resolver)
        let ev = events(of: m)
        await m.start()

        let failedState = await until(m, "тихая постановка отказана") { $0.jobs.count == 1 && ($0.jobs.first?.failed ?? false) }
        XCTAssertEqual(failedState.jobs.first?.code, .notAllowed)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ev.items.isEmpty, "про тихую постановку тоста нет: \(ev.items)")

        refuse.value = false
        m.retry(key("gone"))
        await until(m, "сохранён после «Повторить»") { $0.saved.count == 1 && $0.jobs.isEmpty }
        await waitUntil(5, "итог пакета") { ev.count >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ev.items, [.batchDone(ok: 1, total: 1, failures: [])])
    }

    // ---------- хранилище ----------

    func testRemoveDeletesTheFileAndTheRecordClearAllWipesEverything() async throws {
        backend.add("a", 400_000)
        backend.add("b", 400_000)
        let m = await ready()
        m.enqueue([candidate("a"), candidate("b")])
        await until(m, "оба сохранены") { $0.saved.count == 2 }
        XCTAssertGreaterThanOrEqual(m.usage().bytes, 800_000)

        m.remove(key("a"))
        XCTAssertFalse(m.isSaved(key("a")))
        XCTAssertNil(m.audioPath(key("a")))
        XCTAssertNil(disk().getMeta(.entry, key("a")))
        XCTAssertTrue(m.isSaved(key("b")))

        m.clearAll()
        XCTAssertEqual(m.state.saved.count, 0)
        XCTAssertTrue(names().isEmpty, "\(names())")
    }

    func testMarkPlayedIsStoredInTheRecord() async throws {
        backend.add("a", 400_000)
        let m = await ready()
        m.enqueue([candidate("a")])
        await until(m, "сохранён") { $0.saved.count == 1 }
        XCTAssertNil(m.state.saved.first?.lastPlayedAt)
        m.markPlayed(key("a"))
        let text = disk().getMeta(.entry, key("a"))
        let entry = text.flatMap { ManifestEntry.decode($0) }
        XCTAssertNotNil(entry?.lastPlayedAt)
    }

    func testSavedTracksSurviveANewManagerOnTheSameFolderAndPlayOffline() async throws {
        let f = backend.add("a", 400_000)
        let m1 = await ready()
        m1.enqueue([candidate("a", duration: 10, title: "Alpha")])
        await until(m1, "сохранён") { $0.saved.count == 1 }
        m1.pause()

        // сервера нет совсем и сети тоже
        network.set(false)
        let m2 = await ready(
            storage: FileStorage(root: dir),
            resolver: ClosureResolver { _, _ in throw OfflineError(.noNetwork) },
            transport: FailingTransport(error: .offline)
        )
        XCTAssertEqual(m2.state.saved.first?.title, "Alpha")
        XCTAssertEqual(bytesOf(m2.audioPath(key("a"))), f.bytes)
    }
}
