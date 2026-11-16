import Foundation

// What a new item starts with (spec: creating one takes seconds, everything else defaults) and the short date texts
// the screens show.

struct QuickTime: Hashable {
    var label: String
    var date: Date
}

enum Defaults {
    /// A new reminder's time: an hour from now, on the next 5 minutes.
    static func reminderTime(now: Date, calendar: Calendar) -> Date {
        roundUp(now.addingTimeInterval(3600), toMinutes: 5, calendar: calendar)
    }

    /// The one-tap times of the quick add: In 1 hour, Tonight (until 15 min before it), Tomorrow morning.
    static func quickTimes(now: Date, settings: Settings = Settings(), calendar: Calendar) -> [QuickTime] {
        var out = [QuickTime(label: "In 1 hour", date: reminderTime(now: now, calendar: calendar))]
        let tonight = settings.tonightTime.on(now, calendar)
        if tonight.timeIntervalSince(now) >= 15 * 60 {
            out.append(QuickTime(label: "Tonight", date: tonight))
        }
        let tomorrow = DayKey(now, calendar).adding(days: 1, calendar)
        out.append(QuickTime(label: "Tomorrow", date: tomorrow.at(settings.headsUpTime, calendar)))
        return out
    }

    /// Later -> Pick a time / Pick a day start here: the same clock time tomorrow.
    static func pickStart(for r: Reminder, now: Date, calendar: Calendar) -> Date {
        let time = TimeOfDay(of: r.occurrence, calendar)
        return DayKey(now, calendar).adding(days: 1, calendar).at(time, calendar)
    }

    /// A new habit: every day, a one-hour window from the next full hour, Anywhere, photo proof.
    static func habit(now: Date, calendar: Calendar) -> Habit {
        let start = roundUp(now, toMinutes: 60, calendar: calendar)
        let s = TimeOfDay(of: start, calendar)
        return Habit(name: "", days: .everyDay, window: TimeWindow(start: s, end: TimeOfDay((s.hour + 1) % 24, s.minute)),
                     placeID: nil, proof: .photo, startDay: DayKey(now, calendar))
    }

    /// A new event: tomorrow at the next full hour's clock time, no end, Normal heads-ups, default main alert.
    static func event(now: Date, calendar: Calendar) -> Event {
        let time = TimeOfDay(of: roundUp(now, toMinutes: 60, calendar: calendar), calendar)
        let start = DayKey(now, calendar).adding(days: 1, calendar).at(time, calendar)
        return Event(title: "", start: start)
    }

    static func roundUp(_ date: Date, toMinutes step: Int, calendar: Calendar) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let m = TimeOfDay(of: date, calendar).minutesSinceMidnight
        let over = (m % step == 0 && minuteStart == date) ? 0 : step - m % step
        return minuteStart.addingTimeInterval(TimeInterval(over * 60))
    }
}

enum Formats {
    /// "3:00 PM" (today), "Tomorrow 3:00 PM", "Sat 3:00 PM" (this coming week), "Nov 28, 3:00 PM".
    static func when(_ date: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let clock = time(date, calendar: calendar, locale: locale)
        let days = DayKey(now, calendar).days(until: DayKey(date, calendar), calendar)
        switch days {
        case 0: return clock
        case 1: return "Tomorrow \(clock)"
        case -1: return "Yesterday \(clock)"
        case 2...6: return "\(format("EEE", date, calendar, locale)) \(clock)"
        default: return "\(format("MMM d", date, calendar, locale)), \(clock)"
        }
    }

    static func time(_ date: Date, calendar: Calendar, locale: Locale = .current) -> String {
        // ICU puts a narrow no-break space before AM/PM; a plain space reads the same and compares simply
        format(DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: locale) ?? "h:mm a", date, calendar, locale)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func time(_ t: TimeOfDay, calendar: Calendar, locale: Locale = .current) -> String {
        time(t.on(Date(timeIntervalSince1970: 86_400 * 3), calendar), calendar: calendar, locale: locale)
    }

    /// "Today", "Tomorrow", "In 6 days", "In 3 weeks".
    static func dayDistance(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = DayKey(now, calendar).days(until: DayKey(date, calendar), calendar)
        switch days {
        case ..<0: return "Now"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...13: return "In \(days) days"
        default: return "In \(days / 7) weeks"
        }
    }

    /// The habit's window, "7:00 AM – 8:00 AM".
    static func window(_ w: TimeWindow, calendar: Calendar, locale: Locale = .current) -> String {
        "\(time(w.start, calendar: calendar, locale: locale)) – \(time(w.end, calendar: calendar, locale: locale))"
    }

    /// "Every day", "Weekdays", "Mon, Wed, Fri".
    static func days(_ set: DaySet, calendar: Calendar) -> String {
        switch set {
        case .everyDay: return "Every day"
        case .weekdays(let days):
            if days == [2, 3, 4, 5, 6] { return "Weekdays" }
            if days == [1, 7] { return "Weekends" }
            if days.count == 7 { return "Every day" }
            let names = calendar.shortWeekdaySymbols
            let order = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            return order.filter(days.contains).map { names[$0 - 1] }.joined(separator: ", ")
        }
    }

    static func repeatRule(_ r: RepeatRule, calendar: Calendar) -> String {
        switch r {
        case .never: return "Never"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .days(let set): return days(.weekdays(set), calendar: calendar)
        }
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
