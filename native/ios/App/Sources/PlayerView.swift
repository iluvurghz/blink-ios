import SwiftUI
import BlinkCore

/// Большой плеер один в один с мобильным плеером сайта (Stage.jsx, ветка `narrow`, и .pstage в mobile.css):
/// фон из обложки, шапка «откуда играет», обложка или текст на стеклянной карточке, трек с фото артиста,
/// перемотка, управление и ряд «повтор / текст / перемешать». Развёрнутый текст занимает весь экран, внизу пилюля трека.
struct PlayerView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var stage: StageModel
    @EnvironmentObject private var offline: OfflineStore

    let onClose: () -> Void

    enum Tab { case cover, lyrics, queue, comments }

    @State private var tab: Tab = .cover
    @State private var full = false
    @State private var drag: CGFloat = 0
    @State private var menu = false

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var accent: Color { stage.palette.accent.color }

    var body: some View {
        let ui = player.value
        GeometryReader { geo in
            if let track = ui.track {
                let textOn = tab == .lyrics && stage.hasLyrics
                let big = full && textOn
                ZStack {
                    BlurredCover(url: track.artwork)
                    VStack(spacing: 0) {
                        top(track)
                        main(track, ui: ui, textOn: textOn, big: big, screen: geo.size)
                            .frame(maxHeight: .infinity)
                        if big {
                            pill(track, ui: ui)
                        } else {
                            meta(track)
                            scrub(ui)
                            controls(track, ui: ui)
                            row(ui, textOn: textOn)
                        }
                    }
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, 16 + geo.safeAreaInsets.bottom)
                }
                .ignoresSafeArea()
                .confirmationDialog(track.title, isPresented: $menu, titleVisibility: .visible) {
                    menuItems(track)
                }
                .onChange(of: track.id) { _, _ in
                    if tab == .lyrics && !stage.hasLyrics { tab = .cover }
                    if tab == .comments { tab = .cover }
                }
                .onChange(of: stage.lyrics) { _, _ in
                    if tab == .lyrics, stage.lyrics != .loading, !stage.hasLyrics { tab = .cover }
                }
                .onChange(of: flash.active) { _, wave in
                    if wave && tab == .queue { tab = .cover }
                }
                .task { await launchStage() }
            }
        }
        .offset(y: drag)
        .environment(\.stageAccent, accent)
        .tint(accent)
        .accessibilityAddTraits(.isModal)
    }

    /// Для снимков в CI: открыть текст или очередь, как только они готовы.
    private func launchStage() async {
        guard let want = LaunchHooks.startStage else { return }
        if want == "queue" {
            tab = .queue
            return
        }
        for _ in 0..<60 {
            if stage.hasLyrics {
                tab = .lyrics
                full = want == "full"
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: шапка

    private func top(_ track: Track) -> some View {
        let from = flash.active ? "Вспышка" : "Сейчас играет"
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                StageIcon(.down, "Свернуть", size: 24, box: 44, action: onClose)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("blink").font(.custom("Unbounded-SemiBold", fixedSize: 13)).tracking(-0.26)
                        .foregroundColor(Ink.bone.opacity(0.55))
                    Circle().fill(accent).frame(width: 4, height: 4)
                }
                Text(from).font(.custom("Manrope-Bold", fixedSize: 14)).foregroundColor(Ink.bone.opacity(0.85)).lineLimit(1)
            }
            .fixedSize()
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if track.lic != nil {
                    StageIcon(.chat, "Комментарии", size: 20, box: 44, on: tab == .comments) { pick(.comments) }
                }
                if !flash.active {
                    StageIcon(.queue, "Очередь", size: 22, box: 44, on: tab == .queue) { pick(.queue) }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .contentShape(Rectangle())
        .gesture(closeDrag)
    }

    private func pick(_ t: Tab) {
        full = false
        withAnimation(.easeOut(duration: 0.25)) { tab = tab == t ? .cover : t }
    }

    // MARK: середина

    @ViewBuilder
    private func main(_ track: Track, ui: PlayerUi, textOn: Bool, big: Bool, screen: CGSize) -> some View {
        if big {
            ZStack(alignment: .topTrailing) {
                LyricsPane(track: track, ui: ui, mode: .full)
                StageIcon(.min, "Свернуть текст", size: 18, box: 36, color: Ink.bone.opacity(0.7)) {
                    withAnimation(.easeOut(duration: 0.3)) { full = false }
                }
            }
            .padding(EdgeInsets(top: 0, leading: 22, bottom: 12, trailing: 22))
        } else if tab == .queue || tab == .comments || textOn {
            ZStack(alignment: .topTrailing) {
                Group {
                    switch tab {
                    case .queue: QueuePane()
                    case .comments: ScrollView { CommentsBlock(postId: nil, trackId: track.lic).padding(.top, 34) }
                    default: LyricsPane(track: track, ui: ui, mode: .card)
                    }
                }
                .id(String(describing: tab) + track.id)
                .transition(.opacity.combined(with: .offset(y: 10)))
                .padding(EdgeInsets(top: 22, leading: 18, bottom: 22, trailing: 18))
                if textOn {
                    StageIcon(.max, "Весь текст", size: 18, box: 36, color: Ink.bone.opacity(0.7)) {
                        withAnimation(.easeOut(duration: 0.3)) { full = true }
                    }
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(hex: 0x100E14, opacity: 0.55)))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.7), radius: 30, y: 30)
            .padding(EdgeInsets(top: 4, leading: 18, bottom: 18, trailing: 18))
        } else {
            GeometryReader { box in
                let side = max(120, min(box.size.width, box.size.height, screen.height * 0.52))
                NetImage(url: ArtUrl.scaled(track.artwork, 1000))
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
                    .shadow(color: .black.opacity(0.85), radius: 40, y: 40)
                    .id(track.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .frame(width: box.size.width, height: box.size.height)
                    .contentShape(Rectangle())
                    .gesture(coverSwipe)
            }
            .padding(EdgeInsets(top: 4, leading: 18, bottom: 18, trailing: 18))
            .animation(.easeOut(duration: 0.4), value: track.id)
        }
    }

    // MARK: трек

    private func meta(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Button(action: { openArtist(track) }) {
                NetImage(url: stage.photo ?? ArtUrl.scaled(track.artwork, 100))
                    .frame(width: 52, height: 52)
                    .clipShape(Circle())
            }
            .buttonStyle(TapStyle())
            .accessibilityLabel(track.artist)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.custom("Unbounded-Bold", fixedSize: 20)).tracking(-0.6).foregroundColor(Ink.bone).lineLimit(1)
                Button(action: { openArtist(track) }) {
                    Text(track.artist).font(.custom("Manrope-SemiBold", fixedSize: 15)).foregroundColor(Ink.bone.opacity(0.6)).lineLimit(1)
                }
                .buttonStyle(TapStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StageIcon(.share, "Поделиться ссылкой", size: 20, box: 44, color: Ink.bone.opacity(0.85)) { shareTrack(track) }
            StageIcon(.more, "Ещё", size: 20, box: 44, color: Ink.bone.opacity(0.85)) { menu = true }
        }
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
    }

    private func scrub(_ ui: PlayerUi) -> some View {
        VStack(spacing: 6) {
            StageSeek(positionMs: ui.positionMs, durationMs: ui.durationMs, accent: accent) {
                graph.player.seek(toMs: $0)
                graph.room.onUserSeek($0)
            }
            HStack {
                Text(Format.duration(Int(ui.positionMs / 1000)))
                Spacer(minLength: 0)
                Text(Format.duration(Int(ui.durationMs / 1000)))
            }
            .font(.custom("Manrope-SemiBold", fixedSize: 12))
            .monospacedDigit()
            .foregroundColor(Ink.mute)
            .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 0, trailing: 20))
    }

    private func controls(_ track: Track, ui: PlayerUi) -> some View {
        let liked = flash.isLiked(track)
        return HStack(spacing: 0) {
            if flash.active {
                StageIcon(.thumbDown, "Не моё: больше такое не ставить", size: 22, box: 54) { flash.dislike(track) }
            } else {
                Color.clear.frame(width: 54, height: 54)
            }
            Spacer(minLength: 0)
            StageIcon(.prev, "Назад", size: 28, box: 54) { graph.player.previous() }
            Spacer(minLength: 0)
            PlayIris(playing: ui.playing, buffering: ui.buffering, size: 78, accent: accent, ink: stage.palette.accentInk.color, glow: true) {
                graph.player.toggle()
            }
            Spacer(minLength: 0)
            StageIcon(.next, "Дальше", size: 28, box: 54, enabled: ui.hasNext) { graph.player.next() }
            Spacer(minLength: 0)
            StageIcon(liked ? .heartFill : .heart, "Любимое", size: 24, box: 54, on: liked) { flash.toggleLike(track) }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12))
    }

    private func row(_ ui: PlayerUi, textOn: Bool) -> some View {
        let lyricsHint: String = {
            if !stage.hasLyrics { return stage.lyrics == .loading ? "Ищу текст…" : "У этого трека нет текста" }
            return textOn ? "Убрать текст" : "Показать текст"
        }()
        return HStack(spacing: 14) {
            RowTile(icon: ui.repeatMode == .one ? .repeatOne : .repeat, label: "Повтор", on: ui.repeatMode != .off) {
                graph.player.cycleRepeat()
            }
            RowTile(icon: .lyrics, label: lyricsHint, on: textOn, enabled: stage.hasLyrics) {
                full = false
                withAnimation(.easeOut(duration: 0.25)) { tab = textOn ? .cover : .lyrics }
            }
            RowTile(icon: .shuffle, label: "Перемешать", on: ui.shuffle) { graph.player.toggleShuffle() }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 0, trailing: 20))
    }

    private func pill(_ track: Track, ui: PlayerUi) -> some View {
        HStack(spacing: 12) {
            NetImage(url: ArtUrl.scaled(track.artwork, 100))
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.custom("Unbounded-Bold", fixedSize: 16)).tracking(-0.48).foregroundColor(Ink.bone).lineLimit(1)
                Text(track.artist).font(.custom("Manrope-SemiBold", fixedSize: 13)).foregroundColor(Ink.bone.opacity(0.6)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            PlayIris(playing: ui.playing, buffering: ui.buffering, size: 44, accent: accent, ink: stage.palette.accentInk.color, glow: false) {
                graph.player.toggle()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.3)) { full = false } }
        .padding(.horizontal, 14)
    }

    // MARK: меню «⋯»

    @ViewBuilder
    private func menuItems(_ track: Track) -> some View {
        Button("В плейлист") { graph.pick.track = track }
        Button(graph.room.inRoom ? "Комната" : "Слушать вместе") { graph.nav.open(.room) }
        if OfflinePolicy.savable(track) {
            Button("Сохранить для офлайна") { graph.actions.saveTapped(track) }
        }
        if track.artistId != nil {
            Button("К артисту") { openArtist(track) }
        }
        Button("О треке") { graph.info.track = track }
        if track.lic != nil {
            Button("Пожаловаться", role: .destructive) { report(kind: "track", id: track.lic!, graph: graph, signedIn: graph.auth.session != nil) }
        }
        Button("Отмена", role: .cancel) {}
    }

    private func openArtist(_ track: Track) {
        guard let id = track.artistId else { return }
        onClose()
        graph.nav.openArtist(id)
    }

    private func shareTrack(_ track: Track) {
        Task { @MainActor in
            let link = await graph.shared.trackLink(track)
            graph.presentShare(link)
        }
    }

    // MARK: жесты

    /// Свайп вниз за шапку или обложку: плеер едет за пальцем и закрывается, если потянули достаточно.
    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if value.translation.height > 0 { drag = value.translation.height }
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 320 {
                    onClose()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                }
            }
    }

    /// По обложке: вниз закрывает, вбок листает треки (как свайп по сцене на сайте).
    private var coverSwipe: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                if value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width) { drag = value.translation.height }
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy), abs(dx) > 70 {
                    if dx < 0 { graph.player.next() } else { graph.player.previous() }
                    withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                } else if dy > 120 || value.predictedEndTranslation.height > 320 {
                    onClose()
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { drag = 0 }
                }
            }
    }
}

// MARK: - детали сцены

private struct StageAccentKey: EnvironmentKey {
    static let defaultValue: Color = Ink.accent
}

extension EnvironmentValues {
    /// Акцент из обложки текущего трека.
    var stageAccent: Color {
        get { self[StageAccentKey.self] }
        set { self[StageAccentKey.self] = newValue }
    }
}

/// Круглая кнопка-значок, как .icon-btn на сайте. Включённая подсвечивается акцентом.
struct StageIcon: View {
    @Environment(\.stageAccent) private var accent
    private let icon: LineIcon
    private let label: String
    private let size: CGFloat
    private let box: CGFloat
    private let color: Color
    private let on: Bool
    private let enabled: Bool
    private let action: () -> Void

    init(_ icon: LineIcon, _ label: String, size: CGFloat = 22, box: CGFloat = 44, color: Color = Ink.bone, on: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.size = size
        self.box = box
        self.color = color
        self.on = on
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            LineIconView(icon, color: on ? accent : (enabled ? color : color.opacity(0.3)), size: size)
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Нажатие как на сайте: кнопка чуть сжимается.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

/// Кнопка играть/пауза (.iris): круг цвета акцента, значки меняются с поворотом, кольцо при загрузке.
struct PlayIris: View {
    let playing: Bool
    let buffering: Bool
    let size: CGFloat
    let accent: Color
    let ink: Color
    let glow: Bool
    let action: () -> Void

    @State private var spin = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(accent)
                    .shadow(color: glow ? accent.opacity(0.75) : .clear, radius: glow ? 20 : 0, y: glow ? 14 : 0)
                LineIconView(.play, color: ink, size: size * 0.42)
                    .opacity(playing ? 0 : 1)
                    .scaleEffect(playing ? 0.6 : 1)
                    .rotationEffect(.degrees(playing ? -30 : 0))
                LineIconView(.pause, color: ink, size: size * 0.42)
                    .opacity(playing ? 1 : 0)
                    .scaleEffect(playing ? 1 : 0.6)
                    .rotationEffect(.degrees(playing ? 0 : -30))
                if buffering {
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: size + 8, height: size + 8)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
                }
            }
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.2), value: playing)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(playing ? "Пауза" : "Играть")
    }
}

/// Плитка ряда под управлением (.ps-row button): серая заливка; включённая прозрачная с рамкой цвета кости.
private struct RowTile: View {
    let icon: LineIcon
    let label: String
    let on: Bool
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LineIconView(icon, color: on ? Ink.bone : Ink.bone.opacity(0.7), size: 20)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.clear : Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(on ? Ink.bone.opacity(0.9) : Color.clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .animation(.easeOut(duration: 0.2), value: on)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Перемотка (.stage-scrub .progress): тонкая дорожка, заливка акцентом, белая точка всегда видна.
struct StageSeek: View {
    let positionMs: Int64
    let durationMs: Int64
    let accent: Color
    let onSeek: (Int64) -> Void

    @State private var dragging: Double?
    @State private var held: Double?

    private var fraction: Double {
        if let v = dragging ?? held { return v }
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let x = w * CGFloat(fraction)
            let rail: CGFloat = dragging != nil ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.bone.opacity(0.1)).frame(height: rail)
                Capsule().fill(accent).frame(width: x, height: rail)
                Circle().fill(Ink.bone).frame(width: 12, height: 12).offset(x: x - 6)
            }
            .frame(width: w, height: 20)
            .contentShape(Rectangle().inset(by: -10))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragging = Double(min(1, max(0, $0.location.x / w))) }
                    .onEnded { v in
                        let target = Double(min(1, max(0, v.location.x / w)))
                        dragging = nil
                        if durationMs > 0 {
                            held = target
                            onSeek(Int64(target * Double(durationMs)))
                        }
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging != nil)
        }
        .frame(height: 20)
        .onChange(of: positionMs) { _, now in
            guard let t = held, durationMs > 0 else { return }
            if abs(Double(now) / Double(durationMs) - t) < 0.01 { held = nil }
        }
        .task(id: held) {
            guard held != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { held = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Перемотка")
        .accessibilityValue(Format.duration(Int(positionMs / 1000)) + " из " + Format.duration(Int(durationMs / 1000)))
        .accessibilityAdjustableAction { direction in
            guard durationMs > 0 else { return }
            let target = direction == .increment ? positionMs + 10_000 : positionMs - 10_000
            onSeek(min(durationMs, max(0, target)))
        }
    }
}

/// «Сейчас и дальше»: очередь с тремя прошедшими треками сверху, тап переключает трек.
private struct QueuePane: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var player: PlayerStore
    @Environment(\.stageAccent) private var accent

    var body: some View {
        let ui = player.value
        let snap = graph.player.queueSnapshot()
        let first = max(0, snap.index - 3)
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("СЕЙЧАС И ДАЛЬШЕ").font(.custom("Manrope-Bold", fixedSize: 11)).tracking(0.6).foregroundColor(Ink.mute)
                        .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
                    if first < snap.tracks.count {
                        ForEach(first..<snap.tracks.count, id: \.self) { i in
                            let t = snap.tracks[i]
                            Button(action: { graph.player.jump(to: i) }) {
                                HStack(spacing: 12) {
                                    NetImage(url: ArtUrl.scaled(t.artwork, 100))
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).font(.custom("Manrope-Bold", fixedSize: 15)).foregroundColor(i == snap.index ? accent : Ink.bone).lineLimit(1)
                                        Text(t.artist).font(.custom("Manrope-Medium", fixedSize: 13)).foregroundColor(Ink.mute).lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(Format.duration(t.duration)).font(.custom("Manrope-SemiBold", fixedSize: 12)).monospacedDigit().foregroundColor(Ink.faint)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(i == snap.index ? Color.white.opacity(0.06) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TapStyle())
                            .opacity(i < snap.index ? 0.45 : 1)
                            .id(i)
                        }
                    }
                    Text("Когда очередь закончится, Blink продолжит похожими треками этих артистов.")
                        .font(.custom("Manrope-Medium", fixedSize: 12.5)).foregroundColor(Ink.faint)
                        .padding(EdgeInsets(top: 24, leading: 10, bottom: 24, trailing: 10))
                }
            }
            .onAppear { proxy.scrollTo(snap.index, anchor: .center) }
            .onChange(of: ui.index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}
