import Foundation

public struct ArtistMe: Equatable, Sendable {
    public var id: String
    public var name: String
    public var handle: String?
    public var bio: String?
    public var offerAccepted: Bool
}

public struct MyTrack: Equatable, Sendable {
    public var id: String
    public var title: String
    public var releaseTitle: String
    public var status: String
    public var cover: String?
    public var releaseDate: String
    public var explicit: Bool
    public var streamsTotal: Int64
    public var streamsMonth: Int64
}

/// Поля формы «Новый трек», как на сайте (ui/Profile.jsx, UploadForm).
public struct UploadDraft: Equatable, Sendable {
    public var title = ""
    public var releaseTitle = ""
    public var authors = ""
    public var phonogramMaker = ""
    public var year = ""
    public var genre = ""
    public var language = ""
    public var releaseDate = ""
    public var samples = ""
    public var lyrics = ""
    public var explicit = false
    public var aiUsed = false
    public var rights = false
    public init() {}
}

/// Файл на диске для загрузки: имя, тип и путь.
public struct UploadFile: Equatable, Sendable {
    public var name: String
    public var mime: String
    public var url: URL
    public init(name: String, mime: String, url: URL) {
        self.name = name
        self.mime = mime
        self.url = url
    }
}

/// Отправка большого тела из файла с отчётом о ходе. Приложение делает это через URLSession, тесты подменяют.
public protocol UploadClient: Sendable {
    func upload(_ request: HTTPRequest, bodyFile: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse
}

/// Кабинет артиста: профиль, оферта, свои релизы и загрузка нового трека.
public final class CabinetApi: @unchecked Sendable {
    private let http: HTTPClient
    private let uploader: UploadClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?

    public init(http: HTTPClient, uploader: UploadClient, config: BlinkConfig, tokens: TokenProvider?) {
        self.http = http
        self.uploader = uploader
        self.config = config
        self.tokens = tokens
    }

    private func headers(_ extra: [String: String] = [:]) async -> [String: String] {
        var h = ["Accept": "application/json"]
        if let t = await tokens?.accessToken() { h["Authorization"] = "Bearer " + t }
        for (k, v) in extra { h[k] = v }
        return h
    }

    private func fail(_ status: Int, _ o: [String: Any]?, _ fallback: String) -> SharedError {
        return SharedError(o.flatMap { JSONField.string($0, "error") } ?? (status == 401 ? "Войдите в аккаунт" : fallback))
    }

    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> (Int, [String: Any]?) {
        guard let url = URLBuilder.make(config.base, path: path) else { throw SharedError("Не получилось") }
        var extra: [String: String] = [:]
        var data: Data?
        if let b = body {
            extra["Content-Type"] = "application/json"
            data = try? JSONSerialization.data(withJSONObject: b)
        }
        let res = try await http.send(HTTPRequest(url: url, method: method, headers: await headers(extra), body: data, timeout: 25))
        return (res.status, BlinkJSON.object(res.text))
    }

    /// Профиль артиста или nil, если оферту ещё не принимали.
    public func me() async throws -> ArtistMe? {
        let (code, o) = try await send("api/artist/me")
        if !(200...299).contains(code) { throw fail(code, o, "Не получилось открыть кабинет") }
        guard let a = o?["artist"] as? [String: Any], let id = JSONField.string(a, "id") else { return nil }
        return ArtistMe(id: id, name: JSONField.string(a, "name") ?? "", handle: JSONField.string(a, "handle"), bio: JSONField.string(a, "bio"), offerAccepted: !(JSONField.string(a, "offer_accepted_at") ?? "").isEmpty)
    }

    public func acceptOffer(name: String) async throws -> ArtistMe {
        let (code, o) = try await send("api/artist/accept", method: "POST", body: ["name": name.trimmingCharacters(in: .whitespaces), "accept": true])
        if !(200...299).contains(code) { throw fail(code, o, "Не получилось сохранить профиль") }
        guard let a = o?["artist"] as? [String: Any] else { throw SharedError("Не получилось сохранить профиль") }
        return ArtistMe(id: JSONField.string(a, "id") ?? "", name: JSONField.string(a, "name") ?? "", handle: JSONField.string(a, "handle"), bio: JSONField.string(a, "bio"), offerAccepted: true)
    }

    public func mine() async throws -> [MyTrack] {
        let (code, o) = try await send("api/tracks/mine")
        if !(200...299).contains(code) { throw fail(code, o, "Не получилось загрузить релизы") }
        return (JSONField.array(o ?? [:], "tracks") ?? []).compactMap { e in
            guard let t = e as? [String: Any], let id = JSONField.string(t, "id") else { return nil }
            let s = t["streams"] as? [String: Any]
            return MyTrack(id: id, title: JSONField.string(t, "title") ?? "", releaseTitle: JSONField.string(t, "release_title") ?? "", status: JSONField.string(t, "status") ?? "", cover: JSONField.string(t, "cover_url"), releaseDate: JSONField.string(t, "release_date") ?? "", explicit: JSONField.bool(t, "explicit") == true, streamsTotal: s.flatMap { JSONField.int64($0, "total") } ?? 0, streamsMonth: s.flatMap { JSONField.int64($0, "this_month") } ?? 0)
        }
    }

    public func takedown(_ id: String) async throws {
        let (code, o) = try await send("api/tracks/" + id, method: "DELETE")
        if !(200...299).contains(code) { throw fail(code, o, "Не получилось снять трек") }
    }

    private func authorList(_ s: String) -> [String] {
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Что не заполнено, по-русски; nil, если можно отправлять. Те же поля, что проверяет сервер.
    public func check(_ d: UploadDraft, audio: UploadFile?, cover: UploadFile?) -> String? {
        if audio == nil { return "Прикрепите аудиофайл" }
        if cover == nil { return "Прикрепите обложку" }
        let required: [(String, String)] = [
            ("Название трека", d.title), ("Альбом или сингл", d.releaseTitle), ("Кто записал", d.phonogramMaker),
            ("Год", d.year), ("Жанр", d.genre), ("Язык", d.language), ("Дата релиза", d.releaseDate),
        ]
        for (label, v) in required where v.trimmingCharacters(in: .whitespaces).isEmpty { return "Не заполнено поле «\(label)»" }
        if authorList(d.authors).isEmpty { return "Укажите авторов музыки и текста" }
        if !d.rights { return "Подтвердите права на трек" }
        return nil
    }

    /// Загрузить трек. `onProgress` получает долю от 0 до 1. Возвращает id нового релиза.
    public func upload(_ d: UploadDraft, audio: UploadFile, cover: UploadFile, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        if let e = check(d, audio: audio, cover: cover) { throw SharedError(e) }
        let authors = authorList(d.authors).map { ["name": $0, "role": "музыка и текст"] }
        let authorsJson = String(decoding: (try? JSONSerialization.data(withJSONObject: authors)) ?? Data("[]".utf8), as: UTF8.self)
        let fields: [(String, String)] = [
            ("title", d.title.trimmingCharacters(in: .whitespaces)), ("release_title", d.releaseTitle.trimmingCharacters(in: .whitespaces)),
            ("authors", authorsJson), ("phonogram_maker", d.phonogramMaker.trimmingCharacters(in: .whitespaces)),
            ("year", d.year.trimmingCharacters(in: .whitespaces)), ("genre", d.genre.trimmingCharacters(in: .whitespaces)),
            ("language", d.language.trimmingCharacters(in: .whitespaces)), ("release_date", d.releaseDate.trimmingCharacters(in: .whitespaces)),
            ("samples", d.samples), ("lyrics", d.lyrics), ("explicit", String(d.explicit)), ("ai_used", String(d.aiUsed)), ("rights", String(d.rights)),
        ]
        let boundary = "blink-" + UUID().uuidString
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("upload-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Multipart.write(to: tmp, boundary: boundary, fields: fields, files: [("audio", audio), ("cover", cover)])
        guard let url = URLBuilder.make(config.base, path: "api/tracks") else { throw SharedError("Не получилось") }
        let req = HTTPRequest(url: url, method: "POST", headers: await headers(["Content-Type": "multipart/form-data; boundary=" + boundary]), body: nil, timeout: 120)
        let res = try await uploader.upload(req, bodyFile: tmp, onProgress: onProgress)
        let o = BlinkJSON.object(res.text)
        if !res.ok { throw fail(res.status, o, "Не получилось загрузить") }
        onProgress(1)
        return (o?["track"] as? [String: Any]).flatMap { JSONField.string($0, "id") } ?? ""
    }
}

/// Тело multipart/form-data пишем в файл кусками, чтобы аудио не жило целиком в памяти.
enum Multipart {
    static func write(to dest: URL, boundary: String, fields: [(String, String)], files: [(String, UploadFile)]) throws {
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let out = try FileHandle(forWritingTo: dest)
        defer { try? out.close() }
        func put(_ s: String) { out.write(Data(s.utf8)) }
        for (k, v) in fields {
            put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        for (k, f) in files {
            let safe = f.name.replacingOccurrences(of: "\"", with: "")
            put("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"; filename=\"\(safe)\"\r\nContent-Type: \(f.mime)\r\n\r\n")
            let input = try FileHandle(forReadingFrom: f.url)
            defer { try? input.close() }
            while true {
                let chunk = input.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                out.write(chunk)
            }
            put("\r\n")
        }
        put("--\(boundary)--\r\n")
    }
}
