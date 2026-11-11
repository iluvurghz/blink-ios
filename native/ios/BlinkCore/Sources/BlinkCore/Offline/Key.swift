import Foundation

/// Ключ сохранённого трека: `<source>:<sourceId>`, для лицензионных `blink:<uuid lic_tracks>`.
/// Имя файла на диске: hex от UTF-8 ключа (безопасно для любой файловой системы и одинаково на всех платформах).
public enum Key {
    public static func of(_ source: String, _ id: String) -> String {
        return source + ":" + id
    }

    public static func fkey(_ key: String) -> String {
        let digits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(key.utf8.count * 2)
        for b in key.utf8 {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 15)])
        }
        return out
    }

    public static func fromFkey(_ fkey: String) -> String? {
        let bytes = Array(fkey.utf8)
        if bytes.isEmpty || bytes.count % 2 != 0 { return nil }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = hexValue(bytes[i]), let lo = hexValue(bytes[i + 1]) else { return nil }
            out.append(UInt8(hi * 16 + lo))
            i += 2
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func hexValue(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: return Int(c) - 48
        case 97...102: return Int(c) - 87
        case 65...70: return Int(c) - 55
        default: return nil
        }
    }
}
