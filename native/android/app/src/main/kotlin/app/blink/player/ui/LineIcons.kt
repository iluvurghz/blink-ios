package app.blink.player.ui

/** Значки сайта (ui/Icon.jsx) один в один: обводка 1.75 с круглыми концами, местами заливка. Сетка 24×24.
 *  Сгенерировано вместе с iOS-версией (LineIcon.swift) из одной таблицы. */
class IconPart(val d: String, val fill: Boolean)

enum class LineIcons(vararg val parts: IconPart) {
    Play(IconPart("M8 5.6v12.8c0 .8.9 1.3 1.6.8l9.6-6.4c.6-.4.6-1.2 0-1.6L9.6 4.8C8.9 4.3 8 4.8 8 5.6Z", true)),
    Pause(IconPart("M7.9 5h1.2a1.4 1.4 0 0 1 1.4 1.4v11.2a1.4 1.4 0 0 1 -1.4 1.4h-1.2a1.4 1.4 0 0 1 -1.4 -1.4v-11.2a1.4 1.4 0 0 1 1.4 -1.4Z", true), IconPart("M14.9 5h1.2a1.4 1.4 0 0 1 1.4 1.4v11.2a1.4 1.4 0 0 1 -1.4 1.4h-1.2a1.4 1.4 0 0 1 -1.4 -1.4v-11.2a1.4 1.4 0 0 1 1.4 -1.4Z", true)),
    Next(IconPart("M5 6.2v11.6c0 .7.8 1.1 1.4.7l8.2-5.8c.5-.4.5-1.1 0-1.4L6.4 5.5C5.8 5.1 5 5.5 5 6.2Z", true), IconPart("M18.5 5.5v13", false)),
    Prev(IconPart("M19 6.2v11.6c0 .7-.8 1.1-1.4.7l-8.2-5.8c-.5-.4-.5-1.1 0-1.4l8.2-5.8c.6-.4 1.4 0 1.4.7Z", true), IconPart("M5.5 5.5v13", false)),
    Shuffle(IconPart("M3.5 7h3.2c1.4 0 2.6.7 3.4 1.8l3.8 6.4c.8 1.1 2 1.8 3.4 1.8h3.2M3.5 17h3.2c1.4 0 2.6-.7 3.4-1.8M13.9 8.8c.8-1.1 2-1.8 3.4-1.8h3.2M18 4.5 20.5 7 18 9.5M18 14.5l2.5 2.5-2.5 2.5", false)),
    Repeat(IconPart("M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5", false)),
    RepeatOne(IconPart("M4 11V9.5A3.5 3.5 0 0 1 7.5 6H19m0 0-2.5-2.5M19 6l-2.5 2.5M20 13v1.5a3.5 3.5 0 0 1-3.5 3.5H5m0 0 2.5 2.5M5 18l2.5-2.5", false), IconPart("M11.3 10.6 12.6 10v4.4", false)),
    Heart(IconPart("M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", false)),
    HeartFill(IconPart("M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", true), IconPart("M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 6.9a4.2 4.2 0 0 1 7.5 2.6c0 5.6-7.5 10-7.5 10Z", false)),
    Search(IconPart("M4.5 11a6.5 6.5 0 1 0 13 0a6.5 6.5 0 1 0 -13 0Z", false), IconPart("m16 16 4 4", false)),
    Lyrics(IconPart("M5 7h14M5 12h9M5 17h11", false)),
    Queue(IconPart("M4 6.5h11M4 11.5h11M4 16.5h6M17.5 13v6.5M14.5 16.2l3-3.2 3 3.2", false)),
    Plus(IconPart("M12 5v14M5 12h14", false)),
    Close(IconPart("m6 6 12 12M18 6 6 18", false)),
    Back(IconPart("M14.5 5.5 8 12l6.5 6.5", false)),
    Down(IconPart("m5.5 9 6.5 6.5L18.5 9", false)),
    More(IconPart("M3.9 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", true), IconPart("M10.4 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", true), IconPart("M16.9 12a1.6 1.6 0 1 0 3.2 0a1.6 1.6 0 1 0 -3.2 0Z", true)),
    Min(IconPart("M6 12h12", false)),
    Max(IconPart("M8 6h8a2 2 0 0 1 2 2v8a2 2 0 0 1 -2 2h-8a2 2 0 0 1 -2 -2v-8a2 2 0 0 1 2 -2Z", false)),
    Bolt(IconPart("M13 3 5 13.5h6L10 21l8-10.5h-6L13 3Z", false)),
    Check(IconPart("m5 12.5 4.5 4.5L19 7.5", false)),
    Download(IconPart("M12 4.5v10M7.5 10.5 12 15l4.5-4.5M5.5 19h13", false)),
    Home(IconPart("M4.5 10.5 12 4.5l7.5 6V19a.5.5 0 0 1-.5.5h-4.5v-5h-5v5H5a.5.5 0 0 1-.5-.5v-8.5Z", false)),
    Library(IconPart("M5 4.5v15M9.5 4.5v15M14 5.2l4.6 14.1", false)),
    Chat(IconPart("M5 5.5h14v10H10l-5 4v-14Z", false)),
    User(IconPart("M8.2 8.5a3.8 3.8 0 1 0 7.6 0a3.8 3.8 0 1 0 -7.6 0Z", false), IconPart("M4.8 19.5c1.2-3.4 4-5.2 7.2-5.2s6 1.8 7.2 5.2", false)),
    Together(IconPart("M5.7 8.5a3.3 3.3 0 1 0 6.6 0a3.3 3.3 0 1 0 -6.6 0Z", false), IconPart("M3 19c.9-3 3.2-4.6 6-4.6s5.1 1.6 6 4.6", false), IconPart("M15.5 5.6a3.2 3.2 0 0 1 0 6M17.5 14.6c1.7.6 2.9 2 3.5 4.4", false)),
    Share(IconPart("M12 4v11M8 8l4-4 4 4M5 13v5.5c0 .8.7 1.5 1.5 1.5h11c.8 0 1.5-.7 1.5-1.5V13", false)),
    Translate(IconPart("M4 6h9M8.5 4v2M6 6c.5 3 2.5 5.5 5 6.5M11 6c-.6 3.4-3 6.3-6 7.5M13 20l4-9 4 9M14.4 17h5.2", false)),
    ThumbDown(IconPart("M14.4 3H8.1c-.9 0-1.7.6-1.9 1.5L5 9.7c-.3 1.3.7 2.5 2 2.5h3.2l-.6 3.4c-.2 1.1.4 2.1 1.5 2.4.5.1 1-.1 1.3-.6l2.7-4.6V3Z", false), IconPart("M14.4 3H18c.8 0 1.5.7 1.5 1.5v6c0 .8-.7 1.5-1.5 1.5h-3.6", false)),
    Trash(IconPart("M5 7h14M10 4.5h4M7 7l.8 11.2c.1.9.8 1.6 1.7 1.6h5c.9 0 1.6-.7 1.7-1.6L17 7", false)),
    Settings(IconPart("M4 7h9M17 7h3M4 17h3M11 17h9", false), IconPart("M13 7a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", false), IconPart("M7 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", false)),
    Edit(IconPart("M5 19h3.5L18.7 8.8a2.1 2.1 0 0 0-3-3L5.5 16v3Z", false)),
    Disc(IconPart("M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0 -17 0Z", false), IconPart("M10 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0Z", false)),
}
