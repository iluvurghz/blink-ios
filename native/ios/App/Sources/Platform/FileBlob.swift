import Foundation
import BlinkCore

/// Небольшой JSON-файл ядра (состояние Вспышки, лайки) в Application Support.
final class FileBlob: BlobStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(name: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        url = support.appendingPathComponent(name)
    }

    func load() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let value = value {
            try? Data(value.utf8).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Настройки Вспышки, которые движок читает из любого потока.
final class WaveSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: WaveSettings

    init() {
        let mode = WaveMode.of(UserDefaults.standard.string(forKey: "wave_mode"))
        let explore = UserDefaults.standard.object(forKey: "wave_explore") as? Bool ?? true
        settings = WaveSettings(mode: mode, explore: explore)
    }

    var value: WaveSettings {
        lock.lock()
        defer { lock.unlock() }
        return settings
    }

    func setMode(_ mode: WaveMode) {
        lock.lock()
        settings.mode = mode
        lock.unlock()
        UserDefaults.standard.set(mode.rawValue, forKey: "wave_mode")
    }
}
