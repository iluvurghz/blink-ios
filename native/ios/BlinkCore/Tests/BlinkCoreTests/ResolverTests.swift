import XCTest
@testable import BlinkCore

struct FixedToken: TokenProvider {
    let value: String?

    func accessToken() async -> String? {
        return value
    }
}

final class ResolverTests: XCTestCase {
    private var backend: FakeBackend!

    override func setUp() {
        super.setUp()
        backend = FakeBackend()
    }

    private var config: BlinkConfig {
        return BlinkConfig(baseURL: backend.base, supabaseURL: backend.base, supabaseAnonKey: "anon")
    }

    private func resolver(
        token: String? = "tok",
        legacy: Bool = true,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> ServerResolver {
        return ServerResolver(http: backend, config: config, tokens: FixedToken(value: token), legacyFallback: legacy, now: now)
    }

    private func failure(_ r: ServerResolver, _ id: String = "a", source: String = "blink") async -> OfflineError? {
        return await offlineError { _ = try await r.resolve(source: source, id: id) }
    }

    func testResolvesWithBearerAndReadsEveryField() async throws {
        backend.add("a", 300_000, duration: 213)
        let res = try await resolver().resolve(source: "blink", id: "a")
        XCTAssertEqual(res.bytes, 300_000)
        XCTAssertEqual(res.mime, "audio/mpeg")
        XCTAssertEqual(res.etag, "W/\"e1\"")
        XCTAssertEqual(res.duration, 213)
        XCTAssertTrue(res.url.hasPrefix("\(backend.base)/media/a"), res.url)
        XCTAssertTrue(res.expiresAt > Int64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(backend.resolveRequests.count, 1)
        let req = backend.resolveRequests[0]
        XCTAssertEqual(req.headers["Authorization"], "Bearer tok")
        XCTAssertEqual(queryValue(req, "source"), "blink")
        XCTAssertEqual(queryValue(req, "id"), "a")
    }

    func testRelativeFileUrlIsMadeAbsolute() async throws {
        backend.add("a", 300_000)
        backend.resolveHook = { _ in
            jsonReply(200, #"{"ok":true,"url":"/media/a?sig=1","bytes":300000,"etag":"W/\"e1\"","mime":"audio/mpeg","expiresAt":9999999999999}"#)
        }
        let res = try await resolver().resolve(source: "blink", id: "a")
        XCTAssertEqual(res.url, "\(backend.base)/media/a?sig=1")
    }

    func testNoTokenMeansSignInNoRequest() async throws {
        backend.add("a", 300_000)
        let e = await failure(resolver(token: nil))
        XCTAssertEqual(e?.code, .notAllowed)
        XCTAssertEqual(e?.reason, "auth")
        XCTAssertTrue(backend.resolveRequests.isEmpty)
    }

    func testServerErrorsMapToContractCodes() async throws {
        backend.add("a", 300_000)
        let next = Box<HTTPResponse>(jsonReply(500, ""))
        backend.resolveHook = { _ in next.value }
        func reply(_ status: Int, _ body: String) { next.value = jsonReply(status, body) }

        reply(401, #"{"ok":false,"error":"NOT_ALLOWED","reason":"auth"}"#)
        var e = await failure(resolver())
        XCTAssertEqual(e?.reason, "auth")
        reply(403, #"{"ok":false,"error":"NOT_ALLOWED","reason":"plus"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.reason, "plus")
        reply(403, #"{"ok":false,"error":"NOT_ALLOWED","reason":"artist"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.reason, "artist")
        reply(403, #"{"ok":false,"error":"NOT_ALLOWED"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.reason, "source")
        reply(404, #"{"ok":false,"error":"NOT_DOWNLOADABLE","reason":"unreleased"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.code, .notDownloadable)
        XCTAssertEqual(e?.reason, "unreleased")
        reply(400, #"{"ok":false,"error":"SOURCE_ERROR","reason":"bad_request"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.code, .sourceError)
        reply(503, #"{"ok":false,"error":"SOURCE_ERROR"}"#)
        e = await failure(resolver())
        XCTAssertEqual(e?.code, .sourceError)
        reply(502, "<html>bad gateway</html>")
        e = await failure(resolver())
        XCTAssertEqual(e?.code, .sourceError)
    }

    func testBad200AnswersAreSourceErrors() async throws {
        let bodies = [
            #"{"ok":true,"url":"/media/a"}"#, // нет bytes
            #"{"ok":true,"url":"/media/a","bytes":0}"#,
            #"{"ok":true,"bytes":10}"#, // нет url
            #"{"ok":false,"bytes":10,"url":"/media/a"}"#,
            "not json",
        ]
        for body in bodies {
            backend.resolveHook = { _ in jsonReply(200, body) }
            let e = await failure(resolver())
            XCTAssertEqual(e?.code, .sourceError, body)
            XCTAssertEqual(e?.reason, "bad_response", body)
        }
    }

    func testUntilTheResolverIsOnProdItFallsBackToApiPlayWithNoSizeAndNoEtag() async throws {
        backend.legacyOnly = true
        backend.add("a", 300_000)
        let fixed: Int64 = 1_000_000
        let res = try await resolver(now: { fixed }).resolve(source: "blink", id: "a")
        XCTAssertTrue(res.url.hasPrefix("\(backend.base)/media/a"), res.url)
        XCTAssertNil(res.bytes)
        XCTAssertNil(res.etag)
        XCTAssertNil(res.mime)
        XCTAssertEqual(res.expiresAt, fixed + 55 * 60 * 1000)
        XCTAssertEqual(backend.playRequests.count, 1)
        XCTAssertEqual(backend.playRequests[0].headers["Authorization"], "Bearer tok")
    }

    func testLegacyFallbackMapsItsOwnErrorsAndARealNotDownloadableIsNotMistakenForAMissingEndpoint() async throws {
        backend.legacyOnly = true
        var e = await failure(resolver(), "ghost") // /api/play/ghost → 404
        XCTAssertEqual(e?.code, .notDownloadable)
        XCTAssertEqual(backend.playRequests.filter { $0.headers["Authorization"] == nil }.count, 0)

        backend.legacyOnly = false
        backend.resolveHook = nil
        e = await failure(resolver(), "ghost")
        XCTAssertEqual(e?.code, .notDownloadable, "наш JSON с NOT_DOWNLOADABLE это настоящий ответ")
        XCTAssertEqual(backend.playRequests.count, 1, "в /api/play второй раз не ходили")

        backend.legacyOnly = true
        e = await failure(resolver(legacy: false), "a")
        XCTAssertEqual(e?.code, .notDownloadable)
    }

    func testOnlyBlinkGoesToTheLegacyFallback() async throws {
        backend.legacyOnly = true
        backend.add("a", 300_000)
        let e = await failure(resolver(), "a", source: "soundcloud")
        XCTAssertEqual(e?.code, .notDownloadable)
        XCTAssertTrue(backend.playRequests.isEmpty)
    }
}
