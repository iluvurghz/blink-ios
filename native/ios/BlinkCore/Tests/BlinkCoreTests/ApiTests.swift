import XCTest
@testable import BlinkCore

/// Короткие запросы по маршрутам: путь → обработчик. Всё, что не описано, отвечает 404.
final class RouteHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: @Sendable (HTTPRequest) throws -> HTTPResponse] = [:]
    private var log: [HTTPRequest] = []
    private var isDown = false

    func route(_ path: String, _ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        lock.lock()
        routes[path] = handler
        lock.unlock()
    }

    /// Сети нет: любой запрос падает.
    func setDown(_ down: Bool) {
        lock.lock()
        isDown = down
        lock.unlock()
    }

    var seen: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func requests(_ path: String) -> [HTTPRequest] {
        return seen.filter { $0.url.path == path }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        log.append(request)
        let handler = routes[request.url.path]
        let down = isDown
        lock.unlock()
        if down { throw TransportError.offline }
        guard let h = handler else { return jsonReply(404, "{}") }
        return try h(request)
    }
}

final class MemSessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func save(_ value: String?) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

final class ApiTests: XCTestCase {
    private let base = "http://api.test"
    private var http: RouteHTTP!

    override func setUp() {
        super.setUp()
        http = RouteHTTP()
    }

    private func config(_ key: String = "anon") -> BlinkConfig {
        return BlinkConfig(baseURL: base, supabaseURL: base, supabaseAnonKey: key)
    }

    private func api(token: String? = nil, key: String = "anon") -> BlinkApi {
        return BlinkApi(http: http, config: config(key), tokens: token.map { FixedToken(value: $0) })
    }

    private let itunes = """
    {"results":[
      {"kind":"song","trackId":111,"trackName":"Alive","artistName":"Band","artistId":5,"collectionName":"Record - Single","collectionId":7,
       "artworkUrl100":"https://is1.mzstatic.com/image/x/100x100bb.jpg","trackTimeMillis":215400,"releaseDate":"2024-05-01T07:00:00Z","trackExplicitness":"explicit","primaryGenreName":"Rock"},
      {"kind":"song","trackId":222,"trackName":"Second Song","artistName":"Band","artworkUrl100":"https://x/y/100x100bb.jpg","trackTimeMillis":180000,"releaseDate":"2023-01-01T00:00:00Z"},
      {"wrapperType":"collection","collectionName":"not a song"}]}
    """

    private let yandex = """
    {"results":[
      {"kind":"song","trackId":"y9","trackName":"alive!","artistName":"BAND","artworkUrl600":"https://avatars.yandex.net/get-music-content/1/abc/100x100","trackTimeMillis":215000},
      {"kind":"song","trackId":"y10","trackName":"Third","artistName":"Other","artworkUrl600":"https://avatars.yandex.net/get-music-content/1/def/200x200"}]}
    """

    private let lic = """
    [{"id":"11111111-2222-3333-4444-555555555555","artist_id":"a1","title":"Licensed","artist_name":"Band","release_title":"LP","duration":200,
      "explicit":false,"year":2024,"genre":"Pop","lrc":null,"lyrics":null,"cover_path":"covers/x.jpg","offline_allowed":true,"status":"live"},
     {"id":"99999999-2222-3333-4444-555555555555","title":"No offline","artist_name":"Band","cover_path":null,"offline_allowed":false,"status":"live"}]
    """

    func testSearchMergesBlinkItunesAndYandexWithoutDuplicatesAndInThatOrder() async throws {
        let (itunes, yandex, lic) = (self.itunes, self.yandex, self.lic)
        http.route("/api/itunes/search") { _ in jsonReply(200, itunes) }
        http.route("/api/yandex/search") { _ in jsonReply(200, yandex) }
        http.route("/rest/v1/lic_tracks") { _ in jsonReply(200, lic) }

        let r = try await api().search("band")
        XCTAssertEqual(r.map { $0.id }, ["b:11111111-2222-3333-4444-555555555555", "b:99999999-2222-3333-4444-555555555555", "111", "222", "y10"])

        let blink = r[0]
        XCTAssertEqual(blink.source, "blink")
        XCTAssertEqual(blink.lic, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(blink.artwork, "\(base)/covers/11111111-2222-3333-4444-555555555555.jpg")
        XCTAssertEqual(blink.offline, true)
        XCTAssertEqual(blink.year, "2024")
        XCTAssertTrue(blink.isLicensed)
        XCTAssertEqual(r[1].offline, false)
        XCTAssertEqual(r[1].artwork, "")

        let song = r[2]
        XCTAssertEqual(song.title, "Alive")
        XCTAssertEqual(song.album, "Record", "Single/EP отрезается")
        XCTAssertEqual(song.artwork, "https://is1.mzstatic.com/image/x/600x600bb.jpg")
        XCTAssertEqual(song.duration, 215)
        XCTAssertTrue(song.explicit)
        XCTAssertEqual(song.year, "2024")
        XCTAssertEqual(song.artistId, "5")
        XCTAssertEqual(song.albumId, "7")
        XCTAssertNil(song.source)
        XCTAssertEqual(r[4].artwork, "https://avatars.yandex.net/get-music-content/1/def/1000x1000")

        let lq = http.requests("/rest/v1/lic_tracks")[0]
        XCTAssertEqual(lq.headers["apikey"], "anon")
        XCTAssertEqual(lq.headers["Authorization"], "Bearer anon")
        XCTAssertEqual(queryValue(lq, "status"), "eq.live")
        XCTAssertEqual(queryValue(lq, "or"), "(title.ilike.*band*,artist_name.ilike.*band*,release_title.ilike.*band*)")
        let iq = http.requests("/api/itunes/search")[0]
        XCTAssertEqual(queryValue(iq, "term"), "band")
        XCTAssertEqual(queryValue(iq, "country"), "ru")
        XCTAssertEqual(queryValue(iq, "entity"), "song")
    }

    func testSearchSurvivesOneSourceFailingAndSanitisesTheLicensedQuery() async throws {
        let (yandex, lic) = (self.yandex, self.lic)
        http.route("/api/itunes/search") { _ in jsonReply(500, "boom") }
        http.route("/api/yandex/search") { _ in jsonReply(200, yandex) }
        http.route("/rest/v1/lic_tracks") { _ in jsonReply(401, lic) }
        let r = try await api().search("a,b(c)*%")
        XCTAssertEqual(r.map { $0.id }, ["y9", "y10"])
        let lq = http.requests("/rest/v1/lic_tracks")[0]
        XCTAssertEqual(queryValue(lq, "or"), "(title.ilike.*a b c*,artist_name.ilike.*a b c*,release_title.ilike.*a b c*)")
    }

    func testSearchWithoutAnonKeySkipsTheLicensedCatalogAndAllFailedNetworkIsAnError() async throws {
        let (itunes, yandex) = (self.itunes, self.yandex)
        http.route("/api/itunes/search") { _ in jsonReply(200, itunes) }
        http.route("/api/yandex/search") { _ in jsonReply(200, yandex) }
        let r = try await api(key: "").search("band")
        XCTAssertTrue(r.allSatisfy { $0.source != "blink" })
        XCTAssertTrue(http.requests("/rest/v1/lic_tracks").isEmpty)

        http.setDown(true)
        do {
            _ = try await api().search("band")
            XCTFail("ожидали ошибку сети")
        } catch is TransportError {
            // так и должно быть: ни один источник не ответил
        }
    }

    func testChartMapsYandexItemsToCrIdsWith600pxCovers() async throws {
        http.route("/api/charts/top") { _ in
            jsonReply(200, """
            {"items":[{"track":{"id":4242,"title":"Hit","version":"Remix","artists":[{"name":"A"},{"name":"B"}],
              "albums":[{"title":"LP","year":2024,"genre":"rap"}],"coverUri":"avatars.yandex.net/get-music-content/1/z/%%","durationMs":201400,"contentWarning":"explicit"},
              "chart":{"progress":"up"}},{"track":{"id":1,"title":"No artists","artists":[]}}]}
            """)
        }
        let list = try await api().chart()
        XCTAssertEqual(list.count, 1)
        let t = list[0]
        XCTAssertEqual(t.id, "cr4242")
        XCTAssertEqual(t.source, "chart")
        XCTAssertEqual(t.title, "Hit (Remix)")
        XCTAssertEqual(t.artist, "A, B")
        XCTAssertEqual(t.artwork, "https://avatars.yandex.net/get-music-content/1/z/600x600")
        XCTAssertEqual(t.duration, 201)
        XCTAssertTrue(t.explicit)
        XCTAssertEqual(t.year, "2024")
        XCTAssertEqual(t.genre, "rap")
    }

    // ---------- проигрывание ----------

    private let licTrack = Track(id: "b:u1", title: "T", artist: "A", source: "blink", lic: "u1", offline: true)
    private let plain = Track(id: "111", title: "Alive", artist: "Band")

    private func streamKind(_ a: BlinkApi, _ t: Track) async -> StreamException.Kind? {
        do {
            _ = try await a.streamFor(t)
            XCTFail("ожидали ошибку потока")
            return nil
        } catch let e as StreamException {
            return e.kind
        } catch {
            XCTFail("другая ошибка: \(error)")
            return nil
        }
    }

    func testLicensedTracksStreamThroughApiPlayWithBearer() async throws {
        http.route("/api/play/u1") { _ in jsonReply(200, #"{"url":"/media/u1?sig=zz"}"#) }
        let source = try await api(token: "tok").streamFor(licTrack)
        XCTAssertEqual(source.url, "\(base)/media/u1?sig=zz")
        XCTAssertEqual(http.seen.count, 1)
        XCTAssertEqual(http.seen[0].headers["Authorization"], "Bearer tok")

        let first = await streamKind(api(), licTrack)
        XCTAssertEqual(first, .needSignIn)
        http.route("/api/play/u1") { _ in jsonReply(404, "{}") }
        let second = await streamKind(api(token: "tok"), licTrack)
        XCTAssertEqual(second, .notFound)
        http.route("/api/play/u1") { _ in jsonReply(401, "{}") }
        let third = await streamKind(api(token: "tok"), licTrack)
        XCTAssertEqual(third, .needSignIn)
    }

    func testOtherTracksStreamThroughApiblinkAndRelativeLinksBecomeAbsolute() async throws {
        http.route("/api/apiblink/play") { _ in jsonReply(200, #"{"track":{"title":"Alive","streamUrl":"/api/apiblink/stream/abc","duration":215}}"#) }
        let source = try await api().streamFor(plain)
        XCTAssertEqual(source.url, "\(base)/api/apiblink/stream/abc")
        XCTAssertEqual(http.seen.count, 1)
        XCTAssertEqual(queryValue(http.seen[0], "artist"), "Band")
        XCTAssertEqual(queryValue(http.seen[0], "title"), "Alive")
        XCTAssertNil(http.seen[0].headers["Authorization"])

        http.route("/api/apiblink/play") { _ in jsonReply(503, #"{"error":{"code":"apiblink_unavailable"}}"#) }
        let a = await streamKind(api(), plain)
        XCTAssertEqual(a, .unavailable)
        http.route("/api/apiblink/play") { _ in jsonReply(404, "{}") }
        let b = await streamKind(api(), plain)
        XCTAssertEqual(b, .notFound)
        http.route("/api/apiblink/play") { _ in jsonReply(200, #"{"track":{}}"#) }
        let c = await streamKind(api(), plain)
        XCTAssertEqual(c, .notFound)
        var withStream = plain
        withStream.stream = "https://jamendo/x.mp3"
        let direct = try await api().streamFor(withStream)
        XCTAssertEqual(direct.url, "https://jamendo/x.mp3")
    }

    func testAbsoluteFixesRelativeAndLeakedLocalUrls() {
        let c = config()
        XCTAssertEqual(c.absolute("/api/x"), "\(base)/api/x")
        XCTAssertEqual(c.absolute("http://127.0.0.1:3000/api/x"), "\(base)/api/x")
        XCTAssertEqual(c.absolute("http://localhost/api/x"), "\(base)/api/x")
        XCTAssertEqual(c.absolute("https://cdn.example/a.mp3"), "https://cdn.example/a.mp3")
        XCTAssertEqual(c.absolute("//cdn.example/a.mp3"), "https://cdn.example/a.mp3")
        XCTAssertNil(c.absolute(nil))
        XCTAssertNil(c.absolute(""))
    }

    func testBlinkPlusStatus() async throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let future = "2099-01-01T00:00:00+00:00"
        http.route("/api/plus/me") { _ in jsonReply(200, #"{"active":true,"plus_until":"\#(future)"}"#) }
        let on = try await api(token: "t").plus()
        XCTAssertEqual(on?.active, true)
        XCTAssertTrue((on?.untilMs ?? 0) > nowMs)
        http.route("/api/plus/me") { _ in jsonReply(200, #"{"active":false,"plus_until":null}"#) }
        let off = try await api(token: "t").plus()
        XCTAssertEqual(off?.active, false)
        XCTAssertNil(off?.untilMs)
        let anonymous = try await api().plus()
        XCTAssertNil(anonymous, "без входа статуса нет")
        http.route("/api/plus/me") { _ in jsonReply(500, "{}") }
        let broken = try await api(token: "t").plus()
        XCTAssertNil(broken)
    }

    func testDedupeKeyAndArtScalingFollowTheWebClient() {
        XCTAssertEqual(BlinkApi.dedupeKey(Track(id: "1", title: "Alive!", artist: "BAND")), BlinkApi.dedupeKey(Track(id: "2", title: "alive", artist: "Band")))
        XCTAssertEqual(BlinkApi.scaleArt("https://x/100x100bb.jpg", 600), "https://x/600x600bb.jpg")
        XCTAssertEqual(BlinkApi.scaleArt("https://avatars/get/200x200", 600), "https://avatars/get/600x600")
        XCTAssertEqual(BlinkApi.scaleArt("https://other/pic.png", 600), "https://other/pic.png")
        XCTAssertEqual(BlinkApi.scaleArt("", 600), "")
    }

    // ---------- вход ----------

    private func grant(_ access: String, _ refresh: String, expiresIn: Int = 3600) -> String {
        return """
        {"access_token":"\(access)","token_type":"bearer","expires_in":\(expiresIn),"refresh_token":"\(refresh)",
         "user":{"id":"u-1","email":"me@example.com","user_metadata":{"full_name":"Ayori"}}}
        """
    }

    func testPasswordSignInStoresTheSessionAndRefreshRunsBeforeExpiry() async throws {
        let clock = Box<Int64>(1_000_000)
        let store = MemSessionStore()
        let auth = SupabaseAuth(http: http, config: config(), store: store, now: { clock.value })
        let (g1, g2) = (grant("acc1", "ref1"), grant("acc2", "ref2"))
        http.route("/auth/v1/token") { req in
            switch queryValue(req, "grant_type") {
            case "password": return jsonReply(200, g1)
            case "refresh_token": return jsonReply(200, g2)
            default: return jsonReply(400, "{}")
            }
        }
        let s = try await auth.signIn(email: " me@example.com ", password: "pw")
        XCTAssertEqual(s.accessToken, "acc1")
        XCTAssertEqual(s.name, "Ayori")
        XCTAssertEqual(s.email, "me@example.com")
        XCTAssertEqual(s.expiresAtMs, clock.value + 3_600_000)
        XCTAssertEqual(http.seen.count, 1)
        let first = http.seen[0]
        XCTAssertEqual(first.headers["apikey"], "anon")
        XCTAssertTrue(String(decoding: first.body ?? Data(), as: UTF8.self).contains("\"email\":\"me@example.com\""), "почта обрезана по краям")
        XCTAssertNotNil(store.load())

        let live = await auth.accessToken()
        XCTAssertEqual(live, "acc1")
        XCTAssertEqual(http.seen.count, 1, "токен живой, сеть не трогаем")
        clock.value += 3_600_000 - 30_000 // меньше минуты до конца
        let refreshed = await auth.accessToken()
        XCTAssertEqual(refreshed, "acc2")
        XCTAssertEqual(auth.session?.refreshToken, "ref2")

        let now = clock.value
        let restored = SupabaseAuth(http: http, config: config(), store: store, now: { now })
        XCTAssertNil(restored.session)
        restored.restore()
        XCTAssertEqual(restored.session?.accessToken, "acc2")
    }

    private func authKind(_ op: @Sendable () async throws -> Void) async -> AuthException.Kind? {
        do {
            try await op()
            XCTFail("ожидали ошибку входа")
            return nil
        } catch let e as AuthException {
            return e.kind
        } catch {
            XCTFail("другая ошибка: \(error)")
            return nil
        }
    }

    func testBadPasswordNetworkLossAndRevokedRefreshToken() async throws {
        let clock = Box<Int64>(1_000_000)
        let store = MemSessionStore()
        let auth = SupabaseAuth(http: http, config: config(), store: store, now: { clock.value })
        http.route("/auth/v1/token") { _ in jsonReply(400, #"{"error":"invalid_grant","error_description":"Invalid login credentials"}"#) }
        let bad = await authKind { _ = try await auth.signIn(email: "a@b.c", password: "x") }
        XCTAssertEqual(bad, .badCredentials)
        XCTAssertNil(store.load())

        let g1 = grant("acc1", "ref1", expiresIn: 100)
        http.route("/auth/v1/token") { _ in jsonReply(200, g1) }
        _ = try await auth.signIn(email: "a@b.c", password: "x")
        clock.value += 90_000 // до конца 10 секунд, пора обновлять
        http.route("/auth/v1/token") { _ in jsonReply(400, #"{"error":"invalid_grant"}"#) }
        let token = await auth.accessToken()
        XCTAssertEqual(token, "acc1", "пока токен не истёк, отдаём его, даже если обновить не вышло")
        XCTAssertNil(auth.session, "refresh-токен отозван: сессия сброшена")
        XCTAssertNil(store.load())

        let g3 = grant("acc3", "ref3", expiresIn: 100)
        http.route("/auth/v1/token") { _ in jsonReply(200, g3) }
        _ = try await auth.signIn(email: "a@b.c", password: "x")
        clock.value += 150_000 // токен истёк
        http.setDown(true)
        let none = await auth.accessToken()
        XCTAssertNil(none, "нет сети и токен просрочен")
        XCTAssertNotNil(auth.session, "сессию из-за сети не сбрасываем")

        let offline = await authKind { _ = try await auth.signIn(email: "a@b.c", password: "x") }
        XCTAssertEqual(offline, .network)
    }

    func testSignInWithoutAKeyInTheBuildSaysSo() async throws {
        let auth = SupabaseAuth(http: http, config: config(""), store: MemSessionStore())
        XCTAssertFalse(auth.configured)
        let kind = await authKind { _ = try await auth.signIn(email: "a@b.c", password: "x") }
        XCTAssertEqual(kind, .notConfigured)
        XCTAssertTrue(http.seen.isEmpty)
    }
}
