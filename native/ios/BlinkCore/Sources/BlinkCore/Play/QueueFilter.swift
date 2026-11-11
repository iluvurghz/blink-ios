import Foundation

/// Очередь, которую можно проиграть без интернета. `skipped` это сколько треков выкинули ради тоста «Пропущено N».
public struct OfflineQueue: Equatable, Sendable {
    public let tracks: [Track]
    public let startIndex: Int
    public let skipped: Int

    public init(tracks: [Track], startIndex: Int, skipped: Int) {
        self.tracks = tracks
        self.startIndex = startIndex
        self.skipped = skipped
    }
}

public enum QueueFilter {
    /// Без сети оставляем только сохранённые треки. Если выбранный трек не сохранён, стартуем с ближайшего
    /// сохранённого после него (а если после нет, то с первого). Пустая очередь значит «играть нечего».
    public static func offline(_ tracks: [Track], startIndex: Int, isSaved: (Track) -> Bool) -> OfflineQueue {
        var kept: [Track] = []
        var start = -1
        for (i, t) in tracks.enumerated() {
            if !isSaved(t) { continue }
            if start < 0 && i >= startIndex { start = kept.count }
            kept.append(t)
        }
        if kept.isEmpty { return OfflineQueue(tracks: [], startIndex: 0, skipped: tracks.count) }
        return OfflineQueue(tracks: kept, startIndex: start < 0 ? 0 : start, skipped: tracks.count - kept.count)
    }

    /// «Пропущено 3 трека: нужен интернет».
    public static func skippedText(_ n: Int) -> String {
        return "Пропущено \(Format.tracks(n)): нужен интернет"
    }
}
