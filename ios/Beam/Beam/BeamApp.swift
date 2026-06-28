import SwiftUI
import UIKit

@main
struct BeamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var inbox = InboxStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(inbox)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        PushService.shared.requestPermission()
        Task { try? await APIService.shared.register(pushToken: nil) }
        APIService.shared.startSSE()
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        APIService.shared.startSSE()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        APIService.shared.stopSSE()
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { try? await APIService.shared.register(pushToken: token) }
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler handler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushService.shared.handlePayload(userInfo)
        handler(.newData)
    }
}
