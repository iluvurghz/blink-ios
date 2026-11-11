import MediaPlayer
import UIKit
import BlinkCore

/// Экран блокировки и пункт управления: что играет, кнопки паузы и перемотки, наушники.
final class NowPlayingBridge {
    private let player: PlayerController
    private var token: NetworkObservation?
    private var shownTrackId: String?
    private var shownPlaying = false
    private var shownDuration: Int64 = -1
    private var shownPosition: Int64 = 0
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?

    init(player: PlayerController) {
        self.player = player
        let commands = MPRemoteCommandCenter.shared()
        _ = commands.playCommand.addTarget { [weak self] _ in
            self?.setPlaying(true)
            return .success
        }
        _ = commands.pauseCommand.addTarget { [weak self] _ in
            self?.setPlaying(false)
            return .success
        }
        _ = commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.player.toggle()
            return .success
        }
        _ = commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.player.next()
            return .success
        }
        _ = commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.player.previous()
            return .success
        }
        _ = commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let change = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player.seek(toMs: Int64(change.positionTime * 1000))
            return .success
        }
        token = player.observe { [weak self] ui in
            DispatchQueue.main.async { self?.update(ui) }
        }
    }

    deinit {
        token?.cancel()
    }

    /// Кнопки «играть» и «пауза» не переключают вслепую: смотрим, что делает плеер сейчас.
    private func setPlaying(_ playing: Bool) {
        if player.current.playing != playing { player.toggle() }
    }

    private func update(_ ui: PlayerUi) {
        guard let track = ui.track else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            shownTrackId = nil
            artwork = nil
            artworkTask?.cancel()
            return
        }
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = ui.hasNext
        commands.previousTrackCommand.isEnabled = true

        let trackChanged = shownTrackId != track.id
        // Система сама двигает полосу времени по скорости воспроизведения, поэтому обновляем только по событиям:
        // другой трек, пауза или игра, длительность стала известна, перемотка (позиция ушла от ожидаемой).
        let expected = shownPosition + (shownPlaying ? 500 : 0)
        let jumped = abs(ui.positionMs - expected) > 2500
        if !trackChanged && shownPlaying == ui.playing && shownDuration == ui.durationMs && !jumped {
            shownPosition = ui.positionMs
            return
        }
        if trackChanged {
            shownTrackId = track.id
            artwork = nil
            loadArtwork(track.artwork)
        }
        shownPlaying = ui.playing
        shownDuration = ui.durationMs
        shownPosition = ui.positionMs
        publish(track, ui)
    }

    private func publish(_ track: Track, _ ui: PlayerUi) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: Double(ui.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(ui.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: ui.playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let art = artwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(_ url: String) {
        artworkTask?.cancel()
        artworkTask = nil
        guard !url.isEmpty, let source = URL(string: url) else { return }
        let id = shownTrackId
        let task = URLSession.shared.dataTask(with: source) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.shownTrackId == id else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publish(self.player.current)
            }
        }
        artworkTask = task
        task.resume()
    }

    private func publish(_ ui: PlayerUi) {
        guard let track = ui.track, track.id == shownTrackId else { return }
        publish(track, ui)
    }
}
