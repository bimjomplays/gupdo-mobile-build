import Foundation

// Small value types every rule uses. Time is always passed in (`now`) together with a Calendar that carries the
// time zone, so every rule is a pure function a test can drive with fixed dates.

/// Where "now" comes from (not named Clock: that would shadow Swift's Clock protocol). The app uses `.system`;
/// tests pass `.fixed(date)`.
struct AppClock: Sendable {
    var now: @Sendable () -> Date
    static let system = AppClock { Date() }
    static func fixed(_ date: Date) -> AppClock { AppClock { date } }
}

/// A clock time without a date (window start/end, heads-up time, "Tonight").
struct TimeOfDay: Codable, Hashable, Comparable {
    var hour: Int
    var minute: Int

    init(_ hour: Int, _ minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    init(of date: Date, _ calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(c.hour ?? 0, c.minute ?? 0)
    }

    var minutesSinceMidnight: Int { hour * 60 + minute }

    /// This clock time on the calendar day of `day` (DST gaps move forward, as Foundation does).
    func on(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minutesSinceMidnight * 60))
    }

    static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutesSinceMidnight < b.minutesSinceMidnight }
}

/// A calendar day (no time zone inside: it is read and turned back into dates with the injected Calendar).
struct DayKey: Codable, Hashable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, _ calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 0, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Midnight at the start of this day.
    func start(_ calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)).map { calendar.startOfDay(for: $0) }
            ?? Date(timeIntervalSince1970: 0)
    }

    func at(_ time: TimeOfDay, _ calendar: Calendar) -> Date { time.on(start(calendar), calendar) }

    func adding(days: Int, _ calendar: Calendar) -> DayKey {
        // Noon avoids DST edges when stepping days.
        let noon = calendar.date(byAdding: .hour, value: 12, to: start(calendar)) ?? start(calendar)
        return DayKey(calendar.date(byAdding: .day, value: days, to: noon) ?? noon, calendar)
    }

    func days(until other: DayKey, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: start(calendar), to: other.start(calendar)).day ?? 0
    }

    /// 1 = Sunday ... 7 = Saturday (Calendar's numbering).
    func weekday(_ calendar: Calendar) -> Int { calendar.component(.weekday, from: start(calendar)) }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (a: DayKey, b: DayKey) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// Which days a habit is on. Weekdays use Calendar's numbering: 1 = Sunday ... 7 = Saturday.
enum DaySet: Codable, Hashable {
    case everyDay
    case weekdays(Set<Int>)

    func contains(_ day: DayKey, _ calendar: Calendar) -> Bool {
        switch self {
        case .everyDay: return true
        case .weekdays(let set): return set.contains(day.weekday(calendar))
        }
    }
}

/// Settings the rules read. All have the spec's defaults.
struct Settings: Codable, Hashable {
    /// When advance heads-ups and the morning-of heads-up arrive (spec: configurable, default 9am).
    var headsUpTime = TimeOfDay(9, 0)
    /// "Later -> Tonight".
    var tonightTime = TimeOfDay(20, 0)
    /// Minutes between an unanswered Time Sensitive notification and the first alarm, and between alarms.
    var alarmEveryMinutes = 5
    /// How many alarms one ringing cycle of a reminder or event schedules ahead (the app replans on every answer,
    /// launch and background wake, so this only matters if the phone is ignored for an hour).
    var alarmRepeats = 12
    /// "A few minutes after walking in": delay between arriving at a habit's place and it firing.
    var arrivalDelayMinutes = 3
    /// Habit "15 min" snooze length.
    var habitSnoozeMinutes = 15
    /// Event main alert when time-to-leave is chosen but no travel time is known yet.
    var fallbackLeadMinutes = 60
    /// How far ahead the planner looks for reminders and events (habits: today and tomorrow).
    var planDays = 15
    /// iOS keeps at most 64 pending local notifications; the planner keeps the earliest this many.
    var maxNotifications = 60
}
