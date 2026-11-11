import XCTest
@testable import BlinkCore

/// Транспорт, который всегда падает (закрытый порт, нет сети и т. п.).
struct FailingTransport: Transport {
    let error: TransportError

    func get(_ url: URL, headers: [String: String]) async throws -> TransportResponse {
        throw error
    }
}

/// Хранилище, которое «принимает» вторую порцию, но на диск её не пишет (проверка поправки 2).
final class LossyStorage: FileStorage, @unchecked Sendable {
    private let counterLock = NSLock()
    private var batches = 0

    override func appendPart(_ key: String, _ data: Data) throws {
        counterLock.lock()
        batches += 1
        let skip = batches == 2
        counterLock.unlock()
        if skip { return }
        try super.appendPart(key, data)
    }
}

/// Хранилище без места.
final class FullStorage: FileStorage, @unchecked Sendable {
    override func appendPart(_ key: String, _ data: Data) throws {
        throw OfflineError(.noSpace)
    }
}

final class DownloaderTests: XCTestCase {
    private var backend: FakeBackend!
    private var dir: URL!
    private var storage: FileStorage!
    private var network: StaticNetwork!

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
        dir = tempDir()
        storage = FileStorage(root: dir)
        try? storage.open()
        network = StaticNetwork(true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func downloader(
        resolver: TrackResolver? = nil,
        storage st: Storage? = nil,
        transport: Transport? = nil,
        resolveMs: Int64 = Downloader.resolveTimeoutMs
    ) -> Downloader {
        return Downloader(
            storage: st ?? storage,
            resolver: resolver ?? backend.resolver(),
            transport: transport ?? backend,
            network: network,
            resolveTimeoutMs: resolveMs
        )
    }

    private func run(_ d: Downloader, _ j: OfflineJob, hooks: DownloadHooks = DownloadHooks()) async throws -> ManifestEntry {
        return try await withDeadline(60) { try await d.download(j, hooks: hooks) }
    }

    private func seedPart(_ id: String, _ bytes: [UInt8], _ n: Int) throws {
        let key = Key.of("blink", id)
        try storage.appendPart(key, Data(bytes.prefix(n)))
        XCTAssertEqual(storage.partSize(key), Int64(n))
    }

    private func audioOf(_ id: String) throws -> [UInt8] {
        guard let path = storage.audioPath(Key.of("blink", id)) else {
            XCTFail("нет готового файла \(id)")
            return []
        }
        return Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func partExists(_ id: String) -> Bool {
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(Key.fkey("blink:" + id) + ".part").path)
    }

    private func rangeHeaders() -> [String?] {
        return backend.fileRequests.map { $0.header("Range") }
    }

    // ---------- обычные случаи ----------

    func testSmallFileInOneRequestNoAuthOnTheFileLink() async throws {
        let f = backend.add("a", 300_000)
        let entry = try await run(downloader(), job("a", duration: 10))
        XCTAssertEqual(entry.bytes, 300_000)
        XCTAssertEqual(entry.mime, "audio/mpeg")
        XCTAssertEqual(entry.etag, "W/\"e1\"")
        XCTAssertEqual(try audioOf("a"), f.bytes)
        XCTAssertFalse(partExists("a"), ".part превращается в готовый файл")
        XCTAssertEqual(rangeHeaders(), [nil])
        let req = backend.fileRequests[0]
        XCTAssertNil(req.header("Authorization"), "к ссылке на файл Bearer не добавляем")
        XCTAssertEqual(req.header("Accept-Encoding"), "identity")
    }

    func testStagesAndProgressAreReportedInOrder() async throws {
        backend.add("a", 700_000)
        let stages = Log<Stage>()
        let seen = Log<Int64>()
        let hooks = DownloadHooks(onStage: { stages.add($0) }, onProgress: { have, _ in seen.add(have) })
        _ = try await run(downloader(), job("a", duration: 10), hooks: hooks)
        XCTAssertEqual(stages.items, [.resolving, .downloading, .verifying, .committing])
        XCTAssertEqual(seen.items, seen.items.sorted())
        XCTAssertEqual(seen.last, 700_000)
    }

    // ---------- контракт: Range ----------

    func testContractVectorCutAt1000000ThenRangeAndIfRangeWith2MiBSlices() async throws {
        let f = backend.add("big", 5_000_000, duration: 213)
        let b = backend!
        backend.fileHook = { req, n in n == 1 ? b.cutAt(f, req, 1_000_000) : nil }
        let d = downloader()

        let first = await offlineError { _ = try await d.download(job("big", duration: 213)) }
        XCTAssertEqual(first?.code, .sourceError, "обрыв при живой сети это SOURCE_ERROR, не NO_NETWORK")
        XCTAssertEqual(storage.partSize(Key.of("blink", "big")), 1_000_000, "накопленное сохранено, это и есть смещение Range")

        let entry = try await run(d, job("big", duration: 213))
        XCTAssertEqual(entry.bytes, 5_000_000)
        XCTAssertEqual(try audioOf("big"), f.bytes)
        XCTAssertEqual(rangeHeaders(), [nil, "bytes=1000000-", "bytes=3097152-"])
        XCTAssertEqual(backend.fileRequests.map { $0.header("If-Range") }, [nil, "W/\"e1\"", "W/\"e1\""], "etag дословно, вместе с W/ и кавычками")
    }

    func testLoopsOverThe2MiBCapUntilTotalOne206IsNotDone() async throws {
        let f = backend.add("big", 5_000_000, duration: 120)
        try seedPart("big", f.bytes, 100)
        let entry = try await run(downloader(), job("big", duration: 120))
        XCTAssertEqual(entry.bytes, 5_000_000)
        XCTAssertEqual(try audioOf("big"), f.bytes)
        XCTAssertEqual(rangeHeaders(), ["bytes=100-", "bytes=2097252-", "bytes=4194404-"])
    }

    func testServerIgnoringRangeAnswers200AndWeStartOver() async throws {
        let f = backend.add("a", 400_000) { $0.honorRange = false }
        try seedPart("a", f.bytes, 100_000)
        let entry = try await run(downloader(), job("a", duration: 10))
        XCTAssertEqual(entry.bytes, 400_000)
        XCTAssertEqual(try audioOf("a"), f.bytes)
        XCTAssertEqual(rangeHeaders(), ["bytes=100000-"], "один запрос: 200 целиком берём с нуля")
    }

    func testChangedEtagDropsTheOldPartAndStartsFromZero() async throws {
        let f = backend.add("a", 400_000) { $0.etag = "W/\"new\"" }
        try seedPart("a", f.bytes, 100_000)
        var old = job("a", duration: 10)
        old.etag = "W/\"old\""
        old.total = 400_000
        let entry = try await run(downloader(), old)
        XCTAssertEqual(entry.bytes, 400_000)
        XCTAssertEqual(rangeHeaders(), [nil], "частичный файл от другой версии выброшен")
        XCTAssertEqual(try audioOf("a"), f.bytes)
    }

    func test416ForAShrunkFileRestartsFromZero() async throws {
        let f = backend.add("a", 300_000) { $0.resolveBytes = nil; $0.etag = nil }
        try seedPart("a", Audio.bytes(400_000, seed: 99), 400_000)
        let entry = try await run(downloader(), job("a", duration: 10))
        XCTAssertEqual(entry.bytes, 300_000)
        XCTAssertEqual(try audioOf("a"), f.bytes)
        XCTAssertEqual(rangeHeaders(), ["bytes=400000-", nil])
    }

    func testWithoutBytesFromTheResolverLegacyPlayTheSizeComesFromContentRange() async throws {
        let f = backend.add("a", 5_000_000, duration: 120) { $0.resolveBytes = nil; $0.etag = nil }
        try seedPart("a", f.bytes, 5_000)
        let entry = try await run(downloader(), job("a", duration: 120))
        XCTAssertEqual(entry.bytes, 5_000_000)
        XCTAssertNil(entry.etag)
        XCTAssertEqual(try audioOf("a"), f.bytes)
        XCTAssertTrue(backend.fileRequests.allSatisfy { $0.header("If-Range") == nil })
    }

    // ---------- ссылка просрочена ----------

    func test403OnTheFileReResolvesAndContinuesFromTheSamePlace() async throws {
        let f = backend.add("big", 5_000_000, duration: 120)
        try seedPart("big", f.bytes, 100)
        backend.fileHook = { _, n in n == 2 ? Reply(status: 403) : nil }
        let resolves = Log<Int>()
        let b = backend!
        let counting = ClosureResolver { s, i in
            resolves.add(1)
            return try b.resolved(i)
        }
        let entry = try await run(downloader(resolver: counting), job("big", duration: 120))
        XCTAssertEqual(entry.bytes, 5_000_000)
        XCTAssertEqual(resolves.count, 2)
        XCTAssertEqual(try audioOf("big"), f.bytes)
        XCTAssertEqual(rangeHeaders(), ["bytes=100-", "bytes=2097252-", "bytes=2097252-", "bytes=4194404-"])
        let urls = backend.fileRequests.map { $0.url.absoluteString }
        XCTAssertNotEqual(urls[1], urls[2], "после резолва ссылка новая")
    }

    func test403MoreThanTwiceGivesUp() async throws {
        let f = backend.add("big", 5_000_000, duration: 120)
        try seedPart("big", f.bytes, 100)
        backend.fileHook = { _, _ in Reply(status: 403) }
        let resolves = Log<Int>()
        let b = backend!
        let counting = ClosureResolver { s, i in
            resolves.add(1)
            return try b.resolved(i)
        }
        let d = downloader(resolver: counting)
        let e = await offlineError { _ = try await d.download(job("big", duration: 120)) }
        XCTAssertEqual(e?.code, .sourceError)
        XCTAssertEqual(e?.reason, "expired")
        XCTAssertEqual(resolves.count, 3, "первый резолв и не больше двух повторных")
        XCTAssertEqual(storage.partSize(Key.of("blink", "big")), 100, "накопленное не потеряно")
    }

    func test404OnTheFileMeansNoFile() async throws {
        backend.add("a", 300_000)
        backend.fileHook = { _, _ in Reply(status: 404) }
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(e?.code, .notDownloadable)
    }

    // ---------- проверки файла ----------

    func testHtmlWithAnAudioTypeIsCaughtByTheFirstBytesBeforeAnythingIsWritten() async throws {
        let html = Array(("<html>" + String(repeating: "x", count: 50_000)).utf8.prefix(50_000))
        backend.set(Fixture(id: "a", bytes: html))
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 1)) }
        XCTAssertEqual(e?.code, .badContent)
        XCTAssertEqual(e?.reason, "magic")
        XCTAssertEqual(storage.partSize(Key.of("blink", "a")), 0)
        XCTAssertFalse(partExists("a"))
        XCTAssertEqual(backend.fileRequests.count, 1, "повторов нет")
    }

    func testJsonErrorBodyIsNotAFile() async throws {
        backend.add("a", 300_000) { $0.contentType = "application/json" }
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(e?.code, .badContent)
        XCTAssertEqual(e?.reason, "type")
    }

    func testTooSmallForItsDurationIsBadContentAndThePartIsDropped() async throws {
        backend.add("a", 300_000, duration: 213)
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 213)) }
        XCTAssertEqual(e?.code, .badContent)
        XCTAssertEqual(e?.reason, "too_small")
        XCTAssertEqual(storage.partSize(Key.of("blink", "a")), 0, "битое не докачиваем")
        XCTAssertNil(storage.audioPath(Key.of("blink", "a")))
    }

    func testSizeThatDisagreesWithTheResolverIsBadContent() async throws {
        backend.add("a", 300_000) { $0.resolveBytes = 300_010 }
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(e?.code, .badContent)
        XCTAssertEqual(e?.reason, "size_mismatch")
        XCTAssertNil(storage.audioPath(Key.of("blink", "a")))
    }

    // ---------- сеть ----------

    func testIoFailureWithNetworkUpIsSourceErrorWithNetworkDownNoNetwork() async throws {
        let dead = ClosureResolver { _, _ in Resolved(url: "http://127.0.0.1:1/x", bytes: 300_000, expiresAt: Int64.max) }
        let d = downloader(resolver: dead, transport: FailingTransport(error: .failed("connection refused")))
        let up = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(up?.code, .sourceError)
        network.set(false)
        let down = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(down?.code, .noNetwork)
    }

    func testSilenceFromTheServerIsTimeout() async throws {
        backend.add("a", 300_000)
        backend.fileHook = { _, _ in Reply(status: 0, failure: .timedOut) }
        let d = downloader()
        let e = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(e?.code, .timeout)
    }

    func testResolverTimeoutsAndIoErrorsAreClassified() async throws {
        let io = ClosureResolver { _, _ in throw TransportError.failed("boom") }
        let d1 = downloader(resolver: io)
        let a = await offlineError { _ = try await d1.download(job("a")) }
        XCTAssertEqual(a?.code, .sourceError)
        network.set(false)
        let b = await offlineError { _ = try await d1.download(job("a")) }
        XCTAssertEqual(b?.code, .noNetwork)
        network.set(true)
        let slow = ClosureResolver { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw OfflineError(.sourceError, "unreachable")
        }
        let d2 = downloader(resolver: slow, resolveMs: 300)
        let c = await offlineError { _ = try await d2.download(job("a")) }
        XCTAssertEqual(c?.code, .timeout)
    }

    // ---------- место, отмена ----------

    func testNoSpacePropagatesFromTheStorage() async throws {
        backend.add("a", 700_000)
        let full = FullStorage(root: dir)
        try full.open()
        let d = downloader(storage: full)
        let e = await offlineError { _ = try await d.download(job("a", duration: 10)) }
        XCTAssertEqual(e?.code, .noSpace)
        XCTAssertFalse(OfflineCode.noSpace.retryable)
    }

    func testIoErrorsFromDiskMapToNoSpaceOrSourceError() {
        func ns(_ text: String) -> NSError {
            return NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }
        XCTAssertEqual(FileStorage.mapIo(ns("No space left on device")).code, .noSpace)
        XCTAssertEqual(FileStorage.mapIo(ns("write failed: ENOSPC (No space left on device)")).code, .noSpace)
        XCTAssertEqual(FileStorage.mapIo(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))).code, .noSpace)
        XCTAssertEqual(FileStorage.mapIo(NSError(domain: NSCocoaErrorDomain, code: 640)).code, .noSpace)
        XCTAssertEqual(FileStorage.mapIo(ns("Permission denied")).code, .sourceError)
    }

    func testPartShorterThanTheAcceptedBytesIsBadContentTruncatedThePartIsDroppedAndNothingIsCommitted() async throws {
        backend.add("a", 1_500_000, duration: 60)
        let lossy = LossyStorage(root: dir)
        try lossy.open()
        let key = Key.of("blink", "a")
        let d = downloader(storage: lossy)
        let e = await offlineError { _ = try await d.download(job("a", duration: 60)) }
        XCTAssertEqual(e?.code, .badContent)
        XCTAssertEqual(e?.reason, "truncated")
        XCTAssertEqual(storage.partSize(key), 0, "битое не докачиваем")
        XCTAssertNil(storage.audioPath(key))
        XCTAssertEqual(backend.fileRequests.count, 1, "поверх битого не качаем дальше")
    }

    func testCancelKeepsTheVerifiedPrefixAndCommitsNothing() async throws {
        let f = backend.add("slow", 3_000_000, duration: 60)
        backend.throttleChunk = 200_000
        backend.throttleMs = 100
        let key = Key.of("blink", "slow")
        let d = downloader()
        let task = Task<ManifestEntry, Error> { try await d.download(job("slow", duration: 60)) }
        let b = backend!
        await waitUntil(30, "первый запрос к файлу") { !b.fileRequests.isEmpty }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        _ = await task.result

        let have = storage.partSize(key)
        XCTAssertTrue(have > 0 && have < 3_000_000, "что-то успело записаться: \(have)")
        let onDisk = storage.readPart(key, start: 0, end: have)
        XCTAssertEqual(Array(onDisk), Array(f.bytes.prefix(Int(have))), "в .part только правильный префикс")
        XCTAssertNil(storage.audioPath(key))
    }

    func testCommitMakesTheFileVisibleOnlyAtTheEnd() async throws {
        backend.add("a", 700_000)
        let st = storage!
        let key = Key.of("blink", "a")
        let visible = Log<Bool>()
        let hooks = DownloadHooks(onStage: { stage in
            if stage == .committing { visible.add(st.hasAudio(key)) }
        })
        let entry = try await run(downloader(), job("a", duration: 10), hooks: hooks)
        XCTAssertEqual(visible.items, [false], "I1: плеер видит файл только после commit")
        XCTAssertNotNil(storage.audioPath(entry.key))
    }
}
