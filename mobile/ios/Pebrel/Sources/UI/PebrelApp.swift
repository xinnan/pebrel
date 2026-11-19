import Combine
import SwiftUI
import UserNotifications

struct DeepLinkTarget: Equatable {
    let desktopId: String
    let windowId: Int64
    let paneId: Int64
    let processId: Int64?
}

final class NotificationRouteDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouteDelegate()

    @Published var pendingDeepLink: DeepLinkTarget?

    private override init() {
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if (info["action"] as? String) == "OPEN_TASK",
           let desktop = info["desktop"] as? String,
           let window = (info["window"] as? NSNumber)?.int64Value,
           let pane = (info["pane"] as? NSNumber)?.int64Value {
            let proc = (info["process"] as? NSNumber)?.int64Value
            DispatchQueue.main.async {
                self.pendingDeepLink = DeepLinkTarget(
                    desktopId: desktop,
                    windowId: window,
                    paneId: pane,
                    processId: proc
                )
            }
        }
        completionHandler()
    }
}

@main
struct PebrelApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var repository = SessionRepository()
    @ObservedObject private var notificationDelegate = NotificationRouteDelegate.shared

    init() {
        UNUserNotificationCenter.current().delegate = NotificationRouteDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(repository: repository, notificationDelegate: notificationDelegate)
                .onChange(of: scenePhase) { phase in
                    repository.foregroundChanged(phase == .active)
                }
        }
    }
}
