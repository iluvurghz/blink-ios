import SwiftUI
import UIKit
import BlinkCore

// Общие детали интерфейса. Порт ui/Components.kt: те же размеры, цвета и подписи.

struct PillButton: View {
    private let label: String
    private let primary: Bool
    private let enabled: Bool
    private let danger: Bool
    private let action: () -> Void

    init(_ label: String, primary: Bool = true, enabled: Bool = true, danger: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.primary = primary
        self.enabled = enabled
        self.danger = danger
        self.action = action
    }

    private var fillColor: Color {
        let base: Color
        if danger {
            base = Ink.danger.opacity(0.16)
        } else if primary {
            base = Ink.accent
        } else {
            base = Ink.ink3
        }
        return enabled ? base : base.opacity(0.4)
    }

    private var textColor: Color {
        if danger { return Ink.danger }
        return primary ? Ink.accentInk : Ink.bone
    }

    var body: some View {
        Button(action: action) {
            T(label, .button, color: textColor, lines: 1)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Capsule().fill(fillColor))
        }
        .buttonStyle(TapStyle())
        .disabled(!enabled)
    }
}

struct IconButton: View {
    private let glyph: Glyphs
    private let label: String
    private let color: Color
    private let enabled: Bool
    private let box: CGFloat
    private let size: CGFloat
    private let action: () -> Void

    init(
        _ glyph: Glyphs,
        _ label: String,
        color: Color = Ink.bone,
        enabled: Bool = true,
        box: CGFloat = 44,
        size: CGFloat = 24,
        action: @escaping () -> Void
    ) {
        self.glyph = glyph
        self.label = label
        self.color = color
        self.enabled = enabled
        self.box = box
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            GlyphView(glyph, color: enabled ? color : color.opacity(0.3), size: size)
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Обложка. Пока грузится или обложки нет, видна тёмная плашка с нотой.
struct Cover: View {
    private let url: String
    private let size: CGFloat
    private let radius: CGFloat
    private let note: CGFloat

    init(_ url: String, size: CGFloat, radius: CGFloat = 10, note: CGFloat = 22) {
        self.url = url
        self.size = size
        self.radius = radius
        self.note = note
    }

    var body: some View {
        ZStack {
            Ink.ink3
            if !url.isEmpty, let source = URL(string: url) {
                AsyncImage(url: source) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: size, height: size)
                            .clipped()
                    default:
                        GlyphView(.note, color: Ink.faint, size: note)
                    }
                }
            } else {
                GlyphView(.note, color: Ink.faint, size: note)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Кольцо прогресса вокруг значка загрузки.
struct Ring: View {
    private let fraction: Double
    private let color: Color
    private let size: CGFloat

    init(_ fraction: Double, color: Color = Ink.accent, size: CGFloat = 28) {
        self.fraction = fraction
        self.color = color
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle().stroke(Ink.line2, lineWidth: 2.5)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1.25)
        .frame(width: size, height: size)
    }
}

/// Крутилка, когда размер ещё неизвестен.
struct Spinner: View {
    private let color: Color
    private let size: CGFloat

    init(color: Color = Ink.accent, size: CGFloat = 28) {
        self.color = color
        self.size = size
    }

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = (seconds.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360
            ZStack {
                Circle().stroke(Ink.line2, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: 100.0 / 360.0)
                    .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(angle - 90))
            }
            .padding(1.25)
            .frame(width: size, height: size)
        }
    }
}

/// Кнопка «Сохранить» у трека. Рисует то, что решило ядро (SaveUi); что делать по нажатию, решает вызывающий.
struct SaveButton: View {
    let ui: SaveUi
    let action: () -> Void

    private var label: String {
        switch ui {
        case .onlineOnly: return "Играет только онлайн"
        case .available: return "Сохранить для офлайна"
        case .queued: return "В очереди на сохранение"
        case .progress: return "Сохраняется"
        case .saved: return "Сохранено"
        case .failed: return "Не вышло, повторить"
        }
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(TapStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch ui {
        case .onlineOnly:
            GlyphView(.cloudOff, color: Ink.faint, size: 20)
        case .available:
            GlyphView(.download, color: Ink.mute, size: 22)
        case .queued:
            ZStack {
                Ring(0)
                GlyphView(.download, color: Ink.faint, size: 14)
            }
        case .progress(let fraction, let indeterminate):
            ZStack {
                if indeterminate {
                    Spinner()
                } else {
                    Ring(fraction)
                }
                GlyphView(.download, color: Ink.accent, size: 14)
            }
        case .saved:
            ZStack {
                Circle().fill(Ink.accent).frame(width: 26, height: 26)
                GlyphView(.check, color: Ink.accentInk, size: 16)
            }
        case .failed:
            GlyphView(.refresh, color: Ink.danger, size: 22)
        }
    }
}

struct ExplicitBadge: View {
    var body: some View {
        T("E", BType.label.sized(9, tracking: 0), color: Ink.ink)
            .frame(width: 14, height: 14)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Ink.faint))
    }
}

/// Метка у треков из каталога Blink: их можно сохранить.
struct BlinkTag: View {
    var body: some View {
        T("BLINK", BType.label.sized(9, tracking: 0.5), color: Ink.accent, lines: 1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Ink.accentSoft))
    }
}

struct TrackRow: View {
    let track: Track
    let current: Bool
    let save: SaveUi
    let onPlay: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    Cover(track.artwork, size: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        T(track.title, .title, color: current ? Ink.accent : Ink.bone, lines: 1)
                        HStack(spacing: 0) {
                            if track.explicit {
                                ExplicitBadge()
                                    .padding(.trailing, 6)
                                    .layoutPriority(1)
                            }
                            T(track.artist, .small, color: Ink.mute, lines: 1)
                            if OfflinePolicy.savable(track) {
                                BlinkTag()
                                    .padding(.leading, 8)
                                    .layoutPriority(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(TapStyle())
            SaveButton(ui: save, action: onSave)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }
}

struct SectionHeader: View {
    private let title: String
    private let action: String?
    private let onAction: () -> Void

    init(_ title: String, action: String? = nil, onAction: @escaping () -> Void = {}) {
        self.title = title
        self.action = action
        self.onAction = onAction
    }

    var body: some View {
        HStack {
            T(title, .h2, lines: 1)
            Spacer(minLength: 8)
            if let label = action {
                Button(action: onAction) {
                    T(label, .button, color: Ink.accent, lines: 1)
                        .padding(8)
                }
                .buttonStyle(TapStyle())
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

struct Banner: View {
    let glyph: Glyphs
    let text: String

    init(_ glyph: Glyphs, _ text: String) {
        self.glyph = glyph
        self.text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            GlyphView(glyph, color: Ink.warn, size: 22)
            T(text, .small, color: Ink.mute, fill: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Ink.ink2))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Ink.line, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct EmptyState: View {
    private let glyph: Glyphs
    private let title: String
    private let text: String
    private let button: String?
    private let onButton: () -> Void

    init(_ glyph: Glyphs, _ title: String, _ text: String, button: String? = nil, onButton: @escaping () -> Void = {}) {
        self.glyph = glyph
        self.title = title
        self.text = text
        self.button = button
        self.onButton = onButton
    }

    var body: some View {
        VStack(spacing: 0) {
            GlyphView(glyph, color: Ink.mute, size: 30)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Ink.ink2))
                .overlay(Circle().stroke(Ink.line, lineWidth: 1))
            T(title, .h2, align: .center, fill: true)
                .padding(.top, 18)
            T(text, .body, color: Ink.mute, align: .center, fill: true)
                .padding(.top, 8)
            if let label = button {
                PillButton(label, action: onButton)
                    .padding(.top, 18)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}

/// Серая заглушка трека, пока грузится список.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Ink.ink2)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Ink.ink2).frame(width: 160, height: 12)
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Ink.ink2).frame(width: 100, height: 10)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }
}

/// Тонкая полоса прогресса в строке очереди.
struct BarProgress: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ink.line2)
                Capsule()
                    .fill(Ink.accent)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

/// «12 треков · 84 МБ».
func summary(_ count: Int, _ bytes: Int64) -> String {
    return Format.tracks(count) + " · " + Format.bytes(bytes)
}

/// Поле ввода в стиле Blink: таблетка с подсказкой.
struct TextBox: View {
    private let hint: String
    private let text: Binding<String>
    private let focus: FocusState<Bool>.Binding
    private let secure: Bool
    private let keyboard: UIKeyboardType
    private let contentType: UITextContentType?
    private let submit: SubmitLabel
    private let onSubmit: () -> Void

    init(
        _ hint: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding,
        secure: Bool = false,
        keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil,
        submit: SubmitLabel = .next,
        onSubmit: @escaping () -> Void = {}
    ) {
        self.hint = hint
        self.text = text
        self.focus = focus
        self.secure = secure
        self.keyboard = keyboard
        self.contentType = contentType
        self.submit = submit
        self.onSubmit = onSubmit
    }

    private var prompt: Text {
        return Text(hint).foregroundColor(Ink.faint)
    }

    var body: some View {
        Group {
            if secure {
                SecureField("", text: text, prompt: prompt)
            } else {
                TextField("", text: text, prompt: prompt)
            }
        }
        .font(BType.body.font)
        .foregroundColor(Ink.bone)
        .tint(Ink.accent)
        .keyboardType(keyboard)
        .textContentType(contentType)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused(focus)
        .submitLabel(submit)
        .onSubmit(onSubmit)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(Capsule().fill(Ink.ink2))
        .overlay(Capsule().stroke(Ink.line2, lineWidth: 1))
    }
}

/// Карточка профиля.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Ink.ink2))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Ink.line, lineWidth: 1))
    }
}
