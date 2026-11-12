import Foundation

/// Проверки файла из контракта: тип ответа, первые байты и итоговый размер.
/// Любой отказ здесь это BAD_CONTENT без автоповторов.
public enum Content {
    public static let minBytesFloor: Int64 = 16_384
    public static let bytesPerSecondFloor: Int64 = 2_000
    public static let maxBytes: Int64 = 400 * 1024 * 1024

    /// Сколько первых байт нужно, чтобы опознать любой из форматов (RIFF....WAVE = 12).
    public static let sniffBytes = 12

    /// Тип ответа: любой audio или application/octet-stream; всё остальное (text/html, json) это не файл.
    public static func typeOk(_ contentType: String?) -> Bool {
        guard let raw = contentType else { return true }
        let head = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let t = head.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return true }
        return t.hasPrefix("audio/") || t == "application/octet-stream" || t == "binary/octet-stream"
    }

    /// Первые байты должны быть похожи на звук. В `head` не меньше `sniffBytes` байт, если файл столько весит.
    public static func magicOk(_ head: [UInt8]) -> Bool {
        let len = head.count
        if len == 0 { return false }
        let b0 = head[0]
        if b0 == 0x3C || b0 == 0x7B { return false } // "<" и "{"
        // MP3: ID3-тег или кадр FF Ex / FF Fx
        if len >= 3 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33 { return true }
        if len >= 2 && b0 == 0xFF && (head[1] & 0xE0) == 0xE0 { return true }
        // MP4/M4A: "ftyp" со смещения 4
        if len >= 8 && head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70 { return true }
        // Ogg, FLAC
        if len >= 4 && head[0] == 0x4F && head[1] == 0x67 && head[2] == 0x67 && head[3] == 0x53 { return true }
        if len >= 4 && head[0] == 0x66 && head[1] == 0x4C && head[2] == 0x61 && head[3] == 0x43 { return true }
        // WAV: RIFF....WAVE
        if len >= 12 &&
            head[0] == 0x52 && head[1] == 0x49 && head[2] == 0x46 && head[3] == 0x46 &&
            head[8] == 0x57 && head[9] == 0x41 && head[10] == 0x56 && head[11] == 0x45 {
            return true
        }
        return false
    }

    /// Нижняя граница размера по длительности: меньше этого файл точно обрезан.
    public static func minBytes(durationSec: Int) -> Int64 {
        return max(minBytesFloor, Int64(durationSec) * bytesPerSecondFloor)
    }

    /// Итоговая проверка перед commit. Бросает BAD_CONTENT с причиной.
    public static func verifyFinal(have: Int64, total: Int64?, resolvedBytes: Int64?, durationSec: Int) throws {
        guard let total = total, total > 0 else { throw OfflineError(.badContent, "no_size") }
        if have != total { throw OfflineError(.badContent, "truncated") }
        if let rb = resolvedBytes, rb != total { throw OfflineError(.badContent, "size_mismatch") }
        if have < minBytes(durationSec: durationSec) { throw OfflineError(.badContent, "too_small") }
        if have > maxBytes { throw OfflineError(.badContent, "too_big") }
    }
}
