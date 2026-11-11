import XCTest
@testable import BlinkCore

final class SearchModelTests: XCTestCase {
    private func t(_ id: String) -> Track {
        return Track(id: id, title: id, artist: "A")
    }

    private let none: SearchModel.ListFn = { [] }

    func testWaitsForTheDebounceAndTheLastQueryWins() async throws {
        let asked = Log<String>()
        let model = SearchModel(
            search: { q in asked.add(q); return [Track(id: q, title: q, artist: "A")] },
            newest: none, chart: none, debounceMs: 150
        )
        model.setQuery("b")
        await waitUntil(5, "loading") { model.current.loading }
        try await Task.sleep(nanoseconds: 60_000_000)
        model.setQuery("bl")
        await waitUntil(10, "результат") { model.current.searched }
        XCTAssertEqual(asked.items, ["bl"], "первый запрос не ушёл: его заменил второй")
        XCTAssertEqual(model.current.results.map { $0.id }, ["bl"])
        XCTAssertFalse(model.current.loading)
    }

    func testASlowOldAnswerNeverOverwritesANewerOne() async throws {
        let model = SearchModel(
            search: { q in
                if q == "slow" {
                    // Не уважает отмену: ответ приходит позже, чем у нового запроса.
                    _ = try? await Task.sleep(nanoseconds: 300_000_000)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                return [Track(id: q, title: q, artist: "A")]
            },
            newest: none, chart: none, debounceMs: 20
        )
        model.setQuery("slow")
        try await Task.sleep(nanoseconds: 100_000_000)
        model.setQuery("fast")
        await waitUntil(10, "быстрый ответ") { model.current.results.map { $0.id } == ["fast"] }
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(model.current.results.map { $0.id }, ["fast"])
    }

    func testEmptyQueryClearsAtOnceErrorIsReportedAndRetryRunsWithoutWaiting() async throws {
        let failing = Box<Bool>(true)
        let calls = Log<String>()
        let model = SearchModel(
            search: { q in
                calls.add(q)
                if failing.value { throw TransportError.offline }
                return [Track(id: q, title: q, artist: "A")]
            },
            newest: none, chart: none, debounceMs: 20
        )
        model.setQuery("abc")
        await waitUntil(10, "ошибка") { model.current.error }
        XCTAssertTrue(model.current.searched)
        failing.value = false
        model.retry()
        await waitUntil(10, "повтор") { !model.current.error && model.current.results.count == 1 }
        XCTAssertEqual(model.current.results.map { $0.id }, ["abc"])
        XCTAssertEqual(calls.count, 2)
        model.setQuery("  ")
        await waitUntil(10, "очистка") { !model.current.searched }
        XCTAssertTrue(model.current.results.isEmpty)
    }

    func testHomeSurvivesOneFailingHalf() async throws {
        let fresh = [t("new")]
        let model = SearchModel(
            search: { _ in [] },
            newest: { fresh },
            chart: { throw TransportError.offline },
            debounceMs: 20
        )
        model.refreshHome()
        await waitUntil(10, "главная") { !model.current.homeLoading && !model.current.newest.isEmpty }
        let s = model.current
        XCTAssertEqual(s.newest.map { $0.id }, ["new"])
        XCTAssertTrue(s.chart.isEmpty)
        XCTAssertFalse(s.homeError)
        XCTAssertFalse(s.homeLoading)
    }

    func testHomeErrorOnlyWhenBothHalvesFailAndNothingIsShown() async throws {
        let model = SearchModel(
            search: { _ in [] },
            newest: { throw TransportError.offline },
            chart: { throw TransportError.timedOut },
            debounceMs: 20
        )
        model.refreshHome()
        await waitUntil(10, "ошибка главной") { model.current.homeError }
        XCTAssertTrue(model.current.homeError)
    }
}
