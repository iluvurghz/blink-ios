import UIKit
import Capacitor

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        window = UIWindow(windowScene: windowScene)
        window?.backgroundColor = UIColor(red: 13 / 255, green: 12 / 255, blue: 16 / 255, alpha: 1)
        window?.rootViewController = CAPBridgeViewController()
        window?.makeKeyAndVisible()

        SceneDelegateProxy.shared.scene(scene, willConnectTo: session, options: connectionOptions)

        // CI screenshot tour: the simulator passes a blink:// link here (SIMCTL_CHILD_BLINK_OPEN), because
        // `simctl openurl` stops at an «Open in Blink?» alert. Same path as a real link: the page opens that section.
        if let link = ProcessInfo.processInfo.environment["BLINK_OPEN"], let url = URL(string: link) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                _ = ApplicationDelegateProxy.shared.application(UIApplication.shared, open: url, options: [:])
            }
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        SceneDelegateProxy.shared.scene(scene, openURLContexts: URLContexts)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        SceneDelegateProxy.shared.scene(scene, continue: userActivity)
    }
}
