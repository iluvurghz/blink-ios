import XCTest
@testable import BlinkCore

private func config() -> BlinkConfig {
    let base = "http://127.0.0.1:9"
    return BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: "anon")
}

private struct FakeUploader: UploadClient {
    let seen: Log<String>
    func upload(_ request: HTTPRequest, bodyFile: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse {
        let body = (try? Data(contentsOf: bodyFile)) ?? Data()
        seen.add(String(decoding: body, as: UTF8.self))
        onProgress(0.5)
        return jsonReply(200, #"{"track":{"id":"new1"}}"#)
    }
}

final class PostsApiTests: XCTestCase {
    func testFeedCommentsAndErrors() async throws {
        let http = RouteHTTP()
        http.route("/sb/rest/v1/rpc/post_list") { _ in jsonReply(200, #"[{"id":"p1","artist_id":"a1","artist_name":"Ник","avatar_url":null,"body":"Новый трек","track_id":"11111111-2222-3333-4444-555555555555","created_at":"2026-11-01T10:00:00Z","likes":"3","liked":true}]"#) }
        http.route("/sb/rest/v1/lic_tracks") { _ in jsonReply(200, #"[{"id":"11111111-2222-3333-4444-555555555555","title":"Песня","artist_name":"Ник","duration":180,"cover_path":"c"}]"#) }
        http.route("/sb/rest/v1/rpc/comment_list") { _ in jsonReply(200, #"[{"id":"c1","user_id":"u2","artist_id":null,"name":"Аня","avatar":null,"body":"Огонь","created_at":"2026-11-01T11:00:00Z"}]"#) }
        http.route("/sb/rest/v1/posts") { _ in jsonReply(400, #"{"message":"too_often"}"#) }
        http.route("/sb/rest/v1/comments") { _ in jsonReply(201, "") }
        http.route("/sb/rest/v1/post_likes") { _ in jsonReply(409, "") }
        http.route("/sb/rest/v1/reports") { _ in jsonReply(409, "") }
        http.route("/sb/rest/v1/artists") { _ in jsonReply(204, "") }
        let cfg = config()
        let api = PostsApi(http: http, config: cfg, tokens: nil, api: BlinkApi(http: http, config: cfg), userId: { "u1" })
        let list = try await api.posts(artistId: "a1")
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].likes, 3)
        XCTAssertTrue(list[0].liked)
        XCTAssertEqual(list[0].track?.title, "Песня")
        let c = try await api.comments(postId: "p1")
        XCTAssertEqual(c.first?.name, "Аня")
        do {
            try await api.createPost(artistId: "a1", text: "x", trackId: nil)
            XCTFail("лимит должен падать")
        } catch let e as SharedError {
            XCTAssertEqual(e.message, "Анонс можно публиковать раз в 10 минут")
        }
        try await api.addComment("  Класс  ", postId: "p1")
        let sent = http.requests("/sb/rest/v1/comments").first?.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertTrue(sent.contains("Класс"))
        do {
            try await api.addComment("   ", postId: "p1")
            XCTFail("пустой комментарий должен падать")
        } catch is SharedError {}
        let liked = await api.setPostLike("p1", true)
        XCTAssertTrue(liked, "повтор лайка не ошибка")
        try await api.report("post", "p1")
        try await api.saveBio(artistId: "a1", bio: "  Привет ")
        XCTAssertEqual(http.requests("/sb/rest/v1/artists").first?.method, "PATCH")
        XCTAssertEqual(dateRu("2026-11-01T10:00:00Z"), "01.11.2026")
    }
}

final class SupportApiTests: XCTestCase {
    func testFaqTicketAndErrors() async throws {
        let http = RouteHTTP()
        http.route("/api/support/faq") { _ in jsonReply(200, #"{"faq":[{"id":"1","question":"Как скачать?","answer":"Нужен Blink+","keywords":"скачать, офлайн"},{"id":"2","question":"Пароль","answer":"Сбросьте","keywords":"пароль"}]}"#) }
        http.route("/api/support/ticket") { _ in jsonReply(200, #"{"id":"t1","auto":{"question":"Как скачать?","answer":"Нужен Blink+"}}"#) }
        http.route("/api/support/mine") { _ in jsonReply(200, #"{"tickets":[{"id":"t1","kind":"question","message":"Привет","status":"answered","last_author":"team","updated_at":"2026-11-01"}]}"#) }
        http.route("/api/support/ticket/t1") { _ in jsonReply(200, #"{"ticket":{"id":"t1","kind":"question","message":"Привет","status":"open","attachments":["https://x/a.jpg"]},"auto":null,"messages":[{"id":"m1","author":"team","body":"Здравствуйте","attachments":[],"created_at":"2026-11-01"}]}"#) }
        http.route("/api/support/ticket/t1/message") { _ in jsonReply(200, #"{"message":{"id":"m2","author":"user","body":"Спасибо","attachments":[],"created_at":"2026-11-02"}}"#) }
        http.route("/api/support/ticket/t2") { _ in jsonReply(404, #"{"error":"Обращение не найдено"}"#) }
        let api = SupportApi(http: http, config: config(), tokens: nil)
        let faq = try await api.faq()
        XCTAssertEqual(SupportApi.bestAnswer(faq, "Как СКАЧАТЬ треки офлайн")?.id, "1")
        XCTAssertNil(SupportApi.bestAnswer(faq, "ничего"))
        let sent = try await api.send(message: "Привет", contact: "a@b.c")
        XCTAssertEqual(sent.id, "t1")
        XCTAssertEqual(sent.autoAnswer, "Нужен Blink+")
        let mine = try await api.mine()
        XCTAssertEqual(mine.first?.status, "answered")
        let t = try await api.open("t1")
        XCTAssertEqual(t.images, ["https://x/a.jpg"])
        XCTAssertEqual(t.messages.first?.author, "team")
        let m = try await api.reply("t1", "Спасибо")
        XCTAssertEqual(m.body, "Спасибо")
        do {
            _ = try await api.open("t2")
            XCTFail("нет такого обращения")
        } catch let e as SharedError {
            XCTAssertEqual(e.message, "Обращение не найдено")
        }
    }
}

final class CabinetAndLastfmTests: XCTestCase {
    func testCabinetUploadAndChecks() async throws {
        let http = RouteHTTP()
        http.route("/api/artist/me") { _ in jsonReply(200, #"{"artist":{"id":"a1","name":"Ник","handle":"nick","bio":null,"offer_accepted_at":"2026-11-01"}}"#) }
        http.route("/api/tracks/mine") { _ in jsonReply(200, #"{"tracks":[{"id":"t1","title":"Песня","release_title":"EP","status":"live","release_date":"2026-11-01","explicit":false,"cover_url":"https://x/c.jpg","streams":{"total":10,"this_month":4}}]}"#) }
        http.route("/api/tracks/t1") { _ in jsonReply(200, #"{"ok":true}"#) }
        let seen = Log<String>()
        let api = CabinetApi(http: http, uploader: FakeUploader(seen: seen), config: config(), tokens: nil)
        let me = try await api.me()
        XCTAssertEqual(me?.offerAccepted, true)
        let mine = try await api.mine()
        XCTAssertEqual(mine.first?.streamsMonth, 4)
        let dir = tempDir()
        let audio = dir.appendingPathComponent("a.mp3")
        let cover = dir.appendingPathComponent("c.jpg")
        try Data(repeating: 1, count: 5000).write(to: audio)
        try Data(repeating: 2, count: 800).write(to: cover)
        let af = UploadFile(name: "a.mp3", mime: "audio/mpeg", url: audio)
        let cf = UploadFile(name: "c.jpg", mime: "image/jpeg", url: cover)
        var d = UploadDraft()
        d.title = "Песня"; d.releaseTitle = "EP"; d.authors = "Ник, Аня"; d.phonogramMaker = "Ник"
        d.year = "2026"; d.genre = "Поп"; d.language = "Русский"; d.releaseDate = "2026-11-12"; d.rights = true
        var noRights = d
        noRights.rights = false
        XCTAssertEqual(api.check(noRights, audio: af, cover: cf), "Подтвердите права на трек")
        var noAuthors = d
        noAuthors.authors = " , "
        XCTAssertEqual(api.check(noAuthors, audio: af, cover: cf), "Укажите авторов музыки и текста")
        var noGenre = d
        noGenre.genre = ""
        XCTAssertEqual(api.check(noGenre, audio: af, cover: cf), "Не заполнено поле «Жанр»")
        XCTAssertEqual(api.check(d, audio: af, cover: nil), "Прикрепите обложку")
        let marks = Log<Double>()
        let id = try await api.upload(d, audio: af, cover: cf) { marks.add($0) }
        XCTAssertEqual(id, "new1")
        XCTAssertEqual(marks.last, 1)
        let body = seen.last ?? ""
        XCTAssertTrue(body.contains("name=\"authors\"") && body.contains("музыка и текст"))
        XCTAssertTrue(body.contains("name=\"audio\"; filename=\"a.mp3\""))
        XCTAssertTrue(body.contains("name=\"rights\"\r\n\r\ntrue"))
        try await api.takedown("t1")
    }

    func testLastfm() async {
        let http = RouteHTTP()
        http.route("/api/lastfm") { req in
            let q = req.url.query ?? ""
            if q.contains("method=artist.getinfo") && q.contains("artist=Kahoma") { return jsonReply(200, #"{"artist":{"name":"Kaoma","stats":{"listeners":"99"}}}"#) }
            if q.contains("method=artist.getinfo") { return jsonReply(200, #"{"artist":{"name":"Ник","stats":{"listeners":"12345"}}}"#) }
            if q.contains("method=artist.getsimilar") { return jsonReply(200, #"{"similarartists":{"artist":[{"name":"Аня","match":"0.8"},{"name":"Слабый","match":"0.1"},{"name":"Ник и друзья","match":"0.9"}]}}"#) }
            if q.contains("method=track.getsimilar") { return jsonReply(200, #"{"similartracks":{"track":[{"name":"Песня 2","artist":{"name":"Аня"}}]}}"#) }
            return jsonReply(503, #"{"error":"lastfm_off"}"#)
        }
        let api = LastfmApi(http: http, config: config())
        let l1 = await api.listeners("Ник feat. Аня")
        XCTAssertEqual(l1, 12345)
        let l2 = await api.listeners("Kahoma")
        XCTAssertNil(l2, "тёзка вместо артиста не показывается")
        let sa = await api.similarArtists("Ник")
        XCTAssertEqual(sa.map { $0.name }, ["Аня"])
        let st = await api.similarTracks(artist: "Ник", title: "Трек (feat. X)")
        XCTAssertEqual(st.first?.title, "Песня 2")
        XCTAssertFalse(http.requests("/api/lastfm").contains { ($0.url.query ?? "").contains("track.getsimilar") && ($0.url.query ?? "").lowercased().contains("feat") })
        XCTAssertEqual(LastfmApi.mainName("Ник & Аня"), "Ник")
        _ = await api.listeners("Ник feat. Аня")
        XCTAssertEqual(http.requests("/api/lastfm").filter { ($0.url.query ?? "").contains("getinfo") && !($0.url.query ?? "").contains("Kahoma") }.count, 1, "второй раз из кеша")
    }
}
