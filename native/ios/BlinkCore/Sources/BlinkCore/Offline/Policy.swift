import Foundation

/// Что ставим в очередь: ключ, источник и описание трека.
public struct Candidate: Equatable, Sendable {
    public let key: String
    public let source: String
    public let id: String
    public let meta: JobMeta

    public init(key: String, source: String, id: String, meta: JobMeta) {
        self.key = key
        self.source = source
        self.id = id
        self.meta = meta
    }
}

/// Что можно сохранять: только лицензионный каталог Blink (`source=blink`, `offline_allowed=true`) и только с Blink+.
/// Остальные источники играют только онлайн. Список один и тот же с серверным OFFLINE_SOURCES.
public enum OfflinePolicy {
    public static let allowedSources: Set<String> = [Track.sourceBlink]

    public enum Decision: Equatable, Sendable {
        case allowed
        case denied(OfflineCode, String?)

        /// Текст для человека; у разрешения его нет.
        public var text: OfflineText? {
            if case .denied(let code, let reason) = self { return OfflineTexts.of(code, reason) }
            return nil
        }
    }

    public static func check(_ track: Track, signedIn: Bool, plusActive: Bool) -> Decision {
        let source = track.source ?? ""
        if !allowedSources.contains(source) || (track.lic ?? "").isEmpty { return .denied(.notAllowed, "source") }
        if track.offline == false { return .denied(.notAllowed, "artist") }
        if !signedIn { return .denied(.notAllowed, "auth") }
        if !plusActive { return .denied(.notAllowed, "plus") }
        return .allowed
    }

    /// Можно ли показывать кнопку «Сохранить» в принципе (без учёта входа и подписки).
    public static func savable(_ track: Track) -> Bool {
        return allowedSources.contains(track.source ?? "") && !(track.lic ?? "").isEmpty && track.offline != false
    }

    /// Сохранённое играет с диска всегда первым; без сети нужна активная подписка по последней известной дате.
    public static func canPlaySaved(online: Bool, plusUntilMs: Int64?, nowMs: Int64) -> Bool {
        if online { return true }
        guard let until = plusUntilMs else { return false }
        return until > nowMs
    }

    public static func keyOf(_ track: Track) -> String? {
        guard savable(track), let lic = track.lic else { return nil }
        return Key.of(Track.sourceBlink, lic)
    }

    public static func candidate(_ track: Track) -> Candidate? {
        guard savable(track), let lic = track.lic, !lic.isEmpty else { return nil }
        return Candidate(
            key: Key.of(Track.sourceBlink, lic),
            source: Track.sourceBlink,
            id: lic,
            meta: JobMeta(
                title: track.title,
                artist: track.artist,
                album: track.album,
                cover: track.artwork,
                duration: track.duration,
                offlineAllowed: track.offline != false,
                track: track.asJSON()
            )
        )
    }
}
