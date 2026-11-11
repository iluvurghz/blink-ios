import XCTest
@testable import BlinkCore

final class AuthLinkTests: XCTestCase {
    private let base = "http://api.test"
    private var http: RouteHTTP!

    override func setUp() {
        super.setUp()
        http = RouteHTTP()
    }

    private let session = """
    {"access_token":"acc","refresh_token":"ref","expires_in":3600,"user":{"id":"u1","email":"a@b.c","user_metadata":{"full_name":"Имя"}}}
    """

    private func auth(supabase: String? = nil, store: MemSessionStore = MemSessionStore()) -> SupabaseAuth {
        return SupabaseAuth(http: http, config: BlinkConfig(baseURL: base, supabaseURL: supabase ?? base, supabaseAnonKey: "anon"), store: store)
    }

    func testParseReadsGoogleTelegramAndErrorLinks() {
        XCTAssertEqual(AuthLink.parse("blink://auth?id_token=aaa.bbb.ccc&nonce=0f%2Bab"), .idToken(token: "aaa.bbb.ccc", nonce: "0f+ab"))
        XCTAssertEqual(AuthLink.parse("blink://auth?tg_hash=h4sh"), .telegramHash("h4sh"))
        XCTAssertEqual(AuthLink.parse("blink://auth#tg_hash=h4sh"), .telegramHash("h4sh"))
        XCTAssertEqual(AuthLink.parse("blink://auth?error=access_denied&error_description=No"), .failed("No"))
        XCTAssertNil(AuthLink.parse("blink://auth?foo=bar"))
        XCTAssertNil(AuthLink.parse("https://blinkmusic.cc/?id_token=x&nonce=y"))
        XCTAssertNil(AuthLink.parse(nil))
    }

    func testStartURLsPointToTheSitePages() {
        XCTAssertEqual(AuthLink.startURL(base: "https://blinkmusic.cc/", provider: .google), "https://blinkmusic.cc/?gsignin=desktop")
        XCTAssertEqual(AuthLink.startURL(base: "https://blinkmusic.cc", provider: .telegram), "https://blinkmusic.cc/?tgsignin=desktop")
    }

    func testGoogleIdTokenGoesToTheIdTokenGrantWithTheRawNonce() async throws {
        let store = MemSessionStore()
        let a = auth(store: store)
        let reply = session
        http.route("/auth/v1/token") { _ in jsonReply(200, reply) }
        let s = try await a.finish(.idToken(token: "tok", nonce: "rawnonce"))
        XCTAssertEqual(s.userId, "u1")
        XCTAssertEqual(s.name, "Имя")
        let req = try XCTUnwrap(http.seen.first)
        XCTAssertEqual(queryValue(req, "grant_type"), "id_token")
        let body = String(decoding: req.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"provider\":\"google\"") && body.contains("\"id_token\":\"tok\"") && body.contains("\"nonce\":\"rawnonce\""), body)
        XCTAssertEqual(req.headers["apikey"], "anon")
        XCTAssertNotNil(store.load())
    }

    func testTelegramHashIsVerifiedAsAMagicLink() async throws {
        let a = auth()
        let reply = session
        http.route("/auth/v1/verify") { _ in jsonReply(200, reply) }
        _ = try await a.finish(.telegramHash("h4sh"))
        let body = String(decoding: http.seen[0].body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("\"type\":\"magiclink\"") && body.contains("\"token_hash\":\"h4sh\""), body)
    }

    func testFailedLinkIsAHumanErrorAndDoesNotCallTheServer() async {
        let a = auth()
        do {
            _ = try await a.finish(.failed("x"))
            XCTFail("должно упасть")
        } catch {
            XCTAssertEqual((error as? AuthException)?.kind, .server)
        }
        XCTAssertEqual(http.seen.count, 0)
    }

    func testDeadSupabaseFallsBackToTheSiteMirrorAndRemembersIt() async throws {
        let dead = "http://dead.test"
        let a = auth(supabase: dead)
        let reply = session
        http.route("/sb/auth/v1/token") { _ in jsonReply(200, reply) }
        http.route("/auth/v1/token") { _ in throw TransportError.offline }
        _ = try await a.signIn(email: "a@b.c", password: "pw")
        XCTAssertEqual(http.seen.map { $0.url.path }, ["/auth/v1/token", "/sb/auth/v1/token"])
        _ = try await a.signIn(email: "a@b.c", password: "pw")
        XCTAssertEqual(http.seen.count, 3, "второй раз сразу идём на зеркало")
    }
}
