import XCTest
@testable import BlinkCore

final class ImporterTests: XCTestCase {
    func testParsesCsvAndPlainLines() {
        let csv = "Track name,Artist name,Album\n\"Kosandra\",\"Miyagi & Andy Panda\",x\nSolo,Band,y"
        XCTAssertEqual(Importer.parseList(csv), [TrackRef(artist: "Miyagi & Andy Panda", title: "Kosandra"), TrackRef(artist: "Band", title: "Solo")])
        XCTAssertEqual(Importer.parseList("Артист — Название - часть 2\nБез артиста"), [TrackRef(artist: "Артист", title: "Название - часть 2"), TrackRef(artist: "", title: "Без артиста")])
        XCTAssertTrue(Importer.parseList("  \n ").isEmpty)
    }

    func testRecognizesLinksAndPicksTheBestMatch() {
        XCTAssertEqual(Importer.sourceOf("смотри https://open.spotify.com/playlist/37i9dQZF1DX"), .spotify)
        XCTAssertEqual(Importer.sourceOf("https://music.yandex.ru/users/ivan/playlists/1003"), .yandex)
        XCTAssertNil(Importer.sourceOf("Артист — Название"))
        let tracks = [Track(id: "1", title: "Other", artist: "Miyagi"), Track(id: "2", title: "Kosandra (Remix)", artist: "Miyagi, Andy Panda")]
        XCTAssertEqual(Importer.pick(TrackRef(artist: "Miyagi & Andy Panda", title: "Kosandra"), tracks)?.id, "2")
        XCTAssertEqual(Importer.pick(TrackRef(artist: "Miyagi", title: "Нет такого"), tracks)?.id, "1")
        XCTAssertNil(Importer.pick(TrackRef(artist: "Никто", title: "Ничто"), tracks))
    }

    func testRunsAnImportAndReportsMisses() async throws {
        let http = RouteHTTP()
        let base = "http://127.0.0.1:9"
        let config = BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "")
        http.route("/api/spotify/list") { _ in jsonReply(200, #"{"name":"Мой микс","items":[{"artist":"Band","title":"Solo"},{"artist":"Ghost","title":"Nothing"}]}"#) }
        http.route("/api/itunes/search") { req in
            (req.url.query ?? "").contains("Band")
                ? jsonReply(200, #"{"results":[{"kind":"song","trackId":7,"trackName":"Solo","artistName":"Band"}]}"#)
                : jsonReply(200, #"{"results":[]}"#)
        }
        http.route("/api/yandex/search") { _ in jsonReply(200, #"{"results":[]}"#) }
        let imp = Importer(http: http, config: config, api: BlinkApi(http: http, config: config))
        let r = try await imp.run("https://open.spotify.com/playlist/abc123")
        XCTAssertEqual(r.title, "Мой микс")
        XCTAssertEqual(r.total, 2)
        XCTAssertEqual(r.found.map { $0.id }, ["7"])
        XCTAssertEqual(r.missed, [TrackRef(artist: "Ghost", title: "Nothing")])
        let lib = LibraryStore(MemBlob())
        XCTAssertEqual(lib.addLikes(r.found), 1)
        XCTAssertEqual(lib.addLikes(r.found), 0)
        do {
            _ = try await imp.run("   ")
            XCTFail("пустой текст должен падать")
        } catch let e as ImportError {
            XCTAssertEqual(e.message, "Не нашёл треков в тексте")
        }
    }
}
