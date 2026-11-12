import Foundation

public struct PlusPlan: Equatable, Sendable {
    public var id: String
    public var label: String
    public var price: Int
    public var days: Int
    public var old: Int
    public var tag: String
    public init(id: String, label: String, price: Int, days: Int, old: Int = 0, tag: String = "") {
        self.id = id
        self.label = label
        self.price = price
        self.days = days
        self.old = old
        self.tag = tag
    }
    /// Цена за месяц для сравнения: год делим на 12.
    public var monthly: Int { return days >= 365 ? Int((Double(price) / 12.0).rounded()) : price }
}

public struct PlusPerk: Equatable, Sendable {
    public var icon: String
    public var title: String
    public var text: String
    public init(icon: String, title: String, text: String) {
        self.icon = icon
        self.title = title
        self.text = text
    }
}

public struct PlusRow: Equatable, Sendable {
    public var label: String
    public var free: Bool
    public var plus: Bool
    public init(label: String, free: Bool, plus: Bool) {
        self.label = label
        self.free = free
        self.plus = plus
    }
}

public struct PlusTier: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var from: Int
    public init(id: Int, name: String, from: Int) {
        self.id = id
        self.name = name
        self.from = from
    }
}

/// Что рассказывает страница Blink+: цены, плюсы, сравнение, лесенка «Хранителя». Админка правит это на сервере.
public struct PlusConfig: Equatable, Sendable {
    public var title: String
    public var lead: String
    public var plans: [PlusPlan]
    public var perks: [PlusPerk]
    public var compare: [PlusRow]
    public var tiers: [PlusTier]

    /// Высшая ступень, до которой дотягивает сумма; 0, если ниже первой.
    public func tierFor(_ total: Int) -> Int {
        return tiers.reduce(0) { t, x in total >= x.from ? x.id : t }
    }

    /// Показывается сразу и без сети; версия сервера заменяет её, когда придёт. Совпадает с `PLUS_FALLBACK` сайта.
    public static let fallback = PlusConfig(
        title: "Blink+",
        lead: "Музыка в Blink остаётся бесплатной. Blink+ добавляет то, что нужно каждый день, и отмечает вас в профиле.",
        plans: [PlusPlan(id: "month", label: "Месяц", price: 149, days: 30), PlusPlan(id: "year", label: "Год", price: 1290, days: 365)],
        perks: [
            PlusPerk(icon: "download", title: "Музыка без интернета", text: "Сохраняйте треки и плейлисты на устройство. Играют в метро, самолёте и без сети."),
            PlusPerk(icon: "user", title: "Орбита у аватарки", text: "Тонкий световой круг у вашей аватарки и значок Blink+ рядом с ником. Его видят все."),
            PlusPerk(icon: "bolt", title: "Ранний доступ", text: "Новые функции приходят к подписчикам первыми, пока мы их дорабатываем."),
            PlusPerk(icon: "heart", title: "Вы держите Blink", text: "Подписка оплачивает серверы и помогает выпускать обновления быстрее."),
        ],
        compare: [
            PlusRow(label: "Вся музыка и Вспышка", free: true, plus: true),
            PlusRow(label: "Плейлисты и перенос музыки", free: true, plus: true),
            PlusRow(label: "Сохранение треков без интернета", free: false, plus: true),
            PlusRow(label: "Орбита у аватарки и значок", free: false, plus: true),
            PlusRow(label: "Ранний доступ к новому", free: false, plus: true),
        ],
        tiers: [PlusTier(id: 1, name: "Хранитель", from: 50), PlusTier(id: 2, name: "Хранитель II", from: 1000), PlusTier(id: 3, name: "Хранитель III", from: 5000)]
    )

    public static func parse(_ o: [String: Any]) -> PlusConfig? {
        var plans: [PlusPlan] = []
        for e in JSONField.array(o, "plans") ?? [] {
            guard let p = e as? [String: Any], let id = JSONField.string(p, "id"), let price = JSONField.int(p, "price") else { continue }
            plans.append(PlusPlan(id: id, label: JSONField.string(p, "label") ?? "", price: price, days: JSONField.int(p, "days") ?? 30, old: JSONField.int(p, "old") ?? 0, tag: JSONField.string(p, "tag") ?? ""))
        }
        var tiers: [PlusTier] = []
        for (i, e) in (JSONField.array(o, "tiers") ?? []).enumerated() {
            guard let t = e as? [String: Any], let name = JSONField.string(t, "name"), let from = JSONField.int(t, "from") else { continue }
            tiers.append(PlusTier(id: i + 1, name: name, from: from))
        }
        if plans.isEmpty || tiers.isEmpty { return nil }
        var perks: [PlusPerk] = []
        for e in JSONField.array(o, "perks") ?? [] {
            guard let p = e as? [String: Any], let title = JSONField.string(p, "title") else { continue }
            perks.append(PlusPerk(icon: JSONField.string(p, "icon") ?? "heart", title: title, text: JSONField.string(p, "text") ?? ""))
        }
        var rows: [PlusRow] = []
        for e in JSONField.array(o, "compare") ?? [] {
            guard let r = e as? [String: Any], let label = JSONField.string(r, "label") else { continue }
            rows.append(PlusRow(label: label, free: JSONField.bool(r, "free") == true, plus: JSONField.bool(r, "plus") != false))
        }
        return PlusConfig(title: JSONField.string(o, "title") ?? "Blink+", lead: JSONField.string(o, "lead") ?? "", plans: plans, perks: perks, compare: rows, tiers: tiers)
    }
}

/// Ответ `/api/plus/me`.
public struct PlusMe: Equatable, Sendable {
    public var active: Bool
    public var untilMs: Int64?
    public var supporterSince: String?
    public var keeperTier: Int
    public var donated: Int
}

public enum PromoResult: Equatable, Sendable {
    /// Код на скидку: покажем процент, применится при оплате.
    case discount(code: String, percent: Int)
    /// Код на дни Blink+: сработал сразу.
    case days(code: String, days: Int, untilMs: Int64?)
}

public struct PlusError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public protocol PlusService: Sendable {
    func config() async throws -> PlusConfig?
    func me() async throws -> PlusMe?
    func promo(_ code: String) async throws -> PromoResult
    /// Ссылка на оплату тарифа (страница платёжки открывается в браузере).
    func checkout(plan: String, promo: String?) async throws -> String
    func donate(amountRub: Int) async throws -> String
}

public final class PlusApi: PlusService, @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?
    private let cache: KeyValue?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?, cache: KeyValue? = nil) {
        self.http = http
        self.config = config
        self.tokens = tokens
        self.cache = cache
    }

    /// Последние настройки с сервера или запасные: страница открывается сразу и без сети.
    public func cached() -> PlusConfig {
        if let raw = cache?.get("plus.cfg"), let o = BlinkJSON.object(raw), let c = PlusConfig.parse(o) { return c }
        return PlusConfig.fallback
    }

    private func call(_ path: String, body: [String: Any]?) async throws -> (Int, String, [String: Any]?) {
        guard let url = URLBuilder.make(config.base, path: "api/plus/" + path) else { throw PlusError("Не получилось") }
        var headers = ["Accept": "application/json"]
        if let t = await tokens?.accessToken() { headers["Authorization"] = "Bearer " + t }
        var data: Data?
        if let b = body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: b)
        }
        let res = try await http.send(HTTPRequest(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: data, timeout: 20))
        return (res.status, res.text, BlinkJSON.object(res.text))
    }

    public func config() async throws -> PlusConfig? {
        let (code, text, o) = try await call("config", body: nil)
        guard code == 200, let obj = o, let parsed = PlusConfig.parse(obj) else { return nil }
        cache?.put("plus.cfg", text)
        return parsed
    }

    public func me() async throws -> PlusMe? {
        let (code, _, o) = try await call("me", body: nil)
        guard code == 200, let obj = o else { return nil }
        return PlusMe(
            active: JSONField.bool(obj, "active") == true,
            untilMs: JSONField.string(obj, "plus_until").flatMap { ISODate.parseMs($0) },
            supporterSince: JSONField.string(obj, "supporter_since"),
            keeperTier: JSONField.int(obj, "keeper_tier") ?? 0,
            donated: JSONField.int(obj, "donated") ?? 0
        )
    }

    public func promo(_ code: String) async throws -> PromoResult {
        let (status, _, o) = try await call("promo", body: ["code": code])
        guard status == 200, let obj = o else { throw PlusError(o.flatMap { JSONField.string($0, "error") } ?? "Не получилось, попробуйте ещё раз") }
        let c = JSONField.string(obj, "code") ?? ""
        if JSONField.string(obj, "kind") == "discount" { return .discount(code: c, percent: JSONField.int(obj, "percent") ?? 0) }
        return .days(code: c, days: JSONField.int(obj, "days") ?? 0, untilMs: JSONField.string(obj, "plus_until").flatMap { ISODate.parseMs($0) })
    }

    public func checkout(plan: String, promo: String?) async throws -> String {
        var body: [String: Any] = ["plan": plan]
        if let p = promo, !p.trimmingCharacters(in: .whitespaces).isEmpty { body["code"] = p }
        let (status, _, o) = try await call("checkout", body: body)
        return try payURL(status, o)
    }

    public func donate(amountRub: Int) async throws -> String {
        let (status, _, o) = try await call("donate", body: ["amount": amountRub])
        return try payURL(status, o)
    }

    private func payURL(_ status: Int, _ o: [String: Any]?) throws -> String {
        if status == 200, let o = o, let url = JSONField.string(o, "pay_url"), !url.isEmpty { return url }
        throw PlusError(o.flatMap { JSONField.string($0, "error") } ?? "Не получилось, попробуйте ещё раз")
    }
}
