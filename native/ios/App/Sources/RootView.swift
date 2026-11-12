import SwiftUI
import BlinkCore

/// Размеры нижнего хрома как в mobile.css: плавающий док (64) в 10 от низа и капсула мини-плеера (72) в 10 над ним.
enum Chrome {
    static let dock: CGFloat = 64
    static let capsule: CGFloat = 72
    static let gap: CGFloat = 10

    /// Высота над нижней безопасной зоной, которую занимает хром (списки оставляют под него место).
    static func height(hasTrack: Bool) -> CGFloat {
        return hasTrack ? gap + dock + gap + capsule : gap + dock
    }
}

/// Корень интерфейса. Четыре вкладки живут все сразу (прокрутка и текст в поле не теряются), поверх них
/// плавающий док с капсулой мини-плеера, большой плеер и тосты. Порт ui/Root.kt.
struct RootView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var hasTrack: HasTrackStore
    @EnvironmentObject private var currentId: CurrentIdStore
    @EnvironmentObject private var stage: StageModel

    var body: some View {
        let tab = nav.value.tab
        let withTrack = hasTrack.value
        let playerOpen = nav.value.playerOpen && withTrack
        let chrome = Chrome.height(hasTrack: withTrack)

        ZStack(alignment: .bottom) {
            Ink.ink.ignoresSafeArea()
            FlashView(bottomInset: chrome + 12)
                .screen(tab == .flash)
            SearchView(active: tab == .search, bottomInset: chrome + 12)
                .screen(tab == .search)
            DownloadsView(bottomInset: chrome + 12)
                .screen(tab == .downloads)
            AccountView(active: tab == .account, bottomInset: chrome + 12)
                .screen(tab == .account)
            OverlayHost(overlay: nav.value.overlay, bottomInset: chrome + 12)
                .zIndex(0.5)
            ChromeView(withTrack: withTrack)
            if playerOpen {
                PlayerView(onClose: { graph.nav.openPlayer(false) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
            PlaylistPicker()
                .zIndex(2)
            TrackInfoSheet()
                .zIndex(2)
        }
        .overlay(alignment: .bottom) {
            ToastHost(bottomPadding: playerOpen ? 96 : chrome + 12)
        }
        .environment(\.stageAccent, stage.palette.accent.color)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.38), value: playerOpen)
        .task(id: currentId.value) { stage.trackChanged(graph.player.current.track) }
    }
}

// ---------- нижний хром ----------

/// Плавающий док с вкладками и капсула мини-плеера над ним; под ними мягкое затемнение вместо чёрной полосы.
/// Клавиатура хром не двигает: он остаётся под ней, как на Android.
private struct ChromeView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var downloading: DownloadingStore
    @EnvironmentObject private var stage: StageModel
    let withTrack: Bool

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets.bottom
            ZStack(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color(hex: 0x08070A, opacity: 0.88), location: 0.62)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Chrome.dock + 70 + safe + Chrome.gap)
                    .allowsHitTesting(false)
                VStack(spacing: Chrome.gap) {
                    if withTrack {
                        MiniCapsule()
                            .padding(.horizontal, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Dock(tab: nav.value.tab, downloading: downloading.value, palette: stage.palette) { graph.nav.go($0) }
                        .padding(.horizontal, 12)
                }
                .padding(.bottom, Chrome.gap + safe)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.easeOut(duration: 0.22), value: withTrack)
        .ignoresSafeArea(.keyboard)
    }
}

/// Док с вкладками (.titlebar .nav на телефоне): стекло, подкрашенное обложкой, крупные значки без подписей,
/// под выбранным мягкая светящаяся пилюля цвета акцента.
private struct Dock: View {
    @Environment(\.stageAccent) private var accent
    let tab: AppTab
    let downloading: Bool
    let palette: Palette
    let onTab: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TabItem(icon: .bolt, label: "Вспышка", active: tab == .flash, dot: false) { onTab(.flash) }
            TabItem(icon: .search, label: "Поиск", active: tab == .search, dot: false) { onTab(.search) }
            TabItem(icon: .download, label: "Скачанное", active: tab == .downloads, dot: downloading) { onTab(.downloads) }
            TabItem(icon: .user, label: "Профиль", active: tab == .account, dot: false) { onTab(.account) }
        }
        .padding(6)
        .frame(height: Chrome.dock)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(palette.glowA.mix(0.16, with: (18.0 / 255, 16.0 / 255, 22.0 / 255, 0.94)))
                .animation(.easeOut(duration: 1.2), value: palette)
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.8), radius: 20, y: 18)
    }
}

private struct TabItem: View {
    @Environment(\.stageAccent) private var accent
    let icon: LineIcon
    let label: String
    let active: Bool
    let dot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                LineIconView(icon, color: active ? accent : Ink.bone.opacity(0.55), size: 26)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(active ? accent.opacity(0.2) : .clear)
                            .shadow(color: active ? accent.opacity(0.6) : .clear, radius: 12)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 10)
                    )
                if dot {
                    Circle().fill(accent).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Ink.ink2, lineWidth: 2))
                        .offset(x: -18, y: 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .animation(.easeOut(duration: 0.2), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Капсула мини-плеера (.capsule на телефоне): стекло цвета обложки, ход трека заливкой акцента позади,
/// обложка, название, сердечко и кнопка играть. Тап открывает плеер, свайп вбок листает треки.
private struct MiniCapsule: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var stage: StageModel

    var body: some View {
        let ui = player.value
        if let track = ui.track {
            let fraction = ui.durationMs > 0 ? min(1, max(0, Double(ui.positionMs) / Double(ui.durationMs))) : 0
            let accent = stage.palette.accent.color
            let liked = flash.isLiked(track)
            HStack(spacing: 6) {
                Button(action: { graph.nav.openPlayer(true) }) {
                    HStack(spacing: 12) {
                        NetImage(url: ArtUrl.scaled(track.artwork, 100))
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.custom("Unbounded-Bold", fixedSize: 17)).tracking(-0.51).foregroundColor(Ink.bone).lineLimit(1)
                            Text(track.artist).font(.custom("Manrope-Medium", fixedSize: 14)).foregroundColor(Ink.bone.opacity(0.62)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
                .accessibilityLabel(track.title + ", " + track.artist)
                .accessibilityHint("Открыть плеер")
                StageIcon(liked ? .heartFill : .heart, liked ? "Убрать из любимого" : "Любимое", size: 22, box: 48, on: liked) { flash.toggleLike(track) }
                PlayIris(playing: ui.playing, buffering: ui.buffering, size: 48, accent: accent, ink: stage.palette.accentInk.color, glow: false) {
                    graph.player.toggle()
                }
                .padding(.trailing, 2)
            }
            .padding(.horizontal, 10)
            .frame(height: Chrome.capsule)
            .background(
                ZStack(alignment: .leading) {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(stage.palette.glowA.mix(0.34, with: (16.0 / 255, 14.0 / 255, 19.0 / 255, 0.82)))
                    GeometryReader { g in
                        Rectangle().fill(accent.opacity(0.26))
                            .frame(width: g.size.width * CGFloat(fraction))
                            .animation(.linear(duration: 0.25), value: fraction)
                    }
                }
                .animation(.easeOut(duration: 1.2), value: stage.palette)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.7), radius: 20, y: 18)
            .gesture(
                DragGesture(minimumDistance: 20).onEnded { v in
                    if abs(v.translation.width) > abs(v.translation.height), abs(v.translation.width) > 60 {
                        if v.translation.width < 0 { graph.player.next() } else { graph.player.previous() }
                    } else if v.translation.height < -40 {
                        graph.nav.openPlayer(true)
                    }
                }
            )
        }
    }
}

// ---------- тосты ----------

/// Всплывающая подсказка внизу. Новая заменяет старую; с кнопкой висит дольше (время ведёт ToastCenter).
private struct ToastHost: View {
    @EnvironmentObject private var center: ToastCenter
    let bottomPadding: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            if let shown = center.shown {
                ToastPill(toast: shown.toast, onDismiss: { center.dismiss() })
                    .id(shown.id)
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomPadding)
                    .transition(.opacity.combined(with: .offset(y: 18)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct ToastPill: View {
    let toast: Toast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            T(toast.message, .body, lines: 4)
                .padding(.vertical, 10)
            if let label = toast.action {
                Button(action: {
                    onDismiss()
                    toast.onAction?()
                }) {
                    T(label, .button, color: Ink.accent, lines: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, toast.action != nil ? 6 : 18)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.ink3))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Ink.line2, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onDismiss)
    }
}
