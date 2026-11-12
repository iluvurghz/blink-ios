import Foundation

public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Мс от эпохи.
    public var expiresAtMs: Int64
    public var userId: String
    public var email: String?
    public var name: String?

    public init(accessToken: String, refreshToken: String, expiresAtMs: Int64, userId: String, email: String? = nil, name: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAtMs = expiresAtMs
        self.userId = userId
        self.email = email
        self.name = name
    }
}

/// Где живёт сессия между запусками. На iOS это Keychain.
public protocol SessionStore: AnyObject, Sendable {
    func load() -> String?
    func save(_ value: String?)
}

public struct AuthException: Error, Equatable, Sendable {
    public enum Kind: Sendable {
        case badCredentials
        case network
        case server
        case notConfigured
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Вход в Supabase (GoTrue): почта и пароль, Google и Telegram (через страницы сайта и возврат по `blink://auth`),
/// обновление токена. Если supabase.co не отвечает (в РФ его режут), запросы уходят на зеркало сайта `/sb`.
/// Токен нужен серверу Blink (Bearer): `/api/offline/resolve`, `/api/play/:id`, `/api/plus/me`.
public final class SupabaseAuth: TokenProvider, @unchecked Sendable {
    private static let refreshSkewMs: Int64 = 60_000

    private let http: HTTPClient
    private let config: BlinkConfig
    private let store: SessionStore
    private let now: @Sendable () -> Int64
    private let state = Observable<AuthSession?>(nil)
    private let gate = AsyncGate()
    private let mirrorLock = NSLock()
    private var mirrorFirst = false

    public init(
        http: HTTPClient,
        config: BlinkConfig,
        store: SessionStore,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.http = http
        self.config = config
        self.store = store
        self.now = now
    }

    public var session: AuthSession? { return state.current }

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (AuthSession?) -> Void) -> NetworkObservation {
        return state.observe(handler)
    }

    public var configured: Bool { return config.hasKey }

    /// Достаёт сохранённую сессию. Сети не нужно: сохранённое играет и без входа.
    public func restore() {
        guard let text = store.load() else { return }
        let restored = BlinkJSON.decode(AuthSession.self, from: text)
        state.update { $0 = restored }
    }

    public func signIn(email: String, password: String) async throws -> AuthSession {
        if !configured { throw AuthException(.notConfigured, "В этой сборке нет ключа входа") }
        let res = try await call("password", ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
        if res.ok { return try adopt(res.text) }
        throw failure(res)
    }

    /// Google: id-токен со страницы сайта и сырой nonce (Supabase сам сверяет его хэш с тем, что внутри токена).
    public func signInWithIdToken(provider: String, idToken: String, nonce: String) async throws -> AuthSession {
        if !configured { throw AuthException(.notConfigured, "В этой сборке нет ключа входа") }
        let res = try await call("id_token", ["provider": provider, "id_token": idToken, "nonce": nonce])
        if res.ok { return try adopt(res.text) }
        throw providerFailure(res, "Google")
    }

    /// Telegram: одноразовый token_hash, который сервер выдал после проверки подписи виджета.
    public func signInWithTokenHash(_ tokenHash: String) async throws -> AuthSession {
        if !configured { throw AuthException(.notConfigured, "В этой сборке нет ключа входа") }
        let res = try await send(path: "auth/v1/verify", query: [], body: ["type": "magiclink", "token_hash": tokenHash], bearer: nil, seconds: 20)
        if res.ok { return try adopt(res.text) }
        throw providerFailure(res, "Telegram")
    }

    /// Заканчивает вход по ссылке, с которой сайт вернул пользователя в приложение.
    public func finish(_ link: AuthLink) async throws -> AuthSession {
        switch link {
        case let .idToken(token, nonce): return try await signInWithIdToken(provider: "google", idToken: token, nonce: nonce)
        case let .telegramHash(hash): return try await signInWithTokenHash(hash)
        case .failed: throw AuthException(.server, "Вход отменён или не получился")
        }
    }

    public func accessToken() async -> String? {
        guard let s = state.current else { return nil }
        if s.expiresAtMs - now() > SupabaseAuth.refreshSkewMs { return s.accessToken }
        if let fresh = await refresh(s) { return fresh.accessToken }
        return s.expiresAtMs > now() ? s.accessToken : nil
    }

    private func refresh(_ old: AuthSession) async -> AuthSession? {
        await gate.acquire()
        let result = await doRefresh(old)
        await gate.release()
        return result
    }

    private func doRefresh(_ old: AuthSession) async -> AuthSession? {
        guard let cur = state.current else { return nil }
        if cur.refreshToken != old.refreshToken { return cur } // уже обновили, пока ждали
        if !configured { return nil }
        do {
            let res = try await call("refresh_token", ["refresh_token": cur.refreshToken])
            if res.ok { return try adopt(res.text) }
            if res.status == 400 || res.status == 401 || res.status == 403 {
                signOutLocal() // refresh-токен отозван: сессия не жива
                return nil
            }
            return nil
        } catch {
            return nil // сети нет или сервер молчит: сессию не трогаем
        }
    }

    public func signOut() async {
        let s = state.current
        signOutLocal()
        guard let old = s, configured else { return }
        _ = try? await send(path: "auth/v1/logout", query: [], body: [:], bearer: old.accessToken, seconds: 8)
    }

    private func signOutLocal() {
        state.update { $0 = nil }
        store.save(nil)
    }

    private func call(_ grant: String, _ body: [String: String]) async throws -> HTTPResponse {
        return try await send(path: "auth/v1/token", query: [("grant_type", grant)], body: body, bearer: nil, seconds: 20)
    }

    private func roots() -> [String] {
        if config.supabaseMirror == config.supabase { return [config.supabase] }
        mirrorLock.lock()
        defer { mirrorLock.unlock() }
        return mirrorFirst ? [config.supabaseMirror, config.supabase] : [config.supabase, config.supabaseMirror]
    }

    private func rememberMirror(_ value: Bool) {
        mirrorLock.lock()
        mirrorFirst = value
        mirrorLock.unlock()
    }

    /// Прямой Supabase, а если он молчит, зеркало сайта; удачный выбор запоминаем до перезапуска.
    private func send(path: String, query: [(String, String)], body: [String: String], bearer: String?, seconds: TimeInterval) async throws -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        let list = roots()
        for (i, root) in list.enumerated() {
            guard let url = URLBuilder.make(root, path: path, query: query) else {
                throw AuthException(.server, "Сервер входа ответил непонятно")
            }
            var headers = ["apikey": config.supabaseAnonKey, "Accept": "application/json", "Content-Type": "application/json"]
            if let token = bearer { headers["Authorization"] = "Bearer " + token }
            let req = HTTPRequest(url: url, method: "POST", headers: headers, body: data, timeout: (i == 0 && list.count > 1) ? 6 : seconds)
            do {
                let res = try await http.send(req)
                if list.count > 1 { rememberMirror(root == config.supabaseMirror) }
                return res
            } catch is TransportError {
                continue
            }
        }
        throw AuthException(.network, "Нет связи с сервером входа")
    }

    private func adopt(_ text: String) throws -> AuthSession {
        let unclear = AuthException(.server, "Сервер входа ответил непонятно")
        guard let o = BlinkJSON.object(text) else { throw unclear }
        guard let user = JSONField.object(o, "user") else { throw unclear }
        guard let access = JSONField.string(o, "access_token"), let refresh = JSONField.string(o, "refresh_token"), let id = JSONField.string(user, "id") else {
            throw unclear
        }
        let expiresAt: Int64
        if let at = JSONField.int64(o, "expires_at") {
            expiresAt = at * 1000
        } else {
            expiresAt = now() + (JSONField.int64(o, "expires_in") ?? 3600) * 1000
        }
        let meta = JSONField.object(user, "user_metadata")
        let s = AuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAtMs: expiresAt,
            userId: id,
            email: JSONField.string(user, "email"),
            name: meta.flatMap { JSONField.string($0, "full_name") } ?? meta.flatMap { JSONField.string($0, "name") }
        )
        state.update { $0 = s }
        store.save(BlinkJSON.encode(s))
        return s
    }

    private func failure(_ res: HTTPResponse) -> AuthException {
        let o = BlinkJSON.object(res.text)
        let code = o.flatMap { JSONField.string($0, "error_code") } ?? o.flatMap { JSONField.string($0, "error") }
        if res.status == 400 || res.status == 401 || code == "invalid_credentials" || code == "invalid_grant" {
            return AuthException(.badCredentials, "Неверная почта или пароль")
        }
        if res.status == 429 { return AuthException(.server, "Слишком много попыток, подождите минуту") }
        return AuthException(.server, "Сервер входа не отвечает (\(res.status))")
    }

    private func providerFailure(_ res: HTTPResponse, _ who: String) -> AuthException {
        if res.status == 429 { return AuthException(.server, "Слишком много попыток, подождите минуту") }
        return AuthException(.server, "Вход через \(who) не получился (\(res.status)), попробуйте ещё раз")
    }
}
