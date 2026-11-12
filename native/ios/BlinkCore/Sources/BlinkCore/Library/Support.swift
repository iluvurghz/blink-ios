import Foundation

public struct FaqItem: Equatable, Sendable {
    public var id: String
    public var question: String
    public var answer: String
    public var keywords: String
}

public struct TicketRow: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var message: String
    public var status: String
    public var lastAuthor: String
    public var updatedAt: String
}

public struct TicketMessage: Equatable, Sendable {
    public var id: String
    public var author: String
    public var body: String
    public var images: [String]
    public var createdAt: String
}

public struct TicketView: Equatable, Sendable {
    public var id: String
    public var kind: String
    public var message: String
    public var status: String
    public var images: [String]
    public var autoQuestion: String?
    public var autoAnswer: String?
    public var messages: [TicketMessage]
}

public struct TicketSent: Equatable, Sendable {
    public var id: String
    public var autoQuestion: String?
    public var autoAnswer: String?
}

/// Поддержка: частые вопросы, обращения и переписка (server/supportRoute.js).
public final class SupportApi: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?) {
        self.http = http
        self.config = config
        self.tokens = tokens
    }

    private func call(_ path: String, _ body: [String: Any]?) async throws -> [String: Any] {
        guard let url = URLBuilder.make(config.base, path: "api/support/" + path) else { throw SharedError("Не получилось") }
        var headers = ["Accept": "application/json"]
        if let t = await tokens?.accessToken() { headers["Authorization"] = "Bearer " + t }
        var data: Data?
        if let b = body {
            headers["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: b)
        }
        let res = try await http.send(HTTPRequest(url: url, method: body == nil ? "GET" : "POST", headers: headers, body: data, timeout: 25))
        let o = BlinkJSON.object(res.text)
        if !res.ok {
            throw SharedError(o.flatMap { JSONField.string($0, "error") } ?? (res.status == 404 ? "Поддержка на сервере ещё не обновлена" : "Сервер поддержки не ответил (\(res.status)), попробуйте позже"))
        }
        return o ?? [:]
    }

    public func faq() async throws -> [FaqItem] {
        let o = try await call("faq", nil)
        return (JSONField.array(o, "faq") ?? []).compactMap { e in
            guard let f = e as? [String: Any], let id = JSONField.string(f, "id") else { return nil }
            return FaqItem(id: id, question: JSONField.string(f, "question") ?? "", answer: JSONField.string(f, "answer") ?? "", keywords: JSONField.string(f, "keywords") ?? "")
        }
    }

    /// Новое обращение. Картинки идут как data URL (jpeg, до 1600 px).
    public func send(message: String, contact: String?, images: [String] = []) async throws -> TicketSent {
        var b: [String: Any] = ["kind": "question", "message": message]
        if let c = contact, !c.isEmpty { b["contact"] = c } else { b["contact"] = NSNull() }
        if !images.isEmpty { b["images"] = images }
        let o = try await call("ticket", b)
        let auto = o["auto"] as? [String: Any]
        return TicketSent(id: JSONField.string(o, "id") ?? "", autoQuestion: auto.flatMap { JSONField.string($0, "question") }, autoAnswer: auto.flatMap { JSONField.string($0, "answer") })
    }

    public func mine() async throws -> [TicketRow] {
        let o = try await call("mine", nil)
        return (JSONField.array(o, "tickets") ?? []).compactMap { e in
            guard let t = e as? [String: Any], let id = JSONField.string(t, "id") else { return nil }
            return TicketRow(id: id, kind: JSONField.string(t, "kind") ?? "", message: JSONField.string(t, "message") ?? "", status: JSONField.string(t, "status") ?? "", lastAuthor: JSONField.string(t, "last_author") ?? "", updatedAt: JSONField.string(t, "updated_at") ?? "")
        }
    }

    public func open(_ id: String) async throws -> TicketView {
        let o = try await call("ticket/" + id, nil)
        guard let t = o["ticket"] as? [String: Any] else { throw SharedError("Обращение не найдено") }
        let auto = o["auto"] as? [String: Any]
        let msgs = (JSONField.array(o, "messages") ?? []).compactMap { message($0 as? [String: Any]) }
        return TicketView(id: JSONField.string(t, "id") ?? "", kind: JSONField.string(t, "kind") ?? "", message: JSONField.string(t, "message") ?? "", status: JSONField.string(t, "status") ?? "", images: urls(t["attachments"]), autoQuestion: auto.flatMap { JSONField.string($0, "question") }, autoAnswer: auto.flatMap { JSONField.string($0, "answer") }, messages: msgs)
    }

    public func reply(_ id: String, _ body: String, images: [String] = []) async throws -> TicketMessage {
        var b: [String: Any] = ["body": body]
        if !images.isEmpty { b["images"] = images }
        let o = try await call("ticket/" + id + "/message", b)
        guard let m = message(o["message"] as? [String: Any]) else { throw SharedError("Не получилось отправить") }
        return m
    }

    public func close(_ id: String) async throws {
        _ = try await call("ticket/" + id + "/close", [:])
    }

    private func message(_ o: [String: Any]?) -> TicketMessage? {
        guard let o = o, let id = JSONField.string(o, "id") else { return nil }
        return TicketMessage(id: id, author: JSONField.string(o, "author") ?? "", body: JSONField.string(o, "body") ?? "", images: urls(o["attachments"]), createdAt: JSONField.string(o, "created_at") ?? "")
    }

    private func urls(_ v: Any?) -> [String] {
        return ((v as? [Any]) ?? []).compactMap { x in
            if let s = x as? String { return s }
            return (x as? [String: Any]).flatMap { JSONField.string($0, "url") }
        }
    }

    private static func norm(_ s: String) -> String { return s.lowercased().replacingOccurrences(of: "ё", with: "е") }

    /// Как на сервере: ответ, чьих ключевых слов в тексте больше всего.
    public static func bestAnswer(_ faq: [FaqItem], _ q: String) -> FaqItem? {
        let t = norm(q)
        var best: FaqItem?
        var score = 0
        for f in faq {
            let n = norm(f.keywords).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 && t.contains($0) }.count
            if n > score {
                best = f
                score = n
            }
        }
        return best
    }
}
