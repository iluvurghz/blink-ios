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
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                FlashHero()
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

/// Большая карточка Вспышки: фон из обложки или живые пятна цвета акцента, светящаяся кнопка, режимы.
private struct FlashHero: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var stage: StageModel
    @State private var drift = false

    var body: some View {
        let ui = player.value
        let accent = stage.palette.accent.color
        let ink = stage.palette.accentInk.color
        let track = flash.active ? ui.track : nil
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return ZStack {
            Ink.ink2
            if let t = track {
                BlurredCover(url: t.artwork)
            } else {
                blobs
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    LineIconView(.bolt, color: accent, size: 22)
                    T("Вспышка", BType.h2.sized(18))
                    Spacer(minLength: 0)
                    if flash.active {
                        Button { flash.stop() } label: {
                            T("Стоп", BType.button.sized(13))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.15)))
                        }
                        .buttonStyle(PressScale())
                    }
                }
                Spacer(minLength: 0)
                if let t = track {
                    playing(t, ui: ui, accent: accent, ink: ink)
                } else {
                    idle(accent: accent, ink: ink)
                }
                Spacer(minLength: 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(WaveMode.allCases, id: \.rawValue) { m in
                            ModeChip(label: m.title, selected: m == flash.mode, accent: accent) { flash.setMode(m) }
                        }
                    }
                }
            }
            .padding(22)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .clipShape(shape)
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true } }
    }

    private var blobs: some View {
        let p = stage.palette
        let k: CGFloat = drift ? 1 : 0
        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RadialGradient(colors: [p.glowA.color.opacity(0.55), .clear], center: UnitPoint(x: 0.2 + 0.2 * k, y: 0.3), startRadius: 0, endRadius: w * 0.8)
                RadialGradient(colors: [p.glowB.color.opacity(0.45), .clear], center: UnitPoint(x: 0.85 - 0.2 * k, y: 0.55 + 0.1 * k), startRadius: 0, endRadius: w * 0.75)
                RadialGradient(colors: [p.glowC.color.opacity(0.35), .clear], center: UnitPoint(x: 0.5, y: 0.95 - 0.1 * k), startRadius: 0, endRadius: w * 0.7)
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x08070A).opacity(0.2), location: 0),
                    .init(color: .clear, location: 0.6),
                    .init(color: Color(hex: 0x08070A).opacity(0.8), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: w, height: h)
        }
    }

    private func idle(accent: Color, ink: Color) -> some View {
        VStack(spacing: 0) {
            Button { flash.start() } label: {
                ZStack {
                    Circle().fill(accent).frame(width: 124, height: 124)
                        .shadow(color: accent.opacity(0.6), radius: 30)
                    if flash.loading {
                        Spinner(color: ink, size: 52)
                    } else {
                        LineIconView(.play, color: ink, size: 50)
                    }
                }
            }
            .buttonStyle(PressScale())
            .disabled(flash.loading)
            .accessibilityLabel("Включить Вспышку")
            T(flash.loading ? "Собираю поток…" : "Включить Вспышку", BType.display.sized(26), align: .center)
                .padding(.top, 22)
            T("Бесконечный поток под ваш вкус. Чем больше слушаете и лайкаете, тем точнее.", .body, color: Ink.bone.opacity(0.6), align: .center)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func playing(_ t: Track, ui: PlayerUi, accent: Color, ink: Color) -> some View {
        let liked = flash.isLiked(t)
        return VStack(spacing: 0) {
            Button { graph.nav.openPlayer(true) } label: {
                NetImage(url: ArtUrl.scaled(t.artwork, 400))
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            .buttonStyle(PressScale())
            T(t.title, BType.display.sized(24), lines: 2, align: .center)
                .padding(.top, 18)
            T(t.artist, .title, color: Ink.bone.opacity(0.62), lines: 1, align: .center)
                .padding(.top, 4)
            HStack(spacing: 10) {
                StageIcon(.thumbDown, "Не моё", size: 24, box: 52, color: Ink.bone.opacity(0.8)) { flash.dislike(t) }
                PlayIris(playing: ui.playing, buffering: ui.buffering, size: 72, accent: accent, ink: ink, glow: true) { graph.player.toggle() }
                StageIcon(.next, "Следующий", size: 26, box: 52) { graph.player.next() }
                StageIcon(liked ? .heartFill : .heart, "Любимое", size: 24, box: 52, on: liked) { flash.toggleLike(t) }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ModeChip: View {
    let label: String
    let selected: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            T(label, BType.button.sized(13), color: selected ? accent : Ink.bone.opacity(0.75), lines: 1)
                .padding(.horizontal, 15)
                .padding(.vertical, 9)
                .background(Capsule().fill(selected ? accent.opacity(0.22) : Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(selected ? accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel("Режим \(label)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
