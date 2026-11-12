import Foundation

/// Цвет в HSL: оттенок 0…360, насыщенность и светлота 0…1.
public struct Hsl: Equatable, Sendable {
    public var h: Double
    public var s: Double
    public var l: Double

    public init(_ h: Double, _ s: Double, _ l: Double) {
        self.h = h
        self.s = s
        self.l = l
    }

    /// RGB 0…1, как в CSS.
    public var rgb: (r: Double, g: Double, b: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch hh {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}

/// Палитра из обложки: акцент и три свечения (lib/color.js `paletteFor`). Всё окно берёт свет от трека.
public struct Palette: Equatable, Sendable {
    public var accent: Hsl
    public var accentInk: Hsl
    public var glowA: Hsl
    public var glowB: Hsl
    public var glowC: Hsl

    public static let fallback = Palette(accent: Hsl(18, 0.92, 0.64), accentInk: Hsl(18, 0.6, 0.1), glowA: Hsl(18, 0.7, 0.38), glowB: Hsl(352, 0.48, 0.28), glowC: Hsl(24, 0.42, 0.19))

    static func toHsl(_ r: Double, _ g: Double, _ b: Double) -> Hsl {
        let r = r / 255, g = g / 255, b = b / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        var h = 0.0, s = 0.0
        let l = (mx + mn) / 2
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
        }
        return Hsl(h, s, l)
    }

    /// Пиксели RGBA (обложка, уменьшенная до 24×24) → палитра. Пустой массив даёт палитру по умолчанию.
    public static func from(rgba px: [UInt8]) -> Palette {
        if px.count < 4 { return fallback }
        struct B { var n = 0; var hx = 0.0; var hy = 0.0; var s = 0.0; var l = 0.0 }
        var buckets: [String: B] = [:]
        var order: [String] = []
        var i = 0
        while i + 2 < px.count {
            let c = toHsl(Double(px[i]), Double(px[i + 1]), Double(px[i + 2]))
            let key = c.s < 0.12 ? "n\(Int((c.l * 4).rounded()))" : "\(Int((c.h / 24).rounded()) % 15)"
            if buckets[key] == nil { order.append(key) }
            var b = buckets[key] ?? B()
            b.n += 1
            b.hx += cos(c.h * .pi / 180)
            b.hy += sin(c.h * .pi / 180)
            b.s += c.s
            b.l += c.l
            buckets[key] = b
            i += 4
        }
        struct G { let neutral: Bool; let n: Int; let h: Double; let s: Double; let l: Double }
        let groups: [G] = order.map { k in
            let b = buckets[k]!
            var h = atan2(b.hy, b.hx) * 180 / .pi
            if h < 0 { h += 360 }
            return G(neutral: k.hasPrefix("n"), n: b.n, h: h, s: b.s / Double(b.n), l: b.l / Double(b.n))
        }
        let chroma = groups.filter { !$0.neutral }.enumerated().sorted { x, y in
            let a = Double(x.element.n) * (0.3 + x.element.s), b = Double(y.element.n) * (0.3 + y.element.s)
            return a != b ? a > b : x.offset < y.offset
        }.map { $0.element }
        if chroma.isEmpty || chroma[0].n < 8 {
            let top = groups.enumerated().sorted { $0.element.n != $1.element.n ? $0.element.n > $1.element.n : $0.offset < $1.offset }.first?.element
            return Palette(
                accent: Hsl(36, 0.2, 0.82),
                accentInk: Hsl(36, 0.1, 0.1),
                glowA: Hsl(30, 0.08, min(0.32, 0.12 + (top.map { $0.l * 0.2 } ?? 0.1))),
                glowB: Hsl(250, 0.08, 0.2),
                glowC: Hsl(30, 0.06, 0.16)
            )
        }
        let a = chroma[0]
        let b = chroma.count > 1 ? chroma[1] : G(neutral: false, n: a.n, h: (a.h + 40).truncatingRemainder(dividingBy: 360), s: a.s, l: a.l)
        let c = chroma.count > 2 ? chroma[2] : G(neutral: false, n: a.n, h: (a.h + 300).truncatingRemainder(dividingBy: 360), s: a.s, l: a.l)
        return Palette(
            accent: Hsl(a.h, max(0.55, min(0.95, a.s + 0.25)), 0.66),
            accentInk: Hsl(a.h, 0.6, 0.1),
            glowA: Hsl(a.h, min(0.75, a.s + 0.15), 0.36),
            glowB: Hsl(b.h, min(0.7, b.s + 0.1), 0.3),
            glowC: Hsl(c.h, min(0.6, c.s + 0.05), 0.24)
        )
    }

    /// Адрес маленькой обложки для палитры (как `scaleSc(... '/60x60bb.jpg', 100)` на сайте).
    public static func smallArt(_ url: String) -> String {
        return ArtUrl.scaled(url, 100)
    }
}

/// Размер обложки в адресе: iTunes `/NNNxNNNbb.jpg`, Яндекс `/NNNxNNN`, SoundCloud `-large`/`-t500x500`.
public enum ArtUrl {
    public static func scaled(_ url: String, _ size: Int) -> String {
        if url.isEmpty { return url }
        for (pattern, template) in [
            ("/\\d+x\\d+bb\\.jpg$", "/\(size)x\(size)bb.jpg"),
            ("/\\d+x\\d+$", "/\(size)x\(size)"),
            ("(?i)-(?:large|badge|small|tiny|mini|crop|original|t\\d+x\\d+)\\.(jpe?g|png|webp)(?=$|[?#])", size <= 150 ? "-t300x300.$1" : "-t500x500.$1"),
        ] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = url as NSString
            let r = NSRange(location: 0, length: ns.length)
            if re.firstMatch(in: url, range: r) != nil {
                return re.stringByReplacingMatches(in: url, range: r, withTemplate: template)
            }
        }
        return url
    }
}
