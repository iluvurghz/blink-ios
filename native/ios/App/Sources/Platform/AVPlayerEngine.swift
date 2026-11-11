import AVFoundation
import Foundation
import BlinkCore

/// Звуковой движок на AVPlayer. Все вызовы переходят на главную очередь по порядку, поэтому устаревший
/// «загрузить» не обгоняет более новый «стоп». События идут контроллеру (PlayerController), он решает остальное.
final class AVPlayerEngine: NSObject, PlaybackEngine, @unchecked Sendable {
    weak var delegate: PlaybackEngineDelegate?

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endToken: NSObjectProtocol?
    private var failToken: NSObjectProtocol?
    private var wantPlaying = false
    private var failed = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(routeChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // ---------- PlaybackEngine ----------

    func load(_ source: PlaySource, autoplay: Bool) {
        DispatchQueue.main.async { [self] in loadNow(source, autoplay: autoplay) }
    }

    func setPlaying(_ playing: Bool) {
        DispatchQueue.main.async { [self] in
            wantPlaying = playing
            guard let player = player else { return }
            if playing {
                activateSession()
                player.play()
            } else {
                player.pause()
            }
            emit()
        }
    }

    func seek(toMs ms: Int64) {
        DispatchQueue.main.async { [self] in
            guard let player = player else { return }
            let target = CMTime(value: max(0, ms), timescale: 1000)
            player.seek(to: target) { [weak self] _ in
                DispatchQueue.main.async { self?.emit() }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            teardown()
            wantPlaying = false
            failed = false
        }
    }

    // ---------- внутренности (только главная очередь) ----------

    private func loadNow(_ source: PlaySource, autoplay: Bool) {
        teardown()
        failed = false
        wantPlaying = autoplay
        switch source {
        case .stream: Diag.note("load stream autoplay=" + String(autoplay))
        case .file: Diag.note("load file autoplay=" + String(autoplay))
        }
        guard let url = sourceURL(for: source) else {
            fail("Не получилось открыть трек")
            return
        }
        activateSession()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.item = item
        self.player = player

        observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.itemStatusChanged(item) }
        })
        observations.append(item.observe(\.duration, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.emit() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            let reason = observed.reasonForWaitingToPlay?.rawValue ?? "-"
            Diag.note("timeControl=" + String(observed.timeControlStatus.rawValue) + " reason=" + reason)
            DispatchQueue.main.async { self?.emit() }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 2), queue: .main) { [weak self] _ in
            self?.emit()
        }
        endToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.finished()
        }
        failToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Diag.note("failed to play to end: " + Diag.describe(error))
            self?.fail("Не получилось доиграть трек")
        }
        if autoplay { player.play() }
        emit()
    }

    private func teardown() {
        if let player = player, let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        observations.removeAll()
        if let token = endToken { NotificationCenter.default.removeObserver(token) }
        if let token = failToken { NotificationCenter.default.removeObserver(token) }
        endToken = nil
        failToken = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
    }

    private func itemStatusChanged(_ changed: AVPlayerItem) {
        guard changed === item else { return }
        Diag.note("item status=" + String(changed.status.rawValue) + " error=" + Diag.describe(changed.error))
        if changed.status == .failed {
            if let event = changed.errorLog()?.events.last {
                Diag.note("item errorLog code=" + String(event.errorStatusCode) + " domain=" + event.errorDomain + " comment=" + (event.errorComment ?? "-"))
            }
            fail("Не получилось проиграть трек")
        } else {
            emit()
        }
    }

    private func finished() {
        wantPlaying = false
        delegate?.engineEnded()
    }

    private func fail(_ message: String) {
        if failed { return }
        Diag.note("fail: " + message)
        failed = true
        wantPlaying = false
        player?.pause()
        delegate?.engineFailed(message)
    }

    private func emit() {
        guard let player = player, let item = item, !failed else { return }
        let status = player.timeControlStatus
        let loading = item.status == .unknown
        let buffering = wantPlaying && (status == .waitingToPlayAtSpecifiedRate || loading)
        delegate?.engine(
            playing: status == .playing,
            buffering: buffering,
            positionMs: AVPlayerEngine.millis(player.currentTime()),
            durationMs: AVPlayerEngine.millis(item.duration)
        )
    }

    private static func millis(_ time: CMTime) -> Int64 {
        let seconds = time.seconds
        if !seconds.isFinite || seconds <= 0 { return 0 }
        return Int64(seconds * 1000)
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            // Без сессии звук может не пойти, но пробуем: ошибку покажет сам плеер.
            Diag.note("audio session error: " + Diag.describe(error))
        }
    }

    // ---------- файл или поток ----------

    private func sourceURL(for source: PlaySource) -> URL? {
        switch source {
        case .stream(let text):
            return URL(string: text)
        case .file(let path):
            return playableLink(for: path)
        }
    }

    /// Сохранённые файлы лежат без расширения (имя это hex ключа), и AVPlayer по такому имени формат не определит.
    /// Играем через ссылку с расширением: файл не копируется.
    private func playableLink(for path: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        guard let ext = AVPlayerEngine.sniffExtension(path) else { return URL(fileURLWithPath: path) }
        let dir = fm.temporaryDirectory.appendingPathComponent("blink-play", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent + "." + ext)
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path), target == path {
            return link
        }
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: path)
        } catch {
            return URL(fileURLWithPath: path)
        }
        return link
    }

    /// Формат по первым байтам: ID3 или кадр MPEG это mp3, `ftyp` это m4a, и так далее.
    static func sniffExtension(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count >= 4 else { return nil }
        let b = [UInt8](head)
        if b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33 { return "mp3" }
        if b.count >= 8 && b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return "m4a" }
        if b[0] == 0x66 && b[1] == 0x4C && b[2] == 0x61 && b[3] == 0x43 { return "flac" }
        if b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 { return "wav" }
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return (b[1] & 0x06) == 0 ? "aac" : "mp3" }
        return nil
    }

    // ---------- прерывания и смена выхода звука ----------

    @objc private func interruption(_ note: Notification) {
        guard
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        Diag.note("interruption type=" + String(raw))
        DispatchQueue.main.async { [self] in
            switch type {
            case .began:
                emit()
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) && wantPlaying {
                    activateSession()
                    player?.play()
                }
            @unknown default:
                break
            }
        }
    }

    /// Выдернули наушники: как у всех плееров, ставим на паузу, а не орём на весь автобус.
    @objc private func routeChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        Diag.note("route change reason=" + String(raw))
        guard AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [self] in
            wantPlaying = false
            player?.pause()
            emit()
        }
    }
}
