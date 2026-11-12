import SwiftUI
import BlinkCore

/// Профиль: вход, статус Blink+, место на телефоне. Вход по почте и паролю, через Google или Telegram.
/// Порт ui/AccountScreen.kt.
struct AccountView: View {
    @EnvironmentObject private var graph: Graph
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var offline: OfflineStore

    let active: Bool
    let bottomInset: CGFloat

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                T("Профиль", .display)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 18)
                if let session = auth.value {
                    SessionCard(session: session)
                    PlusCard(info: plus.value)
                        .padding(.top, 14)
                } else {
                    SignInCard(active: active)
                }
                TogetherCard()
                    .padding(.top, 14)
                OfflineCard(state: offline.value)
                    .padding(.top, 14)
                T("Blink " + Graph.versionText, .small, color: Ink.faint)
                    .padding(.top, 22)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, bottomInset, for: .scrollContent)
    }
}

private func nowMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000)
}

/// Кто вошёл и кнопка «Выйти».
private struct SessionCard: View {
    @EnvironmentObject private var graph: Graph
    let session: AuthSession

    var body: some View {
        Card {
            T(session.name ?? session.email ?? "Вы вошли", .h2, lines: 1)
            if let email = session.email, session.name != nil {
                T(email, .small, color: Ink.mute, lines: 1)
                    .padding(.top, 2)
            }
            PillButton("Выйти", primary: false) {
                Task { @MainActor in await graph.auth.signOut() }
            }
            .padding(.top, 14)
        }
    }
}

private struct PlusCard: View {
    @EnvironmentObject private var graph: Graph
    let info: PlusInfo

    var body: some View {
        let isActive = info.activeAt(nowMs())
        Card {
            HStack {
                T("Blink+", .h2)
                Spacer(minLength: 8)
                T(isActive ? "активен" : "не активен", .label, color: isActive ? Ink.accent : Ink.mute, lines: 1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(isActive ? Ink.accentSoft : Ink.ink3))
            }
            T(description(isActive), .body, color: Ink.mute)
                .padding(.top, 8)
            HStack(spacing: 10) {
                if !isActive {
                    PillButton("Открыть Blink+") { graph.actions.openPlus() }
                }
                PillButton("Обновить", primary: false) {
                    Task { @MainActor in
                        let ok = await graph.plus.refresh()
                        graph.toasts.show(ok ? "Статус обновлён" : "Не удалось связаться с сервером")
                    }
                }
            }
            .padding(.top, 14)
        }
    }

    private func description(_ isActive: Bool) -> String {
        if !isActive { return "С Blink+ треки каталога сохраняются на телефон и играют без интернета." }
        if let until = info.untilMs {
            return "Подписка действует до " + Format.date(until) + ". Сохранённые треки играют и без интернета."
        }
        return "Подписка действует. Сохранённые треки играют и без интернета."
    }
}

private struct OfflineCard: View {
    @EnvironmentObject private var graph: Graph
    let state: OfflineState

    var body: some View {
        Card {
            T("Офлайн", .h2)
            T(
                state.saved.isEmpty ? "Пока ничего не сохранено." : summary(state.saved.count, state.usedBytes) + " на телефоне.",
                .body,
                color: Ink.mute
            )
            .padding(.top, 6)
            T("Сохранять можно треки каталога Blink (с меткой BLINK), если артист разрешил. Остальные играют только онлайн.", .small, color: Ink.faint)
                .padding(.top, 6)
            PillButton("Открыть «Скачанное»", primary: false) { graph.nav.go(.downloads) }
                .padding(.top, 14)
        }
    }
}

private struct TogetherCard: View {
    @EnvironmentObject private var graph: Graph

    var body: some View {
        Card {
            T("Вместе", .h2)
            T("Комната, где музыка одна на всех, и друзья, которые видят, что вы слушаете.", .body, color: Ink.mute)
                .padding(.top, 6)
            HStack(spacing: 10) {
                PillButton("Слушать вместе") { graph.nav.open(.room) }
                PillButton("Друзья", primary: false) { graph.nav.open(.friends) }
            }
            .padding(.top, 14)
        }
    }
}

// ---------- вход ----------

private struct SignInCard: View {
    @EnvironmentObject private var graph: Graph
    let active: Bool

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String? = nil
    @FocusState private var emailFocused: Bool
    @FocusState private var passwordFocused: Bool

    init(active: Bool) {
        self.active = active
    }

    var body: some View {
        if !graph.auth.configured {
            Banner(.person, "В этой сборке вход выключен: ей не передали ключ сервера. Музыка из внешних источников играет и так.")
                .padding(.horizontal, -16)
        } else {
            form
                .onChange(of: active) { _, isActive in
                    if !isActive {
                        emailFocused = false
                        passwordFocused = false
                    }
                }
        }
    }

    private var form: some View {
        Card {
            T("Войти в Blink", .h2)
            T("Аккаунт нужен для треков каталога, подписки Blink+ и сохранения офлайн.", .small, color: Ink.mute)
                .padding(.top, 4)
            TextBox(
                "Почта",
                text: $email,
                focus: $emailFocused,
                keyboard: .emailAddress,
                contentType: .username,
                submit: .next,
                onSubmit: { passwordFocused = true }
            )
            .padding(.top, 16)
            TextBox(
                "Пароль",
                text: $password,
                focus: $passwordFocused,
                secure: true,
                contentType: .password,
                submit: .go,
                onSubmit: { submit() }
            )
            .padding(.top, 10)
            if let message = error {
                T(message, .small, color: Ink.danger)
                    .padding(.top, 10)
            }
            PillButton(busy ? "Входим…" : "Войти", enabled: !busy) { submit() }
                .padding(.top, 16)
            T("или через сайт", .small, color: Ink.faint)
                .padding(.top, 18)
            HStack(spacing: 10) {
                PillButton("Google", primary: false) { graph.signIn(with: .google) }
                PillButton("Telegram", primary: false) { graph.signIn(with: .telegram) }
            }
            .padding(.top, 10)
        }
    }

    private func submit() {
        if busy { return }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if mail.isEmpty || password.isEmpty {
            error = "Введите почту и пароль"
            return
        }
        busy = true
        error = nil
        emailFocused = false
        passwordFocused = false
        let pass = password
        Task { @MainActor in
            do {
                _ = try await graph.auth.signIn(email: mail, password: pass)
                password = ""
            } catch let failure as AuthException {
                error = text(for: failure.kind)
            } catch {
                self.error = "Не получилось войти. Попробуйте ещё раз"
            }
            busy = false
        }
    }

    private func text(for kind: AuthException.Kind) -> String {
        switch kind {
        case .badCredentials: return "Неверная почта или пароль"
        case .network: return "Нет связи с сервером. Проверьте интернет"
        case .server: return "Сервер сейчас не отвечает. Попробуйте позже"
        case .notConfigured: return "В этой сборке вход выключен"
        }
    }
}
