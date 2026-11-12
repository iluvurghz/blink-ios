import SwiftUI
import UniformTypeIdentifiers
import BlinkCore

/// Трек, для которого открыто окно «О треке» (похожее, комментарии).
final class InfoState: ObservableObject {
    @Published var track: Track?
}

// ---------- поля ----------

/// Однострочное поле в стиле Blink.
struct Field: View {
    let hint: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField("", text: $text, prompt: Text(hint).foregroundColor(Ink.faint))
            .font(BType.body.font)
            .foregroundColor(Ink.bone)
            .tint(Ink.accent)
            .keyboardType(keyboard)
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Capsule().fill(Ink.ink2))
            .overlay(Capsule().stroke(Ink.line2, lineWidth: 1))
    }
}

/// Многострочное поле.
struct Area: View {
    let hint: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 3...8

    var body: some View {
        TextField("", text: $text, prompt: Text(hint).foregroundColor(Ink.faint), axis: .vertical)
            .lineLimit(lines)
            .font(BType.body.font)
            .foregroundColor(Ink.bone)
            .tint(Ink.accent)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Ink.ink2))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Ink.line2, lineWidth: 1))
    }
}

private struct Head: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        T(title, .h2, lines: 1)
            .padding(.top, 22)
            .padding(.bottom, 8)
    }
}

private func clean(_ error: Error) -> String {
    if let e = error as? SharedError { return e.message }
    return "Не получилось, проверьте интернет"
}

private func compact(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: "%.1f", Double(n) / 1_000_000).replacingOccurrences(of: ".", with: ",") + " млн" }
    if n >= 10_000 { return String(n / 1000) + " тыс." }
    return String(n)
}

// ---------- анонсы и комментарии ----------

/// Анонсы артиста с лайками и комментариями. У владельца сверху поле нового анонса.
struct PostsSection: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    let artistId: String
    let own: Bool
    let tracks: [Track]

    @State private var posts: [Post]?
    @State private var failed = false
    @State private var attempt = 0
    @State private var text = ""
    @State private var attach: Track?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Head("Анонсы")
            if own { composer }
            list
        }
        .task(id: artistId + "#\(attempt)#" + (auth.value?.userId ?? "")) {
            failed = false
            do {
                posts = try await graph.posts.posts(artistId: artistId)
            } catch {
                failed = true
                if posts == nil { posts = [] }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Area(hint: "Что нового? Расскажите подписчикам", text: $text, lines: 2...6)
            if !tracks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(tracks.prefix(20)), id: \.id) { t in
                            Chip(text: t.title, selected: attach?.id == t.id) { attach = attach?.id == t.id ? nil : t }
                        }
                    }
                }
            }
            PillButton(busy ? "Публикуем…" : "Опубликовать", enabled: !busy && !text.trimmingCharacters(in: .whitespaces).isEmpty) { publish() }
        }
        .padding(.bottom, 14)
    }

    @ViewBuilder private var list: some View {
        if let posts = posts {
            if failed && posts.isEmpty {
                T("Не получилось загрузить анонсы.", .body, color: Ink.mute)
                PillButton("Повторить", primary: false) { attempt += 1 }
                    .padding(.top, 8)
            } else if posts.isEmpty {
                if !own { T("Анонсов пока нет.", .body, color: Ink.mute) }
            } else {
                ForEach(posts, id: \.id) { p in
                    PostCard(post: p, own: own) { attempt += 1 }
                        .padding(.bottom, 10)
                }
            }
        } else {
            T("Загружаем…", .body, color: Ink.mute)
        }
    }

    private func publish() {
        busy = true
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trackId = attach.map { $0.id.hasPrefix("b:") ? String($0.id.dropFirst(2)) : $0.id }
        Task { @MainActor in
            do {
                try await graph.posts.createPost(artistId: artistId, text: body, trackId: trackId)
                text = ""
                attach = nil
                attempt += 1
                graph.toasts.show("Анонс опубликован")
            } catch {
                graph.toasts.show(clean(error))
            }
            busy = false
        }
    }
}

private struct PostCard: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    let post: Post
    let own: Bool
    let changed: () -> Void

    @State private var liked: Bool
    @State private var likes: Int64
    @State private var open = false

    init(post: Post, own: Bool, changed: @escaping () -> Void) {
        self.post = post
        self.own = own
        self.changed = changed
        _liked = State(initialValue: post.liked)
        _likes = State(initialValue: post.likes)
    }

    var body: some View {
        Panel {
            HStack(spacing: 10) {
                Cover(post.avatar ?? "", size: 36, radius: 18)
                VStack(alignment: .leading, spacing: 0) {
                    T(post.artistName, .title, lines: 1)
                    T(dateRu(post.createdAt), .small, color: Ink.faint)
                }
                Spacer(minLength: 0)
            }
            T(post.body, .body)
                .padding(.top, 10)
            if let t = post.track {
                Button { graph.actions.play([t], at: 0) } label: {
                    HStack(spacing: 10) {
                        Cover(t.artwork, size: 44)
                        VStack(alignment: .leading, spacing: 0) {
                            T(t.title, .title, lines: 1)
                            T(t.artist, .small, color: Ink.mute, lines: 1)
                        }
                        Spacer(minLength: 0)
                        GlyphView(.play, color: Ink.accent, size: 22)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Ink.ink3))
                }
                .buttonStyle(TapStyle())
                .padding(.top, 10)
            }
            HStack(spacing: 6) {
                Button { toggleLike() } label: {
                    HStack(spacing: 6) {
                        GlyphView(liked ? .heart : .heartOutline, color: liked ? Ink.accent : Ink.mute, size: 20)
                        T(String(likes), .small, color: Ink.mute)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
                .accessibilityLabel(liked ? "Убрать лайк" : "Лайк")
                Chip(text: open ? "Скрыть комментарии" : "Комментарии", selected: open) { open.toggle() }
                Spacer(minLength: 0)
                if own {
                    IconButton(.delete, "Удалить анонс", color: Ink.faint, box: 36, size: 20) { remove() }
                } else {
                    Chip(text: "Пожаловаться", selected: false) { report(kind: "post", id: post.id, graph: graph, signedIn: auth.value != nil) }
                }
            }
            .padding(.top, 8)
            if open {
                CommentsBlock(postId: post.id, trackId: nil)
                    .padding(.top, 8)
            }
        }
    }

    private func toggleLike() {
        if auth.value == nil {
            graph.toasts.show("Войдите, чтобы ставить лайки")
            return
        }
        let on = !liked
        liked = on
        likes += on ? 1 : -1
        Task { @MainActor in
            if await !graph.posts.setPostLike(post.id, on) {
                liked = !on
                likes += on ? -1 : 1
            }
        }
    }

    private func remove() {
        Task { @MainActor in
            do {
                try await graph.posts.deletePost(post.id)
                changed()
            } catch {
                graph.toasts.show(clean(error))
            }
        }
    }
}

@MainActor private func report(kind: String, id: String, graph: Graph, signedIn: Bool) {
    if !signedIn {
        graph.toasts.show("Войдите, чтобы пожаловаться")
        return
    }
    Task { @MainActor in
        do {
            try await graph.posts.report(kind, id)
            graph.toasts.show("Жалоба отправлена, спасибо")
        } catch {
            graph.toasts.show(clean(error))
        }
    }
}

struct CommentsBlock: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    let postId: String?
    let trackId: String?

    @State private var list: [Comment]?
    @State private var failed = false
    @State private var attempt = 0
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let items = list {
                if failed && items.isEmpty {
                    T("Не получилось загрузить комментарии.", .small, color: Ink.mute)
                } else if items.isEmpty {
                    T("Комментариев пока нет. Будьте первым.", .small, color: Ink.mute)
                } else {
                    ForEach(items, id: \.id) { c in row(c) }
                }
            } else {
                T("Загружаем…", .small, color: Ink.mute)
            }
            if auth.value == nil {
                Button { graph.nav.go(.account) } label: {
                    T("Войдите, чтобы написать комментарий.", .small, color: Ink.mute)
                }
                .padding(.top, 8)
            } else {
                Field(hint: "Ваш комментарий", text: $text)
                    .padding(.top, 8)
                PillButton(busy ? "Отправляем…" : "Отправить", primary: false, enabled: !busy && !text.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
                    .padding(.top, 8)
            }
        }
        .task(id: "\(postId ?? "")#\(trackId ?? "")#\(attempt)") {
            failed = false
            do {
                list = try await graph.posts.comments(postId: postId, trackId: trackId)
            } catch {
                failed = true
                if list == nil { list = [] }
            }
        }
    }

    private func row(_ c: Comment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Cover(c.avatar ?? "", size: 30, radius: 15)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    T(c.name, .small, lines: 1)
                    T(dateRu(c.createdAt), .small, color: Ink.faint)
                }
                T(c.body, .body)
                if auth.value != nil {
                    if c.userId == auth.value?.userId {
                        Button { remove(c) } label: { T("Удалить", .small, color: Ink.faint) }
                    } else {
                        Button { report(kind: "comment", id: c.id, graph: graph, signedIn: true) } label: { T("Пожаловаться", .small, color: Ink.faint) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    private func send() {
        busy = true
        let body = text
        Task { @MainActor in
            do {
                try await graph.posts.addComment(body, postId: postId, trackId: trackId)
                text = ""
                attempt += 1
            } catch {
                graph.toasts.show(clean(error))
            }
            busy = false
        }
    }

    private func remove(_ c: Comment) {
        Task { @MainActor in
            do {
                try await graph.posts.deleteComment(c.id)
                attempt += 1
            } catch {
                graph.toasts.show(clean(error))
            }
        }
    }
}

// ---------- похожее (Last.fm) ----------

/// Слушатели и похожие артисты. Если Last.fm недоступен, блок просто не показывается.
struct SimilarArtists: View {
    @EnvironmentObject private var graph: Graph
    let name: String
    @State private var listeners: Int64?
    @State private var similar: [SimilarArtist] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let l = listeners { T(compact(l) + " слушателей в Last.fm", .small, color: Ink.faint) }
            if !similar.isEmpty {
                T("ПОХОЖИЕ АРТИСТЫ", .label, color: Ink.mute).padding(.top, 10).padding(.bottom, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(similar.prefix(12)), id: \.name) { a in
                            Chip(text: a.name, selected: false) { searchFor(graph, a.name) }
                        }
                    }
                }
            }
        }
        .task(id: name) {
            listeners = await graph.lastfm.listeners(name)
            similar = await graph.lastfm.similarArtists(name)
        }
    }
}

@MainActor private func searchFor(_ graph: Graph, _ q: String) {
    graph.search.setQuery(q)
    graph.nav.go(.search)
}

/// Окно «О треке» поверх плеера: похожие треки (Last.fm) и комментарии к трекам Blink.
struct TrackInfoSheet: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var info: InfoState
    @State private var similar: [SimilarTrack] = []

    var body: some View {
        if let t = info.track {
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { info.track = nil }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        T("О треке", .h2)
                        T(t.title + " · " + t.artist, .small, color: Ink.mute, lines: 1)
                            .padding(.bottom, 14)
                        SimilarArtists(name: t.artist)
                        if !similar.isEmpty {
                            T("ПОХОЖИЕ ТРЕКИ", .label, color: Ink.mute).padding(.top, 14).padding(.bottom, 4)
                            ForEach(Array(similar.prefix(10)), id: \.title) { x in
                                Button {
                                    info.track = nil
                                    searchFor(graph, x.artist + " " + x.title)
                                } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        T(x.title, .title, lines: 1)
                                        T(x.artist, .small, color: Ink.mute, lines: 1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(TapStyle())
                            }
                        }
                        if t.id.hasPrefix("b:") {
                            T("КОММЕНТАРИИ", .label, color: Ink.mute).padding(.top, 14).padding(.bottom, 6)
                            CommentsBlock(postId: nil, trackId: String(t.id.dropFirst(2)))
                        }
                        PillButton("Закрыть", primary: false) { info.track = nil }
                            .padding(.top, 12)
                    }
                    .padding(20)
                }
                .frame(maxHeight: 560)
                .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28).fill(Ink.ink2).ignoresSafeArea(edges: .bottom))
            }
            .accessibilityAddTraits(.isModal)
            .zIndex(2)
            .task(id: t.id) { similar = await graph.lastfm.similarTracks(artist: t.artist, title: t.title) }
        }
    }
}

// ---------- поддержка ----------

struct SupportOverlay: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    let bottomInset: CGFloat

    @State private var openTicket: String?
    @State private var faq: [FaqItem] = []
    @State private var expanded: String?
    @State private var text = ""
    @State private var contact = ""
    @State private var busy = false
    @State private var auto: (String, String)?
    @State private var tickets: [TicketRow] = []
    @State private var refresh = 0

    var body: some View {
        if let id = openTicket {
            TicketScreen(id: id, bottomInset: bottomInset) { openTicket = nil; refresh += 1 }
        } else {
            Sheet(title: "Помощь") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        T("Ответы на частые вопросы. Если не нашли своё, напишите нам.", .body, color: Ink.mute)
                            .padding(.bottom, 14)
                        ForEach(faq, id: \.id) { f in
                            Button { expanded = expanded == f.id ? nil : f.id } label: {
                                Panel {
                                    T(f.question, .title)
                                    if expanded == f.id { T(f.answer, .body, color: Ink.mute).padding(.top, 6) }
                                }
                            }
                            .buttonStyle(TapStyle())
                            .padding(.bottom, 8)
                        }
                        Head("Написать в поддержку")
                        Area(hint: "Что случилось?", text: $text)
                        if text.count > 8, let hint = SupportApi.bestAnswer(faq, text) {
                            Panel {
                                T("ВОЗМОЖНО, ЭТО ПОМОЖЕТ", .label, color: Ink.accent)
                                T(hint.question, .title).padding(.top, 4)
                                T(hint.answer, .body, color: Ink.mute)
                            }
                            .padding(.top, 8)
                        }
                        if auth.value == nil {
                            Field(hint: "Как с вами связаться (почта или Telegram)", text: $contact)
                                .padding(.top, 8)
                        }
                        PillButton(busy ? "Отправляем…" : "Отправить", enabled: !busy && !text.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
                            .padding(.top, 10)
                        if let a = auto {
                            Panel {
                                T("ПОКА ВЫ ЖДЁТЕ ОТВЕТ КОМАНДЫ", .label, color: Ink.accent)
                                T(a.0, .title).padding(.top, 4)
                                T(a.1, .body, color: Ink.mute)
                            }
                            .padding(.top, 10)
                        }
                        if !tickets.isEmpty {
                            Head("Ваши обращения")
                            ForEach(tickets, id: \.id) { t in
                                Button { openTicket = t.id } label: {
                                    Panel {
                                        HStack(alignment: .top, spacing: 8) {
                                            T(t.message.isEmpty ? "(картинка)" : t.message, .body, lines: 2, fill: true)
                                            Chip(text: statusRu(t.status), selected: t.status == "answered") { openTicket = t.id }
                                        }
                                        T(dateRu(t.updatedAt), .small, color: Ink.faint)
                                    }
                                }
                                .buttonStyle(TapStyle())
                                .padding(.bottom, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, bottomInset)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .task { faq = (try? await graph.support.faq()) ?? [] }
            .task(id: "\(auth.value?.userId ?? "")#\(refresh)") {
                tickets = auth.value == nil ? [] : ((try? await graph.support.mine()) ?? [])
            }
        }
    }

    private func send() {
        busy = true
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let how = contact.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                let r = try await graph.support.send(message: body, contact: how.isEmpty ? nil : how)
                text = ""
                if let q = r.autoQuestion, let a = r.autoAnswer { auto = (q, a) } else { auto = nil }
                graph.toasts.show("Отправили. Ответ придёт сюда")
                refresh += 1
            } catch {
                graph.toasts.show(clean(error))
            }
            busy = false
        }
    }
}

private func statusRu(_ s: String) -> String {
    switch s {
    case "answered": return "Есть ответ"
    case "closed": return "Закрыто"
    default: return "Ждёт ответа"
    }
}

private struct TicketScreen: View {
    @EnvironmentObject private var graph: Graph
    let id: String
    let bottomInset: CGFloat
    let back: () -> Void

    @State private var ticket: TicketView?
    @State private var failure: String?
    @State private var reply = ""
    @State private var busy = false
    @State private var attempt = 0

    var body: some View {
        Sheet(title: "Обращение", onBack: back) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let v = ticket {
                        Chip(text: statusRu(v.status), selected: v.status == "answered") {}
                        bubble("Вы", v.message, mine: true).padding(.top, 10)
                        ForEach(v.messages, id: \.id) { m in bubble(m.author == "user" ? "Вы" : "Команда Blink", m.body, mine: m.author == "user") }
                        if v.status != "closed" {
                            Area(hint: "Ваш ответ", text: $reply, lines: 2...6).padding(.top, 12)
                            HStack(spacing: 8) {
                                PillButton(busy ? "Отправляем…" : "Ответить", enabled: !busy && !reply.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
                                PillButton("Закрыть обращение", primary: false) { close() }
                            }
                            .padding(.top, 10)
                        }
                    } else {
                        T(failure ?? "Загружаем…", .body, color: Ink.mute)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollIndicators(.hidden)
        }
        .task(id: attempt) {
            do {
                ticket = try await graph.support.open(id)
            } catch {
                failure = clean(error)
            }
        }
    }

    private func bubble(_ who: String, _ text: String, mine: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
            T(who, .label, color: Ink.faint)
            T(text.isEmpty ? "(картинка)" : text, .body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(mine ? Ink.accentSoft : Ink.ink3))
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(.vertical, 5)
    }

    private func send() {
        busy = true
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                _ = try await graph.support.reply(id, body)
                reply = ""
                attempt += 1
            } catch {
                graph.toasts.show(clean(error))
            }
            busy = false
        }
    }

    private func close() {
        Task { @MainActor in
            do {
                try await graph.support.close(id)
                attempt += 1
            } catch {
                graph.toasts.show(clean(error))
            }
        }
    }
}

// ---------- кабинет артиста ----------

struct CabinetOverlay: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    let bottomInset: CGFloat

    @State private var me: ArtistMe?
    @State private var loaded = false
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Sheet(title: "Кабинет артиста") {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if auth.value == nil {
                        EmptyState(.person, "Нужен аккаунт", "Войдите, чтобы загружать музыку и вести страницу артиста.", button: "Войти") { graph.nav.go(.account) }
                    } else if let f = failure {
                        T(f, .body, color: Ink.mute)
                        PillButton("Повторить", primary: false) { attempt += 1 }.padding(.top, 10)
                    } else if !loaded {
                        T("Загружаем…", .body, color: Ink.mute)
                    } else if let m = me, m.offerAccepted {
                        CabinetBody(me: m) { me = $0 }
                    } else {
                        OfferCard(existing: me) { me = $0 }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .task(id: "\(auth.value?.userId ?? "")#\(attempt)") {
            guard auth.value != nil else { return }
            failure = nil
            do {
                me = try await graph.cabinet.me()
                loaded = true
            } catch {
                failure = clean(error)
            }
        }
    }
}

private struct OfferCard: View {
    @EnvironmentObject private var graph: Graph
    @Environment(\.openURL) private var openURL
    let existing: ArtistMe?
    let done: (ArtistMe) -> Void
    @State private var name = ""
    @State private var agree = false
    @State private var busy = false

    var body: some View {
        Panel {
            T("Стать артистом Blink", .h2)
            T("Выкладывайте свою музыку, ведите страницу и публикуйте анонсы для подписчиков. Нужно принять оферту.", .body, color: Ink.mute)
                .padding(.top, 6)
            Field(hint: "Имя артиста", text: $name)
                .padding(.top, 12)
            HStack(spacing: 8) {
                Chip(text: agree ? "Принимаю условия" : "Принять условия оферты", selected: agree) { agree.toggle() }
                Button { if let u = URL(string: "https://blinkmusic.cc/offer.html") { openURL(u) } } label: {
                    T("Читать оферту", .small, color: Ink.accent)
                }
            }
            .padding(.top, 10)
            PillButton(busy ? "Сохраняем…" : "Продолжить", enabled: !busy && agree && !name.trimmingCharacters(in: .whitespaces).isEmpty) { accept() }
                .padding(.top, 12)
        }
        .onAppear { if name.isEmpty { name = existing?.name ?? "" } }
    }

    private func accept() {
        busy = true
        Task { @MainActor in
            do {
                done(try await graph.cabinet.acceptOffer(name: name))
            } catch {
                graph.toasts.show(clean(error))
            }
            busy = false
        }
    }
}

private struct CabinetBody: View {
    @EnvironmentObject private var graph: Graph
    let me: ArtistMe
    let changed: (ArtistMe) -> Void

    @State private var bio: String
    @State private var savingBio = false
    @State private var mine: [MyTrack]?
    @State private var attempt = 0
    @State private var confirm: String?
    @State private var uploading = false

    init(me: ArtistMe, changed: @escaping (ArtistMe) -> Void) {
        self.me = me
        self.changed = changed
        _bio = State(initialValue: me.bio ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            T(me.name, .h1, lines: 2)
            PillButton("Открыть мою страницу", primary: false) { graph.nav.openArtist(me.id) }
                .padding(.top, 10)
            Head("О себе")
            Area(hint: "Пара слов для слушателей", text: $bio, lines: 2...6)
            PillButton(savingBio ? "Сохраняем…" : "Сохранить", primary: false, enabled: !savingBio && bio.trimmingCharacters(in: .whitespacesAndNewlines) != (me.bio ?? "")) { saveBio() }
                .padding(.top, 8)
            Head("Новый трек")
            if uploading {
                UploadForm(me: me, close: { uploading = false }, done: { uploading = false; attempt += 1 })
            } else {
                PillButton("Загрузить трек") { uploading = true }
            }
            Head("Мои релизы")
            releases
            PostsSection(artistId: me.id, own: true, tracks: [])
        }
        .task(id: attempt) { mine = (try? await graph.cabinet.mine()) ?? [] }
    }

    @ViewBuilder private var releases: some View {
        if let list = mine {
            if list.isEmpty {
                T("Пока ни одного релиза.", .body, color: Ink.mute)
            } else {
                ForEach(list, id: \.id) { t in
                    HStack(spacing: 12) {
                        Cover(t.cover ?? "", size: 48)
                        VStack(alignment: .leading, spacing: 0) {
                            T(t.title, .title, lines: 1)
                            T(t.releaseTitle + " · " + dateRu(t.releaseDate), .small, color: Ink.mute, lines: 1)
                            T("\(t.streamsTotal) прослушиваний, \(t.streamsMonth) за месяц" + (t.status != "live" ? " · " + t.status : ""), .small, color: Ink.faint, lines: 1)
                        }
                        Spacer(minLength: 0)
                        if confirm == t.id {
                            PillButton("Снять", danger: true) { takedown(t) }
                        } else {
                            IconButton(.delete, "Снять трек", color: Ink.faint) { confirm = t.id }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        } else {
            T("Загружаем…", .body, color: Ink.mute)
        }
    }

    private func saveBio() {
        savingBio = true
        Task { @MainActor in
            do {
                try await graph.posts.saveBio(artistId: me.id, bio: bio)
                var m = me
                let clean = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                m.bio = clean.isEmpty ? nil : clean
                changed(m)
                graph.toasts.show("Сохранили")
            } catch {
                graph.toasts.show(Community.message(error))
            }
            savingBio = false
        }
    }

    private func takedown(_ t: MyTrack) {
        confirm = nil
        Task { @MainActor in
            do {
                try await graph.cabinet.takedown(t.id)
                attempt += 1
                graph.toasts.show("Трек снят")
            } catch {
                graph.toasts.show(Community.message(error))
            }
        }
    }
}

enum Community {
    static func message(_ error: Error) -> String { return clean(error) }
}

private struct UploadForm: View {
    @EnvironmentObject private var graph: Graph
    let me: ArtistMe
    let close: () -> Void
    let done: () -> Void

    @State private var d = UploadDraft()
    @State private var audio: UploadFile?
    @State private var cover: UploadFile?
    @State private var progress: Double?
    @State private var failure: String?
    @State private var pickAudio = false
    @State private var pickCover = false

    var body: some View {
        Panel {
            PillButton(audio?.name ?? "Аудио: WAV, FLAC, MP3", primary: audio == nil) { pickAudio = true }
            PillButton(cover?.name ?? "Обложка: JPEG или PNG", primary: cover == nil) { pickCover = true }
                .padding(.top, 8)
            Group {
                Field(hint: "Название трека", text: $d.title)
                Field(hint: "Альбом или сингл", text: $d.releaseTitle)
                Field(hint: "Авторы музыки и текста, через запятую", text: $d.authors)
                Field(hint: "Кто записал (изготовитель фонограммы)", text: $d.phonogramMaker)
                Field(hint: "Жанр", text: $d.genre)
                Field(hint: "Язык", text: $d.language)
                HStack(spacing: 8) {
                    Field(hint: "Год", text: $d.year, keyboard: .numberPad).frame(maxWidth: 110)
                    Field(hint: "Дата релиза ГГГГ-ММ-ДД", text: $d.releaseDate)
                }
                Field(hint: "Сэмплы и чужие фрагменты, если есть", text: $d.samples)
                Area(hint: "Текст песни (необязательно)", text: $d.lyrics, lines: 2...6)
            }
            .padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(text: "Есть мат", selected: d.explicit) { d.explicit.toggle() }
                    Chip(text: "Использовался ИИ", selected: d.aiUsed) { d.aiUsed.toggle() }
                    Chip(text: "У меня есть все права", selected: d.rights) { d.rights.toggle() }
                }
            }
            .padding(.top, 10)
            if let f = failure { T(f, .small, color: Ink.danger).padding(.top, 8) }
            if let p = progress {
                BarProgress(fraction: p).padding(.top, 10)
                T("Загрузка \(Int(p * 100))%", .small, color: Ink.mute)
            }
            HStack(spacing: 8) {
                PillButton(progress != nil ? "Загружаем…" : "Опубликовать", enabled: progress == nil) { submit() }
                PillButton("Отмена", primary: false, enabled: progress == nil) { close() }
            }
            .padding(.top, 12)
        }
        .onAppear {
            if d.phonogramMaker.isEmpty {
                d.phonogramMaker = me.name
                let today = ArtistApi.today()
                d.year = String(today.prefix(4))
                d.releaseDate = today
            }
        }
        .fileImporter(isPresented: $pickAudio, allowedContentTypes: [.audio]) { r in audio = copy(r, fallback: "track.mp3", mime: "audio/mpeg") }
        .fileImporter(isPresented: $pickCover, allowedContentTypes: [.image]) { r in cover = copy(r, fallback: "cover.jpg", mime: "image/jpeg") }
    }

    private func copy(_ r: Result<URL, Error>, fallback: String, mime: String) -> UploadFile? {
        guard case .success(let url) = r else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pick-" + UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? mime
        return UploadFile(name: url.lastPathComponent.isEmpty ? fallback : url.lastPathComponent, mime: type, url: dest)
    }

    private func submit() {
        failure = graph.cabinet.check(d, audio: audio, cover: cover)
        guard failure == nil, let a = audio, let c = cover else { return }
        progress = 0
        Task { @MainActor in
            do {
                _ = try await graph.cabinet.upload(d, audio: a, cover: c) { p in Task { @MainActor in progress = progress == nil ? nil : p } }
                graph.toasts.show("Трек опубликован")
                try? FileManager.default.removeItem(at: a.url)
                try? FileManager.default.removeItem(at: c.url)
                done()
            } catch {
                failure = clean(error)
            }
            progress = nil
        }
    }
}
