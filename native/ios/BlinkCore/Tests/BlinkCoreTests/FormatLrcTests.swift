import XCTest
@testable import BlinkCore

final class FormatTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(Format.duration(0), "0:00")
        XCTAssertEqual(Format.duration(-5), "0:00")
        XCTAssertEqual(Format.duration(213), "3:33")
        XCTAssertEqual(Format.duration(605), "10:05")
        XCTAssertEqual(Format.duration(3723), "1:02:03")
    }

    func testBytesInRussian() {
        XCTAssertEqual(Format.bytes(0), "0 Б")
        XCTAssertEqual(Format.bytes(512), "512 Б")
        XCTAssertEqual(Format.bytes(1024), "1 КБ")
        XCTAssertEqual(Format.bytes(840 * 1024), "840 КБ")
        XCTAssertEqual(Format.bytes(Int64(12.3 * 1024 * 1024)), "12,3 МБ")
        XCTAssertEqual(Format.bytes(5 * 1024 * 1024), "5,0 МБ")
        XCTAssertEqual(Format.bytes(120 * 1024 * 1024), "120 МБ")
        XCTAssertEqual(Format.bytes(Int64(1.25 * 1024 * 1024 * 1024)), "1,25 ГБ")
        XCTAssertEqual(Format.bytes(-3), "0 Б")
    }

    func testPluralForms() {
        let forms: [(Int, String)] = [
            (0, "треков"), (1, "трек"), (2, "трека"), (4, "трека"), (5, "треков"), (11, "треков"), (12, "треков"),
            (14, "треков"), (21, "трек"), (22, "трека"), (25, "треков"), (101, "трек"), (111, "треков"),
        ]
        for (n, word) in forms {
            XCTAssertEqual(Format.plural(n, "трек", "трека", "треков"), word, "n=\(n)")
        }
        XCTAssertEqual(Format.tracks(3), "3 трека")
    }

    func testDateInRussian() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-12-12 12:00 UTC
        XCTAssertEqual(Format.date(1_797_076_800_000, timeZone: utc), "12 декабря 2026")
        XCTAssertEqual(Format.date(1_798_761_600_000, timeZone: utc), "1 января 2027")
    }
}

final class LrcTests: XCTestCase {
    func testParsesTagsSeveralStampsPerLineAndSortsByTime() {
        let lines = Lrc.parse("""
        [ar:Artist]
        [ti:Title]
        [00:12.50]Second
        [00:01.00]First
        [00:30.00][01:00.25]Chorus
        no stamp here
        """)
        XCTAssertEqual(lines.map { $0.text }, ["First", "Second", "Chorus", "Chorus"])
        XCTAssertEqual(lines.map { $0.timeMs }, [1_000, 12_500, 30_000, 60_250])
    }

    func testHandlesWindowsLineEndingsAndBareMinutes() {
        let lines = Lrc.parse("[00:05]a\r\n[01:05.5]b\r\n")
        XCTAssertEqual(lines.map { $0.timeMs }, [5_000, 65_500])
        XCTAssertEqual(lines.map { $0.text }, ["a", "b"])
    }

    func testEnhancedWordTimings() {
        let lines = Lrc.parse("[00:10.00]<00:10.00>Hel<00:10.40>lo <00:11.00>world")
        XCTAssertEqual(lines.count, 1)
        guard let line = lines.first else { return }
        XCTAssertEqual(line.text, "Hello world")
        XCTAssertEqual(line.words?.map { $0.timeMs }, [10_000, 10_400, 11_000])
        XCTAssertEqual(line.words?.map { $0.text }, ["Hel", "lo ", "world"])
    }

    func testActiveLineByPosition() {
        let lines = Lrc.parse("[00:05.00]a\n[00:10.00]b\n[00:20.00]c")
        XCTAssertEqual(Lrc.activeIndex(lines, positionMs: 0), -1)
        XCTAssertEqual(Lrc.activeIndex(lines, positionMs: 5_000), 0)
        XCTAssertEqual(Lrc.activeIndex(lines, positionMs: 9_999), 0)
        XCTAssertEqual(Lrc.activeIndex(lines, positionMs: 10_000), 1)
        XCTAssertEqual(Lrc.activeIndex(lines, positionMs: 3_600_000), 2)
        XCTAssertEqual(Lrc.activeIndex([], positionMs: 1000), -1)
        XCTAssertNil(Lrc.parse("just text").first)
    }
}

final class ISODateTests: XCTestCase {
    func testParsesServerTimestamps() {
        XCTAssertEqual(ISODate.parseMs("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(ISODate.parseMs("2026-12-12T12:00:00+00:00"), 1_797_076_800_000)
        XCTAssertEqual(ISODate.parseMs("2026-12-12T12:00:00.123456+00:00"), 1_797_076_800_123)
        // тот же момент в другом поясе
        XCTAssertEqual(ISODate.parseMs("2026-12-12T15:00:00+03:00"), 1_797_076_800_000)
        XCTAssertEqual(ISODate.parseMs("2026-12-12T09:00:00-03:00"), 1_797_076_800_000)
        XCTAssertNil(ISODate.parseMs("вчера"))
        XCTAssertNil(ISODate.parseMs("2026-13-12T12:00:00Z"))
    }
}
