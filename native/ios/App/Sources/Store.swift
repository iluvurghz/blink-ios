import SwiftUI
import UIKit
import BlinkCore

/// Мост от ядра к SwiftUI: хранит последнее значение и обновляет экран на главном потоке.
/// Подписка живёт, пока жив объект. Повторы не публикуются, чтобы экраны зря не перерисовывались.
/// Для каждого значения свой подкласс: так экраны берут нужное из окружения по типу.
class Store<Value: Equatable & Sendable>: ObservableObject {
    @Published private(set) var value: Value
    private var token: NetworkObservation?

    init(_ initial: Value, observe: (@escaping @Sendable (Value) -> Void) -> NetworkObservation) {
        value = initial
        token = observe { [weak self] next in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.value != next { self.value = next }
            }
        }
    }

    deinit {
        token?.cancel()
    }
}

final class NavStore: Store<NavState> {}
final class RoomStore: Store<RoomState?> {}
final class FriendsStore: Store<FriendsUi> {}
/// Версия библиотеки (лайки, плейлисты): меняется при любой правке, экраны перечитывают данные.
final class LibraryVersion: Store<Int> {}
final class PlayerStore: Store<PlayerUi> {}
final class OfflineStore: Store<OfflineState> {}
final class SearchStore: Store<SearchState> {}
final class AuthStore: Store<AuthSession?> {}
final class PlusStore: Store<PlusInfo> {}
final class OnlineStore: Store<Bool> {}
/// Какой трек играет сейчас (только id): строки списков не перерисовываются от каждого тика позиции.
final class CurrentIdStore: Store<String?> {}
/// Есть ли трек в плеере: от этого зависит, показывать ли мини-плеер.
final class HasTrackStore: Store<Bool> {}
/// Идёт ли сейчас хоть одна загрузка: от этого зависит точка на вкладке «Скачанное».
final class DownloadingStore: Store<Bool> {}

/// Тосты на экране: новый заменяет старый, с кнопкой висит дольше (как на Android).
final class ToastCenter: ObservableObject {
    struct Shown: Identifiable {
        let id: Int
        let toast: Toast
    }

    @Published private(set) var shown: Shown?
    private var token: NetworkObservation?
    private var serial = 0
    private var hideWork: DispatchWorkItem?

    init(_ toasts: Toasts) {
        token = toasts.observe { [weak self] toast in
            DispatchQueue.main.async { self?.present(toast) }
        }
    }

    deinit {
        token?.cancel()
    }

    private func present(_ toast: Toast) {
        serial += 1
        let id = serial
        withAnimation(.easeOut(duration: 0.22)) { shown = Shown(id: id, toast: toast) }
        // VoiceOver не видит всплывающую плашку сам: читаем её вслух.
        UIAccessibility.post(notification: .announcement, argument: toast.message)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide(id) }
        hideWork = work
        let seconds: Double = toast.action != nil ? 5.2 : 3.4
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func dismiss() {
        hideWork?.cancel()
        withAnimation(.easeIn(duration: 0.16)) { shown = nil }
    }

    private func hide(_ id: Int) {
        if shown?.id == id {
            withAnimation(.easeIn(duration: 0.16)) { shown = nil }
        }
    }
}

/// Трек, для которого сейчас выбирают плейлист (окно «В плейлист»).
final class PickState: ObservableObject {
    @Published var track: Track?
}
