import SwiftUI
import BlinkCore

/// Вспышка: одна большая кнопка, режимы, «не моё» и сердечко. Ниже понравившееся. Порт ui/FlashScreen.kt.
struct FlashView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var flash: FlashController
    @EnvironmentObject private var player: PlayerStore

    let bottomInset: CGFloat

    var body: some View {
        let ui = player.value
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                T("Вспышка", .display)
                    .accessibilityAddTraits(.isHeader)
                T("Бесконечный поток под ваш вкус. Чем больше слушаете и лайкаете, тем точнее.", .body, color: Ink.mute)
                    .padding(.top, 6)
                modes
                    .padding(.top, 22)
                stage(ui)
                    .padding(.top, 22)
                likes(playingId: ui.track?.id)
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
    }

    private var modes: some View {
        HStack(spacing: 8) {
            ForEach(WaveMode.allCases, id: \.rawValue) { m in
                Button(action: { flash.setMode(m) }) {
                    T(m.title, BType.button.sized(13), color: m == flash.mode ? Ink.accent : Ink.mute, lines: 1)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(m == flash.mode ? Ink.accentSoft : Ink.ink3))
                        .contentShape(Capsule())
                }
                .buttonStyle(TapStyle())
                .accessibilityAddTraits(m == flash.mode ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stage(_ ui: PlayerUi) -> some View {
        if let track = ui.track, flash.active {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Cover(track.artwork, size: 88, radius: 20, note: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        T(track.title, .h2, lines: 2)
                        T(track.artist, .body, color: Ink.mute, lines: 1)
                    }
                    Spacer(minLength: 0)
                }
                SeekBar(positionMs: ui.positionMs, durationMs: ui.durationMs) { graph.player.seek(toMs: $0) }
                    .padding(.top, 12)
                HStack {
                    IconButton(.thumbDown, "Не моё", color: Ink.mute, box: 52, size: 26) { flash.dislike(track) }
                    Spacer(minLength: 0)
                    IconButton(.previous, "Предыдущий", enabled: ui.hasPrevious || ui.positionMs > 3000, box: 52, size: 28) { graph.player.previous() }
                    Spacer(minLength: 0)
                    Button(action: { graph.player.toggle() }) {
                        GlyphView(ui.playing ? .pause : .play, color: Ink.accentInk, size: 32)
                            .frame(width: 64, height: 64)
                            .background(Circle().fill(Ink.accent))
                    }
                    .buttonStyle(TapStyle())
                    .accessibilityLabel(ui.playing ? "Пауза" : "Играть")
                    Spacer(minLength: 0)
                    IconButton(.next, "Следующий", box: 52, size: 28) { graph.player.next() }
                    Spacer(minLength: 0)
                    LikeButton(track: track)
                }
                PillButton("Остановить Вспышку", primary: false) { flash.stop() }
                    .padding(.top, 6)
            }
        } else {
            VStack(spacing: 14) {
                Button(action: { flash.start() }) {
                    ZStack {
                        Circle().fill(Ink.accent).frame(width: 150, height: 150)
                        if flash.loading {
                            Spinner(color: Ink.accentInk, size: 56)
                        } else {
                            GlyphView(.bolt, color: Ink.accentInk, size: 72)
                        }
                    }
                }
                .buttonStyle(TapStyle())
                .disabled(flash.loading)
                .accessibilityLabel("Включить Вспышку")
                T(flash.loading ? "Собираю поток…" : "Включить Вспышку", .h2)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func likes(playingId: String?) -> some View {
        if flash.likes.isEmpty {
            T("Нажимайте сердечко у треков, и они соберутся здесь и на вашем аккаунте на сайте.", .small, color: Ink.faint)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                T("Понравившееся", .h2)
                    .padding(.bottom, 6)
                ForEach(flash.likes, id: \.id) { track in
                    Button(action: { play(track) }) {
                        HStack(spacing: 12) {
                            Cover(track.artwork, size: 52)
                            VStack(alignment: .leading, spacing: 2) {
                                T(track.title, .title, color: track.id == playingId ? Ink.accent : Ink.bone, lines: 1)
                                T(track.artist, .small, color: Ink.mute, lines: 1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(TapStyle())
                }
            }
        }
    }

    private func play(_ track: Track) {
        let list = flash.likes
        let index = list.firstIndex(where: { $0.id == track.id }) ?? 0
        graph.actions.play(list, at: index)
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
