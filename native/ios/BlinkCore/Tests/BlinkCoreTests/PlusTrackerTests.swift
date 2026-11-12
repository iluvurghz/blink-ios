import XCTest
@testable import BlinkCore

final class MemoryKeyValue: KeyValue, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return map[key]
    }

    func put(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let v = value { map[key] = v } else { map.removeValue(forKey: key) }
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return map.isEmpty
    }
}

/// Ответ, который тест меняет по ходу дела.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

final class PlusTrackerTests: XCTestCase {
    func testRefreshStoresTheAnswerAndSurvivesARestart() async {
        let mem = MemoryKeyValue()
        let t1 = PlusTracker(fetch: { PlusStatus(active: true, untilMs: 5_000) }, store: mem, now: { 1_000 })
        XCTAssertFalse(t1.info.active)
        let ok = await t1.refresh()
        XCTAssertTrue(ok)
        XCTAssertTrue(t1.info.activeAt(4_999))
        XCTAssertFalse(t1.info.activeAt(5_000))
        // «перезапуск» без сети: берём последнюю известную дату
        let t2 = PlusTracker(fetch: { throw TransportError.offline }, store: mem, now: { 2_000 })
        XCTAssertEqual(t2.info.untilMs, 5_000)
        XCTAssertEqual(t2.info.offlineUntilMs(), 5_000)
        let again = await t2.refresh()
        XCTAssertFalse(again)
        XCTAssertEqual(t2.info.untilMs, 5_000)
    }

    func testAFailedOrEmptyAnswerKeepsThePreviousValueANoSubscriptionAnswerReplacesIt() async {
        let mem = MemoryKeyValue()
        let next = Box<PlusStatus?>(PlusStatus(active: true, untilMs: 9_000))
        let t = PlusTracker(fetch: { next.value }, store: mem, now: { 1 })
        _ = await t.refresh()
        next.value = nil
        let empty = await t.refresh()
        XCTAssertFalse(empty)
        XCTAssertTrue(t.info.active)
        next.value = PlusStatus(active: false, untilMs: nil)
        let answered = await t.refresh()
        XCTAssertTrue(answered)
        XCTAssertFalse(t.info.active)
        XCTAssertNil(t.info.offlineUntilMs())
    }

    func testLifetimePlusHasNoEndDateAndNeverExpiresOffline() {
        let info = PlusInfo(active: true, untilMs: nil)
        XCTAssertTrue(info.activeAt(Int64.max - 1))
        XCTAssertEqual(info.offlineUntilMs(), Int64.max)
    }

    func testClearForgetsEverything() async {
        let mem = MemoryKeyValue()
        let t = PlusTracker(fetch: { PlusStatus(active: true, untilMs: 9_000) }, store: mem, now: { 1 })
        _ = await t.refresh()
        t.clear()
        XCTAssertFalse(t.info.active)
        XCTAssertTrue(mem.isEmpty)
    }
}
