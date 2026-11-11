import Foundation

/// Текст итога пакета: «Сохранено 3 из 5. 2 не вышло: …» (контракт v1).
/// Подробности по каждому треку видны во вкладке «Скачанное».
public enum BatchSummary {
    public static func text(ok: Int, total: Int, failures: [Failure]) -> String {
        if failures.isEmpty { return total <= 1 ? "Сохранено" : "Сохранено \(ok) из \(total)" }
        if total <= 1 {
            let f = failures[0]
            return "\(f.title): \(f.text.message)"
        }
        let shown = failures.prefix(2).map { "\($0.title): \($0.text.message)" }.joined(separator: "; ")
        let more = failures.count > 2 ? " и ещё \(failures.count - 2)" : ""
        return "Сохранено \(ok) из \(total). \(failures.count) не вышло: \(shown)\(more)"
    }

    public static func text(_ event: OfflineEvent) -> String {
        switch event {
        case .batchDone(let ok, let total, let failures):
            return text(ok: ok, total: total, failures: failures)
        }
    }
}
