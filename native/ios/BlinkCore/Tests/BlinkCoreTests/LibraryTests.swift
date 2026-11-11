import XCTest
@testable import BlinkCore

final class LibraryTests: XCTestCase {
    private let base = "http://api.test"
    private var http: RouteHTTP!

    override func setUp() {
        super.setUp()
        http = RouteHTTP()
    }

    private func t(_ id: String) -> Track { return Track(id: id, title: "T \(id)", artist: "A") }

    private let remote = """
    [{"data":{"likes":[{"id":"cr2","title":"Remote","artist":"R","artistRef":"abc"},{"id":"cr1","title":"Dup","artist":"D"}],"recent":[{"id":"cr9","title":"Rec","artist":"X"}],"playlists":[{"id":"p1","name":"Дорога","tracks":[]}],"nowPlaying":{"time":3},"device":"web"}}]
    """

    func testLikesGoToTheTopCanBeRemovedAndSurviveARestart() {
        let blob = MemBlob()
        let lib = LibraryStore(blob)
        XCTAssertTrue(lib.toggleLike(t("cr1")))
        XCTAssertTrue(lib.toggleLike(t("cr2")))
        XCTAssertEqual(lib.likes.map { $0.id }, ["cr2", "cr1"])
        XCTAssertTrue(lib.isLiked("cr1"))
        XCTAssertFalse(lib.toggleLike(t("cr1")))
        XCTAssertEqual(LibraryStore(blob).likes.map { $0.id }, ["cr2"])
    }

    func testRecentKeepsTheNewestFirstWithoutDuplicatesAndAtMost60() {
        let lib = LibraryStore(MemBlob())
        for i in 1...70 { lib.noteRecent(t("cr\(i)")) }
        lib.noteRecent(t("cr50"))
        XCTAssertEqual(lib.recent.count, 60)
        XCTAssertEqual(lib.recent.first?.id, "cr50")
        XCTAssertEqual(lib.recent.filter { $0.id == "cr50" }.count, 1)
    }

    func testMergeKeepsLocalFirstDropsDuplicatesAndKeepsUnknownFields() throws {
        let lib = LibraryStore(MemBlob())
        lib.toggleLike(t("cr1"))
        let rows = try JSONDecoder().decode([JSONValue].self, from: Data(remote.utf8))
        guard case let .object(d)? = rows[0].objectValue?["data"] else { return XCTFail("нет data") }
        lib.mergeRemote(d)
        XCTAssertEqual(lib.likes.map { $0.id }, ["cr1", "cr2"])
        let snap = lib.snapshot(device: "dev")
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(snap)), as: UTF8.self)
        XCTAssertTrue(text.contains("artistRef"), "поле сайта не потеряно")
        XCTAssertNotNil(snap["playlists"])
        XCTAssertNotNil(snap["nowPlaying"])
        XCTAssertEqual(snap["device"], .string("dev"))
    }

    func testPullMergesTheServerCopyAndPushesTheResultOnce() async throws {
        let lib = LibraryStore(MemBlob())
        lib.toggleLike(t("cr1"))
        let reply = remote
        http.route("/rest/v1/library") { req in req.method == "GET" ? jsonReply(200, reply) : jsonReply(201, "") }
        let cfg = BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "anon")
        let sync = LibrarySync(http: http, config: cfg, tokens: FixedToken(value: "tok"), library: lib, userId: { "u1" }, device: "dev")
        let pulled = await sync.pull()
        XCTAssertTrue(pulled)
        let seen = http.requests("/rest/v1/library")
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(queryValue(seen[0], "user_id"), "eq.u1")
        XCTAssertEqual(seen[0].headers["Authorization"], "Bearer tok")
        XCTAssertEqual(seen[1].method, "POST")
        XCTAssertTrue((seen[1].headers["Prefer"] ?? "").contains("merge-duplicates"))
        let body = String(decoding: seen[1].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"user_id\":\"u1\"") && body.contains("playlists") && body.contains("cr2") && body.contains("artistRef"), body)
        let again = await sync.push()
        XCTAssertTrue(again)
        XCTAssertEqual(http.requests("/rest/v1/library").count, 2, "ничего не изменилось: повторно не пишем")
        lib.toggleLike(t("cr3"))
        let third = await sync.push()
        XCTAssertTrue(third)
        XCTAssertEqual(http.requests("/rest/v1/library").count, 3)
    }

    func testSignedOutMeansNothingIsSent() async {
        let lib = LibraryStore(MemBlob())
        let cfg = BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "anon")
        let sync = LibrarySync(http: http, config: cfg, tokens: FixedToken(value: nil), library: lib, userId: { nil })
        let pulled = await sync.pull()
        let pushed = await sync.push()
        XCTAssertFalse(pulled)
        XCTAssertFalse(pushed)
        XCTAssertEqual(http.seen.count, 0)
    }
}

final class WaveApiTests: XCTestCase {
    private let base = "http://api.test"
    private var http: RouteHTTP!

    override func setUp() {
        super.setUp()
        http = RouteHTTP()
        http.route("/api/wave/pool") { _ in jsonReply(200, """
        {"tracks":[{"id":"cr5","source":"chart","title":"Song","artist":"A, B","artwork":"https://x/600x600","duration":187,"explicit":false,"year":"2024","genre":"rap","released":"2024-05-10T00:00:00+03:00","src":"similar","seed":"S","hits":2},{"title":"no id"}],"seedGenre":[{"q":"Art Seed","genre":"rap","id":"cr9"}]}
        """) }
        http.route("/api/wave/genres") { _ in jsonReply(200, "{\"genres\":{\"cr1\":\"rap\",\"Artist Title\":\"\"}}") }
        http.route("/api/wave/similar-ids") { _ in jsonReply(200, "{\"ids\":[\"cr1\",\"cr2\"],\"genre\":\"rap\",\"id\":\"cr7\"}") }
        http.route("/api/charts/top") { _ in jsonReply(200, """
        {"items":[{"id":153919218,"chart":{"position":1},"track":{"id":"153919218","title":"ДИНАСТИЯ","contentWarning":"explicit","durationMs":150420,"artists":[{"name":"VILLIAN"},{"name":"madk1d"}],"albums":[{"title":"Красивое Зло","year":2026,"releaseDate":"2026-07-24T00:00:00+03:00","coverUri":"x","genre":"rusrap"}],"coverUri":"avatars.yandex.net/get-music-content/1/abc/%%"}},{"track":{"id":"1","title":"no artists","artists":[]}}]}
        """) }
        http.route("/api/charts/weekly") { _ in jsonReply(200, """
        {"items":[{"id":"wVIq7","rank":1,"trackNameStr":"милый ублюдок","artistNameStr":"Егор Крид","artistNames":["Егор Крид"],"coverUrl":"https://music-bandlink.s3.yandex.net/img/x_1120_1120.jpeg"},{"id":"zz","trackNameStr":"Joined","artistNames":["A","B"]}]}
        """) }
    }

    private func api() -> WaveApi { return WaveApi(http: http, config: BlinkConfig(baseURL: base, supabaseURL: base)) }

    func testPoolParsesCandidatesAndSeedGenresAndSendsSeedsJoinedByABar() async throws {
        let r = try await api().pool(seeds: ["Art Seed", "Other One"])
        let req = try XCTUnwrap(http.seen.first)
        XCTAssertEqual(queryValue(req, "seeds"), "Art Seed|Other One")
        XCTAssertEqual(queryValue(req, "n"), "2")
        XCTAssertEqual(r.tracks.count, 1)
        let c = r.tracks[0]
        XCTAssertEqual(c.track.id, "cr5")
        XCTAssertEqual(c.src, "similar")
        XCTAssertEqual(c.hits, 2)
        XCTAssertEqual(c.track.released, "2024-05-10T00:00:00+03:00")
        XCTAssertEqual(r.seedGenre, [SeedGenre(query: "Art Seed", genre: "rap", id: "cr9")])
    }

    func testGenresAndSimilarIds() async throws {
        let g = try await api().genres(items: ["cr1", "Artist Title"])
        XCTAssertEqual(g, ["cr1": "rap", "Artist Title": ""])
        let s = try await api().similarIds(seed: "cr7")
        XCTAssertEqual(s, SimilarResult(ids: ["cr1", "cr2"], genre: "rap"))
    }

    func testMainChartMapsLikeTheWebsiteWithTheReleaseDate() async throws {
        let list = try await api().topChart()
        XCTAssertEqual(list.count, 1)
        let top = list[0]
        XCTAssertEqual(top.id, "cr153919218")
        XCTAssertEqual(top.artist, "VILLIAN, madk1d")
        XCTAssertEqual(top.artwork, "https://avatars.yandex.net/get-music-content/1/abc/600x600")
        XCTAssertEqual(top.duration, 150)
        XCTAssertTrue(top.explicit)
        XCTAssertEqual(top.genre, "rusrap")
        XCTAssertEqual(top.year, "2026")
        XCTAssertEqual(top.released, "2026-07-24T00:00:00+03:00")
    }

    func testPeriodChartMapsCpTracks() async throws {
        let list = try await api().periodChart(kind: "weekly")
        XCTAssertEqual(list.map { $0.id }, ["cpwVIq7", "cpzz"])
        XCTAssertEqual(list[0].artist, "Егор Крид")
        XCTAssertEqual(list[1].artist, "A, B")
        XCTAssertEqual(list[0].artwork, "https://music-bandlink.s3.yandex.net/img/x_1120_1120.jpeg")
    }
}
