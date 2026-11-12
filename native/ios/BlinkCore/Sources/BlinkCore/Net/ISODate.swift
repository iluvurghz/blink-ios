import Foundation

/// Разбор дат ISO 8601 из ответов сервера (`2026-12-10T12:00:00.123456+00:00`, `...Z`) в миллисекунды от эпохи.
/// Считаем сами, без DateFormatter: одинаково на Apple и на Linux и без неожиданностей с локалью.
public enum ISODate {
    public static func parseMs(_ text: String) -> Int64? {
        let pattern = "^(\\d{4})-(\\d{2})-(\\d{2})[Tt ](\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d+))?(Z|z|[+-]\\d{2}(?::?\\d{2})?)?$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let s = text.trimmingCharacters(in: .whitespaces)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }

        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard
            let y = group(1).flatMap({ Int($0) }), let mo = group(2).flatMap({ Int($0) }), let d = group(3).flatMap({ Int($0) }),
            let h = group(4).flatMap({ Int($0) }), let mi = group(5).flatMap({ Int($0) }), let sec = group(6).flatMap({ Int($0) })
        else { return nil }
        if mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 60 { return nil }

        var millis = 0
        if let frac = group(7) {
            let digits = String(frac.prefix(3))
            millis = (Int(digits) ?? 0) * (digits.count == 1 ? 100 : digits.count == 2 ? 10 : 1)
        }
        var offsetSeconds = 0
        if let zone = group(8), zone != "Z", zone != "z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter { $0 != ":" }
            let oh = Int(digits.prefix(2)) ?? 0
            let om = digits.count >= 4 ? (Int(digits.suffix(2)) ?? 0) : 0
            offsetSeconds = sign * (oh * 3600 + om * 60)
        }
        let days = daysFromCivil(y, mo, d)
        let seconds = Int64(days) * 86_400 + Int64(h * 3600 + mi * 60 + sec) - Int64(offsetSeconds)
        return seconds * 1000 + Int64(millis)
    }

    /// Число дней от 1970-01-01 до гражданской даты (алгоритм Говарда Хиннанта).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
