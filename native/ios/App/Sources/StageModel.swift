import SwiftUI
import UIKit
import BlinkCore

/// Значок сайта (ui/Icon.jsx): обводка 1.75 при размере 24, круглые концы, местами заливка.
struct LineIconView: View {
    private let icon: LineIcon
    private let color: Color
    private let size: CGFloat
    private let stroke: CGFloat

    init(_ icon: LineIcon, color: Color = Ink.bone, size: CGFloat = 24, stroke: CGFloat = 1.75) {
        self.icon = icon
        self.color = color
        self.size = size
        self.stroke = stroke
    }

    var body: some View {
        ZStack {
            ForEach(Array(icon.parts.enumerated()), id: \.offset) { _, part in
                let shape = GlyphShape(ops: LineIconCache.ops(part.d))
                if part.fill {
                    shape.fill(color)
                } else {
                    shape.stroke(color, style: StrokeStyle(lineWidth: stroke * size / 24, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum LineIconCache {
    private static let lock = NSLock()
    private static var cache: [String: [PathOp]] = [:]

    static func ops(_ d: String) -> [PathOp] {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[d] { return hit }
        let parsed = SvgPath.parse(d)
        cache[d] = parsed
        return parsed
    }
}

extension Hsl {
    var color: Color {
        let c = rgb
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// `color-mix(in srgb, this pct%, other)`: как в CSS, с учётом прозрачности второго цвета.
    func mix(_ pct: Double, with other: (r: Double, g: Double, b: Double, a: Double)) -> Color {
        let c = rgb
        let a = pct + other.a * (1 - pct)
        guard a > 0 else { return .clear }
        func ch(_ x: Double, _ y: Double) -> Double { return (x * pct + y * other.a * (1 - pct)) / a }
        return Color(.sRGB, red: ch(c.r, other.r), green: ch(c.g, other.g), blue: ch(c.b, other.b), opacity: a)
    }
}

/// Обложки с медленных хостов идут через сервер Blink (lib/img.js `proxied`).
enum Img {
    private static let via = try? NSRegularExpression(pattern: "^https://(lh\\d\\.googleusercontent\\.com|([a-z0-9-]+\\.)?mzstatic\\.com|([a-z0-9-]+\\.)?dzcdn\\.net|([a-z0-9-]+\\.)?sndcdn\\.com|avatars\\.yandex\\.net)/", options: [.caseInsensitive])

    static func proxied(_ url: String) -> String {
        guard !url.isEmpty, let re = via, re.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)) != nil else { return url }
        let q = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
        return Graph.baseURL + "/api/img?u=" + q
    }
}

/// Всё, что плеер берёт от текущего трека: палитра из обложки, текст песни, перевод, фото артиста.
/// Методы зовёт интерфейс с главного потока; результаты загрузок возвращаются туда же.
final class StageModel: ObservableObject {
    enum LyricsState: Equatable {
        case loading
        case failed
        case none
        case data(LyricsData)
    }

    enum TrState: Equatable {
        case off
        case loading
        case on([String: String])
        case native
        case error
    }

    @Published private(set) var palette = Palette.fallback
    @Published private(set) var lyrics: LyricsState = .loading
    @Published private(set) var photo: String?
    @Published private(set) var tr: TrState = .off
    @Published private(set) var translate: Bool

    private let api: LyricsApi
    private let photos: ArtistPhotos
    private var track: Track?
    private var paletteCache: [String: Palette] = [:]
    private var work: [Task<Void, Never>] = []

    init(api: LyricsApi, photos: ArtistPhotos) {
        self.api = api
        self.photos = photos
        translate = UserDefaults.standard.bool(forKey: "blink.lyricsTr")
    }

    /// Фото артиста для полки «Любимые артисты» на главной.
    func artistPhoto(_ t: Track) async -> String? {
        return await photos.photo(t)
    }

    var hasLyrics: Bool {
        if case .data(let d) = lyrics, d != .instrumental { return true }
        return false
    }

    func trackChanged(_ next: Track?) {
        guard next?.id != track?.id else { return }
        track = next
        work.forEach { $0.cancel() }
        work = []
        photo = nil
        tr = .off
        guard let t = next else {
            lyrics = .loading
            return
        }
        loadLyrics(t)
        let art = t.artwork
        if let hit = paletteCache[art] {
            withAnimation(.easeOut(duration: 1.2)) { palette = hit }
        } else {
            work.append(Task { [weak self] in
                let p = await StageModel.palette(art)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self = self else { return }
                    self.paletteCache[art] = p
                    withAnimation(.easeOut(duration: 1.2)) { self.palette = p }
                }
            })
        }
        let photos = self.photos
        work.append(Task { [weak self] in
            let u = await photos.photo(t)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, self.track?.id == t.id else { return }
                self.photo = u
            }
        })
    }

    func retry() {
        if let t = track { loadLyrics(t) }
    }

    func toggleTranslate() {
        translate.toggle()
        UserDefaults.standard.set(translate, forKey: "blink.lyricsTr")
        refreshTranslation()
    }

    private func loadLyrics(_ t: Track) {
        if let hit = api.cached(t.id) {
            lyrics = hit.map { .data($0) } ?? .none
            refreshTranslation()
            return
        }
        lyrics = .loading
        let api = self.api
        work.append(Task { [weak self] in
            let result: LyricsState
            do {
                result = try await api.load(t).map { .data($0) } ?? .none
            } catch {
                result = .failed
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, self.track?.id == t.id else { return }
                self.lyrics = result
                self.refreshTranslation()
            }
        })
    }

    private func refreshTranslation() {
        guard translate, let t = track, case .data(let d) = lyrics, d != .instrumental else {
            tr = .off
            return
        }
        if d.isRussian {
            tr = .native
            return
        }
        tr = .loading
        let api = self.api
        work.append(Task { [weak self] in
            let next: TrState
            do {
                let map = try await api.translate(t.id, d.texts)
                next = map.isEmpty ? .native : .on(map)
            } catch {
                next = .error
            }
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self = self, self.track?.id == t.id, self.translate else { return }
                self.tr = next
            }
        })
    }

    /// Обложка 24×24 → палитра, как canvas на сайте.
    private static func palette(_ url: String) async -> Palette {
        guard !url.isEmpty else { return .fallback }
        let small = ArtUrl.scaled(url, 100)
        var data: Data?
        for candidate in [Img.proxied(small), small] {
            guard let u = URL(string: candidate) else { continue }
            if let pair = try? await URLSession.shared.data(from: u), ((pair.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400 {
                data = pair.0
                break
            }
        }
        guard let d = data, let img = UIImage(data: d), let cg = img.cgImage else { return .fallback }
        return await Task.detached(priority: .utility) { () -> Palette in
            let w = 24, h = 24
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ok: Bool = px.withUnsafeMutableBytes { buf in
                guard let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? Palette.from(rgba: px) : .fallback
        }.value
    }
}

/// Фон из обложки во весь экран: размыто, притемнено, чуть ярче цвета (.ps-bg на сайте).
struct BlurredCover: View {
    let url: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(hex: 0x0B0A0D)
                if let u = URL(string: Img.proxied(ArtUrl.scaled(url, 600))), !url.isEmpty {
                    AsyncImage(url: u) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .saturation(1.25)
                                .colorMultiply(Color(white: 0.42))
                                .blur(radius: 30)
                                .scaleEffect(1.15)
                                .transition(.opacity)
                        }
                    }
                    .id(url)
                }
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x08070A, opacity: 0.6), location: 0),
                    .init(color: Color(hex: 0x08070A, opacity: 0.05), location: 0.18),
                    .init(color: Color(hex: 0x08070A, opacity: 0), location: 0.42),
                    .init(color: Color(hex: 0x08070A, opacity: 0.78), location: 0.64),
                    .init(color: Color(hex: 0x08070A, opacity: 0.96), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.9), value: url)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Картинка по адресу с заглушкой, обрезанная по форме.
struct NetImage: View {
    let url: String?
    var placeholder: Color = Color.white.opacity(0.06)

    var body: some View {
        ZStack {
            placeholder
            if let s = url, !s.isEmpty, let u = URL(string: Img.proxied(s)) {
                AsyncImage(url: u) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
