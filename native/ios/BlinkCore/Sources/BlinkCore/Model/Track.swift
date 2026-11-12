import Foundation

/// Трек в той же форме, что у сайта и ПК-версии. Лайки и плейлисты на сервере хранят такие объекты
/// целиком, поэтому `id` обязан совпадать: `String(trackId)` у iTunes/Яндекса, `b:<uuid>` у лицензионных,
/// `cr<id>` у подборок, `j:<id>` у Jamendo.
public struct Track: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let sourceBlink = "blink"

    public var id: String
    public var title: String
    public var artist: String
    public var artistId: String?
    public var album: String
    public var albumId: String?
    public var artwork: String
    public var duration: Int
    public var explicit: Bool
    public var year: String
    public var genre: String
    /// Дата выхода (ISO), если сервер её отдаёт: нужна «Вспышке» для свежести.
    public var released: String?
    public var source: String?
    public var lic: String?
    public var lrc: String?
    public var lyrics: String?
    /// Артист разрешил офлайн-копии. nil у нелицензионных треков.
    public var offline: Bool?
    public var stream: String?

    public init(
        id: String,
        title: String,
        artist: String,
        artistId: String? = nil,
        album: String = "",
        albumId: String? = nil,
        artwork: String = "",
        duration: Int = 0,
        explicit: Bool = false,
        year: String = "",
        genre: String = "",
        released: String? = nil,
        source: String? = nil,
        lic: String? = nil,
        lrc: String? = nil,
        lyrics: String? = nil,
        offline: Bool? = nil,
        stream: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = artistId
        self.album = album
        self.albumId = albumId
        self.artwork = artwork
        self.duration = duration
        self.explicit = explicit
        self.year = year
        self.genre = genre
        self.released = released
        self.source = source
        self.lic = lic
        self.lrc = lrc
        self.lyrics = lyrics
        self.offline = offline
        self.stream = stream
    }

    /// Трек из лицензионного каталога Blink (`lic_tracks`).
    public var isLicensed: Bool {
        return source == Track.sourceBlink && !(lic ?? "").isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, artistId, album, albumId, artwork, duration, explicit, year, genre, released
        case source, lic, lrc, lyrics, offline, stream
    }

    /// Мягкий разбор: сайт мог сохранить число строкой и наоборот, лишних полей и пропусков не боимся.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: k) { return String(i) }
            return nil
        }
        // id, название и артист обязательны, как в Android-ядре: без них это не трек, а обломок.
        guard let id = str(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "id"))
        }
        guard let title = str(.title) else {
            throw DecodingError.keyNotFound(CodingKeys.title, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "title"))
        }
        guard let artist = str(.artist) else {
            throw DecodingError.keyNotFound(CodingKeys.artist, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "artist"))
        }
        self.id = id
        self.title = title
        self.artist = artist
        self.artistId = str(.artistId)
        self.album = str(.album) ?? ""
        self.albumId = str(.albumId)
        self.artwork = str(.artwork) ?? ""
        if let i = try? c.decodeIfPresent(Int.self, forKey: .duration) {
            self.duration = i
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .duration) {
            self.duration = Int(d.rounded())
        } else {
            self.duration = 0
        }
        self.explicit = (try? c.decodeIfPresent(Bool.self, forKey: .explicit)) ?? false
        self.year = str(.year) ?? ""
        self.genre = str(.genre) ?? ""
        self.released = str(.released)
        self.source = str(.source)
        self.lic = str(.lic)
        self.lrc = str(.lrc)
        self.lyrics = str(.lyrics)
        self.offline = (try? c.decodeIfPresent(Bool.self, forKey: .offline)) ?? nil
        self.stream = str(.stream)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(artistId, forKey: .artistId)
        try c.encode(album, forKey: .album)
        try c.encodeIfPresent(albumId, forKey: .albumId)
        try c.encode(artwork, forKey: .artwork)
        try c.encode(duration, forKey: .duration)
        try c.encode(explicit, forKey: .explicit)
        try c.encode(year, forKey: .year)
        try c.encode(genre, forKey: .genre)
        try c.encodeIfPresent(released, forKey: .released)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(lic, forKey: .lic)
        try c.encodeIfPresent(lrc, forKey: .lrc)
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        try c.encodeIfPresent(offline, forKey: .offline)
        try c.encodeIfPresent(stream, forKey: .stream)
    }

    /// Трек как непрозрачный JSON для записи манифеста.
    public func asJSON() -> JSONValue? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Обратно из непрозрачной копии.
    public static func from(json: JSONValue?) -> Track? {
        guard let json = json, let data = try? JSONEncoder().encode(json) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: data)
    }
}
