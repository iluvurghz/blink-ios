import Foundation

/// Подписи для экранов: одинаковые на всех платформах. Локаль не трогаем: цифры всегда обычные.
public enum Format {
    /// 213 → «3:33», 3723 → «1:02:03».
    public static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = s % 3600 / 60
        let sec = s % 60
        if h > 0 { return "\(h):\(two(m)):\(two(sec))" }
        return "\(m):\(two(sec))"
    }

    private static func two(_ n: Int) -> String {
        return n < 10 ? "0\(n)" : "\(n)"
    }

    /// Размер файлов по-русски: «512 Б», «840 КБ», «12,3 МБ», «1,25 ГБ».
    public static func bytes(_ n: Int64) -> String {
        let v = max(0, n)
        if v < 1024 { return "\(v) Б" }
        if v < 1024 * 1024 { return "\((v + 512) / 1024) КБ" }
        if v < 1024 * 1024 * 1024 {
            let mb = Double(v) / (1024.0 * 1024.0)
            if mb >= 100 { return "\(Int64(mb.rounded())) МБ" }
            return decimal(mb, 1) + " МБ"
        }
        return decimal(Double(v) / (1024.0 * 1024.0 * 1024.0), 2) + " ГБ"
    }

    /// Дробь с запятой и ровным числом знаков, округление «от нуля» как у String.format в Java.
    private static func decimal(_ x: Double, _ digits: Int) -> String {
        var scale: Int64 = 1
        for _ in 0..<digits { scale *= 10 }
        let scaled = Int64((x * Double(scale)).rounded(.toNearestOrAwayFromZero))
        let whole = scaled / scale
        var frac = String(scaled % scale)
        while frac.count < digits { frac = "0" + frac }
        return "\(whole),\(frac)"
    }

    /// Русские формы числительных: 1 трек, 2 трека, 5 треков, 21 трек, 12 треков.
    public static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let a = abs(n) % 100
        let b = a % 10
        if a >= 11 && a <= 14 { return many }
        if b == 1 { return one }
        if b >= 2 && b <= 4 { return few }
        return many
    }

    public static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        return "\(n) \(plural(n, one, few, many))"
    }

    public static func tracks(_ n: Int) -> String {
        return count(n, "трек", "трека", "треков")
    }

    private static let months = [
        "января", "февраля", "марта", "апреля", "мая", "июня",
        "июля", "августа", "сентября", "октября", "ноября", "декабря",
    ]

    /// «12 декабря 2026».
    public static func date(_ epochMs: Int64, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(epochMs) / 1000))
        let month = min(12, max(1, c.month ?? 1))
        return "\(c.day ?? 1) \(months[month - 1]) \(c.year ?? 1970)"
    }
}
