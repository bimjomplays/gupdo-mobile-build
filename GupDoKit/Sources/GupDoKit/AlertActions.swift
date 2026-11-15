import Foundation

// The buttons on GupDo's notifications and alarms and what each one does. The app registers one notification
// category per `AlertActions.categoryID` with these actions, puts an `AlertPayload` in every notification and alarm,
// and when a button is pressed asks `AlertActions.resolve` what to do: apply answers (in the background), or open a
// screen where the choice is made (Pick a time, Pick a day, habit proof).

/// A button on a notification or an alarm.
enum AlertAction: String, Codable, Hashable, CaseIterable {
    case done
    case later15, later60, tonight, tomorrow
    /// Later -> Pick a time (opens the app).
    case pickTime
    /// After the 3rd Later (opens the app).
    case pickDay
    case delete
    /// Habit Done + proof (opens the app's proof screen).
    case prove
    case habit15
    case cantRightNow
    case gotIt
    /// Opens the item's answers in the app (the alarm's slide-to-stop, a tap on the notification).
    case open

    var title: String {
        switch self {
        case .done: return "Done"
        case .later15: return "Later: 15 min"
        case .later60: return "Later: 1 hour"
        case .tonight: return "Later: Tonight"
        case .tomorrow: return "Later: Tomorrow"
        case .pickTime: return "Later: Pick a time…"
        case .pickDay: return "Pick a day…"
        case .delete: return "Delete"
        case .prove: return "Done + proof…"
        case .habit15: return "15 min"
        case .cantRightNow: return "Can't right now"
        case .gotIt: return "Got it"
        case .open: return "Open"
        }
    }

    /// SF Symbol for the button.
    var symbol: String {
        switch self {
        case .done, .prove: return "checkmark.circle"
        case .later15, .later60, .habit15: return "clock"
        case .tonight: return "moon"
        case .tomorrow: return "sunrise"
        case .pickTime, .pickDay: return "calendar"
        case .delete: return "trash"
        case .cantRightNow: return "car"
        case .gotIt: return "hand.thumbsup"
        case .open: return "arrow.up.forward.app"
        }
    }

    /// The choice is made in the app, so pressing it opens the app.
    var opensApp: Bool { [.pickTime, .pickDay, .prove, .open].contains(self) }
    var isDestructive: Bool { self == .delete }
}

/// What travels inside a notification (userInfo) or an alarm (metadata / intent parameters).
struct AlertPayload: Codable, Hashable {
    var alertID: String
    var itemKind: ItemKind
    var itemIDs: [UUID]
    var category: AlertCategory

    init(alertID: String, itemKind: ItemKind, itemIDs: [UUID], category: AlertCategory) {
        self.alertID = alertID
        self.itemKind = itemKind
        self.itemIDs = itemIDs
        self.category = category
    }

    init(_ alert: PlannedAlert) {
        self.init(alertID: alert.id, itemKind: alert.itemKind, itemIDs: alert.itemIDs, category: alert.category)
    }

    /// Plain strings, for notification userInfo and App Intent parameters.
    var fields: [String: String] {
        ["alertID": alertID, "itemKind": itemKind.rawValue, "category": category.rawValue,
         "itemIDs": itemIDs.map(\.uuidString).joined(separator: ",")]
    }

    init?(fields: [String: String]) {
        guard let id = fields["alertID"], let kind = fields["itemKind"].flatMap(ItemKind.init(rawValue:)),
              let category = fields["category"].flatMap(AlertCategory.init(rawValue:)) else { return nil }
        let ids = (fields["itemIDs"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        guard !ids.isEmpty else { return nil }
        self.init(alertID: id, itemKind: kind, itemIDs: ids, category: category)
    }
}

/// A screen the app shows to finish an answer.
enum AnswerScreen: Codable, Hashable {
    /// The item's answers (the same buttons as the notification).
    case answers(ItemKind, [UUID])
    /// Later -> Pick a time for a reminder.
    case pickTime(UUID)
    /// Pick a day for a reminder after its 3rd Later.
    case pickDay(UUID)
    /// Proof for these habits (a group alarm proves each one).
    case proof([UUID])
}

/// What a pressed button leads to.
enum AlertResolution: Hashable {
    case apply([AppAnswer])
    case show(AnswerScreen)
    /// Nothing to do (the item is gone or already answered).
    case nothing
}

enum AlertActions {
    /// The buttons a notification of this category shows. `tonightOffered`: Later -> Tonight is still more than 15
    /// minutes away at the notification's time.
    static func actions(for category: AlertCategory, tonightOffered: Bool = true) -> [AlertAction] {
        switch category {
        case .reminder:
            return [.done, .later15, .later60] + (tonightOffered ? [.tonight] : []) + [.tomorrow, .pickTime]
        case .reminderFinal: return [.done, .pickDay, .delete]
        case .habit: return [.prove, .habit15, .cantRightNow]
        case .headsUp, .eventMain: return [.gotIt]
        }
    }

    /// Every notification category the app registers.
    static let categoryIDs: [String] = [
        categoryID(.reminder, tonightOffered: true), categoryID(.reminder, tonightOffered: false),
        categoryID(.reminderFinal), categoryID(.habit), categoryID(.headsUp), categoryID(.eventMain),
    ]

    static func categoryID(_ category: AlertCategory, tonightOffered: Bool = true) -> String {
        category == .reminder && !tonightOffered ? "reminder-notonight" : category.rawValue
    }

    /// The category id and its buttons, back from the id.
    static func actions(forCategoryID id: String) -> [AlertAction] {
        if id == "reminder-notonight" { return actions(for: .reminder, tonightOffered: false) }
        return AlertCategory(rawValue: id).map { actions(for: $0) } ?? []
    }

    /// The notification category for a planned alert (Tonight is judged at its fire time).
    static func categoryID(for alert: PlannedAlert, settings: Settings, calendar: Calendar) -> String {
        let tonight = ReminderLogic.laterChoices(now: alert.fireDate, settings: settings, calendar: calendar)
            .contains(.tonight)
        return categoryID(alert.category, tonightOffered: tonight)
    }

    /// What pressing `action` on an alert with `payload` does, given the data as it is now.
    static func resolve(_ action: AlertAction, payload: AlertPayload, data: GupDoData, context: PhoneContext,
                        now: Date, calendar: Calendar) -> AlertResolution {
        let ids = payload.itemIDs
        switch payload.itemKind {
        case .reminder:
            guard let id = ids.first, let r = data.reminders.first(where: { $0.id == id }), r.status == .active
            else { return .nothing }
            let final = r.laterCount >= ReminderLogic.maxLaters
            switch action {
            case .done: return .apply([.reminder(id, .done)])
            case .later15, .later60, .tonight, .tomorrow:
                // Too many Laters already (an old notification): show the final choices instead.
                if final { return .show(.answers(.reminder, [id])) }
                let option: LaterOption = action == .later15 ? .fifteenMinutes : action == .later60 ? .oneHour
                    : action == .tonight ? .tonight : .tomorrow
                if option == .tonight,
                   !ReminderLogic.laterChoices(now: now, settings: data.settings, calendar: calendar).contains(.tonight) {
                    return .show(.pickTime(id))
                }
                return .apply([.reminder(id, .later(option))])
            case .pickTime: return final ? .show(.answers(.reminder, [id])) : .show(.pickTime(id))
            case .pickDay: return final ? .show(.pickDay(id)) : .show(.answers(.reminder, [id]))
            case .delete: return final ? .apply([.reminder(id, .delete)]) : .show(.answers(.reminder, [id]))
            default: return .show(.answers(.reminder, [id]))
            }
        case .habit:
            let habits = ids.compactMap { id in data.habits.first { $0.id == id } }
                .filter { !Answers.isProved($0, data: data, now: now, calendar: calendar) }
            guard !habits.isEmpty else { return .nothing }
            switch action {
            case .prove, .done: return .show(.proof(habits.map(\.id)))
            case .habit15:
                let ok = habits.filter {
                    Answers.habitChoices($0, data: data, context: context, now: now, calendar: calendar)
                        .contains(.fifteenMinutes)
                }
                return ok.isEmpty ? .show(.answers(.habit, habits.map(\.id)))
                    : .apply(ok.map { .habit($0.id, .fifteenMinutes) })
            case .cantRightNow:
                let paused = habits.compactMap { h in
                    HabitLogic.pauseReason(h, context: context).map { AppAnswer.habit(h.id, .cantRightNow($0)) }
                }
                // Not driving and not away: the app explains and shows the other answers.
                return paused.isEmpty ? .show(.answers(.habit, habits.map(\.id))) : .apply(paused)
            default: return .show(.answers(.habit, habits.map(\.id)))
            }
        case .event:
            guard let id = ids.first, data.events.contains(where: { $0.id == id }) else { return .nothing }
            switch action {
            case .gotIt, .done:
                return .apply([.event(id, payload.category == .headsUp ? .gotItHeadsUp : .gotItMainAlert)])
            default: return .show(.answers(.event, [id]))
            }
        }
    }

    // MARK: Alarms

    /// The alarm's two buttons (AlarmKit shows its own Stop plus one more): the extra button, and what Stop does.
    static func alarmButtons(for category: AlertCategory) -> (secondary: AlertAction, stop: AlertAction) {
        switch category {
        case .reminder, .reminderFinal: return (.done, .open)
        case .habit: return (.prove, .open)
        case .headsUp, .eventMain: return (.gotIt, .gotIt)
        }
    }
}

/// A stable UUID for a string (AlarmKit wants UUIDs; planned alert ids are strings that stay the same across
/// replans, so the same alarm keeps the same UUID and the app only adds and cancels what changed).
enum StableID {
    static func uuid(_ text: String) -> UUID {
        // Two FNV-1a 64-bit hashes with different offsets make the 128 bits; the version/variant bits mark it as a
        // name-based UUID.
        func fnv(_ offset: UInt64) -> UInt64 {
            var h = offset
            for b in text.utf8 {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
            return h
        }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4 ^ UInt64(text.utf8.count))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i] = UInt8(truncatingIfNeeded: a >> (56 - 8 * UInt64(i)))
            bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (56 - 8 * UInt64(i)))
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Which alarms to keep, cancel and add after a replan, given the ones AlarmKit has.
struct AlarmSync: Hashable {
    var cancel: [UUID]
    var schedule: [PlannedAlert]

    /// `limit`: at most this many alarms pending (the earliest), as AlarmKit has a cap; the app replans often.
    static func diff(plan: Plan, existing: [UUID], limit: Int = 60) -> AlarmSync {
        let wanted = Array(plan.alarms.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
        let wantedIDs = Set(wanted.map { StableID.uuid($0.id) })
        let have = Set(existing)
        return AlarmSync(cancel: existing.filter { !wantedIDs.contains($0) },
                         schedule: wanted.filter { !have.contains(StableID.uuid($0.id)) })
    }
}
