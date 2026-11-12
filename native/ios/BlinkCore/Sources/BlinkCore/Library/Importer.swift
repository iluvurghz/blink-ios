import Foundation

/// Строка списка для переноса: исполнитель и название.
public struct TrackRef: Equatable, Sendable {
    public var artist: String
    public var title: String
    public init(artist: String, title: String) {
        self.artist = artist
        self.title = title
    }
}

public enum ImportSource: CaseIterable, Sendable {
    case spotify, yandex

    public var title: String { return self == .spotify ? "Spotify" : "Яндекс Музыки" }
    var api: String { return self == .spotify ? "spotify" : "yandex" }

    var pattern: String {
        switch self {
        case .spotify: return "open\\.spotify\\.com/(?:intl-[a-z-]+/)?(?:playlist|album)/[A-Za-z0-9]+|spotify:(?:playlist|album):[A-Za-z0-9]+"
        case .yandex: return "(?:https?://)?music\\.yandex\\.[a-z]{2,3}/(?:users/[^/\\s]+/(?:playlists/\\d+|tracks)|playlists/[A-Za-z0-9.-]+|album/\\d+(?:/track/\\d+)?)"
        }
    }

    var closed: String {
        switch self {
        case .spotify: return "Spotify не отдал этот плейлист. Открытые плейлисты и альбомы переносятся, а закрытые и подборки самого Spotify нет"
        case .yandex: return "Яндекс не отдал этот плейлист. Сделайте его публичным (для «Мне нравится» откройте профиль в настройках Яндекс Музыки) и попробуйте ещё раз"
        }
    }

    func find(in text: String) -> String? {
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }
}

public struct ImportError: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public struct ImportRun: Equatable, Sendable {
    public var title: String
    public var found: [Track]
    public var missed: [TrackRef]
    public var total: Int
}

/// Перенос музыки: ссылка Spotify/Яндекс, CSV из TuneMyMusic или список «Артист — Название». Порт `Import.jsx`.
public final class Importer: @unchecked Sendable {
    public static let max = 2000

    private let http: HTTPClient
    private let config: BlinkConfig
    private let api: BlinkApi

    public init(http: HTTPClient, config: BlinkConfig, api: BlinkApi) {
        self.http = http
        self.config = config
        self.api = api
    }

    /// Читает список по ссылке через сервер Blink.
    public func read(_ src: ImportSource, _ link: String) async throws -> (String, [TrackRef]) {
        guard let url = URLBuilder.make(config.base, path: "api/\(src.api)/list", query: [("url", link)]) else { throw ImportError("Не получилось прочитать ссылку, попробуйте ещё раз") }
        let res: HTTPResponse
        do {
            res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 40))
        } catch {
            throw ImportError("Не получилось прочитать ссылку, попробуйте ещё раз")
        }
        let o = BlinkJSON.object(res.text)
        let items = o?["items"] as? [Any]
        if res.ok, let items = items, !items.isEmpty {
            var refs: [TrackRef] = []
            for e in items {
                guard let d = e as? [String: Any] else { continue }
                let r = TrackRef(artist: JSONField.string(d, "artist") ?? "", title: JSONField.string(d, "title") ?? "")
                if !r.title.isEmpty { refs.append(r) }
            }
            return (o.flatMap { JSONField.string($0, "name") } ?? "", refs)
        }
        if res.status == 404 || (res.ok && items != nil) { throw ImportError(src.closed) }
        if src == .yandex { throw ImportError("Яндекс Музыка не ответила. Если вы не в России, она может быть недоступна: попробуйте ещё раз или загрузите CSV из TuneMyMusic") }
        throw ImportError("Не получилось прочитать ссылку, попробуйте ещё раз")
    }

    /// Весь перенос: читаем (если ссылка), ищем каждый трек в четыре потока, `progress(сделано, всего)` по ходу.
    public func run(_ text: String, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ImportRun {
        var title = ""
        var list: [TrackRef]
        if let src = Importer.sourceOf(text), let link = src.find(in: text) {
            let (name, refs) = try await read(src, link)
            title = name
            list = refs
        } else {
            list = Importer.parseList(text)
        }
        let refs = Array(list.prefix(Importer.max))
        if refs.isEmpty { throw ImportError("Не нашёл треков в тексте") }
        let counter = ProgressBox(total: refs.count, report: progress)
        var found = [Track?](repeating: nil, count: refs.count)
        await withTaskGroup(of: (Int, Track?).self) { group in
            var next = 0
            func launch() {
                guard next < refs.count else { return }
                let i = next
                next += 1
                group.addTask { [self] in
                    let t = await self.match(refs[i])
                    counter.step()
                    return (i, t)
                }
            }
            for _ in 0..<min(4, refs.count) { launch() }
            while let (i, t) = await group.next() {
                found[i] = t
                launch()
            }
        }
        var seen = Set<String>()
        let hits = found.compactMap { $0 }.filter { seen.insert($0.id).inserted }
        var missed: [TrackRef] = []
        for (i, r) in refs.enumerated() where found[i] == nil { missed.append(r) }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? "Перенесённое" : title
        return ImportRun(title: String(name.prefix(80)), found: hits, missed: missed, total: refs.count)
    }

    public func match(_ ref: TrackRef) async -> Track? {
        guard let tracks = try? await api.search((ref.artist + " " + ref.title).trimmingCharacters(in: .whitespaces)) else { return nil }
        return Importer.pick(ref, tracks)
    }

    public static func sourceOf(_ text: String) -> ImportSource? {
        return ImportSource.allCases.first { $0.find(in: text) != nil }
    }

    static func norm(_ s: String) -> String {
        let parts = s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        return parts.joined(separator: " ")
    }

    /// Лучший трек из выдачи: артист и название, иначе хотя бы артист.
    public static func pick(_ ref: TrackRef, _ tracks: [Track]) -> Track? {
        let first = ref.artist.split(whereSeparator: { $0 == "," || $0 == "&" }).first.map(String.init) ?? ""
        let a = norm(first)
        let title = ref.title.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        let t = norm(title)
        return tracks.first { norm($0.artist).contains(a) && norm($0.title).contains(t) } ?? tracks.first { norm($0.artist).contains(a) }
    }

    private static func splitCsv(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var q = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if q && i + 1 < chars.count && chars[i + 1] == "\"" {
                    cur.append("\"")
                    i += 1
                } else {
                    q.toggle()
                }
            } else if (c == "," || c == ";") && !q {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else {
                cur.append(c)
            }
            i += 1
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// CSV из TuneMyMusic или строки «Артист — Название».
    public static func parseList(_ text: String) -> [TrackRef] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let head = splitCsv(lines[0]).map { $0.lowercased() }
        func idx(_ pattern: String) -> Int? { return head.firstIndex { $0.range(of: pattern, options: .regularExpression) != nil } }
        if let ti = idx("track|title|трек|назв"), let ai = idx("artist|исполн|артист"), ti != ai {
            return lines.dropFirst().map(splitCsv).map { r in
                TrackRef(artist: ai < r.count ? r[ai] : "", title: ti < r.count ? r[ti] : "")
            }.filter { !$0.title.isEmpty }
        }
        return lines.map { l in
            let m = l.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " – ") }.flatMap { $0.components(separatedBy: " — ") }
            return m.count >= 2 ? TrackRef(artist: m[0].trimmingCharacters(in: .whitespaces), title: m.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)) : TrackRef(artist: "", title: l)
        }.filter { !$0.title.isEmpty }
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private let total: Int
    private let report: @Sendable (Int, Int) -> Void

    init(total: Int, report: @escaping @Sendable (Int, Int) -> Void) {
        self.total = total
        self.report = report
    }

    func step() {
        lock.lock()
        done += 1
        let d = done
        lock.unlock()
        report(d, total)
    }
}
