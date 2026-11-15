import AlarmKit
import AppIntents
import Foundation
import SwiftUI
import UserNotifications

/// Turns the planner's list into what the phone does: `plain` and `timeSensitive` alerts become local notifications
/// (with the category's buttons), `alarm` alerts become AlarmKit alarms (alarm volume, through silent mode and Focus).
protocol AlertScheduling: Sendable {
    func requestPermissions() async
    /// Makes the pending notifications and alarms exactly `plan`'s.
    func apply(_ plan: Plan, settings: Settings, calendar: Calendar) async
    /// Takes these items' delivered notifications out of Notification Center (they were answered).
    func clearDelivered(items: Set<UUID>) async
}

struct AlertScheduler: AlertScheduling {
    func requestPermissions() async {
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(NotificationFactory.categories())
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        if AlarmManager.shared.authorizationState == .notDetermined {
            _ = try? await AlarmManager.shared.requestAuthorization()
        }
    }

    func apply(_ plan: Plan, settings: Settings, calendar: Calendar) async {
        // Notifications: replace everything pending (at most 60, the planner keeps the earliest).
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for alert in plan.notifications {
            try? await center.add(NotificationFactory.request(for: alert, settings: settings, calendar: calendar))
        }

        // Alarms: keep the ones that stay, cancel the rest, add the new ones (the same alert keeps the same id).
        let manager = AlarmManager.shared
        guard manager.authorizationState == .authorized else { return }
        let existing = ((try? manager.alarms) ?? []).map(\.id)
        let sync = AlarmSync.diff(plan: plan, existing: existing)
        for id in sync.cancel {
            try? manager.stop(id: id)
            try? manager.cancel(id: id)
        }
        for alert in sync.schedule {
            do {
                _ = try await manager.schedule(id: StableID.uuid(alert.id), configuration: AlarmFactory.configuration(for: alert))
            } catch {
                // Over AlarmKit's limit: the earliest are in; the next replan adds the rest as these go off.
                break
            }
        }
    }

    func clearDelivered(items: Set<UUID>) async {
        guard !items.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let ids = delivered.filter { n in
            guard let p = AlertPayload(fields: NotificationFactory.fields(n.request.content.userInfo)) else { return false }
            return !items.isDisjoint(with: p.itemIDs)
        }.map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
}

/// The notification side: categories with their buttons, and one request per planned alert.
enum NotificationFactory {
    static func categories() -> Set<UNNotificationCategory> {
        Set(AlertActions.categoryIDs.map { id in
            let actions = AlertActions.actions(forCategoryID: id).map { a in
                var options: UNNotificationActionOptions = []
                if a.opensApp { options.insert(.foreground) }
                if a.isDestructive { options.insert(.destructive) }
                return UNNotificationAction(identifier: a.rawValue, title: a.title, options: options,
                                            icon: UNNotificationActionIcon(systemImageName: a.symbol))
            }
            return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
        })
    }

    static func request(for alert: PlannedAlert, settings: Settings, calendar: Calendar) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        if let body = alert.body { content.body = body }
        content.sound = .default
        content.interruptionLevel = alert.kind == .timeSensitive ? .timeSensitive : .active
        content.categoryIdentifier = AlertActions.categoryID(for: alert, settings: settings, calendar: calendar)
        content.userInfo = AlertPayload(alert).fields
        content.threadIdentifier = alert.itemIDs.first?.uuidString ?? ""
        let when = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: alert.fireDate)
        return UNNotificationRequest(identifier: alert.id, content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
    }

    static func fields(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in userInfo { if let k = k as? String, let v = v as? String { out[k] = v } }
        return out
    }

    /// The button pressed on a notification (a plain tap opens the item's answers).
    static func action(for identifier: String) -> AlertAction {
        identifier == UNNotificationDefaultActionIdentifier ? .open : AlertAction(rawValue: identifier) ?? .open
    }
}

/// What an alarm carries.
struct GupDoAlarm: AlarmMetadata {
    var alertID: String
}

/// The alarm side: a full-screen alarm with the item's title, AlarmKit's own Stop and one more button
/// (`AlertActions.alarmButtons`). Both run an intent in the app: the extra button answers (Done, Got it) or opens the
/// proof screen; Stop opens the app on the item's answers (reminders, habits) or answers Got it (events).
enum AlarmFactory {
    static func configuration(for alert: PlannedAlert) -> AlarmManager.AlarmConfiguration<GupDoAlarm> {
        let buttons = AlertActions.alarmButtons(for: alert.category)
        let extra = AlarmButton(text: LocalizedStringResource(stringLiteral: title(buttons.secondary)),
                                textColor: .white, systemImageName: buttons.secondary.symbol)
        let name = LocalizedStringResource(stringLiteral: alert.title)
        let shown: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            shown = AlarmPresentation.Alert(title: name, secondaryButton: extra, secondaryButtonBehavior: .custom)
        } else {
            shown = AlarmPresentation.Alert(title: name,
                                            stopButton: AlarmButton(text: "Stop", textColor: .white,
                                                                    systemImageName: "stop.circle"),
                                            secondaryButton: extra, secondaryButtonBehavior: .custom)
        }
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: shown),
                                         metadata: GupDoAlarm(alertID: alert.id), tintColor: Color.accentColor)
        let payload = AlertPayload(alert)
        return .alarm(schedule: .fixed(alert.fireDate), attributes: attributes,
                      stopIntent: intent(buttons.stop, payload), secondaryIntent: intent(buttons.secondary, payload))
    }

    static func title(_ action: AlertAction) -> String {
        action == .prove ? "Prove it" : action.title
    }

    static func intent(_ action: AlertAction, _ payload: AlertPayload) -> any LiveActivityIntent {
        action.opensApp ? AlarmOpenIntent(action: action, payload: payload)
            : AlarmAnswerIntent(action: action, payload: payload)
    }
}

/// An alarm button that answers without opening the app (Done, Got it).
struct AlarmAnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer a GupDo alarm"
    static let isDiscoverable = false

    @Parameter(title: "Action") var action: String
    @Parameter(title: "Alert") var fields: String

    init() {}

    init(action: AlertAction, payload: AlertPayload) {
        self.action = action.rawValue
        self.fields = AlarmIntentFields.encode(payload)
    }

    func perform() async throws -> some IntentResult {
        await AlarmIntentFields.run(action, fields)
        return .result()
    }
}

/// An alarm button whose choice is made in the app (Prove it, Stop on a reminder or habit): opens it there.
struct AlarmOpenIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open a GupDo alarm"
    static let isDiscoverable = false
    static let openAppWhenRun = true

    @Parameter(title: "Action") var action: String
    @Parameter(title: "Alert") var fields: String

    init() {}

    init(action: AlertAction, payload: AlertPayload) {
        self.action = action.rawValue
        self.fields = AlarmIntentFields.encode(payload)
    }

    func perform() async throws -> some IntentResult {
        await AlarmIntentFields.run(action, fields)
        return .result()
    }
}

enum AlarmIntentFields {
    static func encode(_ p: AlertPayload) -> String {
        (try? String(data: JSONEncoder().encode(p.fields), encoding: .utf8)) ?? "{}"
    }

    static func decode(_ text: String) -> AlertPayload? {
        guard let dict = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return nil }
        return AlertPayload(fields: dict)
    }

    @MainActor
    static func run(_ action: String, _ fields: String) async {
        guard let payload = decode(fields) else { return }
        await AppModel.shared.handle(AlertAction(rawValue: action) ?? .open, payload)
    }
}
