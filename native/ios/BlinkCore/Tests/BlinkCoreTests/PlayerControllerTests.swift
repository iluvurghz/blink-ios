import XCTest
@testable import BlinkCore

/// Движок-двойник: запоминает команды, события шлёт тест.
final class FakeEngine: PlaybackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: PlaybackEngineDelegate?
    let log = Log<String>()

    var delegate: PlaybackEngineDelegate? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return target
        }
        set {
            lock.lock()
            target = newValue
            lock.unlock()
        }
    }

    func load(_ source: PlaySource, autoplay: Bool) {
        switch source {
        case .file(let path): log.add("load file \(path) autoplay=\(autoplay)")
        case .stream(let url): log.add("load stream \(url) autoplay=\(autoplay)")
        }
    }

    func setPlaying(_ playing: Bool) { log.add("playing \(playing)") }
    func seek(toMs ms: Int64) { log.add("seek \(ms)") }
    func stop() { log.add("stop") }

    var loads: [String] { return log.items.filter { $0.hasPrefix("load") } }
}

final class FakeSaved: SavedAudio, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String>
    let played = Log<String>()

    init(_ keys: Set<String> = []) { self.keys = keys }

    func isSaved(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.contains(key)
    }

    func audioPath(_ key: String) -> String? { return isSaved(key) ? "/saved/" + key : nil }
    func markPlayed(_ key: String) { played.add(key) }
}

struct ClosureSource: PlaySourceProvider {
    let body: @Sendable (Track) async throws -> PlaySource

    func source(for track: Track) async throws -> PlaySource {
        return try await body(track)
    }
}

final class PlayerControllerTests: XCTestCase {
    /// Трек каталога Blink (его можно сохранить) или обычный.
    private func t(_ id: String, blink: Bool = false, seconds: Int = 200) -> Track {
        if blink {
            return Track(id: "b:" + id, title: "T" + id, artist: "A", duration: seconds, source: "blink", lic: id, offline: true)
        }
        return Track(id: id, title: "T" + id, artist: "A", duration: seconds)
    }

    private struct Rig {
        let c: PlayerController
        let engine: FakeEngine
        let toasts: Toasts
        let seen: Log<Toast>
        let nav: Nav
        let plus: Box<Int>
        let saved: FakeSaved
    }

    private func rig(
        saved: Set<String> = [],
        source: @escaping @Sendable (Track) async throws -> PlaySource = { .stream(url: "http://x/" + $0.id) }
    ) -> Rig {
        let engine = FakeEngine()
        let toasts = Toasts()
        let seen = Log<Toast>()
        toasts.observe { seen.add($0) }
        let nav = Nav()
        let plus = Box<Int>(0)
        let savedAudio = FakeSaved(saved)
        let c = PlayerController(
            engine: engine,
            source: ClosureSource(body: source),
            saved: savedAudio,
            toasts: toasts,
            nav: nav,
            openPlus: { plus.value += 1 }
        )
        return Rig(c: c, engine: engine, toasts: toasts, seen: seen, nav: nav, plus: plus, saved: savedAudio)
    }

    private func loaded(_ r: Rig, _ count: Int = 1) async {
        await waitUntil(10, "загрузка в движок") { r.engine.loads.count >= count }
    }

    func testPlaysTheChosenTrackAndFillsTheState() async throws {
        let r = rig()
        r.c.play([t("a"), t("b"), t("c")], at: 1)
        await loaded(r)
        XCTAssertEqual(r.engine.loads, ["load stream http://x/b autoplay=true"])
        let s = r.c.current
        XCTAssertEqual(s.track?.id, "b")
        XCTAssertTrue(s.hasNext)
        XCTAssertTrue(s.hasPrevious)
        XCTAssertTrue(s.playing)
        XCTAssertEqual(s.durationMs, 200_000)
    }

    func testEngineEventsUpdatePositionAndDuration() async throws {
        let r = rig()
        r.c.play([t("a")], at: 0)
        await loaded(r)
        r.c.engine(playing: true, buffering: false, positionMs: 1500, durationMs: 187_000)
        let s = r.c.current
        XCTAssertEqual(s.positionMs, 1500)
        XCTAssertEqual(s.durationMs, 187_000)
        XCTAssertTrue(s.playing)
        XCTAssertFalse(s.buffering)
        XCTAssertFalse(s.hasNext)
        XCTAssertFalse(s.hasPrevious)
    }

    func testASlowAnswerForAnOldTrackNeverStartsPlayback() async throws {
        let r = rig(source: { track in
            if track.id == "a" { try? await Task.sleep(nanoseconds: 300_000_000) }
            return .stream(url: "http://x/" + track.id)
        })
        r.c.play([t("a"), t("b")], at: 0)
        try await Task.sleep(nanoseconds: 50_000_000)
        r.c.play([t("b")], at: 0)
        await loaded(r)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(r.engine.loads, ["load stream http://x/b autoplay=true"])
        XCTAssertEqual(r.c.current.track?.id, "b")
    }

    func testTrackEndAdvancesAndTheLastOneStopsAndRestartsOnPlay() async throws {
        let r = rig()
        r.c.play([t("a"), t("b")], at: 0)
        await loaded(r)
        r.c.engineEnded()
        await loaded(r, 2)
        XCTAssertEqual(r.c.current.track?.id, "b")
        r.c.engine(playing: true, buffering: false, positionMs: 100, durationMs: 200_000)

        r.c.engineEnded()
        let s = r.c.current
        XCTAssertFalse(s.playing)
        XCTAssertEqual(s.positionMs, 200_000)
        XCTAssertEqual(r.engine.loads.count, 2, "после последнего трека ничего нового не грузим")

        r.c.toggle()
        XCTAssertTrue(r.engine.log.items.suffix(2).elementsEqual(["seek 0", "playing true"]), "\(r.engine.log.items)")
        XCTAssertTrue(r.c.current.playing)
        XCTAssertEqual(r.c.current.positionMs, 0)
    }

    func testPreviousRestartsAfterThreeSecondsOtherwiseGoesBack() async throws {
        let r = rig()
        r.c.play([t("a"), t("b"), t("c")], at: 1)
        await loaded(r)
        r.c.engine(playing: true, buffering: false, positionMs: 5000, durationMs: 200_000)
        r.c.previous()
        XCTAssertTrue(r.engine.log.items.suffix(2).elementsEqual(["seek 0", "playing true"]), "\(r.engine.log.items)")
        XCTAssertEqual(r.c.current.track?.id, "b", "позже трёх секунд «Назад» только перематывает")

        r.c.engine(playing: true, buffering: false, positionMs: 1000, durationMs: 200_000)
        r.c.previous()
        await loaded(r, 2)
        XCTAssertEqual(r.c.current.track?.id, "a")
        XCTAssertEqual(r.engine.loads.last, "load stream http://x/a autoplay=true")

        // на первом треке «Назад» всегда в начало
        r.c.engine(playing: true, buffering: false, positionMs: 1000, durationMs: 200_000)
        r.c.previous()
        XCTAssertEqual(r.c.current.track?.id, "a")
        XCTAssertEqual(r.engine.loads.count, 2)
    }

    func testNextMovesOnlyWhenThereIsOne() async throws {
        let r = rig()
        r.c.play([t("a"), t("b")], at: 0)
        await loaded(r)
        r.c.next()
        await loaded(r, 2)
        XCTAssertEqual(r.c.current.track?.id, "b")
        r.c.next()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.engine.loads.count, 2)
        XCTAssertEqual(r.c.current.track?.id, "b")
    }

    // ---------- отказы ----------

    func testNeedSignInAsksToSignInAndPauses() async throws {
        let r = rig(source: { _ in throw PlayFailure(.needSignIn, "Войдите, чтобы слушать треки Blink") })
        r.c.play([t("a"), t("b")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        let toast = r.seen.items[0]
        XCTAssertEqual(toast.message, "Войдите, чтобы слушать треки Blink")
        XCTAssertEqual(toast.action, "Войти")
        XCTAssertFalse(r.c.current.playing)
        XCTAssertTrue(r.engine.loads.isEmpty)
        toast.onAction?()
        XCTAssertEqual(r.nav.current.tab, .account)
    }

    func testPlusRequiredOffersBlinkPlus() async throws {
        let r = rig(source: { _ in throw PlayFailure(.plusRequired, "Без интернета сохранённые играют с Blink+") })
        r.c.play([t("a")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        let toast = r.seen.items[0]
        XCTAssertEqual(toast.action, "Открыть Blink+")
        toast.onAction?()
        XCTAssertEqual(r.plus.value, 1)
        XCTAssertFalse(r.c.current.playing)
    }

    func testNoNetworkSkipsToTheNextSavedTrackWithOneToast() async throws {
        let r = rig(saved: ["blink:c"], source: { track in
            if track.lic == "c" { return .file(path: "/saved/blink:c") }
            throw PlayFailure(.needsNetwork, "Нужен интернет: этот трек не сохранён")
        })
        r.c.play([t("a"), t("b"), t("c", blink: true), t("d")], at: 0)
        await loaded(r)
        XCTAssertEqual(r.engine.loads, ["load file /saved/blink:c autoplay=true"])
        XCTAssertEqual(r.c.current.track?.id, "b:c")
        XCTAssertEqual(r.seen.items.map { $0.message }, ["Пропущено 2 трека: нужен интернет"])
    }

    func testNoNetworkAndNothingSavedStopsWithOneToast() async throws {
        let r = rig(source: { _ in throw PlayFailure(.needsNetwork, "Нужен интернет: этот трек не сохранён") })
        r.c.play([t("a"), t("b")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.seen.items.map { $0.message }, ["Нет интернета. Дальше в очереди нет сохранённых треков"])
        XCTAssertFalse(r.c.current.playing)
        XCTAssertTrue(r.engine.loads.isEmpty)
    }

    func testNotFoundToastsAndMovesOn() async throws {
        let r = rig(source: { track in
            if track.id == "a" { throw PlayFailure(.notFound, "Трек снят или ещё не вышел") }
            return .stream(url: "http://x/" + track.id)
        })
        r.c.play([t("a"), t("b")], at: 0)
        await loaded(r)
        XCTAssertEqual(r.seen.items.map { $0.message }, ["Трек снят или ещё не вышел"])
        XCTAssertEqual(r.c.current.track?.id, "b")
        XCTAssertEqual(r.engine.loads, ["load stream http://x/b autoplay=true"])
    }

    func testNotFoundOnTheLastTrackStops() async throws {
        let r = rig(source: { _ in throw PlayFailure(.unavailable, "Источник сейчас недоступен") })
        r.c.play([t("a")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(r.c.current.playing)
        XCTAssertFalse(r.c.current.buffering)
        XCTAssertEqual(r.seen.count, 1)
    }

    func testAServerHiccupToastsAndStaysOnTheTrackInsteadOfBurningThroughTheQueue() async throws {
        let r = rig(source: { _ in throw TransportError.offline })
        r.c.play([t("a"), t("b"), t("c")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(r.seen.count, 1)
        XCTAssertEqual(r.c.current.track?.id, "a")
        XCTAssertFalse(r.c.current.playing)
        XCTAssertTrue(r.engine.loads.isEmpty)
    }

    func testToggleAfterAFailureTriesTheSameTrackAgain() async throws {
        let attempts = Box<Int>(0)
        let r = rig(source: { track in
            attempts.value += 1
            if attempts.value == 1 { throw TransportError.timedOut }
            return .stream(url: "http://x/" + track.id)
        })
        r.c.play([t("a")], at: 0)
        await waitUntil(10, "тост") { r.seen.count >= 1 }
        r.c.toggle()
        await loaded(r)
        XCTAssertEqual(r.engine.loads, ["load stream http://x/a autoplay=true"])
        XCTAssertTrue(r.c.current.playing)
    }

    func testEngineFailureToastsAndAdvances() async throws {
        let r = rig()
        r.c.play([t("a"), t("b")], at: 0)
        await loaded(r)
        r.c.engineFailed("Не открылось")
        await loaded(r, 2)
        XCTAssertEqual(r.seen.items.map { $0.message }, ["Не открылось"])
        XCTAssertEqual(r.c.current.track?.id, "b")
    }

    // ---------- пауза, перемотка ----------

    func testPausingWhileTheLinkIsStillBeingFoundPreparesWithoutPlaying() async throws {
        let r = rig(source: { track in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return .stream(url: "http://x/" + track.id)
        })
        r.c.play([t("a")], at: 0)
        XCTAssertTrue(r.c.current.playing)
        r.c.toggle()
        XCTAssertFalse(r.c.current.playing)
        await loaded(r)
        XCTAssertEqual(r.engine.loads, ["load stream http://x/a autoplay=false"])
    }

    func testToggleFlipsPlayAndPauseOnALoadedTrack() async throws {
        let r = rig()
        r.c.play([t("a")], at: 0)
        await loaded(r)
        r.c.engine(playing: true, buffering: false, positionMs: 10, durationMs: 200_000)
        r.c.toggle()
        XCTAssertEqual(r.engine.log.items.last, "playing false")
        XCTAssertFalse(r.c.current.playing)
        r.c.toggle()
        XCTAssertEqual(r.engine.log.items.last, "playing true")
        XCTAssertTrue(r.c.current.playing)
    }

    func testSeekGoesToTheEngineAndIsClampedToTheTrack() async throws {
        let r = rig()
        r.c.play([t("a")], at: 0)
        await loaded(r)
        r.c.engine(playing: true, buffering: false, positionMs: 0, durationMs: 200_000)
        r.c.seek(toMs: 90_000)
        XCTAssertEqual(r.engine.log.items.last, "seek 90000")
        XCTAssertEqual(r.c.current.positionMs, 90_000)
        r.c.seek(toMs: 999_999)
        XCTAssertEqual(r.engine.log.items.last, "seek 200000")
        r.c.seek(toMs: -5)
        XCTAssertEqual(r.engine.log.items.last, "seek 0")
    }

    func testAnEmptyQueueDoesNothing() async throws {
        let r = rig()
        r.c.play([], at: 0)
        r.c.toggle()
        r.c.next()
        r.c.previous()
        r.c.seek(toMs: 5)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(r.c.current.track)
        XCTAssertTrue(r.engine.log.items.isEmpty)
    }

    func testToastsReachOnlyThoseSubscribedNow() async throws {
        let toasts = Toasts()
        toasts.show("раньше")
        let seen = Log<Toast>()
        toasts.observe { seen.add($0) }
        toasts.show("позже", action: "Ок") {}
        await waitUntil(5, "тост") { seen.count >= 1 }
        XCTAssertEqual(seen.items.map { $0.message }, ["позже"])
        XCTAssertEqual(seen.items.first?.action, "Ок")
    }

    func testNavGoClosesThePlayer() async throws {
        let nav = Nav()
        XCTAssertEqual(nav.current, NavState(tab: .search, playerOpen: false))
        nav.openPlayer(true)
        XCTAssertTrue(nav.current.playerOpen)
        nav.go(.downloads)
        XCTAssertEqual(nav.current, NavState(tab: .downloads, playerOpen: false))
    }
}
