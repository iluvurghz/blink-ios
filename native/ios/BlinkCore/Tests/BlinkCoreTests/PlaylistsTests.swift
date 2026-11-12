import XCTest
@testable import BlinkCore

private func tr(_ id: String) -> Track {
    return Track(id: id, title: "T" + id, artist: "A")
}

final class PlaylistsTests: XCTestCase {
    func testCreateAddRemoveRenameDelete() {
        let lib = LibraryStore(MemBlob())
        let p = lib.createPlaylist("  Дорога ", now: 1000)
        XCTAssertEqual(p.name, "Дорога")
        XCTAssertEqual(p.id, "p" + String(1000, radix: 36))
        XCTAssertTrue(lib.addToPlaylist(p.id, tr("1")))
        XCTAssertFalse(lib.addToPlaylist(p.id, tr("1")), "дубль не добавляется")
        XCTAssertTrue(lib.addToPlaylist(p.id, tr("2")))
        XCTAssertEqual(lib.playlist(p.id)?.tracks.map { $0.id }, ["1", "2"])
        lib.removeFromPlaylist(p.id, "1")
        XCTAssertEqual(lib.playlist(p.id)?.tracks.map { $0.id }, ["2"])
        lib.renamePlaylist(p.id, "Ночь")
        XCTAssertEqual(lib.playlist(p.id)?.name, "Ночь")
        lib.renamePlaylist(p.id, "   ")
        XCTAssertEqual(lib.playlist(p.id)?.name, "Ночь")
        lib.deletePlaylist(p.id)
        XCTAssertTrue(lib.playlists.isEmpty)
        XCTAssertEqual(lib.createPlaylist("", now: 5).name, "Новый плейлист")
    }

    func testSurvivesRestart() {
        let blob = MemBlob()
        let lib = LibraryStore(blob)
        lib.createPlaylist("A", tracks: [tr("1")], now: 10)
        let again = LibraryStore(blob)
        XCTAssertEqual(again.playlists.map { $0.name }, ["A"])
        XCTAssertEqual(again.playlists.first?.tracks.first?.id, "1")
    }

    func testMergeKeepsBothSidesAndLocalWins() {
        let lib = LibraryStore(MemBlob())
        let mine = lib.createPlaylist("Моё", tracks: [tr("1")], now: 2000)
        func pl(_ id: String, _ name: String, _ created: Double, _ ids: [String]) -> JSONValue {
            return .object([
                "id": .string(id), "name": .string(name), "created": .number(created),
                "tracks": .array(ids.map { JSONValue.object(["id": .string($0), "title": .string("T" + $0), "artist": .string("A")]) }),
            ])
        }
        lib.mergeRemote(["playlists": .array([pl(mine.id, "Старое имя", 2000, ["9", "1"]), pl("pz", "С сайта", 3000, ["5"])])])
        let list = lib.playlists
        XCTAssertEqual(list.map { $0.id }, ["pz", mine.id], "новые первыми")
        let m = list.first { $0.id == mine.id }
        XCTAssertEqual(m?.name, "Моё")
        XCTAssertEqual(m?.tracks.map { $0.id }, ["1", "9"])
    }

    func testDeepLinks() {
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/r/abc123"), .room("abc123"))
        XCTAssertEqual(DeepLink.parse("blink://together?together=abc123"), .room("abc123"))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/?friend=fr1x"), .friend("fr1x"))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/p/k3j4h5"), .playlist("k3j4h5"))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/?playlist=k3j4h5"), .playlist("k3j4h5"))
        XCTAssertEqual(DeepLink.parse("https://www.blinkmusic.cc/u/Nick.X"), .artist("nick.x"))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/t/Xk3p9aQ"), .track(ref: "Xk3p9aQ", title: "", artist: ""))
        XCTAssertEqual(DeepLink.parse("https://t.blinkmusic.cc/Xk3p9aQ"), .track(ref: "Xk3p9aQ", title: "", artist: ""))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/t/b%3A11111111-2222-3333-4444-555555555555"), .track(ref: "b:11111111-2222-3333-4444-555555555555", title: "", artist: ""))
        XCTAssertEqual(DeepLink.parse("https://blinkmusic.cc/t/yt1?n=%D0%9F%D0%B5%D1%81%D0%BD%D1%8F&a=%D0%90%D1%80%D1%82%D0%B8%D1%81%D1%82"), .track(ref: "yt1", title: "Песня", artist: "Артист"))
        XCTAssertNil(DeepLink.parse("https://example.com/p/abc"))
        XCTAssertNil(DeepLink.parse(nil))
    }

    func testSharedApi() async throws {
        let http = RouteHTTP()
        let base = "http://127.0.0.1:9"
        let config = BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "anon")
        http.route("/sb/rest/v1/shared_playlists") { req in
            let q = req.url.query ?? ""
            if req.method == "GET", q.contains("code=eq.abc") {
                return jsonReply(200, #"[{"code":"abc","owner_name":"Аня","data":{"name":"Лето","tracks":[{"id":"1","title":"x","artist":"y"},{"broken":true}]}}]"#)
            }
            if req.method == "GET" { return jsonReply(200, "[]") }
            return jsonReply(201, "")
        }
        http.route("/api/share/track") { _ in jsonReply(200, #"{"code":"Xk3p9aQ","url":"x"}"#) }
        http.route("/api/share/track/Xk3p9aQ") { _ in jsonReply(200, #"{"id":"b:11111111-2222-3333-4444-555555555555","title":"Т","artist":"Я","artwork":"https://blinkmusic.cc/c.jpg"}"#) }
        let api = SharedApi(http: http, config: config, tokens: FixedToken(value: "tok"), userId: { "u1" }, userName: { "Я" })
        let s = try await api.fetchShared("abc")
        XCTAssertEqual(s?.name, "Лето")
        XCTAssertEqual(s?.owner, "Аня")
        XCTAssertEqual(s?.tracks.map { $0.id }, ["1"])
        let none = try await api.fetchShared("nope")
        XCTAssertNil(none)
        let link = try await api.share(Playlist(id: "p1", name: "N", created: 1, tracks: [tr("1")]), code: { "zzz" })
        XCTAssertEqual(link, "https://blinkmusic.cc/p/zzz")
        let post = http.seen.first { $0.method == "POST" }
        XCTAssertTrue(String(decoding: post?.body ?? Data(), as: UTF8.self).contains("\"owner_id\":\"u1\""))
        let short = await api.trackLink(tr("yt1"))
        XCTAssertEqual(short, base + "/t/Xk3p9aQ")
        let m = await api.resolveTrack("Xk3p9aQ")
        let track = m?.toTrack()
        XCTAssertEqual(track?.lic, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(track?.source, "blink")
        XCTAssertTrue(api.longTrackLink(Track(id: "yt1", title: "Пе", artist: "А")).hasPrefix(base + "/t/yt1?n="))
        XCTAssertTrue(SharedApi.isShortCode("Xk3p9aQ"))
        XCTAssertFalse(SharedApi.isShortCode("Xk3p9a1"))
    }
}
