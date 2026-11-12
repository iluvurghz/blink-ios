import Foundation

public struct SimilarTrack: Equatable, Sendable {
    public var artist: String
    public var title: String
}

public struct SimilarArtist: Equatable, Sendable {
    public var name: String
    public var match: Double
}

/// Last.fm через наш сервер (`/api/lastfm`): ключ лежит на сервере. Без сети или ключа отвечает «ничего».
public final class LastfmApi: @unchecked Sendable {
    private let http: HTTPClient
    private let config: BlinkConfig
    private let lock = NSLock()
    private var cache: [String: Any] = [:]

    public init(http: HTTPClient, config: BlinkConfig) {
        self.http = http
        self.config = config
    }

    private func call(_ params: [(String, String)]) async -> [String: Any]? {
        guard let url = URLBuilder.make(config.base, path: "api/lastfm", query: params),
              let res = try? await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 12)), res.ok,
              let o = BlinkJSON.object(res.text), o["error"] == nil else { return nil }
        return o
    }

    private func lookup(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    private func store(_ key: String, _ value: Any) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = value
    }

    private func cached<T>(_ key: String, _ load: () async -> T?) async -> T? {
        if let hit = lookup(key) as? T { return hit }
        guard let v = await load() else { return nil }
        store(key, v)
        return v
    }

    /// Слушатели артиста за всё время; nil, если Last.fm не знает такого (или подменил тёзкой).
    public func listeners(_ artist: String) async -> Int64? {
        return await cached("l:" + artist) { () async -> Int64? in
            let want = LastfmApi.mainName(artist)
            guard let d = await call([("method", "artist.getinfo"), ("artist", want)]), let a = d["artist"] as? [String: Any],
                  LastfmApi.squash(JSONField.string(a, "name") ?? "") == LastfmApi.squash(want) else { return nil }
            return (a["stats"] as? [String: Any]).flatMap { JSONField.int64($0, "listeners") }
        }
    }

    public func similarTracks(artist: String, title: String, limit: Int = 12) async -> [SimilarTrack] {
        return await cached("st:\(artist):\(title)") { () async -> [SimilarTrack]? in
            guard let d = await call([("method", "track.getsimilar"), ("artist", LastfmApi.mainName(artist)), ("track", LastfmApi.cleanTitle(title)), ("limit", String(limit))]) else { return nil }
            let list = ((d["similartracks"] as? [String: Any])?["track"] as? [Any]) ?? []
            return list.compactMap { e in
                guard let t = e as? [String: Any], let n = JSONField.string(t, "name"), let a = (t["artist"] as? [String: Any]).flatMap({ JSONField.string($0, "name") }) else { return nil }
                return SimilarTrack(artist: a, title: n)
            }
        } ?? []
    }

    public func similarArtists(_ name: String, limit: Int = 15) async -> [SimilarArtist] {
        return await cached("sa:" + name) { () async -> [SimilarArtist]? in
            guard let d = await call([("method", "artist.getsimilar"), ("artist", LastfmApi.mainName(name)), ("limit", String(limit))]) else { return nil }
            let own = LastfmApi.mainName(name).lowercased()
            let list = ((d["similarartists"] as? [String: Any])?["artist"] as? [Any]) ?? []
            return list.compactMap { e -> SimilarArtist? in
                guard let a = e as? [String: Any], let n = JSONField.string(a, "name") else { return nil }
                return SimilarArtist(name: n, match: Double(JSONField.string(a, "match") ?? "") ?? 0)
            }.filter { $0.match >= 0.35 && !$0.name.lowercased().contains(own) }
        } ?? []
    }

    public static func mainName(_ s: String) -> String {
        var cut = s
        for sep in [",", "&", " feat. ", " feat ", " ft. ", " ft ", " x ", " X "] {
            if let r = cut.range(of: sep, options: .caseInsensitive) { cut = String(cut[cut.startIndex..<r.lowerBound]) }
        }
        return cut.trimmingCharacters(in: .whitespaces)
    }

    public static func cleanTitle(_ s: String) -> String {
        var t = s
        while let r = t.range(of: "\\s*[(\\[](feat|with|prod)[^)\\]]*[)\\]]", options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func squash(_ s: String) -> String { return String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
}
