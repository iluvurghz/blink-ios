import SwiftUI
import BlinkCore

/// Большой плеер: обложка, перемотка, управление и кнопка сохранения. Закрывается кнопкой сверху
/// или свайпом вниз за шапку и обложку. Порт ui/PlayerScreen.kt.
struct PlayerView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var player: PlayerStore
    @EnvironmentObject private var offline: OfflineStore

    let onClose: () -> Void

    @State private var drag: CGFloat = 0

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    var body: some View {
        let ui = player.value
        GeometryReader { geo in
            if let track = ui.track {
                let side = max(150, min(geo.size.width - 48, geo.size.height - 400))
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    Cover(track.artwork, size: side, radius: 28, note: 72)
                        .gesture(closeDrag)
                    titleBlock(track)
                        .padding(.top, 26)
                        .gesture(closeDrag)
                    SeekBar(positionMs: ui.positionMs, durationMs: ui.durationMs) { graph.player.seek(toMs: $0) }
                        .padding(.top, 18)
                    HStack {
                        T(Format.duration(Int(ui.positionMs / 1000)), .small, color: Ink.faint)
                        Spacer(minLength: 0)
                        T(Format.duration(Int(ui.durationMs / 1000)), .small, color: Ink.faint)
                    }
                    .accessibilityHidden(true)
                    controls(ui)
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                    SaveChip(
                        ui: SaveUi.of(track, offline.value),
                        onPhone: OfflinePolicy.keyOf(track).map { offline.value.savedKeys.contains($0) } ?? false
                    ) { graph.actions.saveTapped(track) }
                    .padding(.bottom, 18)
                }
                .padding(.horizontal, 24)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Ink.ink.ignoresSafeArea())
        .offset(y: drag)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 0) {
            IconButton(.expandMore, "Свернуть плеер", action: onClose)
            T("СЕЙЧАС ИГРАЕТ", .label, color: Ink.mute, align: .center, fill: true)
            Color.clear.frame(width: 44, height: 44)
        }
        .frame(height: 56)
        .contentShape(Rectangle())
        .gesture(closeDrag)
    }

    private func titleBlock(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            T(track.title, .h1, lines: 2, fill: true)
            HStack(spacing: 6) {
                if track.explicit {
                    ExplicitBadge()
                }
                T(track.artist, .title, color: Ink.mute, lines: 1)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func controls(_ ui: PlayerUi) -> some View {
        HStack(spacing: 14) {
            IconButton(.previous, "Предыдущий", enabled: ui.hasPrevious || ui.positionMs > 3000, box: 60, size: 32) {
                graph.player.previous()
            }
            ZStack {
                if ui.buffering {
                    Spinner(color: Ink.accent, size: 84)
                }
                Button(action: { graph.player.toggle() }) {
                    GlyphView(ui.playing ? .pause : .play, color: Ink.accentInk, size: 36)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Ink.accent))
                }
                .buttonStyle(TapStyle())
                .accessibilityLabel(ui.playing ? "Пауза" : "Играть")
            }
            .frame(width: 84, height: 84)
            IconButton(.next, "Следующий", enabled: ui.hasNext, box: 60, size: 32) {
                graph.player.next()
            }
        }
    }

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
}

// ---------- сохранить ----------

/// Пилюля внизу плеера: сохранить, идёт сохранение, уже на телефоне или «только онлайн».
private struct SaveChip: View {
    let ui: SaveUi
    let onPhone: Bool
    let action: () -> Void

    private var label: String {
        switch ui {
        case .onlineOnly: return "Играет только онлайн"
        case .available: return "Сохранить для офлайна"
        case .queued: return "В очереди на сохранение"
        case .progress: return "Сохраняется…"
        case .saved: return onPhone ? "На телефоне, играет без интернета" : "Сохранено"
        case .failed: return "Не вышло. Повторить"
        }
    }

    private var tint: Color {
        switch ui {
        case .onlineOnly: return Ink.faint
        case .available: return Ink.bone
        case .queued: return Ink.mute
        case .progress: return Ink.accent
        case .saved: return Ink.accent
        case .failed: return Ink.danger
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                glyph.frame(width: 32, height: 32)
                T(label, .button, color: tint, lines: 1)
                    .padding(.trailing, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Capsule().fill(Ink.ink2))
            .overlay(Capsule().stroke(Ink.line2, lineWidth: 1))
        }
        .buttonStyle(TapStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var glyph: some View {
        switch ui {
        case .onlineOnly:
            GlyphView(.cloudOff, color: tint, size: 20)
        case .available, .queued:
            GlyphView(.download, color: tint, size: 20)
        case .progress(let fraction, let indeterminate):
            if indeterminate {
                Spinner(color: tint, size: 24)
            } else {
                Ring(fraction, color: tint, size: 24)
            }
        case .saved:
            GlyphView(.checkCircle, color: tint, size: 22)
        case .failed:
            GlyphView(.refresh, color: tint, size: 20)
        }
    }
}

// ---------- перемотка ----------

/// Полоса перемотки: тап и перетаскивание. Пока тянем, показываем палец, а не позицию плеера;
/// после отпускания держим выбранное место, пока плеер не догонит (иначе ползунок на миг прыгает назад).
struct SeekBar: View {
    let positionMs: Int64
    let durationMs: Int64
    let onSeek: (Int64) -> Void

    @State private var dragging: Double? = nil
    @State private var held: Double? = nil

    init(positionMs: Int64, durationMs: Int64, onSeek: @escaping (Int64) -> Void) {
        self.positionMs = positionMs
        self.durationMs = durationMs
        self.onSeek = onSeek
    }

    private var fraction: Double {
        if let value = dragging ?? held { return value }
        guard durationMs > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(durationMs)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let x = width * CGFloat(fraction)
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.line2).frame(height: 4)
                Capsule().fill(Ink.accent).frame(width: x, height: 4)
                Circle().fill(Ink.bone).frame(width: 14, height: 14).offset(x: x - 7)
            }
            .frame(width: width, height: 32, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = clamp(value.location.x / width)
                    }
                    .onEnded { value in
                        let target = clamp(value.location.x / width)
                        dragging = nil
                        if durationMs > 0 {
                            held = target
                            onSeek(Int64(target * Double(durationMs)))
                        }
                    }
            )
        }
        .frame(height: 32)
        // Отпускаем выбранное место, когда плеер до него дошёл; а если не дошёл (долгая перемотка), через полторы секунды.
        .onChange(of: positionMs) { _, now in
            guard let target = held, durationMs > 0 else { return }
            if abs(Double(now) / Double(durationMs) - target) < 0.01 { held = nil }
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
            let step: Int64 = 10_000
            let target = direction == .increment ? positionMs + step : positionMs - step
            onSeek(min(durationMs, max(0, target)))
        }
    }

    private func clamp(_ value: CGFloat) -> Double {
        return Double(min(1, max(0, value)))
    }
}
