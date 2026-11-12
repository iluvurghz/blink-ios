import SwiftUI
import UIKit
import BlinkCore

/// Текст песни как на сайте (Stage.jsx `Lyrics` + `Synced`): караоке со словами, которые заливаются по одному,
/// «• • •» и отсчёт 3·2·1 на паузах, перевод под строкой. На карточке строки по центру, во весь экран слева.
struct LyricsPane: View {
    enum Mode { case card, full }

    @EnvironmentObject private var stage: StageModel
    @EnvironmentObject private var graph: Graph
    let track: Track
    let ui: PlayerUi
    let mode: Mode

    var body: some View {
        switch stage.lyrics {
        case .loading:
            VStack(alignment: mode == .card ? .center : .leading, spacing: 18) {
                ForEach([0.72, 0.54, 0.64].indices, id: \.self) { i in
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06))
                            .frame(width: g.size.width * [0.72, 0.54, 0.64][i], height: 36)
                            .frame(maxWidth: .infinity, alignment: mode == .card ? .center : .leading)
                    }
                    .frame(height: 36)
                    .opacity(1 - Double(i) * 0.25)
                }
            }
            .frame(maxHeight: .infinity)
        case .failed:
            empty("Тексты сейчас недоступны", "Сервис с текстами не отвечает. Обычно это ненадолго.", retry: true)
        case .none:
            empty("Текста для этого трека пока нет", "Просто слушайте. Тексты берутся из открытой базы LRCLIB, она пополняется каждый день.")
        case .data(let d):
            switch d {
            case .instrumental:
                empty("Инструментал", "В этом треке нет слов.")
            case .plain(let lines):
                ZStack(alignment: .topLeading) {
                    PlainLyrics(lines: lines, tr: trMap, center: mode == .card)
                    tools(d)
                }
            case .synced(let lines):
                ZStack(alignment: .topLeading) {
                    SyncedLyrics(rows: Karaoke.build(lines), ui: ui, tr: trMap, mode: mode) { graph.player.seek(toMs: $0) }
                        .id(track.id)
                    tools(d)
                }
            }
        }
    }

    private var trMap: [String: String]? {
        if case .on(let m) = stage.tr { return m }
        return nil
    }

    private func empty(_ big: String, _ small: String, retry: Bool = false) -> some View {
        VStack(alignment: mode == .card ? .center : .leading, spacing: 8) {
            Text(big).font(.custom("Unbounded-Medium", fixedSize: 20)).foregroundColor(Ink.bone)
            Text(small).font(.custom("Manrope-Medium", fixedSize: 14)).foregroundColor(Ink.mute)
            if retry {
                PillButton("Повторить", primary: false) { stage.retry() }.padding(.top, 10)
            }
        }
        .multilineTextAlignment(mode == .card ? .center : .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: mode == .card ? .center : .leading)
    }

    /// Пилюля над текстом (.lyr-tools): «Перевод» и «Поделиться».
    private func tools(_ d: LyricsData) -> some View {
        let native = d.isRussian || stage.tr == .native
        let disabled = native || stage.tr == .error
        let on = stage.translate && !disabled
        return HStack(spacing: 4) {
            Button(action: { stage.toggleTranslate() }) {
                HStack(spacing: 6) {
                    LineIconView(.translate, color: on ? Ink.bone : Ink.mute, size: 15)
                    Text(stage.tr == .loading ? "Перевожу…" : "Перевод").font(.custom("Manrope-Bold", fixedSize: 12))
                        .foregroundColor(on ? Ink.bone : Ink.mute)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(on ? Ink.bone.opacity(0.08) : .clear))
            }
            .buttonStyle(TapStyle())
            .disabled(disabled)
            .opacity(disabled ? 0.5 : 1)
            .accessibilityLabel(disabled ? "Перевод не нужен" : "Перевод строк на русский под оригиналом")
            Button(action: share) {
                LineIconView(.share, color: Ink.mute, size: 15).frame(width: 34, height: 28)
            }
            .buttonStyle(TapStyle())
            .accessibilityLabel("Поделиться")
        }
        .padding(4)
        .background(Capsule().fill(Color(hex: 0x0D0C10, opacity: 0.5)))
        .overlay(Capsule().stroke(Ink.line, lineWidth: 1))
        .opacity(on ? 1 : 0.55)
        .offset(x: mode == .card ? -8 : 0, y: mode == .card ? -12 : 0)
    }

    private func share() {
        let t = track
        Task { @MainActor in
            let link = await graph.shared.trackLink(t)
            graph.presentShare(link)
        }
    }
}

/// Простой текст без времени: прокрутка, мягкие края.
private struct PlainLyrics: View {
    let lines: [String]
    let tr: [String: String]?
    let center: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: center ? .center : .leading, spacing: 6) {
                ForEach(lines.indices, id: \.self) { i in
                    let l = lines[i]
                    VStack(alignment: center ? .center : .leading, spacing: 2) {
                        Text(l.isEmpty ? " " : l).font(.custom("Unbounded-Medium", fixedSize: 19)).tracking(-0.38)
                            .foregroundColor(Ink.bone.opacity(0.75))
                        if let t = tr?[l.trimmingCharacters(in: .whitespaces)], !l.isEmpty {
                            Text(t).font(.custom("Manrope-SemiBold", fixedSize: 13)).foregroundColor(Ink.bone.opacity(0.38))
                        }
                    }
                    .multilineTextAlignment(center ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
                }
            }
            .padding(.vertical, 60)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.1), .init(color: .black, location: 0.85), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}

private struct RowMid: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Строки со временем. Активная строка стоит на 36% высоты, лента едет за песней.
private struct SyncedLyrics: View {
    @Environment(\.stageAccent) private var accent
    let rows: [KaraokeRow]
    let ui: PlayerUi
    let tr: [String: String]?
    let mode: LyricsPane.Mode
    let onSeek: (Int64) -> Void

    @State private var mids: [Int: CGFloat] = [:]
    @State private var anchor: (ms: Int64, at: Date) = (0, Date())
    @State private var breathe = false

    private var center: Bool { mode == .card }

    private func now(_ date: Date) -> Double {
        let base = Double(anchor.ms) / 1000
        if !ui.playing { return Double(ui.positionMs) / 1000 }
        let t = base + date.timeIntervalSince(anchor.at)
        // не уходим дальше чем на секунду от последнего сообщения плеера
        return min(t, Double(ui.positionMs) / 1000 + 1)
    }

    var body: some View {
        GeometryReader { box in
            let w = box.size.width
            // размеры как clamp(…, vw, …) в mobile.css: от ширины экрана, а не карточки
            let vw = UIScreen.main.bounds.width
            let base = center ? min(26, max(21, vw * 0.06)) : min(30, max(24, vw * 0.07))
            let big = center ? min(36, max(28, vw * 0.084)) : min(40, max(30, vw * 0.09))
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !ui.playing)) { ctx in
                let t = now(ctx.date)
                let active = Karaoke.active(rows, at: t)
                let count = Karaoke.countdown(rows, active: active, at: t)
                let target = mids[max(0, active)] ?? 0
                VStack(alignment: center ? .center : .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { i in
                        row(i, active: active, count: count, t: t, base: base, big: big)
                            .padding(.horizontal, center ? 18 : 0)
                            .frame(width: w)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowMid.self, value: [i: g.frame(in: .named("lyr")).midY])
                            })
                    }
                }
                .frame(width: w, alignment: center ? .center : .leading)
                .coordinateSpace(name: "lyr")
                .offset(y: box.size.height * 0.36 - target)
                .animation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.7), value: active)
                .frame(width: w, height: box.size.height, alignment: .top)
            }
            .onPreferenceChange(RowMid.self) { mids = $0 }
        }
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .onAppear { anchor = (ui.positionMs, Date()) }
        .onChange(of: ui.positionMs) { _, p in anchor = (p, Date()) }
        .onChange(of: ui.playing) { _, _ in anchor = (ui.positionMs, Date()) }
    }

    @ViewBuilder
    private func row(_ i: Int, active: Int, count: Int, t: Double, base: CGFloat, big: CGFloat) -> some View {
        let r = rows[i]
        let on = i == active
        if r.gap {
            ZStack {
                Text("• • •").font(.custom("Unbounded-SemiBold", fixedSize: base)).tracking(base * 0.3)
                    .foregroundColor(on ? accent : Ink.bone.opacity(0.3))
                    .opacity(on && count > 0 ? 0 : (on && breathe ? 0.35 : 1))
                    .scaleEffect(on && count > 0 ? 0.6 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { breathe = true } }
                if on && count > 0 {
                    Text("\(count)").font(.custom("Unbounded-Bold", fixedSize: 40)).tracking(-1.6)
                        .foregroundColor(accent)
                        .shadow(color: accent.opacity(0.5), radius: 12)
                        .id(count)
                        .transition(.asymmetric(insertion: .scale(scale: 1.5).combined(with: .opacity), removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
            .padding(.vertical, 10)
            .animation(.easeOut(duration: 0.3), value: count)
        } else {
            let past = i < active
            let far = active >= 0 ? abs(i - active) > 3 : i > 3
            let translated = tr?[r.text.trimmingCharacters(in: .whitespaces)].flatMap { $0.lowercased() == r.text.trimmingCharacters(in: .whitespaces).lowercased() ? nil : $0 }
            Button(action: { onSeek(Int64(max(0, r.t + 0.05) * 1000)) }) {
                VStack(alignment: center ? .center : .leading, spacing: 6) {
                    lineText(r, on: on, past: past, t: t, size: on ? big : base)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if let tt = translated {
                        Text(tt).font(.custom("Manrope-SemiBold", fixedSize: (on ? big : base) * 0.46))
                            .foregroundColor(Ink.bone.opacity(on ? 0.7 : past ? 0.2 : 0.38))
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(center ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
                .padding(.vertical, 10)
                .scaleEffect(on ? 1 : 0.94, anchor: center ? .center : .leading)
                .blur(radius: far ? 1.5 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(.easeOut(duration: 0.45), value: on)
        }
    }

    /// Активная строка: каждое слово заливается от тусклого к яркому по своему времени.
    private func lineText(_ r: KaraokeRow, on: Bool, past: Bool, t: Double, size: CGFloat) -> Text {
        let font = Font.custom(on ? "Unbounded-Bold" : "Unbounded-Medium", fixedSize: size)
        if !on {
            return Text(r.text).font(font).tracking(-size * 0.03).foregroundColor(Ink.bone.opacity(past ? 0.22 : 0.3))
        }
        var out = Text("")
        for seg in r.segs {
            let p = seg.t == nil ? 1 : seg.progress(at: t)
            // как градиент сайта: слово светлеет, пока по нему идёт заливка
            let lit = min(1, max(0, (p * 1.4 - 0.2) + 0.2))
            out = out + Text(seg.text).font(font).tracking(-size * 0.03).foregroundColor(Ink.bone.opacity(0.72 + 0.28 * lit))
        }
        return out
    }
}
