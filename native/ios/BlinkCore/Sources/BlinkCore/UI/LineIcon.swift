import Foundation

/// Значки сайта (ui/Icon.jsx) один в один: обводка 1.75 с круглыми концами, местами заливка. Сетка 24×24.
/// Сгенерировано вместе с Android-версией (LineIcons.kt) из одной таблицы.
public struct IconPart: Equatable, Sendable {
    public let d: String
    public let fill: Bool
}

public enum LineIcon: String, CaseIterable, Sendable {
    case play, pause, next, prev, shuffle, `repeat`, repeatOne, heart, heartFill, search, lyrics, queue, plus, close, back, down, more, min, max, bolt, check, download, home, library, chat, user, together, share, translate, thumbDown, trash, settings, edit, disc

    public var parts: [IconPart] {
        switch self {
        case .play: return [IconPart(d: "M8 5.6v12.8c0 .8.9 1.3 1.6.8l9.6-6.4c.6-.4.6-1.2 0-1.6L9.6 4.8C8.9 4.3 8 4.8 8 5.6Z", fill: true)]
        case .pause: return [IconPart(d: "M7.9 5h1.2a1.4 1.4 0 0 1 1.4 1.4v11.2a1.4 1.4 0 0 1 -1.4 1.4h-1.2a1.4 1.4 0 0 1 -1.4 -1.4v-11.2a1.4 1.4 0 0 1 1.4 -1.4Z", fill: true), IconPart(d: "M14.9 5h1.2a1.4 1.4 0 0 1 1.4 1.4v11.2a1.4 1.4 0 0 1 -1.4 1.4h-1.2a1.4 1.4 0 0 1 -1.4 -1.4v-11.2a1.4 1.4 0 0 1 1.4 -1.4Z", fill: true)]
        case .next: return [IconPart(d: "M5 6.2v11.6c0 .7.8 1.1 1.4.7l8.2-5.8c.5-.4.5-1.1 0-1.4L6.4 5.5C5.8 5.1 5 5.5 5 6.2Z", fill: true), IconPart(d: "M18.5 5.5v13", fill: false)]
        case .prev: return [IconPart(d: "M19 6.2v11.6c0 .7-.8 1.1-1.4.7l-8.2-5.8c-.5-.4-.5-1.1 0-1.4l8.2-5.8c.6-.4 1.4 0 1.4.7Z", fill: true), IconPart(d: "M5.5 5.5v13", fill: false)]
        case .shuffle: return [IconPart(d: "M3.5 7h3.2c1.4 0 2.6.7 3.4 1.8l3.8 6.4c.8 1.1 2 1.8 3.4 1.8h3.2M3.5 17h3.2c1.4 0 2.6-.7 3.4-1.8M13.9 8.8c.8-1.1 2-1.8 3.4-1.8h3.2M18 4.5 20.5 7 18 9.5M18 14.5l2.5 2.5-2.5 2.5", fill: false)]
        case .repeat: return [IconPart(d: "M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5", fill: false)]
        case .repeatOne: return [IconPart(d: "M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5", fill: false), IconPart(d: "M11.3 10.6 12.6 10v4.4", fill: false)]
        case .heart: return [IconPart(d: "M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", fill: false)]
        case .heartFill: return [IconPart(d: "M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", fill: true), IconPart(d: "M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", fill: false)]
        case .search: return [IconPart(d: "M4.5 11a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0Z", fill: false), IconPart(d: "m16 16 4 4", fill: false)]
        case .lyrics: return [IconPart(d: "M5 7h14M5 12h9M5 17h11", fill: false)]
        case .queue: return [IconPart(d: "M4 6.5h11M4 11.5h11M4 16.5h6M17.5 13v6.5M14.5 16.2l3-3.2 3 3.2", fill: false)]
        case .plus: return [IconPart(d: "M12 5v14M5 12h14", fill: false)]
        case .close: return [IconPart(d: "m6 6 12 12M18 6 6 18", fill: false)]
        case .back: return [IconPart(d: "M14.5 5.5 8 12l6.5 6.5", fill: false)]
        case .down: return [IconPart(d: "m5.5 9 6.5 6.5L18.5 9", fill: false)]
        case .more: return [IconPart(d: "M3.9 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", fill: true), IconPart(d: "M10.4 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", fill: true), IconPart(d: "M16.9 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", fill: true)]
        case .min: return [IconPart(d: "M6 12h12", fill: false)]
        case .max: return [IconPart(d: "M8 6h8a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2h-8a2 2 0 0 1 -2 -2v-8a2 2 0 0 1 2 -2Z", fill: false)]
        case .bolt: return [IconPart(d: "M13 3 5 13.5h6L10 21l8-10.5h-6L13 3Z", fill: false)]
        case .check: return [IconPart(d: "m5 12.5 4.5 4.5L19 7.5", fill: false)]
        case .download: return [IconPart(d: "M12 4.5v10M7.5 10.5 12 15l4.5-4.5M5.5 19h13", fill: false)]
        case .home: return [IconPart(d: "M4.5 10.5 12 4.5l7.5 6V19a.5.5 0 0 1-.5.5h-4.5v-5h-5v5H5a.5.5 0 0 1-.5-.5v-8.5Z", fill: false)]
        case .library: return [IconPart(d: "M5 4.5v15M9.5 4.5v15M14 5.2l4.6 14.1", fill: false)]
        case .chat: return [IconPart(d: "M5 5.5h14v10H10l-5 4v-14Z", fill: false)]
        case .user: return [IconPart(d: "M8.2 8.5a3.8 3.8 0 1 0 7.6 0a3.8 3.8 0 1 0 -7.6 0Z", fill: false), IconPart(d: "M4.8 19.5c1.2-3.4 4-5.2 7.2-5.2s6 1.8 7.2 5.2", fill: false)]
        case .together: return [IconPart(d: "M5.7 8.5a3.3 3.3 0 1 0 6.6 0a3.3 3.3 0 1 0 -6.6 0Z", fill: false), IconPart(d: "M3 19c.9-3 3.2-4.6 6-4.6s5.1 1.6 6 4.6", fill: false), IconPart(d: "M15.5 5.6a3.2 3.2 0 0 1 0 6M17.5 14.6c1.7.6 2.9 2 3.5 4.4", fill: false)]
        case .share: return [IconPart(d: "M12 4v11M8 8l4-4 4 4M5 13v5.5c0 .8.7 1.5 1.5 1.5h11c.8 0 1.5-.7 1.5-1.5V13", fill: false)]
        case .translate: return [IconPart(d: "M4 6h9M8.5 4v2M6 6c.5 3 2.5 5.5 5 6.5M11 6c-.6 3.4-3 6.3-6 7.5M13 20l4-9 4 9M14.4 17h5.2", fill: false)]
        case .thumbDown: return [IconPart(d: "M14.4 3H8.1c-.9 0-1.7.6-1.9 1.5L5 9.7c-.3 1.3.7 2.5 2 2.5h3.2l-.6 3.4c-.2 1.1.4 2.1 1.5 2.4.5.1 1-.1 1.3-.6l2.7-4.6V3Z", fill: false), IconPart(d: "M14.4 3H18c.8 0 1.5.7 1.5 1.5v6c0 .8-.7 1.5-1.5 1.5h-3.6", fill: false)]
        case .trash: return [IconPart(d: "M5 7h14M10 4.5h4M7 7l.8 11.2c.1.9.8 1.6 1.7 1.6h5c.9 0 1.6-.7 1.7-1.6L17 7", fill: false)]
        case .settings: return [IconPart(d: "M4 7h9M17 7h3M4 17h3M11 17h9", fill: false), IconPart(d: "M13 7a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", fill: false), IconPart(d: "M7 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", fill: false)]
        case .edit: return [IconPart(d: "M5 19h3.5L18.7 8.8a2.1 2.1 0 0 0-3-3L5.5 16v3Z", fill: false)]
        case .disc: return [IconPart(d: "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0Z", fill: false), IconPart(d: "M10 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", fill: false)]
        }
    }

    /// Толщина линии на сайте при размере 24.
    public static let stroke = 1.75
}
