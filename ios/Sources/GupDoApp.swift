import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

@main
struct GupDoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    guard !AppDelegate.underTest else { return }
                    model.startTicking()
                    await model.requestPermissions()
                }
        }
        .onChange(of: phase) { _, phase in
            guard !AppDelegate.underTest else { return }
            switch phase {
            case .active: Task { await model.refresh() }
            case .background: AppDelegate.scheduleWake()
            default: break
            }
        }
    }
}

/// Sets up what has to exist before the first notification or wake arrives: the notification delegate and its
/// categories, and the background refresh that replans (habits are planned a day ahead, so a phone that isn't opened
/// for a while still gets them).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let wakeID = "com.dltnp.gupdo.replan"
    /// The unit tests use the app as their host: no permission prompts, nothing scheduled.
    static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationFactory.categories())
        guard !Self.underTest else { return true }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.wakeID, using: nil) { task in
            let work = Task { @MainActor in
                await AppModel.shared.refresh()
                Self.scheduleWake()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
        Self.scheduleWake()
        // Region monitoring relaunches the app in the background for an arrival: watching the places again (in the
        // replan) is what receives that event.
        Task { @MainActor in await AppModel.shared.refresh() }
        return true
    }

    /// The next background refresh: in 3 hours, or sooner to refresh a drive time before a time-to-leave alarm (not
    /// guaranteed to come on time; the alarm is already scheduled with the last drive time).
    @MainActor
    static func scheduleWake() {
        let request = BGAppRefreshTaskRequest(identifier: wakeID)
        request.earliestBeginDate = AppModel.shared.nextWake
        try? BGTaskScheduler.shared.submit(request)
    }

    /// A button on a notification (in the background unless it opens the app), or a tap on it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let fields = NotificationFactory.fields(response.notification.request.content.userInfo)
        let action = NotificationFactory.action(for: response.actionIdentifier)
        guard let payload = AlertPayload(fields: fields) else { return }
        await AppModel.shared.handle(action, payload)
    }

    /// While the app is open its notifications still show (and the screen catches up).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await AppModel.shared.refresh()
        return [.banner, .list, .sound]
    }
}
