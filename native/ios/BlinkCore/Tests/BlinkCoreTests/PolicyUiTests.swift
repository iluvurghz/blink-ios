import XCTest
@testable import BlinkCore

func edit(_ t: Track, _ change: (inout Track) -> Void) -> Track {
    var copy = t
    change(&copy)
    return copy
}

final class PolicyTests: XCTestCase {
    private let licensed = Track(
        id: "b:u1", title: "T", artist: "A", album: "LP", artwork: "https://x/c.jpg", duration: 200,
        source: "blink", lic: "u1", offline: true
    )

    private func denied(_ t: Track, signedIn: Bool = true, plus: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> (reason: String?, text: OfflineText?) {
        let d = OfflinePolicy.check(t, signedIn: signedIn, plusActive: plus)
        guard case .denied(let code, let reason) = d else {
            XCTFail("ожидали отказ", file: file, line: line)
            return (nil, nil)
        }
        XCTAssertEqual(code, .notAllowed, file: file, line: line)
        return (reason, d.text)
    }

    func testOnlyLicensedCatalogWithArtistConsentSignedInWithPlus() {
        XCTAssertEqual(OfflinePolicy.check(licensed, signedIn: true, plusActive: true), .allowed)
        XCTAssertEqual(denied(edit(licensed) { $0.source = nil; $0.lic = nil; $0.id = "123" }).reason, "source")
        XCTAssertEqual(denied(edit(licensed) { $0.source = "soundcloud" }).reason, "source")
        XCTAssertEqual(denied(edit(licensed) { $0.source = "jamendo"; $0.id = "j:1"; $0.lic = nil }).reason, "source")
        XCTAssertEqual(denied(edit(licensed) { $0.source = "chart"; $0.id = "cr1" }).reason, "source")
        XCTAssertEqual(denied(edit(licensed) { $0.lic = nil }).reason, "source")
        XCTAssertEqual(denied(edit(licensed) { $0.offline = false }).reason, "artist")
        XCTAssertEqual(denied(licensed, signedIn: false).reason, "auth")
        let noPlus = denied(licensed, plus: false)
        XCTAssertEqual(noPlus.reason, "plus")
        XCTAssertEqual(noPlus.text?.action, .openPlus)
        XCTAssertEqual(denied(edit(licensed) { $0.source = "vk" }).text?.message, "Этот трек играет только онлайн")
    }

    func testSavableDecidesWhetherTheSaveButtonExistsAtAll() {
        XCTAssertTrue(OfflinePolicy.savable(licensed))
        XCTAssertFalse(OfflinePolicy.savable(edit(licensed) { $0.offline = false }))
        XCTAssertFalse(OfflinePolicy.savable(edit(licensed) { $0.source = "chart"; $0.lic = nil }))
        XCTAssertEqual(OfflinePolicy.keyOf(licensed), "blink:u1")
        XCTAssertNil(OfflinePolicy.keyOf(edit(licensed) { $0.offline = false }))
    }

    func testSavedCopyPlaysOnlineAlwaysAndOfflineOnlyWhilePlusLasts() {
        let now: Int64 = 1_000
        XCTAssertTrue(OfflinePolicy.canPlaySaved(online: true, plusUntilMs: nil, nowMs: now))
        XCTAssertTrue(OfflinePolicy.canPlaySaved(online: false, plusUntilMs: now + 1, nowMs: now))
        XCTAssertFalse(OfflinePolicy.canPlaySaved(online: false, plusUntilMs: now, nowMs: now))
        XCTAssertFalse(OfflinePolicy.canPlaySaved(online: false, plusUntilMs: nil, nowMs: now))
    }

    func testCandidateCarriesAFullCopyOfTheTrackForTheManifest() {
        guard let c = OfflinePolicy.candidate(licensed) else { return XCTFail("нет кандидата") }
        XCTAssertEqual(c.key, "blink:u1")
        XCTAssertEqual(c.id, "u1")
        XCTAssertEqual(c.meta.title, "T")
        XCTAssertEqual(c.meta.cover, "https://x/c.jpg")
        XCTAssertEqual(c.meta.duration, 200)
        XCTAssertEqual(c.meta.track?.objectValue?["id"]?.stringValue, "b:u1")
        XCTAssertNil(OfflinePolicy.candidate(edit(licensed) { $0.offline = false }))
    }

    func testManifestEntryRoundTripsAsSchema1() {
        let e = ManifestEntry(
            key: "blink:u1", source: "blink", id: "u1", title: "T", artist: "A", bytes: 10, savedAt: 5,
            track: OfflinePolicy.candidate(licensed)?.meta.track
        )
        let text = e.encode()
        XCTAssertEqual(ManifestEntry.decode(text), e)
        XCTAssertTrue(text.contains("\"schema\":1") && text.contains("\"status\":\"saved\""), text)
        XCTAssertNil(ManifestEntry.decode(#"{"schema":2,"key":"k","source":"s","id":"i","title":"t","artist":"a","bytes":1,"savedAt":1}"#))
        XCTAssertNil(ManifestEntry.decode("not json"))
    }
}

final class SaveUiTests: XCTestCase {
    private let track = Track(id: "b:u1", title: "T", artist: "A", source: "blink", lic: "u1", offline: true)

    private func job(_ stage: Stage, have: Int64 = 0, total: Int64? = nil, code: OfflineCode? = nil, reason: String? = nil) -> JobView {
        return JobView(key: "blink:u1", title: "T", artist: "A", cover: "", stage: stage, have: have, total: total, attempt: 0, code: code, reason: reason, retryAt: nil)
    }

    private func state(_ jobs: [JobView] = [], saved: [ManifestEntry] = []) -> OfflineState {
        return OfflineState(ready: true, jobs: jobs, saved: saved)
    }

    func testNotSavableTracksAreOnlineOnlyWithTheRightReason() {
        XCTAssertEqual(SaveUi.of(edit(track) { $0.source = "soundcloud"; $0.lic = nil; $0.id = "sc1" }, state()), .onlineOnly(reason: "source"))
        XCTAssertEqual(SaveUi.of(edit(track) { $0.source = nil; $0.lic = nil; $0.id = "123" }, state()), .onlineOnly(reason: "source"))
        XCTAssertEqual(SaveUi.of(edit(track) { $0.offline = false }, state()), .onlineOnly(reason: "artist"))
    }

    func testAvailableThenQueuedThenProgressThenSaved() {
        XCTAssertEqual(SaveUi.of(track, state()), .available)
        XCTAssertEqual(SaveUi.of(track, state([job(.queued)])), .queued)
        XCTAssertEqual(SaveUi.of(track, state([job(.resolving)])), .progress(fraction: 0, indeterminate: true))
        XCTAssertEqual(SaveUi.of(track, state([job(.downloading, have: 250, total: 1000)])), .progress(fraction: 0.25, indeterminate: false))
        XCTAssertEqual(SaveUi.of(track, state([job(.downloading, have: 250, total: nil)])), .progress(fraction: 0, indeterminate: true))
        XCTAssertEqual(SaveUi.of(track, state([job(.verifying, have: 1000, total: 1000)])), .progress(fraction: 1, indeterminate: false))
        let entry = ManifestEntry(key: "blink:u1", source: "blink", id: "u1", title: "T", artist: "A", bytes: 10, savedAt: 1)
        XCTAssertEqual(SaveUi.of(track, state(saved: [entry])), .saved)
    }

    func testFailedCarriesTheHumanText() {
        guard case .failed(let text) = SaveUi.of(track, state([job(.failed, code: .notAllowed, reason: "plus")])) else {
            return XCTFail("ожидали ошибку")
        }
        XCTAssertEqual(text.message, "Сохранение для офлайна доступно с Blink+")
        XCTAssertEqual(text.action, .openPlus)
        guard case .failed(let timeout) = SaveUi.of(track, state([job(.failed, code: .timeout)])) else {
            return XCTFail("ожидали ошибку")
        }
        XCTAssertFalse(timeout.message.isEmpty)
    }
}

final class BatchSummaryTests: XCTestCase {
    private func fail(_ title: String, _ code: OfflineCode, _ reason: String? = nil) -> Failure {
        return Failure(key: "blink:" + title, title: title, code: code, reason: reason)
    }

    func testAllSaved() {
        XCTAssertEqual(BatchSummary.text(.batchDone(ok: 1, total: 1, failures: [])), "Сохранено")
        XCTAssertEqual(BatchSummary.text(.batchDone(ok: 5, total: 5, failures: [])), "Сохранено 5 из 5")
    }

    func testSingleFailureNamesTheTrackAndTheReason() {
        let e = OfflineEvent.batchDone(ok: 0, total: 1, failures: [fail("Rain", .notDownloadable)])
        XCTAssertEqual(BatchSummary.text(e), "Rain: Для этого трека нет файла")
    }

    func testMixedBatchListsTheFirstReasons() {
        let e = OfflineEvent.batchDone(ok: 3, total: 5, failures: [fail("A", .timeout), fail("B", .notAllowed, "plus")])
        XCTAssertEqual(
            BatchSummary.text(e),
            "Сохранено 3 из 5. 2 не вышло: A: Сервер долго не отвечает; B: Сохранение для офлайна доступно с Blink+"
        )
    }

    func testLongFailureListsAreCut() {
        let fails = (1...4).map { fail("T\($0)", .badContent) }
        let text = BatchSummary.text(.batchDone(ok: 1, total: 5, failures: fails))
        XCTAssertEqual(text, "Сохранено 1 из 5. 4 не вышло: T1: Файл пришёл повреждённым; T2: Файл пришёл повреждённым и ещё 2")
    }
}

final class QueueFilterTests: XCTestCase {
    private func t(_ n: Int) -> Track {
        return Track(id: "b:\(n)", title: "T\(n)", artist: "A", source: "blink", lic: "\(n)", offline: true)
    }

    private var all: [Track] { return (0...5).map { t($0) } }

    func testKeepsSavedOnlyAndMovesTheStart() {
        let saved: Set<String> = ["b:1", "b:3", "b:4"]
        let q = QueueFilter.offline(all, startIndex: 3) { saved.contains($0.id) }
        XCTAssertEqual(q.tracks.map { $0.id }, ["b:1", "b:3", "b:4"])
        XCTAssertEqual(q.startIndex, 1)
        XCTAssertEqual(q.skipped, 3)
    }

    func testUnsavedStartGoesToTheNextSavedOne() {
        let saved: Set<String> = ["b:1", "b:4"]
        let q = QueueFilter.offline(all, startIndex: 2) { saved.contains($0.id) }
        XCTAssertEqual(q.tracks[q.startIndex].id, "b:4")
    }

    func testNothingAfterTheStartWrapsToTheFirstSaved() {
        let saved: Set<String> = ["b:0", "b:1"]
        let q = QueueFilter.offline(all, startIndex: 4) { saved.contains($0.id) }
        XCTAssertEqual(q.startIndex, 0)
        XCTAssertEqual(q.skipped, 4)
    }

    func testNothingSavedMeansNothingToPlay() {
        let q = QueueFilter.offline(all, startIndex: 0) { _ in false }
        XCTAssertTrue(q.tracks.isEmpty)
        XCTAssertEqual(q.skipped, 6)
    }

    func testToastText() {
        XCTAssertEqual(QueueFilter.skippedText(1), "Пропущено 1 трек: нужен интернет")
        XCTAssertEqual(QueueFilter.skippedText(3), "Пропущено 3 трека: нужен интернет")
        XCTAssertEqual(QueueFilter.skippedText(7), "Пропущено 7 треков: нужен интернет")
    }
}

final class EntriesTests: XCTestCase {
    private func entry(_ track: JSONValue?) -> ManifestEntry {
        return ManifestEntry(
            key: "blink:u1", source: "blink", id: "u1", title: "Rain", artist: "Ayo", album: "LP",
            cover: "https://c/1.jpg", duration: 200, bytes: 10, savedAt: 1, track: track
        )
    }

    func testFullCopyWins() {
        let original = Track(id: "b:u1", title: "Rain", artist: "Ayo", explicit: true, source: "blink", lic: "u1", lyrics: "la la", offline: true)
        XCTAssertEqual(entry(original.asJSON()).toTrack(), original)
    }

    func testRebuildsFromEntryFieldsWhenTheCopyIsMissingOrBroken() {
        let expected = Track(
            id: "b:u1", title: "Rain", artist: "Ayo", album: "LP", artwork: "https://c/1.jpg", duration: 200,
            source: "blink", lic: "u1", offline: true
        )
        XCTAssertEqual(entry(nil).toTrack(), expected)
        XCTAssertEqual(entry(.object(["id": .number(5)])).toTrack(), expected)
    }
}
