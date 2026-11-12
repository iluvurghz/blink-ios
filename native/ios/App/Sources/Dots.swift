import SwiftUI
import UIKit
import BlinkCore

// «Точка» и заставка с сайта (ui/dots.js, electron/screens/dotword.js): точки, кольца света, обложка из точек.
// Порт ui/Dots.kt.

/// Цвет как три числа 0…1: так его можно смешивать по кадрам.
struct RGB {
    var r: Double
    var g: Double
    var b: Double

    static let bone = RGB(r: 238 / 255, g: 233 / 255, b: 226 / 255)
    static let hot = RGB(r: 1, g: 238 / 255, b: 212 / 255)
    static let accent = RGB(r: 248 / 255, g: 129 / 255, b: 79 / 255)

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ h: Hsl) {
        let c = h.rgb
        self.init(r: c.r, g: c.g, b: c.b)
    }

    func mix(_ o: RGB, _ k: Double) -> RGB {
        return RGB(r: r + (o.r - r) * k, g: g + (o.g - g) * k, b: b + (o.b - b) * k)
    }

    func color(_ a: Double = 1) -> Color {
        return Color(.sRGB, red: r, green: g, blue: b, opacity: min(1, max(0, a)))
    }
}

private func clamp01(_ x: Double) -> Double { return min(1, max(0, x)) }
private func eo(_ x: Double) -> Double { return 1 - pow(1 - clamp01(x), 3) }

/// Тот же шум, что на сайте: у каждой точки свой постоянный разброс размера и яркости.
private func hash(_ i: Int, _ j: Int) -> Double {
    var h = Int32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263) &* 1274126177
    h ^= Int32(bitPattern: UInt32(bitPattern: h) >> 13)
    h = h &* 1274126177
    let v = UInt32(bitPattern: h ^ Int32(bitPattern: UInt32(bitPattern: h) >> 16))
    return Double(v) / 4294967296
}

/// Состояние Вспышки для «Точки»: спит, разгорается (собираем музыку), горит (играет).
enum DotPhase {
    case rest, igniting, flash
}

/// Решётка: скруглённый квадрат точек, нечётное число, чтобы точка была ровно в середине; в центре значок «играть» из точек.
private struct Lattice {
    let s: Double
    let p: Double
    var xs: [Double] = []
    var ys: [Double] = []
    var noise: [Double] = []
    var dm: [Double] = []
    var icon: [Bool] = []
    var ph: [Double] = []
    var maxDm: Double = 1

    init(size: Double) {
        s = size
        let n0 = Int((size / 10).rounded())
        let n = min(49, max(17, n0 % 2 == 1 ? n0 : n0 + 1))
        p = size / Double(n)
        let c = size / 2
        let rho = size * 0.24
        for j in 0..<n {
            for i in 0..<n {
                let x = (Double(i) + 0.5) * p
                let y = (Double(j) + 0.5) * p
                let dx = max(abs(x - c) - (size / 2 - rho), 0)
                let dy = max(abs(y - c) - (size / 2 - rho), 0)
                if hypot(dx, dy) > rho - p * 0.35 { continue }
                let m = abs(x - c) + abs(y - c)
                maxDm = max(maxDm, m)
                xs.append(x)
                ys.append(y)
                noise.append(hash(i, j))
                dm.append(m)
            }
        }
        let tri: [(Double, Double)] = [(-3.2, -4.9), (-3.2, 4.9), (5.1, 0)]
        icon = Array(repeating: false, count: xs.count)
        ph = Array(repeating: 0, count: xs.count)
        for k in xs.indices {
            let u = (xs[k] - c) / p - 0.47
            let v = (ys[k] - c) / p
            var sum = 0
            for e in 0..<3 {
                let a = tri[e]
                let b = tri[(e + 1) % 3]
                let cr = (b.0 - a.0) * (v - a.1) - (b.1 - a.1) * (u - a.0)
                sum += cr >= 0 ? 1 : -1
            }
            if abs(sum) == 3 {
                icon[k] = true
                ph[k] = clamp01((u + 3.2) / 8.3)
            }
        }
    }
}

/// Часы «Точки»: всё, что меняется от кадра к кадру, живёт здесь, а не в состоянии SwiftUI.
private final class DotClock {
    enum Mode { case rest, ignite, reveal, cover }
    var mode = Mode.rest
    var t0 = Date()
    var fade = 1.0
    var t = Double.random(in: 0..<20)
    var lit = false
    var phase = DotPhase.rest
    var cover: Image?
    var coverSide: Double = 1
    var imgReady = false
    var coverAt = Date()
    var cleared = false
    var tau: Double { return Date().timeIntervalSince(t0) }

    func set(_ phase: DotPhase) {
        let lit = phase != .rest
        self.phase = phase
        if lit && !self.lit {
            mode = .ignite
            t0 = Date()
            imgReady = false
            cover = nil
        } else if !lit && self.lit {
            mode = .rest
            fade = 0.1
            t0 = Date()
            cleared = false
        }
        self.lit = lit
    }

    /// Шаг времени; true, когда картинка собралась целиком.
    func step(_ dt: Double) -> Bool {
        t += dt
        switch mode {
        case .rest:
            fade = min(1, fade + dt * 4)
        case .ignite:
            if phase == .flash && imgReady && tau > 0.5 {
                mode = .reveal
                t0 = Date()
            }
        case .reveal:
            if tau >= 0.92 {
                mode = .cover
                coverAt = Date()
                return true
            }
        case .cover:
            break
        }
        return false
    }
}

/// Обложка квадратом: через неё рисуются растущие точки.
private func loadSquare(_ url: String?) async -> UIImage? {
    guard let url, !url.isEmpty, let u = URL(string: Img.proxied(ArtUrl.scaled(url, 600))) else { return nil }
    guard let (data, _) = try? await URLSession.shared.data(from: u), let img = UIImage(data: data), let cg = img.cgImage else { return nil }
    let side = min(cg.width, cg.height)
    guard let sq = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return nil }
    return UIImage(cgImage: sq, scale: 1, orientation: img.imageOrientation)
}

/// «Точка»: квадрат из точек со значком «играть» из точек. Спит: по точкам бежит полоса света. Нажали:
/// значок вспыхивает, от него бегут кольца. Музыка пришла: точки растут от центра и сливаются в обложку.
/// Остановили: точки возвращаются. Как на сайте, 20 кадров в секунду в покое и 30 во время вспышки.
struct DotObject<Cover: View>: View {
    let phase: DotPhase
    let accent: RGB
    let photo: String?
    let size: CGFloat
    let paused: Bool
    @ViewBuilder let cover: () -> Cover

    @State private var clock = DotClock()
    @State private var lattice: Lattice?
    @State private var frame = 0
    @State private var revealed = false

    var body: some View {
        let lit = phase != .rest
        ZStack {
            // холст шире «Точки» на 48 с каждой стороны: тень и свечение не обрезаются
            Canvas { ctx, _ in
                _ = frame
                ctx.translateBy(x: 48, y: 48)
                if let g = lattice { drawDots(&ctx, g, clock, accent) }
            }
            .frame(width: size + 96, height: size + 96)
            .allowsHitTesting(false)
            if revealed {
                cover()
                    .frame(width: size, height: size)
                    .background(Color(hex: 0x15131A))
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).stroke(Ink.bone.opacity(0.08), lineWidth: 1))
                    .shadow(color: accent.color(0.45), radius: 34)
                    .transition(.opacity.animation(.easeOut(duration: 0.26)))
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if lattice?.s != Double(size) { lattice = Lattice(size: Double(size)) }
            clock.set(phase)
        }
        .onChange(of: size) { _, s in lattice = Lattice(size: Double(s)) }
        .onChange(of: phase) { _, p in
            clock.set(p)
            if p == .rest { revealed = false }
            frame &+= 1
        }
        .task(id: lit ? (photo ?? "") + "|lit" : "rest") {
            guard lit else { return }
            let img = await loadSquare(photo)
            if Task.isCancelled { return }
            clock.cover = img.map { Image(uiImage: $0) }
            clock.coverSide = Double(img?.size.width ?? 1)
            clock.imgReady = true
        }
        .task(id: paused) {
            if paused { return }
            var last = Date()
            while !Task.isCancelled {
                if clock.mode == .cover {
                    if !clock.cleared && Date().timeIntervalSince(clock.coverAt) > 0.3 {
                        clock.cleared = true
                        frame &+= 1
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    last = Date()
                    continue
                }
                let busy = clock.mode == .ignite || clock.mode == .reveal
                try? await Task.sleep(nanoseconds: busy ? 33_000_000 : 50_000_000)
                let now = Date()
                let dt = min(0.1, now.timeIntervalSince(last))
                last = now
                if clock.step(dt) {
                    withAnimation(.easeOut(duration: 0.26)) { revealed = true }
                }
                frame &+= 1
            }
        }
    }
}

private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
    return Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}

private func drawDots(_ ctx: inout GraphicsContext, _ g: Lattice, _ c: DotClock, _ accent: RGB) {
    if c.mode == .cover && c.cleared { return }
    let p = g.p
    let s = g.s
    // под точками мягкая тень: на сайте фон тёмный, а здесь под «Точкой» светится аура того же цвета
    ctx.fill(
        circle(s / 2, s / 2, s * 0.78),
        with: .radialGradient(Gradient(colors: [Color(hex: 0x0B0A0D).opacity(0.55), Color(hex: 0x0B0A0D).opacity(0)]), center: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endRadius: s * 0.78)
    )
    func icon(_ scale: Double, _ heat: Double, _ glow: Double, _ alpha: Double) {
        let center = CGPoint(x: s / 2, y: s / 2)
        ctx.fill(
            circle(s / 2, s / 2, s * 0.34),
            with: .radialGradient(Gradient(colors: [accent.color(min(1, 0.2 * glow) * alpha), accent.color(0)]), center: center, startRadius: 0, endRadius: s * 0.34)
        )
        for k in g.xs.indices where g.icon[k] {
            let shimmer = 0.5 + 0.5 * sin(c.t * 2.6 - g.ph[k] * 3.4)
            let r = p * (0.4 + 0.05 * shimmer) * scale
            ctx.fill(circle(g.xs[k], g.ys[k], r), with: .color(accent.mix(.hot, clamp01(0.3 + 0.16 * shimmer + heat)).color(0.96 * alpha)))
        }
    }
    switch c.mode {
    case .rest:
        let band = (c.t * 0.17).truncatingRemainder(dividingBy: 1.7) - 0.35
        for k in g.xs.indices where !g.icon[k] {
            let sd = (g.xs[k] + g.ys[k]) / (s * 2)
            let b = exp(-pow((sd - band) / 0.07, 2))
            let n = g.noise[k]
            ctx.fill(
                circle(g.xs[k], g.ys[k], (p / 10) * (1.25 + 0.3 * n + 1.2 * b)),
                with: .color(RGB.bone.mix(accent, b * 0.5).color((0.2 + 0.1 * n + 0.55 * b) * c.fade))
            )
        }
        icon(1, 0, 1, c.fade)
    case .ignite:
        let tau = c.tau
        let pop = exp(-pow((tau - 0.08) / 0.09, 2))
        let period = 1.1
        let ringT = tau < 0.04 ? -1 : (tau - 0.04).truncatingRemainder(dividingBy: period)
        let ringN = tau < 0.04 ? 0 : Int(floor((tau - 0.04) / period))
        let R = ringT < 0 ? -1 : eo(ringT / 0.78) * g.maxDm * 1.08
        let w = g.maxDm * 0.085
        let charge = ringN > 0 ? 1 : (R < 0 ? 0 : clamp01(R / g.maxDm))
        for k in g.xs.indices where !g.icon[k] {
            let d = g.dm[k]
            let ring = R < 0 ? 0 : exp(-pow((d - R) / w, 2)) * (1 - 0.45 * clamp01(R / g.maxDm))
            let swept: Double = (ringN > 0 || d < R) ? 1 : 0
            let n = g.noise[k]
            let a = 0.2 + 0.1 * n + 0.2 * swept * charge + 0.7 * ring
            ctx.fill(
                circle(g.xs[k], g.ys[k], (p / 10) * (1.25 + 0.3 * n + 0.4 * swept + 2.6 * ring)),
                with: .color(RGB.bone.mix(accent, 0.55 * swept).mix(.hot, ring * 0.8).color(min(1, a)))
            )
        }
        icon(1 + 0.9 * pop, pop * 0.8, 1 + pop, 1)
    case .reveal, .cover:
        // точки растут от середины к краям; через них видно обложку, пока они малы, на ней свет
        let tr = c.mode == .cover ? 2 : c.tau
        let rLit = p * 0.34
        let rFull = p * 0.8
        var bins = Array(repeating: Path(), count: 6)
        for k in g.xs.indices {
            let delay = (g.dm[k] / g.maxDm) * 0.46
            let e = eo((tr - delay) / 0.44)
            let r = rLit + (rFull - rLit) * e
            let b = min(5, Int(floor(e * 5.999)))
            bins[b].addEllipse(in: CGRect(x: g.xs[k] - r, y: g.ys[k] - r, width: r * 2, height: r * 2))
        }
        let light = accent.mix(.hot, 0.25)
        let plain = accent.mix(RGB(r: 20 / 255, g: 18 / 255, b: 24 / 255), 0.55)
        for b in 0..<6 where !bins[b].isEmpty {
            if let img = c.cover {
                ctx.fill(bins[b], with: .tiledImage(img, origin: .zero, sourceRect: CGRect(x: 0, y: 0, width: 1, height: 1), scale: s / c.coverSide))
            } else {
                ctx.fill(bins[b], with: .color(plain.color()))
            }
            ctx.fill(bins[b], with: .color(light.color(0.85 * (1 - (Double(b) + 0.5) / 6))))
        }
    }
}

/// Ход трека точками, как на сайте: пройденные светлые, текущая точка Blink с ореолом. Нажать или вести пальцем: перемотка.
struct DotProgress: View {
    let positionMs: Int64
    let durationMs: Int64
    let accent: RGB
    let seek: (Int64) -> Void
    @State private var drag: Double?

    var body: some View {
        let duration = max(0, durationMs)
        let fraction = drag ?? (duration > 0 ? min(1, max(0, Double(positionMs) / Double(duration))) : 0)
        let label = BType(name: "Manrope-SemiBold", size: 12, line: 16, tracking: 0)
        HStack(spacing: 8) {
            T(Format.duration(Int(fraction * Double(duration) / 1000)), label, color: Ink.bone.opacity(0.6), lines: 1)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let count = min(90, max(24, Int(floor(w / 7.2))))
                Canvas { ctx, size in
                    let pad = 6.0
                    let step = (size.width - pad * 2) / Double(count - 1)
                    let idx = Int((fraction * Double(count - 1)).rounded())
                    let cy = size.height / 2
                    for i in 0..<count where i != idx {
                        let played = i < idx
                        ctx.fill(circle(pad + Double(i) * step, cy, played ? 1.7 : 1.5), with: .color(Ink.bone.opacity(played ? 0.92 : 0.24)))
                    }
                    let x = pad + Double(idx) * step
                    ctx.fill(circle(x, cy, 8), with: .color(accent.color(0.22)))
                    ctx.fill(circle(x, cy, 4.4), with: .color(accent.color()))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in drag = min(1, max(0, (v.location.x - 6) / max(1, w - 12))) }
                        .onEnded { v in
                            let f = min(1, max(0, (v.location.x - 6) / max(1, w - 12)))
                            drag = nil
                            if duration > 0 { seek(Int64(f * Double(duration))) }
                        }
                )
            }
            .frame(height: 22)
            .accessibilityLabel("Ход трека")
            T(Format.duration(Int(duration / 1000)), label, color: Ink.bone.opacity(0.6), lines: 1)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// Большая кнопка «играть» сайта (.iris.big на главной): круг цвета обложки, кольцо 8 pt и свечение снизу.
struct IrisButton: View {
    let playing: Bool
    let buffering: Bool
    let accent: RGB
    let ink: Color
    var size: CGFloat = 78
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(accent.color()).frame(width: size, height: size)
                if buffering {
                    Spinner(color: ink, size: size * 0.5)
                } else {
                    LineIconView(playing ? .pause : .play, color: ink, size: size * 0.36, stroke: 2.2)
                }
            }
            .background(Circle().fill(accent.color(0.18)).frame(width: size + 16, height: size + 16))
            .shadow(color: accent.color(0.7), radius: 22, y: 14)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(playing ? "Пауза" : "Играть")
    }
}

/// Круглая кнопка без фона (.hm-b): 50 pt, светлая, выбранная цвета обложки.
struct BareButton: View {
    let icon: LineIcon
    let label: String
    let iconSize: CGFloat
    var on: Bool = false
    var accent: Color = Ink.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LineIconView(icon, color: on ? accent : Ink.bone, size: iconSize)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

// ---------------------------------------------------------------- заставка

/// Поле заставки: точки на весь экран и слово «blink» из точек, точка Blink справа от слова.
private struct WordField {
    var pitch = 6.0
    var px = 0.0
    var py = 0.0
    var dotR = 1.0
    var far = 1.0
    var wx: [Double] = []
    var wy: [Double] = []
    var wcov: [Double] = []
    var wdm: [Double] = []
    var dim: Image?
    var lit: Image?
    var hot: Image?

    init(w: Double, h: Double) {
        pitch = max(5.5, sqrt(w * h / 9000))
        let cols = Int(ceil(w / pitch))
        let rows = Int(ceil(h / pitch))
        let fs = min(w * 0.78 / 3.2, h * 0.3)
        let cx = w / 2
        let cy = h * 0.46
        let font = UIFont(name: "Unbounded-SemiBold", size: fs / pitch) ?? .systemFont(ofSize: fs / pitch, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .kern: -0.04 * fs / pitch]
        let m = ("blink" as NSString).size(withAttributes: attrs).width
        dotR = fs * 0.1
        let x0 = (Double(cols) - (m + dotR * 3.4 / pitch)) / 2
        let base = cy / pitch + fs * 0.36 / pitch
        var cov = [UInt8](repeating: 0, count: cols * rows)
        if let ctx = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: cols, height: rows))
            ctx.translateBy(x: 0, y: CGFloat(rows))
            ctx.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(ctx)
            ("blink" as NSString).draw(at: CGPoint(x: x0, y: base - font.ascender), withAttributes: attrs)
            UIGraphicsPopContext()
            if let data = ctx.data {
                let bpr = ctx.bytesPerRow
                let bytes = data.bindMemory(to: UInt8.self, capacity: bpr * rows)
                for j in 0..<rows {
                    for i in 0..<cols { cov[j * cols + i] = bytes[j * bpr + i] }
                }
            }
        }
        px = (x0 + m) * pitch + dotR * 1.9
        py = (base - fs * 0.09 / pitch) * pitch
        far = max(px, w - px) + max(py, h - py)
        var lx: [Double] = [], ly: [Double] = [], ln: [Double] = [], lv: [Double] = []
        let diag = hypot(w, h)
        for j in 0..<rows {
            for i in 0..<cols {
                let x = (Double(i) + 0.5) * pitch
                let y = (Double(j) + 0.5) * pitch
                let c = Double(cov[j * cols + i]) / 255
                let d = abs(x - px) + abs(y - py)
                let n = hash(i, j)
                let vig = 1 - clamp01((hypot(x - cx, y - cy) / diag - 0.18) / 0.32)
                if c > 0.3 {
                    wx.append(x); wy.append(y); wcov.append(c); wdm.append(d)
                } else {
                    lx.append(x); ly.append(y); ln.append(n); lv.append(vig)
                }
            }
        }
        // три неподвижных слоя (тусклый, зажжённый, раскалённый) рисуются один раз, кадр это несколько картинок
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        func layer(_ r: Double, _ color: RGB, _ alphaOf: (Double, Double) -> Double) -> Image {
            let img = renderer.image { rc in
                let g = rc.cgContext
                for q in lx.indices {
                    let a = alphaOf(ln[q], lv[q])
                    if a < 0.01 { continue }
                    g.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: a)
                    let rr = r * (0.8 + 0.5 * ln[q])
                    g.fillEllipse(in: CGRect(x: lx[q] - rr, y: ly[q] - rr, width: rr * 2, height: rr * 2))
                }
            }
            return Image(uiImage: img)
        }
        dim = layer(pitch * 0.15, .bone) { n, v in (0.12 + 0.07 * n) * (0.15 + 0.85 * v) }
        lit = layer(pitch * 0.2, RGB.bone.mix(.accent, 0.6)) { n, v in (0.26 + 0.1 * n) * (0.15 + 0.85 * v) }
        hot = layer(pitch * 0.3, .hot) { _, v in 0.95 * (0.35 + 0.65 * v) }
    }

    func diamond(_ r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: px - r, y: py))
        p.addLine(to: CGPoint(x: px, y: py - r))
        p.addLine(to: CGPoint(x: px + r, y: py))
        p.addLine(to: CGPoint(x: px, y: py + r))
        p.closeSubpath()
        return p
    }
}

private func drawWord(_ ctx: inout GraphicsContext, _ f: WordField, _ size: CGSize, _ t: Double, _ flood: Double) {
    let full = CGRect(origin: .zero, size: size)
    if let dim = f.dim { ctx.draw(dim, in: full) }
    let ring = clamp01((t - 0.3) / 0.62)
    let R = eo(ring) * f.far * 1.12
    if t > 0.3 {
        // внутри кольца точки горят, на самом кольце раскалены
        if let lit = f.lit {
            ctx.drawLayer { c in
                c.clip(to: f.diamond(R))
                c.opacity = 0.9
                c.draw(lit, in: full)
            }
        }
        if ring < 1, let hot = f.hot {
            var band = f.diamond(R)
            band.addPath(f.diamond(max(0, R - f.far * 0.07)))
            ctx.drawLayer { c in
                c.clip(to: band, style: FillStyle(eoFill: true))
                c.opacity = 1 - ring * 0.6
                c.draw(hot, in: full)
            }
        }
    }
    // буквы вырастают из точек, когда по ним проходит кольцо
    for k in f.wx.indices {
        let q = clamp01((R - f.wdm[k]) / (f.far * 0.1))
        let e = eo(q)
        let r = f.pitch * 0.5 * (0.2 + 0.78 * e) * min(1, f.wcov[k] * 1.2) * (1 + 0.3 * flood)
        if r < 0.3 { continue }
        ctx.fill(circle(f.wx[k], f.wy[k], r), with: .color(RGB.bone.mix(.hot, (1 - q) * 0.7).mix(.hot, flood).color(0.2 + 0.8 * e)))
    }
    // точка: сперва выскакивает, потом моргает, пока ждём
    let pop = eo(t / 0.3)
    var bl = 1.0
    if t > 1.1 {
        let ph = (t - 1.1).truncatingRemainder(dividingBy: 2.4) / 2.4
        if ph < 0.05 { bl = 1 - 0.85 * sin(ph / 0.05 * .pi) }
    }
    let r = f.dotR * (0.3 + 0.7 * pop) * (1 + 0.12 * flood)
    ctx.fill(
        circle(f.px, f.py, r * 5),
        with: .radialGradient(Gradient(colors: [RGB.accent.color(0.45 + 0.4 * flood), RGB.accent.color(0)]), center: CGPoint(x: f.px, y: f.py), startRadius: 0, endRadius: r * 5)
    )
    let ry = max(0.5, r * bl)
    ctx.fill(Path(ellipseIn: CGRect(x: f.px - r, y: f.py - ry, width: r * 2, height: ry * 2)), with: .color(RGB.accent.mix(.hot, flood * 0.8).color()))
    if flood > 0, let hot = f.hot {
        ctx.drawLayer { c in
            c.opacity = flood * 0.9
            c.draw(hot, in: full)
        }
    }
}

/// Заставка при запуске, как в приложении на сайте: из точки Blink бежит ромбическое кольцо света по полю точек,
/// буквы «blink» вырастают из точек, точка моргает; через 1,15 с всё вспыхивает светом и заставка уходит.
/// `freezeAt` держит один кадр (снимки экрана для отчёта).
struct DotIntro: View {
    let freezeAt: Double?
    let onDone: () -> Void
    @State private var field: WordField?
    @State private var start = Date()
    @State private var gone = false

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: freezeAt != nil || field == nil)) { tl in
                Canvas { ctx, size in
                    guard let f = field else { return }
                    let t = freezeAt ?? tl.date.timeIntervalSince(start)
                    let flood = freezeAt == nil && t > 1.15 ? eo((t - 1.15) / 0.22) : 0
                    drawWord(&ctx, f, size, t, flood)
                }
            }
            .task {
                let w = Double(geo.size.width)
                let h = Double(geo.size.height)
                let made = await Task.detached(priority: .userInitiated) { WordField(w: w, h: h) }.value
                field = made
                start = Date()
                if freezeAt != nil { return }
                try? await Task.sleep(nanoseconds: 1_370_000_000)
                withAnimation(.easeOut(duration: 0.32)) { gone = true }
                try? await Task.sleep(nanoseconds: 330_000_000)
                onDone()
            }
        }
        .background(Ink.ink)
        .ignoresSafeArea()
        .opacity(gone ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityLabel("Заставка Blink")
    }
}
