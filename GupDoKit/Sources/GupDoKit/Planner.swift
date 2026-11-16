import Foundation

// The planner: from the saved data, the habit history, where the phone is and now, the full list of notifications
// and alarms that should be pending. The app clears what it scheduled before and schedules exactly this list
// (plain / timeSensitive -> UNUserNotificationCenter, alarm -> AlarmKit), and watches `regions` for arrivals. It
// replans on every answer, every launch and every background wake (arrival, driving change), so the list never
// needs to be longer than a cycle ahead.

enum AlertKind: String, Codable, Hashable {
    /// Normal notification (event heads-ups).
    case plain
    /// Time Sensitive notification: breaks through Focus.
    case timeSensitive
    /// AlarmKit alarm: alarm volume, silent mode and Focus included.
    case alarm
}

enum ItemKind: String, Codable, Hashable { case reminder, habit, event }

/// Which answer buttons the alert carries (the app maps each to a notification category / alarm intent set).
enum AlertCategory: String, Codable, Hashable {
    /// Done · Later.
    case reminder
    /// After the 3rd Later: Done · Pick a day · Delete.
    case reminderFinal
    /// Done + proof · 15 min · Can't right now (checked again when answered). A group alarm is a checklist.
    case habit
    /// Got it (no escalation).
    case headsUp
    /// Got it (stops the main alert's alarms).
    case eventMain
}

struct PlannedAlert: Codable, Hashable, Identifiable {
    /// Stable for the same alert across replans, so the app can diff if it wants to.
    var id: String
    var kind: AlertKind
    var fireDate: Date
    var itemKind: ItemKind
    var itemIDs: [UUID]
    var category: AlertCategory
    var title: String
    var body: String?
}

/// A place to watch for arrivals (arrival reminders, place habits).
struct RegionWatch: Codable, Hashable {
    var place: Place
    var itemIDs: [UUID]
}

struct Plan: Codable, Hashable {
    var alerts: [PlannedAlert] = []
    var regions: [RegionWatch] = []

    var notifications: [PlannedAlert] { alerts.filter { $0.kind != .alarm } }
    var alarms: [PlannedAlert] { alerts.filter { $0.kind == .alarm } }
}

enum Planner {
    static func plan(_ data: GupDoData, now: Date, presence: Set<UUID> = [], calendar: Calendar) -> Plan {
        let s = data.settings
        let horizon = now.addingTimeInterval(TimeInterval(s.planDays * 86_400))
        var alerts: [PlannedAlert] = []
        var watch: [UUID: [UUID]] = [:]

        // Reminders
        for r in data.reminders where r.status == .active {
            guard let due = r.due else {
                if let place = r.placeID { watch[place, default: []].append(r.id) }
                continue
            }
            guard due <= horizon else { continue }
            let category: AlertCategory = r.laterCount >= ReminderLogic.maxLaters ? .reminderFinal : .reminder
            alerts += cycle(idPrefix: "r-\(r.id.uuidString)-\(stamp(due))", start: due, until: nil,
                            alarms: r.alarmIfIgnored, now: now, settings: s, itemKind: .reminder, itemIDs: [r.id],
                            category: category, title: r.title, body: r.note)
        }

        // Habits: yesterday (an overnight window may still be open), today and tomorrow. Each habit-day has its own
        // window, so they never overlap.
        let today = DayKey(now, calendar)
        struct GroupKey: Hashable { var start: Date; var window: TimeWindow; var place: UUID? }
        for day in [today.adding(days: -1, calendar), today, today.adding(days: 1, calendar)] {
            var groups: [GroupKey: [Habit]] = [:]
            var order: [GroupKey] = []
            for h in data.habits where HabitLogic.isScheduled(h, on: day, calendar: calendar) {
                let log = data.history.log(h.id, day)
                guard log?.provedAt == nil,
                      HabitLogic.phase(h, on: day, history: data.history, now: now, calendar: calendar).notifies
                else { continue }
                let end = HabitLogic.windowEnd(h, on: day, calendar: calendar)
                guard end > now else { continue }
                if let place = h.placeID { watch[place, default: []].append(h.id) }
                let inside = h.placeID.map { presence.contains($0) } ?? false
                guard let start = HabitLogic.cycleStart(h, on: day, log: log, insideNow: inside, settings: s,
                                                        calendar: calendar), start < end else { continue }
                let key = GroupKey(start: start, window: h.window, place: h.placeID)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(h)
            }
            for key in order {
                let habits = groups[key] ?? []
                let end = HabitLogic.windowEnd(habits[0], on: day, calendar: calendar)
                let title = habits.count == 1 ? habits[0].name : "\(habits.count) habits"
                let body = habits.count == 1 ? nil : habits.map(\.name).joined(separator: " · ")
                let groupID = "h-\(day)-\(key.place?.uuidString ?? "any")-\(key.window.start.minutesSinceMidnight)-"
                    + "\(key.window.end.minutesSinceMidnight)-\(stamp(key.start))"
                alerts += cycle(idPrefix: groupID, start: key.start, until: end, alarms: true, now: now, settings: s,
                                itemKind: .habit, itemIDs: habits.map(\.id), category: .habit, title: title, body: body)
            }
        }

        // Events
        for e in data.events {
            let main = EventLogic.mainAlertDate(e, settings: s)
            for h in EventLogic.headsUps(e, settings: s, calendar: calendar) where h.date > now && h.date <= horizon {
                alerts.append(PlannedAlert(id: "e-\(e.id.uuidString)-hu\(h.daysBefore)", kind: .plain, fireDate: h.date,
                                           itemKind: .event, itemIDs: [e.id], category: .headsUp, title: e.title,
                                           body: headsUpText(h.daysBefore, e: e, calendar: calendar)))
            }
            guard e.mainAlertAnsweredAt == nil, main <= horizon else { continue }
            // the fire date is in the id: a new drive time (or start) moves the alarms instead of keeping the old ones
            alerts += cycle(idPrefix: "e-\(e.id.uuidString)-main-\(stamp(main))", start: main, until: nil, alarms: true, now: now,
                            settings: s, itemKind: .event, itemIDs: [e.id], category: .eventMain, title: e.title,
                            body: mainAlertText(e))
        }

        alerts.sort { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        // iOS keeps 64 pending notifications: keep the earliest ones (alarms aren't notifications).
        var kept = 0
        alerts = alerts.filter { a in
            guard a.kind != .alarm else { return true }
            kept += 1
            return kept <= s.maxNotifications
        }

        let places = Dictionary(data.places.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let regions = watch.compactMap { id, items in places[id].map { RegionWatch(place: $0, itemIDs: unique(items)) } }
            .sorted { $0.place.name < $1.place.name }
        return Plan(alerts: alerts, regions: regions)
    }

    /// One ringing cycle: Time Sensitive at `start`, then an alarm every few minutes (reminders and events: a fixed
    /// number; habits: until the window ends). Only what is still in the future.
    static func cycle(idPrefix: String, start: Date, until end: Date?, alarms: Bool, now: Date, settings s: Settings,
                      itemKind: ItemKind, itemIDs: [UUID], category: AlertCategory, title: String,
                      body: String?) -> [PlannedAlert] {
        var out: [PlannedAlert] = []
        func add(_ kind: AlertKind, _ date: Date, _ suffix: String) {
            out.append(PlannedAlert(id: "\(idPrefix)-\(suffix)", kind: kind, fireDate: date, itemKind: itemKind,
                                    itemIDs: itemIDs, category: category, title: title, body: body))
        }
        if start > now { add(.timeSensitive, start, "ts") }
        guard alarms else { return out }
        let step = TimeInterval(s.alarmEveryMinutes * 60)
        var k = 1
        while true {
            let date = start.addingTimeInterval(step * Double(k))
            if let end {
                if date >= end { break }
            } else if k > s.alarmRepeats {
                break
            }
            if date > now { add(.alarm, date, "a\(k)") }
            k += 1
        }
        return out
    }

    static func headsUpText(_ daysBefore: Int, e: Event, calendar: Calendar) -> String {
        let time = TimeOfDay(of: e.start, calendar)
        let clock = String(format: "%d:%02d", time.hour, time.minute)
        switch daysBefore {
        case 0: return "Today at \(clock)"
        case 1: return "Tomorrow at \(clock)"
        case 7: return "In 1 week"
        case 14: return "In 2 weeks"
        default: return daysBefore % 7 == 0 ? "In \(daysBefore / 7) weeks" : "In \(daysBefore) days"
        }
    }

    static func mainAlertText(_ e: Event) -> String {
        let place = e.location.map { " · \($0.name)" } ?? ""
        switch EventLogic.timing(e) {
        case .atStart: return "Starting now\(place)"
        case .thirtyMinutesBefore: return "In 30 minutes\(place)"
        case .hourBefore: return "In 1 hour\(place)"
        case .timeToLeave:
            guard let travel = e.travelMinutes else { return "In 1 hour\(place)" }
            return "Time to leave · \(Formats.duration(minutes: travel)) drive" + (e.location.map { " to \($0.name)" } ?? "")
        }
    }

    private static func stamp(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
