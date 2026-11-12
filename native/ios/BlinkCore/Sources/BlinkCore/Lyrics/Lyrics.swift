import Foundation

/// Слово с собственным временем (TTML). `from`/`to` указывают на место слова в тексте строки (UTF-16, как на сайте).
public struct LyricWord: Equatable, Sendable {
    public var t: Double
    public var end: Double?
    public var text: String
    public var from: Int?
    public var to: Int?

    public init(t: Double, end: Double? = nil, text: String, from: Int? = nil, to: Int? = nil) {
        self.t = t
        self.end = end
        self.text = text
        self.from = from
        self.to = to
    }
}

/// Строка текста со временем в секундах (как `{ t, end, text, words }` на сайте).
public struct LyricLine: Equatable, Sendable {
    public var t: Double
    public var end: Double?
    public var text: String
    public var words: [LyricWord]?

    public init(t: Double, end: Double? = nil, text: String, words: [LyricWord]? = nil) {
        self.t = t
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Что нашлось: строки со временем, простой текст или «инструментал».
public enum LyricsData: Equatable, Sendable {
    case synced([LyricLine])
    case plain([String])
    case instrumental

    /// Все строки подряд (для перевода и проверки языка).
    public var texts: [String] {
        switch self {
        case .synced(let l): return l.map { $0.text }
        case .plain(let p): return p
        case .instrumental: return []
        }
    }

    /// Текст в основном кириллицей: перевод не нужен (`isRussian` на сайте).
    public var isRussian: Bool {
        let s = texts.joined(separator: " ")
        var cyr = 0
        var lat = 0
        for u in s.lowercased().unicodeScalars {
            if (u.value >= 0x430 && u.value <= 0x44F) || u.value == 0x451 { cyr += 1 } else if u.value >= 0x61 && u.value <= 0x7A { lat += 1 }
        }
        return cyr > lat
    }
}

/// Сервис текстов не ответил: «нет текста» не запоминаем, можно повторить.
public struct LyricsUnavailable: Error, Equatable {}

/// Кусок строки для караоке: слово со временем или пробел/хвост без него.
public struct KaraokeSeg: Equatable, Sendable {
    public var text: String
    public var t: Double?
    public var end: Double?

    public init(text: String, t: Double? = nil, end: Double? = nil) {
        self.text = text
        self.t = t
        self.end = end
    }

    /// Насколько слово уже «залито» к моменту `time`: 0…1.
    public func progress(at time: Double) -> Double {
        guard let t = t, let e = end else { return 0 }
        return max(0, min(1, (time - t) / max(0.05, e - t)))
    }
}

/// Строка караоке: обычная или «• • •» на паузе.
public struct KaraokeRow: Equatable, Sendable {
    public var t: Double
    public var end: Double
    public var gap: Bool
    public var text: String
    public var segs: [KaraokeSeg]
}

/// Разметка караоке, как `buildLines` и `lineWords` в Stage.jsx.
public enum Karaoke {
    public static func build(_ synced: [LyricLine]) -> [KaraokeRow] {
        var out: [KaraokeRow] = []
        if let first = synced.first, first.t > 4 { out.append(KaraokeRow(t: 0, end: first.t, gap: true, text: "", segs: [])) }
        for (i, l) in synced.enumerated() {
            let next: LyricLine? = i + 1 < synced.count ? synced[i + 1] : nil
            let nextT = next?.t ?? l.t + 6
            if l.text.isEmpty {
                if nextT - l.t > 3 { out.append(KaraokeRow(t: l.t, end: nextT, gap: true, text: "", segs: [])) }
                continue
            }
            let end = (l.end.map { $0 < nextT } ?? false) ? l.end! : nextT
            let line = LyricLine(t: l.t, end: end, text: l.text, words: l.words)
            out.append(KaraokeRow(t: l.t, end: end, gap: false, text: l.text, segs: words(line)))
            if next != nil, nextT - end > 4 { out.append(KaraokeRow(t: end, end: nextT, gap: true, text: "", segs: [])) }
        }
        return out
    }

    /// Слова строки: у TTML свои времена, у обычной строки слова растянуты на всю строку (длинные дольше).
    public static func words(_ l: LyricLine) -> [KaraokeSeg] {
        let text = l.text as NSString
        let lineEnd = l.end ?? l.t + 6
        let timed = (l.words ?? []).filter { $0.from != nil && $0.to != nil }
        if !timed.isEmpty {
            var out: [KaraokeSeg] = []
            var at = 0
            for (k, w) in timed.enumerated() {
                let from = w.from!, to = w.to!
                if from > at { out.append(KaraokeSeg(text: text.substring(with: NSRange(location: at, length: from - at)))) }
                let next: LyricWord? = k + 1 < timed.count ? timed[k + 1] : nil
                out.append(KaraokeSeg(text: text.substring(with: NSRange(location: from, length: to - from)), t: w.t, end: w.end ?? next?.t ?? lineEnd))
                at = to
            }
            if at < text.length { out.append(KaraokeSeg(text: text.substring(from: at))) }
            return out
        }
        let parts = splitKeepingSpaces(l.text)
        let weight = parts.reduce(0) { $0 + (isSpace($1) ? 0 : ($1 as NSString).length + 1) }
        let w = Double(max(1, weight))
        let span = max(0.6, min(lineEnd - l.t - 0.12, max(3, Double(text.length) * 0.25)))
        var t = l.t
        return parts.map { s in
            if isSpace(s) { return KaraokeSeg(text: s) }
            let d = span * Double((s as NSString).length + 1) / w
            let seg = KaraokeSeg(text: s, t: t, end: t + d)
            t += d
            return seg
        }
    }

    /// Строка, что звучит сейчас, или -1 до первой.
    public static func active(_ rows: [KaraokeRow], at t: Double) -> Int {
        var i = -1
        for (k, r) in rows.enumerated() {
            if r.t <= t { i = k } else { break }
        }
        return i
    }

    /// Обратный отсчёт 3·2·1 в конце паузы, 0 если не нужен.
    public static func countdown(_ rows: [KaraokeRow], active i: Int, at t: Double) -> Int {
        guard i >= 0, i < rows.count, rows[i].gap, i + 1 < rows.count else { return 0 }
        let left = rows[i + 1].t - t
        return left > 0 && left <= 3 ? Int(left.rounded(.up)) : 0
    }

    private static func isSpace(_ s: String) -> Bool {
        return !s.isEmpty && s.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    /// `text.split(/(\s+)/).filter(Boolean)`: слова и пробелы между ними по очереди.
    static func splitKeepingSpaces(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var curSpace: Bool?
        for ch in text {
            let sp = ch.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if curSpace != nil, curSpace != sp {
                out.append(cur)
                cur = ""
            }
            cur.append(ch)
            curSpace = sp
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// TTML (Apple-style): строки из `<p begin end>`, слова из `<span begin>` внутри (lib/ttml.js).
public enum Ttml {
    static func seconds(_ raw: String?) -> Double? {
        guard let raw = raw else { return nil }
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return nil }
        if let m = match("^(\\d+(?:\\.\\d+)?)(h|ms|m|s)$", v) {
            let n = Double(m[1]) ?? 0
            switch m[2] {
            case "h": return n * 3600
            case "m": return n * 60
            case "ms": return n * 0.001
            default: return n
            }
        }
        if let m = match("^(?:(\\d+):)?(\\d+):(\\d+(?:\\.\\d+)?)$", v) {
            return (Double(m[1]) ?? 0) * 3600 + (Double(m[2]) ?? 0) * 60 + (Double(m[3]) ?? 0)
        }
        return Double(v)
    }

    public static func parse(_ xml: String) -> [LyricLine]? {
        guard
            let pRe = try? NSRegularExpression(pattern: "<(?:[\\w-]+:)?p\\b([^>]*)>([\\s\\S]*?)</(?:[\\w-]+:)?p>"),
            let spanRe = try? NSRegularExpression(pattern: "<(?:[\\w-]+:)?span\\b([^>]*)>([^<]*)</(?:[\\w-]+:)?span>"),
            let tagRe = try? NSRegularExpression(pattern: "<[^>]+>"),
            let wsRe = try? NSRegularExpression(pattern: "\\s+")
        else { return nil }
        let ns = xml as NSString
        var lines: [LyricLine] = []
        for pm in pRe.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: pm.range(at: 1))
            guard let t = seconds(attr(attrs, "begin")) else { continue }
            let end = seconds(attr(attrs, "end"))
            let inner = ns.substring(with: pm.range(at: 2))
            let innerNS = inner as NSString
            var words: [LyricWord] = []
            for sm in spanRe.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                let sa = innerNS.substring(with: sm.range(at: 1))
                guard let wt = seconds(attr(sa, "begin")) else { continue }
                words.append(LyricWord(t: wt, end: seconds(attr(sa, "end")), text: decode(innerNS.substring(with: sm.range(at: 2)))))
            }
            let stripped = decode(tagRe.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: innerNS.length), withTemplate: ""))
            let text = wsRe.stringByReplacingMatches(in: stripped, range: NSRange(location: 0, length: (stripped as NSString).length), withTemplate: " ")
                .trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let textNS = text as NSString
            var at = 0
            for i in words.indices {
                let w = words[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if w.isEmpty { continue }
                let r = textNS.range(of: w, range: NSRange(location: at, length: textNS.length - at))
                if r.location != NSNotFound {
                    words[i].from = r.location
                    at = r.location + r.length
                    words[i].to = at
                }
            }
            lines.append(LyricLine(t: t, end: end, text: text, words: words.isEmpty ? nil : words))
        }
        lines.sort { $0.t < $1.t }
        return lines.isEmpty ? nil : lines
    }

    private static func attr(_ attrs: String, _ name: String) -> String? {
        guard let m = match("(?:^|\\s)" + name + "\\s*=\\s*\"([^\"]*)\"", attrs) ?? match("(?:^|\\s)" + name + "\\s*=\\s*'([^']*)'", attrs) else { return nil }
        return m[1]
    }

    static func decode(_ s: String) -> String {
        if !s.contains("&") { return s }
        var out = s
        if let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                if let n = num, let u = Unicode.Scalar(n) { result.unicodeScalars.append(u) } else { result += ns.substring(with: m.range) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
}

/// Тексты песен, как `api.lyrics` + `useLyrics` на сайте: свои треки Blink (TTML, LRC, текст), остальные через LRCLIB
/// и lyrics.ovh на сервере Blink. Найденное держим в памяти на время работы.
public final class LyricsApi: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let tokens: TokenProvider?
    private let lock = NSLock()
    private var cache: [String: LyricsData?] = [:]
    private var translations: [String: [String: String]] = [:]

    public init(http: HTTPClient, config: BlinkConfig, tokens: TokenProvider?) {
        self.http = http
        self.config = config
        self.tokens = tokens
    }

    /// Уже найденное для трека (двойной nil = ещё не искали, `.some(nil)` = текста нет).
    public func cached(_ id: String) -> LyricsData?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[id]
    }

    public func load(_ track: Track) async throws -> LyricsData? {
        if let hit = cached(track.id) { return hit }
        let data = try await fetch(track)
        lock.lock()
        cache[track.id] = data
        lock.unlock()
        return data
    }

    private func fetch(_ track: Track) async throws -> LyricsData? {
        if track.source == Track.sourceBlink {
            if let lic = track.lic, let xml = await ttml(lic), let lines = Ttml.parse(xml) { return .synced(lines) }
            if let lrc = track.lrc, !lrc.isEmpty { return .synced(LyricsApi.fromLrc(lrc)) }
            if let txt = track.lyrics, !txt.isEmpty { return .plain(LyricsApi.lines(txt)) }
            return nil
        }
        let title = LyricsApi.cleanTitle(track.title)
        let main = LyricsApi.mainArtist(track.artist)
        var q: [(String, String)] = [("track_name", title), ("artist_name", main)]
        if !track.album.isEmpty { q.append(("album_name", track.album)) }
        if track.duration > 0 { q.append(("duration", String(track.duration))) }
        var down = false
        var plain: LyricsData?
        do {
            let got = LyricsApi.pick(try await json("api/lrclib/get", q) as? [String: Any])
            if let g = got, case .synced = g { return g }
            if got == .instrumental { return .instrumental }
            plain = got
        } catch let e as Status {
            down = e.code != 404
        } catch {
            down = true
        }
        if !down {
            do {
                if let list = try await json("api/lrclib/search", [("track_name", title), ("artist_name", track.artist)]) as? [Any], !list.isEmpty {
                    let nt = LyricsApi.norm(title)
                    let scored = list.compactMap { $0 as? [String: Any] }.map { d -> ([String: Any], Double) in
                        var s = 0.0
                        if LyricsApi.norm(JSONField.string(d, "trackName") ?? "") == nt { s += 5 }
                        if let sl = JSONField.string(d, "syncedLyrics"), !sl.isEmpty { s += 4 }
                        if track.duration > 0, let dd = JSONField.int(d, "duration") ?? (d["duration"] as? Double).map({ Int($0) }), dd > 0 {
                            s -= min(6, Double(abs(dd - track.duration)) / 2)
                        }
                        return (d, s)
                    }.sorted { $0.1 > $1.1 }
                    if let best = scored.first, let got = LyricsApi.pick(best.0) { return got }
                }
            } catch let e as Status {
                down = e.code != 404
            } catch {
                down = true
            }
        }
        if let p = plain { return p }
        if let d = try? await json("api/lyricsovh", [("artist", main), ("title", title)]) as? [String: Any], var text = JSONField.string(d, "lyrics") {
            if let re = try? NSRegularExpression(pattern: "^Paroles de la chanson.*\\r?\\n") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return .plain(LyricsApi.lines(text)) }
        }
        if down { throw LyricsUnavailable() }
        return nil
    }

    private struct Status: Error { let code: Int }

    private func json(_ path: String, _ q: [(String, String)]) async throws -> Any? {
        guard let url = URLBuilder.make(config.base, path: path, query: q) else { throw Status(code: 400) }
        let res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 7))
        if !res.ok { throw Status(code: res.status) }
        return try? JSONSerialization.jsonObject(with: res.data, options: [.fragmentsAllowed])
    }

    private func ttml(_ lic: String) async -> String? {
        guard let url = URLBuilder.make(config.base, path: "api/tracks/\(lic)/ttml") else { return nil }
        var h: [String: String] = [:]
        if let t = await tokens?.accessToken() { h["Authorization"] = "Bearer " + t }
        guard let res = try? await http.send(HTTPRequest(url: url, headers: h, timeout: 10)), res.ok else { return nil }
        let text = res.text
        return text.isEmpty ? nil : text
    }

    // MARK: перевод

    /// Перевод строк на русский: исходная строка → перевод. Пусто, если текст и так русский.
    public func translate(_ id: String, _ texts: [String]) async throws -> [String: String] {
        lock.lock()
        let hit = translations[id]
        lock.unlock()
        if let h = hit { return h }
        var seen = Set<String>()
        let uniq = texts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        let lang = LyricsApi.guessLang(uniq)
        if lang == "ru" || uniq.isEmpty { return [:] }
        var map: [String: String] = [:]
        var backup = false
        var i = 0
        while i < uniq.count {
            let part = Array(uniq[i..<min(uniq.count, i + 25)])
            var out: [String]?
            if !backup {
                if let o = try? await google(part), o.count == part.count { out = o } else { backup = true }
            }
            if out == nil {
                var res: [String] = []
                for t in part { res.append((try? await mymemory([t], lang))?.first ?? "") }
                out = res
            }
            for (k, t) in part.enumerated() where k < (out?.count ?? 0) && !(out![k].isEmpty) { map[t] = out![k] }
            i += 25
        }
        if map.isEmpty { throw SharedError("Перевод сейчас недоступен") }
        lock.lock()
        translations[id] = map
        lock.unlock()
        return map
    }

    private func google(_ lines: [String]) async throws -> [String] {
        guard let d = try await json("api/translate/google", [("q", lines.joined(separator: "\n"))]) as? [Any], let segs = d.first as? [Any] else { throw SharedError("") }
        let text = segs.map { (($0 as? [Any])?.first as? String) ?? "" }.joined()
        return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func mymemory(_ lines: [String], _ from: String) async throws -> [String] {
        guard let d = try await json("api/translate/mymemory", [("q", lines.joined(separator: "\n")), ("from", from)]) as? [String: Any],
              let rd = d["responseData"] as? [String: Any], (JSONField.int(d, "responseStatus") ?? Int(JSONField.string(d, "responseStatus") ?? "") ?? 0) == 200
        else { throw SharedError("") }
        return (JSONField.string(rd, "translatedText") ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: помощники (как в api.js)

    static func pick(_ d: [String: Any]?) -> LyricsData? {
        guard let d = d else { return nil }
        if JSONField.bool(d, "instrumental") == true { return .instrumental }
        if let s = JSONField.string(d, "syncedLyrics"), !s.isEmpty { return .synced(fromLrc(s)) }
        if let p = JSONField.string(d, "plainLyrics"), !p.isEmpty { return .plain(lines(p)) }
        return nil
    }

    public static func fromLrc(_ text: String) -> [LyricLine] {
        // Слова из расширенного LRC сайт не подсвечивает отдельно: строка растягивается целиком.
        return Lrc.parse(text).map { LyricLine(t: Double($0.timeMs) / 1000, text: $0.text) }
    }

    static func lines(_ text: String) -> [String] {
        return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    static func cleanTitle(_ title: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "\\s*\\((feat|with|prod)\\.?[^)]*\\)", options: [.caseInsensitive]) else { return title }
        let ns = title as NSString
        var out = title
        if let m = re.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) { out = ns.replacingCharacters(in: m.range, with: "") }
        return out.trimmingCharacters(in: .whitespaces)
    }

    public static func mainArtist(_ artist: String) -> String {
        guard let re = try? NSRegularExpression(pattern: ",|&| feat", options: [.caseInsensitive]) else { return artist }
        let ns = artist as NSString
        if let m = re.firstMatch(in: artist, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
        }
        return artist.trimmingCharacters(in: .whitespaces)
    }

    static func norm(_ s: String) -> String {
        var t = s.lowercased()
        for p in ["\\(.*?\\)|\\[.*?\\]", "feat\\..*$", "[^\\p{L}\\p{N} ]", "\\s+"] {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let with = p == "\\(.*?\\)|\\[.*?\\]" || p == "feat\\..*$" ? "" : " "
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: with)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func guessLang(_ texts: [String]) -> String {
        let s = texts.joined(separator: " ")
        var cyr = 0
        var lat = 0
        for u in s.unicodeScalars {
            if u.value >= 0x400 && u.value <= 0x4FF { cyr += 1 } else if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { lat += 1 }
        }
        if cyr > lat { return "ru" }
        let low = s.lowercased()
        if low.contains(where: { "ñ¿¡".contains($0) }) { return "es" }
        if low.contains(where: { "äöüß".contains($0) }) { return "de" }
        if low.contains(where: { "àâçéèêëîïôûùœ".contains($0) }) { return "fr" }
        return "en"
    }
}

/// Фото артиста для плеера (lib/photos.js): Deezer через сервер Blink, точное совпадение имени. Держим в памяти.
public final class ArtistPhotos: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(http: HTTPClient, config: BlinkConfig) {
        self.http = http
        self.config = config
    }

    public func photo(_ track: Track) async -> String? {
        let name = LyricsApi.mainArtist(track.artist)
        if name.isEmpty { return nil }
        let key = name.lowercased()
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let h = hit { return h }
        var found: String?
        if let url = URLBuilder.make(config.base, path: "api/deezer/artist", query: [("q", name)]),
           let res = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 6)), res.ok,
           let o = BlinkJSON.object(res.text), let list = JSONField.array(o, "data") {
            let match = list.compactMap { $0 as? [String: Any] }.first { (JSONField.string($0, "name") ?? "").lowercased() == key }
            if let u = match.flatMap({ JSONField.string($0, "picture_xl") }), !u.contains("/artist//"), !u.contains("/images/artist//") { found = u }
            lock.lock()
            cache[key] = .some(found)
            lock.unlock()
        }
        return found
    }
}
