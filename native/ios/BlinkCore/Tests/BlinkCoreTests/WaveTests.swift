import XCTest
@testable import BlinkCore

final class MemBlob: BlobStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ value: String?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

private final class Lib: Library, @unchecked Sendable {
    let likes: [Track]
    let recent: [Track]

    init(_ likes: [Track], _ recent: [Track] = []) {
        self.likes = likes
        self.recent = recent
    }
}

private func tr(_ id: Int, _ artist: String, _ genre: String, _ title: String? = nil) -> Track {
    return Track(id: "cr\(id)", title: title ?? "Song \(id)", artist: artist, genre: genre, source: "chart")
}

private final class FakeSource: WaveSource, @unchecked Sendable {
    private let lock = NSLock()
    let poolTracks: [WaveCandidate]
    let top: [Track]
    private var isDown = false
    private var similar: [String] = []

    init(_ pool: [WaveCandidate], _ top: [Track]) {
        self.poolTracks = pool
        self.top = top
    }

    func setDown(_ v: Bool) {
        lock.lock()
        isDown = v
        lock.unlock()
    }

    var similarCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return similar
    }

    private var down: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isDown
    }

    func pool(seeds: [String]) async throws -> PoolResult {
        if down { throw ServerError("pool", 500) }
        return PoolResult(tracks: poolTracks, seedGenre: [])
    }

    func genres(items: [String]) async throws -> [String: String] { return [:] }

    func similarIds(seed: String) async throws -> SimilarResult {
        lock.lock()
        similar.append(seed)
        lock.unlock()
        return SimilarResult(ids: ["cr777", "cr778"], genre: "rap")
    }

    func topChart() async throws -> [Track] {
        if down { throw ServerError("top", 500) }
        return top
    }

    func periodChart(kind: String) async throws -> [Track] {
        if down { throw ServerError("period", 500) }
        return []
    }
}

final class WaveEngineTests: XCTestCase {
    private let clock = Box<Int64>(1_800_000_000_000)
    private let genres = ["rusrap", "local-indie", "pop"]
    private let day: Int64 = 86_400_000

    /// 3 жанра по 4 артиста по 3 лайка и две «шумовые» одиночки из метала (≈4% профиля, меньше порога 6%).
    private func likes() -> [Track] {
        var out: [Track] = []
        var id = 1
        for g in genres {
            for a in 1...4 {
                for _ in 1...3 {
                    out.append(tr(id, "\(g) artist \(a)", g))
                    id += 1
                }
            }
        }
        out.append(tr(900, "Noise one", "metal"))
        out.append(tr(901, "Noise two", "metal"))
        return out
    }

    private func pool() -> [WaveCandidate] {
        var out: [WaveCandidate] = []
        var id = 100
        for g in genres {
            for a in 1...14 {
                out.append(WaveCandidate(track: tr(id, "pool \(g) \(a)", g), src: a % 3 == 0 ? "popular" : "similar", seed: "seed", hits: 1))
                id += 1
            }
        }
        for n in 1...4 { out.append(WaveCandidate(track: tr(800 + n, "Metal band \(n)", "metal"), src: "similar", seed: "seed", hits: 1)) }
        return out
    }

    private func top() -> [Track] {
        var out: [Track] = []
        for i in 1...12 { out.append(tr(300 + i, "chart \(genres[i % 3]) \(i)", genres[i % 3])) }
        for i in 1...3 { out.append(tr(850 + i, "Chart metal \(i)", "metal")) }
        return out
    }

    private func engine(_ src: WaveSource, _ store: WaveStore, _ lib: Library? = nil, _ settings: WaveSettings = WaveSettings(), seed: UInt64 = 1) -> WaveEngine {
        let c = clock
        return WaveEngine(source: src, store: store, library: lib ?? Lib(likes()), settings: { settings }, now: { c.value }, rng: WaveRandom(seed: seed))
    }

    func testProfileKeepsSingleLikesOutOfTheCoreAndOutOfTheGenreTop() async {
        let e = engine(FakeSource(pool(), top()), WaveStore(MemBlob()))
        let p = await e.buildProfile(clock.value)
        XCTAssertEqual(p.core.count, 12)
        XCTAssertEqual(p.top, Set(["rusrap", "local-indie", "pop"]))
        XCTAssertFalse(p.top.contains("metal"))
        XCTAssertTrue(p.active)
    }

    func testBatchHasTheRightSizeAndSkipsForeignGenresWithoutTheExploreSlot() async {
        let e = engine(FakeSource(pool(), top()), WaveStore(MemBlob()), nil, WaveSettings(mode: .mix, explore: false))
        let b = await e.batch(16)
        XCTAssertEqual(b.count, 16)
        XCTAssertTrue(b.allSatisfy { $0.genre != "metal" }, "метал не в профиле")
        let counts = Dictionary(grouping: b, by: { $0.artist.lowercased() }).mapValues { $0.count }
        XCTAssertTrue(counts.values.allSatisfy { $0 <= 2 }, "не больше двух треков артиста")
        XCTAssertEqual(Set(b.map { $0.id }).count, b.count)
    }

    func testExploreSlotLetsAtMostACoupleOfForeignTracksThrough() async {
        let e = engine(FakeSource(pool(), top()), WaveStore(MemBlob()))
        var metal = 0
        for _ in 0..<5 {
            metal += await e.batch(16).filter { $0.genre == "metal" }.count
            clock.value += 3 * day
        }
        XCTAssertLessThanOrEqual(metal, 10, "слот исследования: около двух из шестнадцати, было \(metal)")
    }

    func testTheNextBatchDoesNotRepeatWhatWasJustShown() async {
        let e = engine(FakeSource(pool(), top()), WaveStore(MemBlob()))
        let a = Set(await e.batch(16).map { $0.id })
        clock.value += 60_000
        let b = Set(await e.batch(16).map { $0.id })
        XCTAssertTrue(a.intersection(b).isEmpty, "повторы: \(a.intersection(b))")
    }

    func testTracksAlreadyInTheQueueAndInRecentAreSkipped() async {
        let e = engine(FakeSource(pool(), top()), WaveStore(MemBlob()), Lib(likes(), [tr(101, "pool rusrap 1", "rusrap")]))
        let b = await e.batch(16, exclude: ["cr102", "cr103"])
        XCTAssertTrue(b.allSatisfy { $0.id != "cr101" && $0.id != "cr102" && $0.id != "cr103" })
    }

    func testDislikeTwiceRemovesTheArtistForGoodAndBlacklistsSimilarTracks() async {
        let src = FakeSource(pool(), top())
        let store = WaveStore(MemBlob())
        let e = engine(src, store)
        await e.dislike(tr(101, "pool rusrap 1", "rusrap"))
        await e.dislike(tr(555, "pool rusrap 1", "rusrap", "Another"))
        XCTAssertEqual(store.data.banArtists["pool rusrap 1"], 2)
        XCTAssertNotNil(store.data.negIds["cr777"])
        XCTAssertNotNil(store.data.negIds["cr778"])
        XCTAssertEqual(store.data.banIds, ["cr101", "cr555"])
        XCTAssertEqual(src.similarCalls.first, "cr101")
        for _ in 0..<4 {
            let b = await e.batch(16)
            XCTAssertTrue(b.allSatisfy { $0.artist != "pool rusrap 1" })
            clock.value += 2 * day
        }
    }

    func testThreeEarlySkipsExcludeTheArtistAndListeningToTheEndRaisesIt() async {
        let store = WaveStore(MemBlob())
        let e = engine(FakeSource(pool(), top()), store)
        let t = tr(102, "pool rusrap 2", "rusrap")
        for _ in 0..<3 { await e.noteSkip(t) }
        let b = await e.batch(16)
        XCTAssertTrue(b.allSatisfy { $0.artist != "pool rusrap 2" })
        await e.noteListen(tr(103, "pool rusrap 3", "rusrap"), fraction: 0.5)
        XCTAssertTrue(store.data.listen.isEmpty, "меньше 70% не считается")
        await e.noteListen(tr(103, "pool rusrap 3", "rusrap"), fraction: 0.9)
        XCTAssertEqual(store.data.listen["pool rusrap 3"]?.score, 1.0)
    }

    func testDiscoverModeNeverReturnsFavouriteArtists() async {
        let withFavourite = pool() + [WaveCandidate(track: tr(150, "rusrap artist 1", "rusrap"), src: "similar", seed: "seed", hits: 3)]
        let e = engine(FakeSource(withFavourite, top()), WaveStore(MemBlob()), nil, WaveSettings(mode: .discover))
        for _ in 0..<3 {
            let b = await e.batch(16)
            XCTAssertTrue(b.allSatisfy { !$0.artist.hasPrefix("rusrap artist") })
            clock.value += 2 * day
        }
    }

    func testServerDownMeansAnEmptyBatchSoTheCallerCanFallBack() async {
        let src = FakeSource(pool(), top())
        src.setDown(true)
        let b = await engine(src, WaveStore(MemBlob())).batch(16)
        XCTAssertTrue(b.isEmpty)
    }

    func testQuickStartUsesTheSpareFromTheLastBatchAndThenTheHistory() async {
        let store = WaveStore(MemBlob())
        let e = engine(FakeSource(pool(), top()), store)
        let first = await e.quickStart()
        XCTAssertEqual(first.count, 3)
        clock.value += 3 * day
        _ = await e.batch(16)
        XCTAssertGreaterThanOrEqual(store.data.spare.count, 3)
        clock.value += 3 * day
        let q = await e.quickStart()
        XCTAssertEqual(q.count, 4)
        let spareIds = Set(store.data.spare.map { $0.id })
        XCTAssertTrue(q.allSatisfy { spareIds.contains($0.id) })
    }

    func testStateSurvivesARestart() async {
        let blob = MemBlob()
        let s1 = WaveStore(blob)
        _ = await engine(FakeSource(pool(), top()), s1).batch(16)
        let s2 = WaveStore(blob)
        XCTAssertEqual(Set(s1.data.seen.keys), Set(s2.data.seen.keys))
        XCTAssertFalse(s2.data.seen.isEmpty)
    }

    func testSplitArtistsHandlesCollaborations() {
        XCTAssertEqual(splitArtists("A, B feat. C"), ["A", "B", "C"])
        XCTAssertEqual(splitArtists("Kid & Mad"), ["Kid", "Mad"])
        XCTAssertEqual(splitArtists("Solo"), ["Solo"])
    }
}
