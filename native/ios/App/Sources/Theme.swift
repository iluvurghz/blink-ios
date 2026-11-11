import SwiftUI
import UIKit

extension Color {
    /// Цвет из значения 0xRRGGBB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Палитра Blink: тёмная бумага, тёплая кость и один коралловый акцент. Те же значения, что на сайте и в Android.
enum Ink {
    static let ink = Color(hex: 0x0D0C10)
    static let ink2 = Color(hex: 0x15131A)
    static let ink3 = Color(hex: 0x1D1A22)
    static let bone = Color(hex: 0xEEE9E2)
    static let mute = Color(hex: 0xA8A3B0)
    static let faint = Color(hex: 0x857F90)
    static let accent = Color(hex: 0xF8814F)
    static let accentInk = Color(hex: 0x29130A)
    static let danger = Color(hex: 0xFF6B6B)
    static let good = Color(hex: 0x4FD08A)
    static let warn = Color(hex: 0xF3BD5A)

    /// Тонкие линии: 8% и 14% кости.
    static let line = Color(hex: 0xEEE9E2, opacity: 20.0 / 255.0)
    static let line2 = Color(hex: 0xEEE9E2, opacity: 36.0 / 255.0)
    static let accentSoft = Color(hex: 0xF8814F, opacity: 41.0 / 255.0)
}

/// Текстовый стиль: шрифт (имя PostScript из файлов в native/design/res/font), размер, высота строки и разрядка.
struct BType {
    let name: String
    let size: CGFloat
    let line: CGFloat
    let tracking: CGFloat

    /// Размер не зависит от настроек «крупного текста»: плавающие панели рассчитаны на фиксированную высоту.
    var font: Font { return Font.custom(name, fixedSize: size) }

    /// Добавка между строками, чтобы высота строки была как в макете.
    var extraSpacing: CGFloat {
        let natural = UIFont(name: name, size: size)?.lineHeight ?? size * 1.3
        return max(0, line - natural)
    }

    func sized(_ newSize: CGFloat, tracking newTracking: CGFloat? = nil) -> BType {
        return BType(name: name, size: newSize, line: line * newSize / size, tracking: newTracking ?? tracking)
    }

    static let display = BType(name: "Unbounded-Bold", size: 28, line: 33, tracking: -0.6)
    static let h1 = BType(name: "Unbounded-Bold", size: 22, line: 27, tracking: -0.4)
    static let h2 = BType(name: "Unbounded-SemiBold", size: 16, line: 21, tracking: -0.2)
    static let title = BType(name: "Manrope-SemiBold", size: 15, line: 20, tracking: 0)
    static let body = BType(name: "Manrope-Medium", size: 14, line: 20, tracking: 0)
    static let small = BType(name: "Manrope-Medium", size: 12.5, line: 17, tracking: 0)
    static let label = BType(name: "Manrope-Bold", size: 11, line: 14, tracking: 0.6)
    static let button = BType(name: "Manrope-ExtraBold", size: 14, line: 18, tracking: 0)
}

/// Текст в стиле Blink. Короткая запись, потому что встречается на каждом экране.
struct T: View {
    private let text: String
    private let style: BType
    private let color: Color
    private let lines: Int?
    private let align: TextAlignment
    private let fill: Bool

    init(
        _ text: String,
        _ style: BType = .body,
        color: Color = Ink.bone,
        lines: Int? = nil,
        align: TextAlignment = .leading,
        fill: Bool = false
    ) {
        self.text = text
        self.style = style
        self.color = color
        self.lines = lines
        self.align = align
        self.fill = fill
    }

    private var frameAlignment: Alignment {
        switch align {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var body: some View {
        Text(text)
            .font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.extraSpacing)
            .foregroundColor(color)
            .multilineTextAlignment(align)
            .lineLimit(lines)
            .frame(maxWidth: fill ? CGFloat.infinity : nil, alignment: frameAlignment)
    }
}

/// Нажатие без системной подсветки: на секунду темнеем. Один и тот же отклик везде в приложении.
struct TapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

extension View {
    /// Вкладки живут все сразу (прокрутка и текст в поле не теряются), видна и доступна только выбранная.
    func screen(_ active: Bool) -> some View {
        return self
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
    }
}
