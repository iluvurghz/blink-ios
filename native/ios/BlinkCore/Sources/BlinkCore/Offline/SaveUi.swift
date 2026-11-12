import Foundation

/// Что рисуем на кнопке «Сохранить» у трека. Считается из состояния менеджера, UI только показывает.
public enum SaveUi: Equatable, Sendable {
    /// Трек нельзя сохранять (не из каталога Blink или артист не разрешил): играет только онлайн.
    case onlineOnly(reason: String)
    case available
    case queued
    /// `fraction` от 0 до 1; `indeterminate` пока неизвестен размер.
    case progress(fraction: Double, indeterminate: Bool)
    case saved
    case failed(OfflineText)

    public static func of(_ track: Track, _ state: OfflineState) -> SaveUi {
        if !OfflinePolicy.savable(track) {
            let allowedSource = OfflinePolicy.allowedSources.contains(track.source ?? "") && !(track.lic ?? "").isEmpty
            return .onlineOnly(reason: allowedSource && track.offline == false ? "artist" : "source")
        }
        guard let key = OfflinePolicy.keyOf(track) else { return .onlineOnly(reason: "source") }
        if state.savedKeys.contains(key) { return .saved }
        guard let job = state.job(key) else { return .available }
        switch job.stage {
        case .queued: return .queued
        case .resolving: return .progress(fraction: 0, indeterminate: true)
        case .downloading: return .progress(fraction: job.fraction, indeterminate: job.total == nil)
        case .verifying, .committing: return .progress(fraction: 1, indeterminate: false)
        case .failed: return .failed(job.text ?? OfflineTexts.of(.sourceError))
        }
    }
}
