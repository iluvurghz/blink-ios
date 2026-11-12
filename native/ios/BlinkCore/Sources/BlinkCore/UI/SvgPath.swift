import Foundation

/// Шаг контура. Координаты как в SVG: ось Y вниз, сетка значка 24×24.
public enum PathOp: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case curve(c1x: Double, c1y: Double, c2x: Double, c2y: Double, x: Double, y: Double)
    case close
}

/// Разбор пути SVG (атрибут `d`) в простые шаги. Понимает M, L, H, V, C, S, Z в обоих регистрах, повтор команды
/// без буквы и числа «впритык» (`1.5-2`, `.5.5`). Дуги и квадратичные кривые в значках Blink не встречаются:
/// на них разбор останавливается и отдаёт то, что успел.
/// Лежит в ядре, потому что одинаков на всех платформах и проверяется тестами без интерфейса.
public enum SvgPath {
    private struct Cursor {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ text: String) {
            s = Array(text.unicodeScalars)
        }

        static func digit(_ u: Unicode.Scalar) -> Bool {
            return u.value >= 48 && u.value <= 57
        }

        static func letter(_ u: Unicode.Scalar) -> Bool {
            return (u.value >= 65 && u.value <= 90) || (u.value >= 97 && u.value <= 122)
        }

        mutating func skipSeparators() {
            while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" || s[i] == "\r" {
                i += 1
            }
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = i
            var j = i
            if j < s.count, s[j] == "-" || s[j] == "+" { j += 1 }
            var digits = 0
            while j < s.count, Cursor.digit(s[j]) {
                j += 1
                digits += 1
            }
            if j < s.count, s[j] == "." {
                j += 1
                while j < s.count, Cursor.digit(s[j]) {
                    j += 1
                    digits += 1
                }
            }
            if digits == 0 { return nil }
            if j < s.count, s[j] == "e" || s[j] == "E" {
                var k = j + 1
                if k < s.count, s[k] == "-" || s[k] == "+" { k += 1 }
                var expDigits = 0
                while k < s.count, Cursor.digit(s[k]) {
                    k += 1
                    expDigits += 1
                }
                if expDigits > 0 { j = k }
            }
            var text = String.UnicodeScalarView()
            text.append(contentsOf: s[start..<j])
            i = j
            return Double(String(text))
        }
    }

    public static func parse(_ text: String) -> [PathOp] {
        var c = Cursor(text)
        var ops: [PathOp] = []
        var cx = 0.0
        var cy = 0.0
        var sx = 0.0
        var sy = 0.0
        var lastX = 0.0
        var lastY = 0.0
        var afterCurve = false
        var cmd: Unicode.Scalar = " "

        while true {
            c.skipSeparators()
            if c.i >= c.s.count { break }
            let ch = c.s[c.i]
            if Cursor.letter(ch) {
                cmd = ch
                c.i += 1
                if cmd == "Z" || cmd == "z" {
                    ops.append(.close)
                    cx = sx
                    cy = sy
                    afterCurve = false
                    continue
                }
            } else if cmd == " " || cmd == "Z" || cmd == "z" {
                break // число без команды: дальше разбирать нечего
            }

            switch cmd {
            case "M", "m":
                guard let x = c.number(), let y = c.number() else { return ops }
                let rel = cmd == "m"
                cx = rel ? cx + x : x
                cy = rel ? cy + y : y
                sx = cx
                sy = cy
                ops.append(.move(x: cx, y: cy))
                cmd = rel ? "l" : "L" // следующие пары это отрезки
                afterCurve = false
            case "L", "l":
                guard let x = c.number(), let y = c.number() else { return ops }
                let rel = cmd == "l"
                cx = rel ? cx + x : x
                cy = rel ? cy + y : y
                ops.append(.line(x: cx, y: cy))
                afterCurve = false
            case "H", "h":
                guard let x = c.number() else { return ops }
                cx = cmd == "h" ? cx + x : x
                ops.append(.line(x: cx, y: cy))
                afterCurve = false
            case "V", "v":
                guard let y = c.number() else { return ops }
                cy = cmd == "v" ? cy + y : y
                ops.append(.line(x: cx, y: cy))
                afterCurve = false
            case "C", "c":
                guard
                    let a = c.number(), let b = c.number(),
                    let d = c.number(), let e = c.number(),
                    let x = c.number(), let y = c.number()
                else { return ops }
                let rel = cmd == "c"
                let ox = rel ? cx : 0
                let oy = rel ? cy : 0
                ops.append(.curve(c1x: ox + a, c1y: oy + b, c2x: ox + d, c2y: oy + e, x: ox + x, y: oy + y))
                lastX = ox + d
                lastY = oy + e
                cx = ox + x
                cy = oy + y
                afterCurve = true
            case "S", "s":
                guard
                    let d = c.number(), let e = c.number(),
                    let x = c.number(), let y = c.number()
                else { return ops }
                let rel = cmd == "s"
                let ox = rel ? cx : 0
                let oy = rel ? cy : 0
                // первая опорная точка это отражение прошлой относительно текущей (или сама текущая)
                let c1x = afterCurve ? 2 * cx - lastX : cx
                let c1y = afterCurve ? 2 * cy - lastY : cy
                ops.append(.curve(c1x: c1x, c1y: c1y, c2x: ox + d, c2y: oy + e, x: ox + x, y: oy + y))
                lastX = ox + d
                lastY = oy + e
                cx = ox + x
                cy = oy + y
                afterCurve = true
            default:
                return ops
            }
        }
        return ops
    }
}

/// Значки Blink: контуры в сетке 24×24 (те же, что на Android). Рисует их платформенный слой.
public enum Glyphs: CaseIterable, Sendable {
    case play, pause, next, previous, download, check, close, search, person, refresh
    case cloudOff, delete, expandMore, note, checkCircle
    case bolt, heart, heartOutline, thumbDown
    case group, share, star, send, add, queue

    public var d: String {
        switch self {
        case .play: return "M8,5v14l11,-7z"
        case .pause: return "M6,19h4V5H6v14zM14,5v14h4V5h-4z"
        case .next: return "M6,18l8.5,-6L6,6v12zM16,6v12h2V6h-2z"
        case .previous: return "M6,6h2v12H6zM9.5,12l8.5,6V6z"
        case .download: return "M19,9h-4V3H9v6H5l7,7 7,-7zM5,18v2h14v-2H5z"
        case .check: return "M9,16.17L4.83,12l-1.42,1.41L9,19 21,7l-1.41,-1.41z"
        case .close:
            return "M19,6.41L17.59,5 12,10.59 6.41,5 5,6.41 10.59,12 5,17.59 6.41,19 12,13.41 17.59,19 19,17.59 13.41,12z"
        case .search:
            return "M15.5,14h-0.79l-0.28,-0.27C15.41,12.59 16,11.11 16,9.5 16,5.91 13.09,3 9.5,3S3,5.91 3,9.5 5.91,16 9.5,16c1.61,0 3.09,-0.59 4.23,-1.57l0.27,0.28v0.79l5,4.99L20.49,19l-4.99,-5zM9.5,14C7.01,14 5,11.99 5,9.5S7.01,5 9.5,5 14,7.01 14,9.5 11.99,14 9.5,14z"
        case .person:
            return "M12,12c2.21,0 4,-1.79 4,-4s-1.79,-4 -4,-4 -4,1.79 -4,4 1.79,4 4,4zM12,14c-2.67,0 -8,1.34 -8,4v2h16v-2c0,-2.66 -5.33,-4 -8,-4z"
        case .refresh:
            return "M17.65,6.35C16.2,4.9 14.21,4 12,4c-4.42,0 -7.99,3.58 -7.99,8s3.57,8 7.99,8c3.73,0 6.84,-2.55 7.73,-6h-2.08c-0.82,2.33 -3.04,4 -5.65,4 -3.31,0 -6,-2.69 -6,-6s2.69,-6 6,-6c1.66,0 3.14,0.69 4.22,1.78L13,11h7V4l-2.35,2.35z"
        case .cloudOff:
            return "M19.35,10.04C18.67,6.59 15.64,4 12,4c-1.48,0 -2.85,0.43 -4.01,1.17l1.46,1.46C10.21,6.23 11.08,6 12,6c3.04,0 5.5,2.46 5.5,5.5v0.5H19c1.66,0 3,1.34 3,3 0,1.13 -0.64,2.11 -1.56,2.62l1.45,1.45C23.16,18.16 24,16.68 24,15c0,-2.64 -2.05,-4.78 -4.65,-4.96zM3,5.27l2.75,2.74C2.56,8.15 0,10.77 0,14c0,3.31 2.69,6 6,6h11.73l2,2L21,20.73 4.27,4 3,5.27zM7.73,10l8,8H6c-2.21,0 -4,-1.79 -4,-4s1.79,-4 4,-4h1.73z"
        case .delete: return "M6,19c0,1.1 0.9,2 2,2h8c1.1,0 2,-0.9 2,-2V7H6v12zM19,4h-3.5l-1,-1h-5l-1,1H5v2h14V4z"
        case .expandMore: return "M16.59,8.59L12,13.17 7.41,8.59 6,10l6,6 6,-6z"
        case .note: return "M12,3v10.55c-0.59,-0.34 -1.27,-0.55 -2,-0.55 -2.21,0 -4,1.79 -4,4s1.79,4 4,4 4,-1.79 4,-4V7h4V3h-6z"
        case .bolt:
            return "M11,21h-1l1,-7H7.5c-0.88,0 -0.33,-0.75 -0.31,-0.78C8.48,10.94 10.42,7.54 13.01,3h1l-1,7h3.51c0.4,0 0.62,0.19 0.4,0.66C12.97,17.55 11,21 11,21z"
        case .heart:
            return "M12,21.35l-1.45,-1.32C5.4,15.36 2,12.28 2,8.5 2,5.42 4.42,3 7.5,3c1.74,0 3.41,0.81 4.5,2.09C13.09,3.81 14.76,3 16.5,3 19.58,3 22,5.42 22,8.5c0,3.78 -3.4,6.86 -8.55,11.54L12,21.35z"
        case .heartOutline:
            return "M16.5,3c-1.74,0 -3.41,0.81 -4.5,2.09C10.91,3.81 9.24,3 7.5,3 4.42,3 2,5.42 2,8.5c0,3.78 3.4,6.86 8.55,11.54L12,21.35l1.45,-1.32C18.6,15.36 22,12.28 22,8.5 22,5.42 19.58,3 16.5,3zM12.1,18.55l-0.1,0.1 -0.1,-0.1C7.14,14.24 4,11.39 4,8.5 4,6.5 5.5,5 7.5,5c1.54,0 3.04,0.99 3.57,2.36h1.87C13.46,5.99 14.96,5 16.5,5c2,0 3.5,1.5 3.5,3.5 0,2.89 -3.14,5.74 -7.9,10.05z"
        case .thumbDown:
            return "M15,3H6c-0.83,0 -1.54,0.5 -1.84,1.22l-3.02,7.05c-0.09,0.23 -0.14,0.47 -0.14,0.73v2c0,1.1 0.9,2 2,2h6.31l-0.95,4.57 -0.03,0.32c0,0.41 0.17,0.79 0.44,1.06L9.83,23l6.59,-6.59c0.36,-0.36 0.58,-0.86 0.58,-1.41V5c0,-1.1 -0.9,-2 -2,-2zM19,3v12h4V3h-4z"
        case .group:
            return "M16,11c1.66,0 2.99,-1.34 2.99,-3S17.66,5 16,5c-1.66,0 -3,1.34 -3,3s1.34,3 3,3zM8,11c1.66,0 2.99,-1.34 2.99,-3S9.66,5 8,5C6.34,5 5,6.34 5,8s1.34,3 3,3zM8,13c-2.33,0 -7,1.17 -7,3.5V19h14v-2.5c0,-2.33 -4.67,-3.5 -7,-3.5zM16,13c-0.29,0 -0.62,0.02 -0.97,0.05 1.16,0.84 1.97,1.97 1.97,3.45V19h6v-2.5c0,-2.33 -4.67,-3.5 -7,-3.5z"
        case .share:
            return "M18,16.08c-0.76,0 -1.44,0.3 -1.96,0.77L8.91,12.7c0.05,-0.23 0.09,-0.46 0.09,-0.7s-0.04,-0.47 -0.09,-0.7l7.05,-4.11c0.54,0.5 1.25,0.81 2.04,0.81 1.66,0 3,-1.34 3,-3s-1.34,-3 -3,-3 -3,1.34 -3,3c0,0.24 0.04,0.47 0.09,0.7L8.04,9.81C7.5,9.31 6.79,9 6,9c-1.66,0 -3,1.34 -3,3s1.34,3 3,3c0.79,0 1.5,-0.31 2.04,-0.81l7.12,4.16c-0.05,0.21 -0.08,0.43 -0.08,0.65 0,1.61 1.31,2.92 2.92,2.92 1.61,0 2.92,-1.31 2.92,-2.92s-1.31,-2.92 -2.92,-2.92z"
        case .star: return "M12,17.27L18.18,21l-1.64,-7.03L22,9.24l-7.19,-0.61L12,2 9.19,8.63 2,9.24l5.46,4.73L5.82,21z"
        case .send: return "M2.01,21L23,12 2.01,3 2,10l15,2 -15,2z"
        case .add: return "M19,13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"
        case .queue: return "M15,6H3v2h12V6zM15,10H3v2h12v-2zM3,16h8v-2H3v2zM17,6v8.18c-0.31,-0.11 -0.65,-0.18 -1,-0.18 -1.66,0 -3,1.34 -3,3s1.34,3 3,3 3,-1.34 3,-3V8h3V6h-5z"
        case .checkCircle:
            return "M12,2C6.48,2 2,6.48 2,12s4.48,10 10,10 10,-4.48 10,-10S17.52,2 12,2zM10,17l-5,-5 1.41,-1.41L10,14.17l7.59,-7.59L19,8l-9,9z"
        }
    }

    public var ops: [PathOp] {
        return SvgPath.parse(d)
    }
}
