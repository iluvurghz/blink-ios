import SwiftUI
import BlinkCore

/// Размеры нижней панели. Списки оставляют под неё место, а тосты встают над ней.
enum Chrome {
    static let tabsHeight: CGFloat = 64
    static let miniHeight: CGFloat = 62

    /// Высота панели над нижней безопасной зоной (вкладки и, если что-то играет, мини-плеер).
    static func height(hasTrack: Bool) -> CGFloat {
        return hasTrack ? tabsHeight + miniHeight : tabsHeight
    }
}

/// Корень интерфейса. Четыре вкладки живут все сразу (прокрутка и текст в поле не теряются), поверх них
/// плавающая панель, большой плеер и тосты. Порт ui/Root.kt.
struct RootView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var hasTrack: HasTrackStore

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
        .animation(.easeOut(duration: 0.26), value: playerOpen)
    }
}

// ---------- нижняя панель ----------

/// Одна панель во всю ширину: сверху мини-плеер (если что-то играет), под ним вкладки. Фон уходит под
/// индикатор «домой». Клавиатура панель не двигает: она остаётся под ней, как на Android.
private struct ChromeView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var nav: NavStore
    @EnvironmentObject private var downloading: DownloadingStore
    let withTrack: Bool

    var body: some View {
        VStack(spacing: 0) {
            if withTrack {
                MiniPlayer()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                Rectangle().fill(Ink.line).frame(height: 1)
            }
            BottomBar(tab: nav.value.tab, downloading: downloading.value) { graph.nav.go($0) }
        }
        .frame(maxWidth: .infinity)
        .background(
            Ink.ink2
                .overlay(alignment: .top) { Rectangle().fill(Ink.line2).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(.easeOut(duration: 0.22), value: withTrack)
        .ignoresSafeArea(.keyboard)
    }
}

private struct BottomBar: View {
    let tab: AppTab
    let downloading: Bool
    let onTab: (AppTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            TabItem(glyph: .bolt, label: "Вспышка", active: tab == .flash, dot: false) { onTab(.flash) }
            TabItem(glyph: .search, label: "Поиск", active: tab == .search, dot: false) { onTab(.search) }
            TabItem(glyph: .download, label: "Скачанное", active: tab == .downloads, dot: downloading) { onTab(.downloads) }
            TabItem(glyph: .person, label: "Профиль", active: tab == .account, dot: false) { onTab(.account) }
        }
        .padding(.horizontal, 8)
        .frame(height: Chrome.tabsHeight)
    }
}

/// Значок над подписью. Выбранная вкладка: акцентный цвет и мягкая капсула под значком. Подписи видны всегда.
private struct TabItem: View {
    let glyph: Glyphs
    let label: String
    let active: Bool
    let dot: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    GlyphView(glyph, color: active ? Ink.accent : Ink.mute, size: 22)
                        .frame(width: 56, height: 30)
                        .background(Capsule().fill(active ? Ink.accentSoft : Color.clear))
                    if dot {
                        Circle().fill(Ink.accent).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Ink.ink2, lineWidth: 2))
                            .offset(x: -10, y: 2)
                    }
                }
                T(label, BType.label.sized(11, tracking: 0.2), color: active ? Ink.accent : Ink.mute, lines: 1, align: .center)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Chrome.tabsHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .animation(.easeOut(duration: 0.18), value: active)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Строка мини-плеера внутри панели: обложка, название, пауза и следующий; тонкая полоска хода на верхней кромке.
private struct MiniPlayer: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var player: PlayerStore

    var body: some View {
        let ui = player.value
        if let track = ui.track {
            let fraction = ui.durationMs > 0 ? min(1, max(0, Double(ui.positionMs) / Double(ui.durationMs))) : 0
            HStack(spacing: 0) {
                Button(action: { graph.nav.openPlayer(true) }) {
                    HStack(spacing: 12) {
                        Cover(track.artwork, size: 44, radius: 10, note: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            T(track.title, BType.title.sized(14), lines: 1)
                            T(track.artist, .small, color: Ink.mute, lines: 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
                .accessibilityLabel(track.title + ", " + track.artist)
                .accessibilityHint("Открыть плеер")
                IconButton(ui.playing ? .pause : .play, ui.playing ? "Пауза" : "Играть", size: 26) { graph.player.toggle() }
                IconButton(.next, "Следующий", enabled: ui.hasNext) { graph.player.next() }
            }
            .padding(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
            .frame(height: Chrome.miniHeight)
            .overlay(alignment: .topLeading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Ink.accent)
                        .frame(width: geo.size.width * CGFloat(fraction), height: 2)
                        .animation(.linear(duration: 0.5), value: fraction)
                }
                .frame(height: 2)
            }
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
