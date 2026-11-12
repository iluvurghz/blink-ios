import SwiftUI
import UIKit
import BlinkCore

// Комната «Слушать вместе», друзья и страница Blink+. Порт ui/Social.kt: те же тексты и порядок блоков.

/// Полноэкранный слой поверх вкладок (и поверх большого плеера). Показывается, пока в навигации открыт оверлей.
struct OverlayHost: View {
    let overlay: AppOverlay
    let bottomInset: CGFloat

    var body: some View {
        switch overlay {
        case .none:
            Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
        case .room:
            Sheet(title: "Слушать вместе") { RoomContent(bottomInset: bottomInset) }
        case .friends:
            Sheet(title: "Друзья") { FriendsContent(bottomInset: bottomInset) }
        case .plus:
            PlusSheet(bottomInset: bottomInset)
        }
    }
}

/// Шапка с кнопкой «Назад» и прокручиваемое тело.
private struct Sheet<Content: View>: View {
    @EnvironmentObject private var graph: Graph
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconButton(.expandMore, "Закрыть") { graph.nav.close() }
                    .rotationEffect(.degrees(90))
                T(title, .h2, lines: 1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .frame(height: 56)
            .padding(.horizontal, 8)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Ink.ink.ignoresSafeArea())
        .accessibilityAddTraits(.isModal)
    }
}

private struct Panel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Ink.ink2))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Ink.line, lineWidth: 1))
    }
}

private struct Chip: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            T(text, .button, color: selected ? Ink.accentInk : Ink.bone, lines: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(selected ? Ink.accent : Ink.ink3))
        }
        .buttonStyle(TapStyle())
    }
}

/// Просим войти: комната, друзья и Blink+ работают только с аккаунтом.
private struct NeedSignIn: View {
    @EnvironmentObject private var graph: Graph
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            T(text, .body, color: Ink.mute, align: .center)
            PillButton("Войти") { graph.nav.go(.account) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func copyToClipboard(_ text: String, _ graph: Graph) {
    UIPasteboard.general.string = text
    graph.toasts.show("Скопировано")
}

// ---------- комната ----------

private struct RoomContent: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var roomStore: RoomStore
    let bottomInset: CGFloat

    var body: some View {
        if auth.value == nil {
            NeedSignIn(text: "Комната работает с аккаунтом: так друзья видят, кто есть кто. Войдите, и можно слушать вместе.")
        } else if let room = roomStore.value {
            RoomView(room: room, me: auth.value?.userId, bottomInset: bottomInset)
        } else {
            RoomStart(bottomInset: bottomInset)
        }
    }
}

private struct RoomStart: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var friends: FriendsStore
    let bottomInset: CGFloat

    @State private var code = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Panel {
                    T("Создать комнату", .h2)
                    T("Музыка играет у всех одновременно: пауза, перемотка и следующий трек общие. До \(RoomSession.maxMembers) человек.", .body, color: Ink.mute)
                        .padding(.top, 6)
                    PillButton(busy ? "Создаём…" : "Создать комнату", enabled: !busy) {
                        busy = true
                        Task { @MainActor in
                            _ = await graph.room.create()
                            busy = false
                        }
                    }
                    .padding(.top, 14)
                }
                Panel {
                    T("Войти по коду или ссылке", .h2)
                    TextBox("Код или ссылка", text: $code, focus: $focused, submit: .go) { join() }
                        .padding(.top, 10)
                    PillButton("Войти", primary: false, enabled: !code.trimmingCharacters(in: .whitespaces).isEmpty) { join() }
                        .padding(.top, 10)
                }
                let live = friends.value.friends.filter { $0.room != nil }
                if !live.isEmpty {
                    T("Друзья в комнатах", .label, color: Ink.faint)
                        .padding(.top, 6)
                    ForEach(live) { f in
                        FriendRow(friend: f) { if let r = f.room { graph.room.join(r) } }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private func join() {
        let raw = code.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return }
        graph.room.join(RoomSession.codeFrom(raw) ?? raw)
        code = ""
        focused = false
    }
}

private struct RoomView: View {
    @EnvironmentObject private var graph: Graph
    let room: RoomState
    let me: String?
    let bottomInset: CGFloat

    @State private var text = ""
    @FocusState private var focused: Bool

    private var isHost: Bool { return room.isHost(me) }
    private var controlled: Bool { return room.mode == "host" && !isHost }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                codePanel
                membersPanel
                nowPanel
                reactionsPanel
                if room.queue.count > 1 { queuePanel }
                chatPanel
                PillButton("Выйти из комнаты", primary: false, danger: true) { graph.room.leave() }
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, bottomInset)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }

    private var codePanel: some View {
        let link = RoomSession.link(room.code)
        return Panel {
            T("КОД КОМНАТЫ", .label, color: Ink.faint)
            T(room.code, .h1, lines: 1)
                .padding(.top, 4)
            T(link, .small, color: Ink.mute, lines: 1)
                .padding(.top, 2)
            HStack(spacing: 10) {
                ShareLink(item: link) {
                    T("Поделиться", .button, color: Ink.accentInk, lines: 1)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(Ink.accent))
                }
                PillButton("Скопировать", primary: false) { copyToClipboard(link, graph) }
            }
            .padding(.top, 12)
        }
    }

    private var membersPanel: some View {
        Panel {
            HStack {
                T("Слушают · \(room.members.count) из \(RoomSession.maxMembers)", .label, color: Ink.faint)
                Spacer(minLength: 0)
                if isHost {
                    HStack(spacing: 8) {
                        Chip(text: "Все", selected: room.mode != "host") { Task { await graph.room.setMode("all") } }
                        Chip(text: "Только хост", selected: room.mode == "host") { Task { await graph.room.setMode("host") } }
                    }
                }
            }
            ForEach(room.members, id: \.id) { m in
                HStack(spacing: 8) {
                    GlyphView(m.host ? .star : .person, color: m.host ? Ink.accent : Ink.mute, size: 18)
                    T(m.name.isEmpty ? "Слушатель" : m.name, .body, lines: 1)
                    if m.id == me { T("вы", .small, color: Ink.faint) }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
            if room.mode == "host" {
                T(isHost ? "Управляете только вы." : "Управляет хост комнаты.", .small, color: Ink.faint)
                    .padding(.top, 10)
            }
        }
    }

    private var nowPanel: some View {
        Panel {
            if let t = room.track {
                HStack(spacing: 12) {
                    Cover(t.artwork, size: 56, radius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        T(t.title, .title, lines: 1)
                        T(t.artist, .small, color: Ink.mute, lines: 1)
                        T(room.playing ? "Играет" : "На паузе", .small, color: room.playing ? Ink.accent : Ink.faint)
                    }
                    Spacer(minLength: 0)
                }
                if room.queue.count > 1 {
                    let need = max(1, (room.members.count + 1) / 2)
                    let voted = me.map { room.skips.contains($0) } ?? false
                    HStack(spacing: 10) {
                        PillButton(voted ? "Голос за пропуск отдан" : "Пропустить трек", primary: false, enabled: !voted) {
                            Task { await graph.room.voteSkip() }
                        }
                        if !room.skips.isEmpty {
                            T("\(room.skips.count) из \(need)", .small, color: Ink.mute)
                        }
                    }
                    .padding(.top, 12)
                }
            } else {
                T("Пока ничего не играет. Включите трек, и он зазвучит у всех в комнате.", .body, color: Ink.mute)
            }
        }
    }

    private var reactionsPanel: some View {
        Panel {
            T("РЕАКЦИИ", .label, color: Ink.faint)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(RoomSession.emoji, id: \.self) { e in
                        Button {
                            Task { await graph.room.react(e) }
                        } label: {
                            Text(e)
                                .font(.system(size: 24))
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Ink.ink3))
                        }
                        .buttonStyle(TapStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.top, 8)
            if let last = room.reactions.last {
                T("\(last.name.isEmpty ? "Кто-то" : last.name) \(last.emoji)", .small, color: Ink.mute)
                    .padding(.top, 8)
            }
        }
    }

    private var queuePanel: some View {
        Panel {
            T("ОЧЕРЕДЬ КОМНАТЫ", .label, color: Ink.faint)
            ForEach(Array(room.queue.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 10) {
                    T(i == room.index ? "▶" : "\(i + 1)", .small, color: i == room.index ? Ink.accent : Ink.faint)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 0) {
                        T(t.title, .body, color: i == room.index ? Ink.accent : Ink.bone, lines: 1)
                        T(t.artist, .small, color: Ink.mute, lines: 1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            }
        }
    }

    private var chatPanel: some View {
        Panel {
            T("ЧАТ", .label, color: Ink.faint)
            if room.chat.isEmpty {
                T("Напишите первым.", .small, color: Ink.mute)
                    .padding(.top, 8)
            }
            ForEach(room.chat.suffix(40), id: \.id) { c in
                VStack(alignment: .leading, spacing: 1) {
                    T(c.by == me ? "Вы" : (c.name.isEmpty ? "Слушатель" : c.name), .small, color: c.by == me ? Ink.accent : Ink.mute)
                    T(c.text, .body)
                }
                .padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextBox("Сообщение", text: $text, focus: $focused, submit: .send) { send() }
                IconButton(.send, "Отправить", color: Ink.accent, enabled: !text.trimmingCharacters(in: .whitespaces).isEmpty) { send() }
            }
            .padding(.top, 12)
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        text = ""
        Task { @MainActor in
            let ok = await graph.room.sendChat(t)
            if !ok { text = t }
        }
    }
}

// ---------- друзья ----------

private struct FriendRow: View {
    let friend: Friend
    let onJoin: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let t = friend.track {
                Cover(t.artwork, size: 44, radius: 10)
            } else {
                ZStack {
                    Circle().fill(Ink.ink3)
                    GlyphView(.person, color: Ink.mute, size: 22)
                }
                .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 1) {
                T(friend.name.isEmpty ? "Друг" : friend.name, .title, lines: 1)
                if let t = friend.track {
                    T(t.title + " · " + t.artist, .small, color: Ink.accent, lines: 1)
                } else {
                    T("Сейчас не слушает", .small, color: Ink.faint, lines: 1)
                }
            }
            Spacer(minLength: 0)
            if friend.room != nil {
                PillButton("Войти", primary: false, action: onJoin)
            }
        }
    }
}

private struct FriendsContent: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var store: FriendsStore
    let bottomInset: CGFloat

    @State private var inviteLink: String? = nil
    @State private var code = ""
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        if auth.value == nil {
            NeedSignIn(text: "Друзья работают с аккаунтом. Войдите, и вы увидите, что слушают те, кого вы добавили.")
        } else {
            let ui = store.value
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Panel {
                        T("Пригласить друга", .h2)
                        T("Отправьте ссылку: когда друг её откроет, вы увидите друг у друга, что играет.", .body, color: Ink.mute)
                            .padding(.top, 6)
                        if let link = inviteLink {
                            T(link, .small, color: Ink.mute, lines: 1)
                                .padding(.top, 10)
                            HStack(spacing: 10) {
                                ShareLink(item: link) {
                                    T("Поделиться", .button, color: Ink.accentInk, lines: 1)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 11)
                                        .background(Capsule().fill(Ink.accent))
                                }
                                PillButton("Скопировать", primary: false) { copyToClipboard(link, graph) }
                            }
                            .padding(.top, 10)
                        } else {
                            PillButton(busy ? "Создаём…" : "Создать ссылку", enabled: !busy) {
                                busy = true
                                Task { @MainActor in
                                    inviteLink = await graph.friends.invite()
                                    busy = false
                                }
                            }
                            .padding(.top, 12)
                        }
                    }
                    Panel {
                        T("Есть ссылка от друга?", .h2)
                        TextBox("Ссылка или код", text: $code, focus: $focused, submit: .go) { accept() }
                            .padding(.top, 10)
                        PillButton("Добавить", primary: false, enabled: !code.trimmingCharacters(in: .whitespaces).isEmpty) { accept() }
                            .padding(.top, 10)
                    }
                    Panel {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                T("Скрыть, что я слушаю", .title)
                                T("Друзья не увидят ваш трек.", .small, color: Ink.mute)
                            }
                            Spacer(minLength: 0)
                            Toggle("", isOn: Binding(get: { ui.hidden }, set: { v in Task { await graph.friends.setHidden(v) } }))
                                .labelsHidden()
                                .tint(Ink.accent)
                        }
                    }
                    T("ДРУЗЬЯ", .label, color: Ink.faint)
                        .padding(.top, 6)
                    if ui.friends.isEmpty {
                        T(ui.offline ? "Не получилось загрузить список. Проверьте интернет." : (ui.loaded ? "Пока никого. Отправьте ссылку первому другу." : "Загружаем…"), .body, color: Ink.mute)
                    }
                    ForEach(ui.friends) { f in
                        FriendRow(friend: f) { if let r = f.room { graph.room.join(r); graph.nav.open(.room) } }
                            .contextMenu {
                                Button("Удалить из друзей", role: .destructive) { Task { await graph.friends.remove(f.id) } }
                            }
                    }
                    if !ui.friends.isEmpty {
                        T("Удерживайте строку, чтобы удалить друга.", .small, color: Ink.faint)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .refreshable { await graph.friends.refresh() }
            .task { await graph.friends.refresh() }
        }
    }

    private func accept() {
        let raw = code.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return }
        let c = FriendsApi.codeFrom(raw) ?? raw
        focused = false
        Task { @MainActor in
            if await graph.friends.accept(c) { code = "" }
        }
    }
}

// ---------- Blink+ ----------

private struct PlusSheet: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var plus: PlusStore
    let bottomInset: CGFloat

    @State private var cfg = PlusConfig.fallback
    @State private var me: PlusMe? = nil
    @State private var plan = ""
    @State private var promo = ""
    @State private var promoNote: String? = nil
    @State private var discount = 0
    @State private var busy = false
    @State private var donate = ""
    @FocusState private var promoFocused: Bool
    @FocusState private var donateFocused: Bool

    var body: some View {
        Sheet(title: cfg.title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    T(cfg.lead, .body, color: Ink.mute)
                    statusPanel
                    plansPanel
                    perksPanel
                    comparePanel
                    supportPanel
                    T("Оплата откроется в браузере.", .small, color: Ink.faint)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, bottomInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .task {
            cfg = graph.plusApi.cached()
            if plan.isEmpty { plan = cfg.plans.first?.id ?? "" }
            if let c = try? await graph.plusApi.config() {
                cfg = c
                if !c.plans.contains(where: { $0.id == plan }) { plan = c.plans.first?.id ?? "" }
            }
            if auth.value != nil { me = try? await graph.plusApi.me() }
        }
    }

    private func until(_ ms: Int64?) -> String {
        guard let ms = ms else { return "без срока" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        return "до " + f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private var statusPanel: some View {
        Panel {
            if plus.value.active {
                T("Blink+ активен", .h2, color: Ink.accent)
                T(until(plus.value.untilMs), .body, color: Ink.mute)
                    .padding(.top, 4)
            } else {
                T("Blink+ не подключён", .h2)
                T("Музыка и Вспышка бесплатны. Подписка добавляет сохранение без интернета и орбиту у аватарки.", .body, color: Ink.mute)
                    .padding(.top, 4)
            }
            if let m = me, m.donated > 0 {
                let tier = cfg.tiers.last(where: { $0.id == m.keeperTier })
                T("Вы поддержали Blink на \(m.donated) ₽" + (tier.map { " · " + $0.name } ?? ""), .small, color: Ink.mute)
                    .padding(.top, 8)
            }
        }
    }

    private func price(_ p: PlusPlan) -> Int {
        return discount > 0 ? max(1, p.price * (100 - discount) / 100) : p.price
    }

    private var plansPanel: some View {
        Panel {
            T("ТАРИФ", .label, color: Ink.faint)
            ForEach(cfg.plans, id: \.id) { p in
                Button { plan = p.id } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .stroke(plan == p.id ? Ink.accent : Ink.line2, lineWidth: plan == p.id ? 6 : 1.5)
                            .frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            T(p.label, .title)
                            if p.days >= 365 { T("\(p.monthly) ₽ в месяц", .small, color: Ink.mute) }
                        }
                        if !p.tag.isEmpty {
                            T(p.tag, .label, color: Ink.accentInk)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Ink.accent))
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 0) {
                            if p.old > p.price { T("\(p.old) ₽", .small, color: Ink.faint) }
                            T("\(price(p)) ₽", .title)
                        }
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TapStyle())
            }
            HStack(spacing: 8) {
                TextBox("Промокод", text: $promo, focus: $promoFocused, submit: .done) { applyPromo() }
                PillButton("Применить", primary: false, enabled: !promo.trimmingCharacters(in: .whitespaces).isEmpty && !busy) { applyPromo() }
            }
            .padding(.top, 6)
            if let n = promoNote {
                T(n, .small, color: Ink.mute)
                    .padding(.top, 6)
            }
            PillButton(auth.value == nil ? "Войти, чтобы оплатить" : (busy ? "Секунду…" : "Оплатить"), enabled: !busy) {
                if auth.value == nil { graph.nav.go(.account) } else { checkout() }
            }
            .padding(.top, 12)
        }
    }

    private var perksPanel: some View {
        Panel {
            ForEach(Array(cfg.perks.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 2) {
                    T(p.title, .title)
                    T(p.text, .small, color: Ink.mute)
                }
                .padding(.top, i == 0 ? 0 : 12)
            }
        }
    }

    private var comparePanel: some View {
        Panel {
            HStack {
                Spacer(minLength: 0)
                T("Бесплатно", .label, color: Ink.faint).frame(width: 82)
                T("Blink+", .label, color: Ink.accent).frame(width: 56)
            }
            ForEach(Array(cfg.compare.enumerated()), id: \.offset) { _, r in
                HStack {
                    T(r.label, .small, lines: 2)
                    Spacer(minLength: 0)
                    T(r.free ? "✓" : "—", .body, color: r.free ? Ink.good : Ink.faint, align: .center).frame(width: 82)
                    T(r.plus ? "✓" : "—", .body, color: r.plus ? Ink.accent : Ink.faint, align: .center).frame(width: 56)
                }
                .padding(.top, 8)
            }
        }
    }

    private var supportPanel: some View {
        Panel {
            T("Поддержать Blink", .h2)
            T("Любая сумма идёт на серверы. Начиная с " + String(cfg.tiers.first?.from ?? 50) + " ₽ вы получаете значок «" + (cfg.tiers.first?.name ?? "Хранитель") + "».", .body, color: Ink.mute)
                .padding(.top, 4)
            HStack(spacing: 8) {
                TextBox("Сумма, ₽", text: $donate, focus: $donateFocused, keyboard: .numberPad, submit: .done) {}
                PillButton("Отправить", primary: false, enabled: Int(donate) != nil && !busy && auth.value != nil) { sendDonation() }
            }
            .padding(.top, 10)
            if auth.value == nil {
                T("Чтобы поддержать, войдите в аккаунт.", .small, color: Ink.faint)
                    .padding(.top, 6)
            }
        }
    }

    private func applyPromo() {
        let code = promo.trimmingCharacters(in: .whitespaces)
        if code.isEmpty { return }
        if auth.value == nil {
            promoNote = "Войдите, чтобы применить промокод."
            return
        }
        busy = true
        promoFocused = false
        Task { @MainActor in
            defer { busy = false }
            do {
                switch try await graph.plusApi.promo(code) {
                case .discount(_, let percent):
                    discount = percent
                    promoNote = "Скидка \(percent)% применится при оплате."
                case .days(_, let days, _):
                    promoNote = "Готово: добавили \(days) дн. Blink+."
                    discount = 0
                    _ = await graph.plus.refresh()
                    me = try? await graph.plusApi.me()
                }
            } catch let e as PlusError {
                promoNote = e.message
            } catch {
                promoNote = "Нет связи с сервером"
            }
        }
    }

    private func checkout() {
        busy = true
        let code = discount > 0 ? promo : nil
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await graph.plusApi.checkout(plan: plan, promo: code)
                if let u = URL(string: url) { graph.actions.openURL(u) }
            } catch let e as PlusError {
                graph.toasts.show(e.message)
            } catch {
                graph.toasts.show("Нет связи с сервером")
            }
        }
    }

    private func sendDonation() {
        guard let amount = Int(donate) else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let url = try await graph.plusApi.donate(amountRub: amount)
                if let u = URL(string: url) { graph.actions.openURL(u) }
            } catch let e as PlusError {
                graph.toasts.show(e.message)
            } catch {
                graph.toasts.show("Нет связи с сервером")
            }
        }
    }
}
