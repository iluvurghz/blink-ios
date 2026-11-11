import SwiftUI
import BlinkCore

/// Контур значка из ядра (`Glyphs`) в сетке 24×24, масштабируется под любой квадрат.
struct GlyphShape: Shape {
    let ops: [PathOp]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: Double, _ y: Double) -> CGPoint {
            return CGPoint(x: rect.minX + CGFloat(x) * scale, y: rect.minY + CGFloat(y) * scale)
        }
        var path = Path()
        for op in ops {
            switch op {
            case .move(let x, let y):
                path.move(to: point(x, y))
            case .line(let x, let y):
                path.addLine(to: point(x, y))
            case .curve(let c1x, let c1y, let c2x, let c2y, let x, let y):
                path.addCurve(to: point(x, y), control1: point(c1x, c1y), control2: point(c2x, c2y))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

/// Разобранные контуры хранятся один раз на весь процесс: строки списка не разбирают путь заново.
private enum GlyphCache {
    private static let lock = NSLock()
    private static var cache: [Glyphs: [PathOp]] = [:]

    static func ops(_ glyph: Glyphs) -> [PathOp] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[glyph] { return hit }
        let parsed = glyph.ops
        cache[glyph] = parsed
        return parsed
    }
}

struct GlyphView: View {
    private let glyph: Glyphs
    private let color: Color
    private let size: CGFloat

    init(_ glyph: Glyphs, color: Color = Ink.bone, size: CGFloat = 24) {
        self.glyph = glyph
        self.color = color
        self.size = size
    }

    var body: some View {
        GlyphShape(ops: GlyphCache.ops(glyph))
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
