import XCTest
@testable import BlinkCore

private struct Tok: TokenProvider {
    func accessToken() async -> String? { return "tok" }
}

private func query(_ r: HTTPRequest, _ name: String) -> String? {
    return URLComponents(url: r.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class LyricsTests: XCTestCase {
    func testKaraokeGapsAndWords() {
        let rows = Karaoke.build([LyricLine(t: 10, text: "Hello world"), LyricLine(t: 14, text: ""), LyricLine(t: 20, text: "Again")])
        XCTAssertEqual(rows.map { $0.gap }, [true, false, true, false])
        XCTAssertEqual(rows[1].end, 14)
        let segs = rows[1].segs
        XCTAssertEqual(segs.map { $0.text }, ["Hello", " ", "world"])
        XCTAssertEqual(segs[0].end!, 11.5, accuracy: 1e-9)
        XCTAssertEqual(segs[2].t, segs[0].end)
        XCTAssertEqual(Karaoke.active(rows, at: 10.5), 1)
        XCTAssertEqual(Karaoke.countdown(rows, active: 2, at: 17.5), 3)
        XCTAssertEqual(Karaoke.countdown(rows, active: 2, at: 15), 0)
        XCTAssertEqual(segs[0].progress(at: 10.75), 0.5, accuracy: 1e-9)
        let brk = Karaoke.build([LyricLine(t: 0.5, end: 2, text: "One"), LyricLine(t: 9, text: "Two")])
        XCTAssertEqual(brk.map { $0.gap }, [false, true, false])
    }

    func testTtml() {
        let xml = """
        <tt><body><div>
        <p begin="00:01.500" end="00:04.000"><span begin="1.5s" end="2s">Hey</span><span begin="2s" end="3s">you&amp;me</span></p>
        <p begin="1:00:00.0">Second <br/> line</p>
        <p begin="bad">skip</p>
        </div></body></tt>
        """
        let lines = Ttml.parse(xml)!
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].t, 1.5)
        XCTAssertEqual(lines[0].text, "Heyyou&me")
        XCTAssertEqual(lines[0].words!.map { $0.from! }, [0, 3])
        XCTAssertEqual(lines[1].t, 3600)
        XCTAssertEqual(lines[1].text, "Second line")
        XCTAssertEqual(Karaoke.words(lines[0]).map { $0.text }, ["Hey", "you&me"])
        XCTAssertEqual(Ttml.seconds("250ms")!, 0.25, accuracy: 1e-9)
        XCTAssertNil(Ttml.parse("<tt></tt>"))
    }

    func testHelpers() {
        XCTAssertEqual(LyricsApi.cleanTitle("Song (feat. X)"), "Song")
        XCTAssertEqual(LyricsApi.mainArtist("A, B & C"), "A")
        XCTAssertEqual(LyricsApi.norm("Hello (Live) World!"), "hello world")
        XCTAssertEqual(LyricsApi.guessLang(["Привет мир"]), "ru")
        XCTAssertTrue(LyricsData.plain(["Ёлка"]).isRussian)
    }

    func testBlinkAndLrclib() async throws {
        let http = RouteHTTP()
        http.route("/api/tracks/L1/ttml") { _ in HTTPResponse(status: 200, headers: [:], data: Data("<tt><p begin=\"1s\">Мой текст</p></tt>".utf8)) }
        http.route("/api/lrclib/get") { r in
            switch query(r, "track_name") {
            case "Synced": return jsonReply(200, #"{"syncedLyrics":"[00:01.00]one\n[00:03.00]two"}"#)
            case "Down": return jsonReply(502, "{}")
            default: return jsonReply(404, "{}")
            }
        }
        http.route("/api/lrclib/search") { _ in jsonReply(200, #"[{"trackName":"Other","syncedLyrics":"[00:01.00]bad","duration":500},{"trackName":"Found","syncedLyrics":"[00:02.00]good","duration":200}]"#) }
        let api = LyricsApi(http: http, config: BlinkConfig(baseURL: "http://api.test"), tokens: Tok())
        let own = try await api.load(Track(id: "b:L1", title: "П", artist: "Н", source: Track.sourceBlink, lic: "L1"))
        guard case .synced(let l)? = own else { return XCTFail("нет текста") }
        XCTAssertEqual(l[0].text, "Мой текст")
        XCTAssertEqual(http.requests("/api/tracks/L1/ttml").first?.headers["Authorization"], "Bearer tok")

        let a = try await api.load(Track(id: "1", title: "Synced (feat. Z)", artist: "Ann, Bob", album: "Alb", duration: 180))
        guard case .synced(let al)? = a else { return XCTFail("нет текста") }
        XCTAssertEqual(al.map { $0.text }, ["one", "two"])
        let q = http.requests("/api/lrclib/get").first!
        XCTAssertEqual(query(q, "artist_name"), "Ann")
        XCTAssertEqual(query(q, "duration"), "180")

        let b = try await api.load(Track(id: "2", title: "Found", artist: "Ann", duration: 200))
        guard case .synced(let bl)? = b else { return XCTFail("нет текста") }
        XCTAssertEqual(bl[0].text, "good")

        do {
            _ = try await api.load(Track(id: "4", title: "Down", artist: "Ann"))
            XCTFail("ждали ошибку")
        } catch is LyricsUnavailable {}
        XCTAssertNil(api.cached("4"))
    }

    func testPalette() {
        let red = [UInt8](repeating: 0, count: 24 * 24 * 4).enumerated().map { i, _ -> UInt8 in [0xCC, 0x20, 0x20, 0xFF][i % 4] }
        let p = Palette.from(rgba: red)
        XCTAssertEqual(p.accent.h, 0, accuracy: 0.5)
        XCTAssertEqual(p.accent.s, 0.95, accuracy: 1e-9)
        let gray = Palette.from(rgba: [UInt8](repeating: 0x80, count: 24 * 24 * 4))
        XCTAssertEqual(gray.accent, Hsl(36, 0.2, 0.82))
        XCTAssertEqual(Palette.from(rgba: []), Palette.fallback)
        let c = Hsl(0, 1, 0.5).rgb
        XCTAssertEqual(c.r, 1, accuracy: 1e-9)
        XCTAssertEqual(c.g, 0, accuracy: 1e-9)
        XCTAssertEqual(ArtUrl.scaled("https://a/x/600x600bb.jpg", 100), "https://a/x/100x100bb.jpg")
        XCTAssertEqual(ArtUrl.scaled("https://i1.sndcdn.com/a-large.jpg", 100), "https://i1.sndcdn.com/a-t300x300.jpg")
    }

    func testLineIconsParseWithArcs() {
        for icon in LineIcon.allCases {
            for part in icon.parts {
                let ops = SvgPath.parse(part.d)
                XCTAssertFalse(ops.isEmpty, "\(icon)")
                if part.d.contains("Z") { XCTAssertEqual(ops.last, .close, "\(icon)") }
            }
        }
        // полукруг радиуса 2 от (0,0) до (4,0): две четверти, середина внизу (sweep 0 из (0,0) идёт через y>0? проверяем концы)
        let ops = SvgPath.parse("M0 0a2 2 0 1 0 4 0")
        XCTAssertEqual(ops.count, 3)
        if case .curve(_, _, _, _, let x, let y) = ops.last! {
            XCTAssertEqual(x, 4, accuracy: 1e-9)
            XCTAssertEqual(y, 0, accuracy: 1e-9)
        } else {
            XCTFail("ждали кривую")
        }
    }
}
