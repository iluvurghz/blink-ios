import Foundation

/// Запросы Вспышки к серверу Blink (без входа). Формы ответов сняты с `waveRoute.js` и `charts.js` сайта.
public final class WaveApi: WaveSource {
    private let http: HTTPClient
    private let config: BlinkConfig

    public init(http: HTTPClient, config: BlinkConfig) {
        self.http = http
        self.config = config
    }

    private func get(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        guard let url = URLBuilder.make(config.base, path: path, query: query) else { throw ServerError(path, 0) }
        let res = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"], timeout: 15))
        if !res.ok { throw ServerError(path, res.status) }
        guard let o = BlinkJSON.object(res.text) else { throw ServerError(path + ": ответ не JSON", res.status) }
        return o
    }

    public func pool(seeds: [String]) async throws -> PoolResult {
        if seeds.isEmpty { return PoolResult(tracks: [], seedGenre: []) }
        let o = try await get("api/wave/pool", [("seeds", seeds.joined(separator: "|")), ("n", String(seeds.count))])
        let tracks = (JSONField.array(o, "tracks") ?? []).compactMap { e -> WaveCandidate? in
            guard let r = e as? [String: Any], let t = poolTrack(r) else { return nil }
            return WaveCandidate(track: t, src: JSONField.string(r, "src"), seed: JSONField.string(r, "seed"), hits: JSONField.int(r, "hits") ?? 1)
        }
        let genres = (JSONField.array(o, "seedGenre") ?? []).compactMap { e -> SeedGenre? in
            guard let r = e as? [String: Any], let q = JSONField.string(r, "q") else { return nil }
            return SeedGenre(query: q, genre: JSONField.string(r, "genre") ?? "", id: JSONField.string(r, "id"))
        }
        return PoolResult(tracks: tracks, seedGenre: genres)
    }

    public func genres(items: [String]) async throws -> [String: String] {
        if items.isEmpty { return [:] }
        let o = try await get("api/wave/genres", [("items", items.prefix(16).joined(separator: "|"))])
        guard let g = JSONField.object(o, "genres") else { return [:] }
        var out: [String: String] = [:]
        for k in g.keys { out[k] = JSONField.string(g, k) ?? "" }
        return out
    }

    public func similarIds(seed: String) async throws -> SimilarResult {
        let o = try await get("api/wave/similar-ids", [("seed", seed)])
        let ids = (JSONField.array(o, "ids") ?? []).compactMap { $0 as? String }
        return SimilarResult(ids: ids, genre: JSONField.string(o, "genre") ?? "")
    }

    public func topChart() async throws -> [Track] {
        let o = try await get("api/charts/top")
        return (JSONField.array(o, "items") ?? []).compactMap { e in
            guard let r = e as? [String: Any], let t = JSONField.object(r, "track") else { return nil }
            return chartTrack(t)
        }
    }

    public func periodChart(kind: String) async throws -> [Track] {
        let o = try await get("api/charts/" + kind)
        return (JSONField.array(o, "items") ?? []).compactMap { e in
            guard let r = e as? [String: Any] else { return nil }
            return periodTrack(r)
        }
    }

    func poolTrack(_ r: [String: Any]) -> Track? {
        guard let id = JSONField.string(r, "id"), let title = JSONField.string(r, "title"), let artist = JSONField.string(r, "artist") else { return nil }
        return Track(
            id: id,
            title: title,
            artist: artist,
            artistId: JSONField.string(r, "artistId"),
            album: JSONField.string(r, "album") ?? "",
            albumId: JSONField.string(r, "albumId"),
            artwork: JSONField.string(r, "artwork") ?? "",
            duration: JSONField.int(r, "duration") ?? 0,
            explicit: JSONField.bool(r, "explicit") ?? false,
            year: JSONField.string(r, "year") ?? "",
            genre: JSONField.string(r, "genre") ?? "",
            released: JSONField.string(r, "released"),
            source: JSONField.string(r, "source")
        )
    }

    /// Элемент главного чарта Яндекса (`track`) → трек; `released` берём из альбома.
    func chartTrack(_ t: [String: Any]) -> Track? {
        guard let id = JSONField.string(t, "id"), let title = JSONField.string(t, "title") else { return nil }
        let artists = (JSONField.array(t, "artists") ?? []).compactMap { ($0 as? [String: Any]).flatMap { JSONField.string($0, "name") } }
        if artists.isEmpty { return nil }
        let album = (JSONField.array(t, "albums") ?? []).first as? [String: Any]
        let version = JSONField.string(t, "version") ?? ""
        let cover = JSONField.string(t, "coverUri") ?? ""
        return Track(
            id: "cr" + id,
            title: version.isEmpty ? title : "\(title) (\(version))",
            artist: artists.joined(separator: ", "),
            album: album.flatMap { JSONField.string($0, "title") } ?? "",
            artwork: cover.isEmpty ? "" : "https://" + cover.replacingOccurrences(of: "%%", with: "600x600"),
            duration: JSONField.int64(t, "durationMs").map { BlinkApi.secondsFromMs($0) } ?? 0,
            explicit: JSONField.string(t, "contentWarning") == "explicit",
            year: album.flatMap { JSONField.string($0, "year") } ?? "",
            genre: album.flatMap { JSONField.string($0, "genre") } ?? "",
            released: album.flatMap { JSONField.string($0, "releaseDate") },
            source: "chart"
        )
    }

    /// Элемент недельного или месячного чарта новинок (id `cp…`, длительности и жанра в нём нет).
    func periodTrack(_ x: [String: Any]) -> Track? {
        guard let id = JSONField.string(x, "id"), let title = JSONField.string(x, "trackNameStr") else { return nil }
        var artist = JSONField.string(x, "artistNameStr") ?? ""
        if artist.isEmpty { artist = (JSONField.array(x, "artistNames") ?? []).compactMap { $0 as? String }.joined(separator: ", ") }
        if artist.isEmpty { return nil }
        return Track(id: "cp" + id, title: title, artist: artist, artwork: JSONField.string(x, "coverUrl") ?? "", source: "chart")
    }
}
