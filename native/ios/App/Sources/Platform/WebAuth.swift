import AuthenticationServices
import UIKit
import BlinkCore

/// Вход через сайт (Google или Telegram): системное окно браузера, которое закрывается, когда сайт возвращает по blink://auth.
final class WebAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Зовите с главного потока. `completion` получает ссылку возврата или nil, если окно закрыли.
    func start(_ url: URL, completion: @escaping (String?) -> Void) {
        let s = ASWebAuthenticationSession(url: url, callbackURLScheme: AuthLink.scheme) { [weak self] callback, _ in
            DispatchQueue.main.async {
                self?.session = nil
                completion(callback?.absoluteString)
            }
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first ?? ASPresentationAnchor()
    }
}
