import SwiftUI
import BlinkCore

/// Главная: сверху большая Вспышка (фон из обложки, кнопка, режимы), ниже «Коллекция»:
/// «Мне нравится», скачанное, плейлисты, любимые артисты и последние лайки. Порт ui/FlashScreen.kt.
struct FlashView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var version: LibraryVersion

    let bottomInset: CGFloat

    var body: some View {
        _ = version.value
        let ui = player.value
        let liked = flash.likes
        let playlists = graph.library.playlists
        let artists = FlashView.favouriteArtists(liked)
        return GeometryReader { geo in
        ZStack(alignment: .top) {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FlashHero(top: geo.safeAreaInsets.top, bottom: Chrome.dock + Chrome.gap * 2 + 18 + geo.safeAreaInsets.bottom)
                    .frame(height: geo.size.height + geo.safeAreaInsets.top)
                HStack(alignment: .lastTextBaseline) {
                    T("Коллекция", .h1)
                    Spacer(minLength: 0)
                    Button { graph.nav.openLibrary() } label: { T("Всё", .button, color: Ink.mute).padding(6) }
                        .buttonStyle(TapStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .id("collection")
                HStack(spacing: 10) {
                    LikesTile(count: liked.count) { graph.nav.openLibrary(.likes) }
                    CollectionTile(icon: .download, title: "Скачанное", sub: "Без интернета") { graph.nav.go(.downloads) }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Shelf(title: "Плейлисты", action: "Все") { graph.nav.openLibrary() }
                    .padding(.top, 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(playlists) { p in
                            ShelfCard(cover: p.cover ?? p.tracks.first?.artwork ?? "", icon: nil, title: p.name, sub: Format.tracks(p.tracks.count)) {
                                graph.nav.openLibrary(.mine(p.id))
                            }
                        }
                        ShelfCard(cover: nil, icon: .plus, title: "Перенести музыку", sub: "Яндекс, Spotify") { graph.nav.openLibrary(.importMusic) }
                    }
                    .padding(.horizontal, 16)
                }
                if !artists.isEmpty {
                    Shelf(title: "Любимые артисты", action: nil) {}
                        .padding(.top, 22)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(artists, id: \.name) { a in
                                ArtistBubble(name: a.name, track: a.tracks[0]) {
                                    if let id = a.tracks[0].artistId { graph.nav.openArtist(id) } else { graph.actions.play(a.tracks, at: 0) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                Shelf(title: "Понравившееся", action: liked.count > 6 ? "Все \(liked.count)" : nil) { graph.nav.openLibrary(.likes) }
                    .padding(.top, 22)
                if liked.isEmpty {
                    T("Нажимайте сердечко у треков, и они соберутся здесь и на вашем аккаунте на сайте.", .small, color: Ink.faint)
                        .padding(.horizontal, 20)
                } else {
                    ForEach(Array(liked.prefix(6).enumerated()), id: \.element.id) { i, track in
                        LikedRow(track: track, current: track.id == ui.track?.id) { graph.actions.play(liked, at: i) }
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
        .task {
            guard let anchor = LaunchHooks.startScroll else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            proxy.scrollTo(anchor, anchor: .top)
        }
        }
        .ignoresSafeArea(edges: .top)
        // под часами и значками строки состояния, когда главная прокручена вниз
        LinearGradient(colors: [Color(hex: 0x0B0A0D), Color(hex: 0x0B0A0D).opacity(0.85), Color(hex: 0x0B0A0D).opacity(0)], startPoint: .top, endPoint: .bottom)
            .frame(height: geo.safeAreaInsets.top + 12)
            .offset(y: -geo.safeAreaInsets.top)
            .allowsHitTesting(false)
        }
        }
    }

    struct FavArtist {
        let name: String
        let tracks: [Track]
    }

    /// Артисты из лайков: у кого больше всего понравившихся треков.
    static func favouriteArtists(_ liked: [Track]) -> [FavArtist] {
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for t in liked {
            let name = LyricsApi.mainArtist(t.artist)
            if name.isEmpty { continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(t)
        }
        let sorted = order.enumerated().sorted { a, b in
            let ca = groups[a.element]?.count ?? 0
            let cb = groups[b.element]?.count ?? 0
            return ca != cb ? ca > cb : a.offset < b.offset
        }
        return sorted.prefix(12).map { FavArtist(name: $0.element, tracks: groups[$0.element] ?? []) }
    }
}

private extension Hsl {
    /// Яркий вариант цвета палитры для свечения: светлее и насыщеннее, в том же тоне.
    func vivid(_ l: Double = 0.56, _ s: Double = 0.85) -> Hsl {
        return Hsl(h, min(1, max(self.s, s)), max(self.l, l))
    }
}

/// Живой свет за Вспышкой (порт ui/AuraGL.jsx): три мягких пятна цветов обложки плывут, тёплое ядро дышит,
/// к низу и краям темнеет. 30 кадров в секунду.
struct FlashAura: View {
    let palette: Palette
    let energy: Double

    var body: some View {
        let c0 = palette.accent.vivid(0.58).color
        let c1 = palette.glowB.vivid(0.5).color
        let c2 = palette.glowA.vivid(0.52).color
        let c3 = palette.accent.vivid(0.66, 0.9).color
        return TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            Canvas { g, size in
                let w = size.width
                let h = size.height
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [c1.opacity(0.10), c0.opacity(0.06)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                func blob(_ ux: Double, _ uy: Double, _ k: Double, _ c: Color, _ amp: Double) {
                    let r = (4.6 / k).squareRoot() * w
                    let a = min(1, max(0, amp))
                    let center = CGPoint(x: ux * w, y: uy * h)
                    var layer = g
                    layer.blendMode = .plusLighter
                    layer.translateBy(x: center.x, y: center.y)
                    layer.scaleBy(x: 1, y: h / w * 0.62)
                    let grad = Gradient(stops: [
                        .init(color: c.opacity(a), location: 0),
                        .init(color: c.opacity(a * 0.75), location: 0.25),
                        .init(color: c.opacity(a * 0.32), location: 0.5),
                        .init(color: c.opacity(a * 0.075), location: 0.75),
                        .init(color: c.opacity(0), location: 1),
                    ])
                    layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)), with: .radialGradient(grad, center: .zero, startRadius: 0, endRadius: r))
                }
                let s = t * 0.16
                blob(0.22 + 0.12 * sin(s * 0.9), 1 - (0.78 + 0.08 * cos(s * 0.7)), 6, c0, 0.62)
                blob(0.80 + 0.10 * cos(s * 0.8 + 1), 1 - (0.46 + 0.12 * sin(s * 0.6)), 6.5, c1, 0.55)
                blob(0.46 + 0.14 * sin(s * 0.5 + 2), 1 - (0.16 + 0.08 * cos(s * 0.9 + 2)), 7, c2, 0.45)
                let beat = pow(0.5 + 0.5 * sin(t * 0.9), 3)
                blob(0.5, 0.40, 7, c3, 0.34 + 0.22 * energy + 0.24 * beat * energy)
                blob(0.5, 0.40, 3, c3, 0.12)
                let dark = Color(hex: 0x08070A)
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .clear, location: 0.4),
                    .init(color: dark.opacity(0.35), location: 0.7), .init(color: dark.opacity(0.78), location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(Gradient(stops: [
                    .init(color: .clear, location: 0.5), .init(color: dark.opacity(0.55), location: 1),
                ]), center: CGPoint(x: w / 2, y: h * 0.45), startRadius: 0, endRadius: max(w, h) * 0.75))
            }
        }
        .animation(.easeOut(duration: 1.5), value: palette)
        .allowsHitTesting(false)
    }
}

/// Главный экран Вспышки на всю высоту, как «Моя волна», но в стиле Blink: живой свет цветов обложки,
/// большое «Вспышка.», светящаяся кнопка. Когда играет: артист крупно, обложка, пауза, плашка трека и сердце.
private struct FlashHero: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var stage: StageModel
    let top: CGFloat
    let bottom: CGFloat
    @State private var dx: CGFloat = 0

    var body: some View {
        let ui = player.value
        let p = stage.palette
        let accent = p.accent.color
        let ink = p.accentInk.color
        let flashing = flash.active && ui.track != nil
        return ZStack {
            Color(hex: 0x0B0A0D)
            FlashAura(palette: p, energy: ui.playing ? 1 : 0.35)
            VStack(spacing: 0) {
                header(flashing: flashing, accent: accent, ink: ink)
                    .frame(height: 48)
                Spacer(minLength: 8)
                if flashing, let t = ui.track {
                    playing(t, ui: ui, accent: accent)
                } else {
                    rest(ui.track, accent: accent, ink: ink)
                }
                Spacer(minLength: 8)
                ModeBubbles(palette: p, mode: flash.mode) { m in
                    flash.setMode(m)
                    if !flash.active && !flash.loading { flash.start() }
                }
            }
            .padding(.top, top + 10)
            .padding(.bottom, bottom)
        }
    }

    @ViewBuilder
    private func header(flashing: Bool, accent: Color, ink: Color) -> some View {
        if flashing {
            HStack(spacing: 8) {
                T("Вспышка · " + flash.mode.title, BType.button.sized(15), color: accent, lines: 1)
                Button { flash.stop() } label: {
                    LineIconView(.close, color: ink, size: 16, stroke: 2.4)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(accent))
                }
                .buttonStyle(PressScale())
                .accessibilityLabel("Остановить Вспышку")
            }
            .padding(.leading, 18)
            .padding(.trailing, 5)
            .frame(height: 44)
            .background(Capsule().fill(Color.black.opacity(0.25)))
            .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 1))
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                T("blink", BType.h2.sized(20, tracking: -0.6))
                Circle().fill(accent).frame(width: 6, height: 6)
            }
        }
    }

    private func rest(_ track: Track?, accent: Color, ink: Color) -> some View {
        let hint: String = {
            let names = FlashView.favouriteArtists(flash.likes).prefix(3).map { $0.name }
            return names.isEmpty ? "Слушайте и ставьте лайки, и поток подстроится под вас" : names.joined(separator: ", ") + " и похожее на них"
        }()
        return VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                T("Вспышка", BType.display.sized(56, tracking: -3), lines: 1)
                Circle().fill(accent).frame(width: 10, height: 10)
            }
            Button { flash.start() } label: {
                ZStack {
                    Circle().fill(accent).frame(width: 112, height: 112)
                        .shadow(color: accent.opacity(0.65), radius: 36)
                    if flash.loading {
                        Spinner(color: ink, size: 48)
                    } else {
                        LineIconView(.play, color: ink, size: 46, stroke: 2.2)
                    }
                }
            }
            .buttonStyle(PressScale())
            .disabled(flash.loading)
            .accessibilityLabel("Включить Вспышку")
            .padding(.top, 26)
            if let t = track {
                let liked = flash.isLiked(t)
                HStack(spacing: 0) {
                    Button { graph.nav.openPlayer(true) } label: {
                        T("\(t.artist) — \(t.title)", BType.title.sized(16), lines: 1, align: .center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TapStyle())
                    StageIcon(liked ? .heartFill : .heart, "Любимое", size: 24, box: 48, on: liked) { flash.toggleLike(t) }
                }
                .padding(.leading, 22)
                .padding(.trailing, 6)
                .frame(height: 60)
                .background(Capsule().fill(Color.black.opacity(0.25)))
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                .padding(.horizontal, 24)
                .padding(.top, 26)
            }
            T(flash.loading ? "Подбираю музыку…" : hint, BType.body.sized(16), color: Ink.bone.opacity(0.85), lines: 2, align: .center)
                .padding(.horizontal, 36)
                .padding(.top, track == nil ? 26 : 18)
        }
        .frame(maxWidth: .infinity)
    }

    private func playing(_ t: Track, ui: PlayerUi, accent: Color) -> some View {
        let liked = flash.isLiked(t)
        let fraction = ui.durationMs > 0 ? min(1, max(0, Double(ui.positionMs) / Double(ui.durationMs))) : 0
        return VStack(spacing: 0) {
            T(t.artist, BType.display.sized(40, tracking: -1.8), lines: 2, align: .center)
                .padding(.horizontal, 20)
            Button { graph.nav.openPlayer(true) } label: {
                NetImage(url: ArtUrl.scaled(t.artwork, 400))
                    .frame(width: 148, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: accent.opacity(0.5), radius: 30)
            }
            .buttonStyle(PressScale())
            .offset(x: dx * 0.35)
            .simultaneousGesture(DragGesture(minimumDistance: 20).onChanged { dx = $0.translation.width }.onEnded { v in
                if v.translation.width < -90 { graph.player.next() } else if v.translation.width > 90 { graph.player.previous() }
                withAnimation(.easeOut(duration: 0.2)) { dx = 0 }
            })
            .accessibilityLabel("Открыть плеер")
            .padding(.top, 26)
            HStack(spacing: 8) {
                RoundGlass(icon: ui.playing ? .pause : .play, label: ui.playing ? "Пауза" : "Играть") { graph.player.toggle() }
                Button { graph.nav.openPlayer(true) } label: {
                    T(t.title, BType.title.sized(17), lines: 1, align: .center)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 64, maxHeight: 64)
                        .background(
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Color.black.opacity(0.2)
                                    accent.opacity(0.3).frame(width: g.size.width * fraction)
                                }
                            }
                        )
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
                }
                .buttonStyle(TapStyle())
                RoundGlass(icon: liked ? .heartFill : .heart, label: "Любимое", on: liked, accent: accent) { flash.toggleLike(t) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            HStack(spacing: 18) {
                QuietAction(icon: .thumbDown, label: "Не моё") { flash.dislike(t) }
                QuietAction(icon: .next, label: "Дальше") { graph.player.next() }
            }
            .padding(.top, 14)
        }
    }
}

private struct RoundGlass: View {
    let icon: LineIcon
    let label: String
    var on: Bool = false
    var accent: Color = Ink.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LineIconView(icon, color: on ? accent : Ink.bone, size: 26)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.black.opacity(0.2)))
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

private struct QuietAction: View {
    let icon: LineIcon
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LineIconView(icon, color: Ink.bone.opacity(0.7), size: 18)
                T(label, BType.button.sized(13), color: Ink.bone.opacity(0.7), lines: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// Режимы потока пузырями внизу экрана: у каждого свой цвет из палитры, выбранный ярче.
private struct ModeBubbles: View {
    let palette: Palette
    let mode: WaveMode
    let pick: (WaveMode) -> Void

    var body: some View {
        let hues = [palette.accent, palette.glowB, palette.glowA, palette.glowC]
        let icons: [LineIcon] = [.bolt, .heart, .search, .plus]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(WaveMode.allCases.enumerated()), id: \.element.rawValue) { i, m in
                    let on = m == mode
                    let c = hues[i % hues.count].vivid(0.5).color
                    let shape = UnevenRoundedRectangle(topLeadingRadius: 59, bottomLeadingRadius: 24, bottomTrailingRadius: 24, topTrailingRadius: 59, style: .continuous)
                    Button { pick(m) } label: {
                        VStack(spacing: 0) {
                            LineIconView(icons[i % icons.count], color: Ink.bone.opacity(on ? 1 : 0.75), size: 24)
                            Spacer(minLength: 0)
                            T(m.title, BType.button.sized(14), color: Ink.bone.opacity(on ? 1 : 0.8), lines: 1)
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 14)
                        .frame(width: 118, height: 112)
                        .background(shape.fill(LinearGradient(colors: [c.opacity(on ? 0.95 : 0.55), c.opacity(on ? 0.35 : 0.12)], startPoint: .top, endPoint: .bottom)))
                        .overlay(shape.stroke(Color.white.opacity(on ? 0.4 : 0.08), lineWidth: on ? 1.5 : 1))
                    }
                    .buttonStyle(PressScale())
                    .accessibilityLabel("Режим \(m.title)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct Shelf: View {
    let title: String
    let action: String?
    let onAction: () -> Void

    var body: some View {
        HStack {
            T(title, .h2)
            Spacer(minLength: 0)
            if let a = action {
                Button(action: onAction) { T(a, BType.button.sized(13), color: Ink.mute).padding(6) }
                    .buttonStyle(TapStyle())
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }
}

/// «Мне нравится»: плитка цвета акцента с сердцем и числом треков.
private struct LikesTile: View {
    @EnvironmentObject private var stage: StageModel
    let count: Int
    let action: () -> Void

    var body: some View {
        let p = stage.palette
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                LineIconView(.heartFill, color: Ink.bone, size: 22)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.black.opacity(0.2)))
                Spacer(minLength: 0)
                T("Мне нравится", .h2, lines: 1)
                T(Format.tracks(count), .small, color: Ink.bone.opacity(0.75), lines: 1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .leading)
            .background(LinearGradient(colors: [p.accent.color.opacity(0.95), p.glowB.color.opacity(0.85), Ink.ink3], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Мне нравится")
    }
}

private struct CollectionTile: View {
    let icon: LineIcon
    let title: String
    let sub: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                LineIconView(icon, color: Ink.bone, size: 22)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Spacer(minLength: 0)
                T(title, .h2, lines: 1)
                T(sub, .small, color: Ink.mute, lines: 1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .leading)
            .background(Ink.ink2)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(title)
    }
}

private struct ShelfCard: View {
    let cover: String?
    let icon: LineIcon?
    let title: String
    let sub: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let c = cover {
                        NetImage(url: ArtUrl.scaled(c, 300))
                    } else {
                        Ink.ink2
                        if let i = icon { LineIconView(i, color: Ink.bone.opacity(0.7), size: 34) }
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                T(title, .title, lines: 1)
                    .padding(.top, 8)
                T(sub, .small, color: Ink.mute, lines: 1)
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(PressScale())
    }
}

private struct ArtistBubble: View {
    @EnvironmentObject private var stage: StageModel
    let name: String
    let track: Track
    let action: () -> Void
    @State private var photo: String?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                NetImage(url: photo ?? ArtUrl.scaled(track.artwork, 200))
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                T(name, BType.small, lines: 1, align: .center)
            }
            .frame(width: 88)
        }
        .buttonStyle(PressScale())
        .task(id: name) { photo = await stage.artistPhoto(track) }
    }
}

private struct LikedRow: View {
    let track: Track
    let current: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Cover(track.artwork, size: 52, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    T(track.title, .title, color: current ? Ink.accent : Ink.bone, lines: 1)
                    T(track.artist, .small, color: Ink.mute, lines: 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
    }
}

/// Сердечко: лайк трека. Лайки уходят в аккаунт и видны на сайте.
struct LikeButton: View {
    @EnvironmentObject private var flash: FlashController
    let track: Track

    var body: some View {
        let liked = flash.isLiked(track)
        IconButton(
            liked ? .heart : .heartOutline,
            liked ? "Убрать из понравившегося" : "В понравившееся",
            color: liked ? Ink.accent : Ink.bone,
            box: 52,
            size: 26
        ) { flash.toggleLike(track) }
    }
}
