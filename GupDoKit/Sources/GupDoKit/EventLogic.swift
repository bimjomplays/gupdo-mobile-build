import Foundation

// Events: advance heads-ups (presets Big / Normal / Small / Custom, morning-of included) are plain notifications at
// the heads-up time (default 9am), answered Got it, never escalating. The main alert is Time Sensitive, then an
// alarm every 5 min until answered; at start, 30 min before, 1 hour before, or time to leave (default with a place).
// Adding an event that overlaps another warns right away.

struct HeadsUp: Hashable {
    /// 0 = morning of.
    var daysBefore: Int
    var date: Date
}

enum EventLogic {
    static func defaultTiming(for e: Event) -> MainAlertTiming { e.location != nil ? .timeToLeave : .atStart }

    static func timing(_ e: Event) -> MainAlertTiming { e.mainAlert ?? defaultTiming(for: e) }

    /// The main alert's fire date. Time to leave: the time TravelTime picked (the start minus the drive time and the
    /// buffer; 1 hour before while the drive time is unknown).
    static func mainAlertDate(_ e: Event, settings: Settings = Settings()) -> Date {
        let minutes: Int
        switch timing(e) {
        case .atStart: minutes = 0
        case .thirtyMinutesBefore: minutes = 30
        case .hourBefore: minutes = 60
        case .timeToLeave:
            return e.leaveAt ?? TravelTime.leaveTime(start: e.start, travelMinutes: e.travelMinutes,
                                                     checkedAt: e.travelCheckedAt, previous: nil, now: .distantPast,
                                                     settings: settings)
        }
        return e.start.addingTimeInterval(TimeInterval(-minutes * 60))
    }

    /// Is the main alert's time worked out from a real drive time (time to leave with a known travel time)?
    static func usesDriveTime(_ e: Event) -> Bool { timing(e) == .timeToLeave && e.travelMinutes != nil }

    /// The advance heads-ups, earliest first. One that would come at or after the main alert is dropped.
    static func headsUps(_ e: Event, settings: Settings = Settings(), calendar: Calendar) -> [HeadsUp] {
        let eventDay = DayKey(e.start, calendar)
        let main = mainAlertDate(e, settings: settings)
        var days = Set(e.headsUps.daysBefore.filter { $0 > 0 })
        if e.headsUps.morningOf { days.insert(0) }
        return days.sorted(by: >).compactMap { n in
            let date = eventDay.adding(days: -n, calendar).at(settings.headsUpTime, calendar)
            return date < main ? HeadsUp(daysBefore: n, date: date) : nil
        }
    }

    static func answer(_ answer: EventAnswer, to e: Event, now: Date) -> Event {
        var e = e
        switch answer {
        case .gotItHeadsUp: e.headsUpAcknowledgedAt = now
        case .gotItMainAlert: e.mainAlertAnsweredAt = now
        }
        return e
    }

    /// Is the main alert ringing (fired and unanswered)?
    static func isRinging(_ e: Event, now: Date, settings: Settings = Settings()) -> Bool {
        e.mainAlertAnsweredAt == nil && mainAlertDate(e, settings: settings) <= now
    }

    /// Events `e` overlaps. An event without an end counts as an instant at its start.
    static func clashes(for e: Event, among others: [Event]) -> [Event] {
        others.filter { $0.id != e.id && overlaps(e, $0) }.sorted { $0.start < $1.start }
    }

    static func overlaps(_ a: Event, _ b: Event) -> Bool {
        let aEnd = max(a.end ?? a.start, a.start), bEnd = max(b.end ?? b.start, b.start)
        if a.start == b.start { return true }
        if a.start < bEnd && b.start < aEnd { return true }
        // An instant inside the other's span.
        return (a.start == aEnd && b.start <= a.start && a.start < bEnd)
            || (b.start == bEnd && a.start <= b.start && b.start < aEnd)
    }

    /// Events from now on (ongoing ones included), sorted by start: the Upcoming list.
    static func upcoming(_ events: [Event], now: Date) -> [Event] {
        events.filter { max($0.end ?? $0.start, $0.start) >= now }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }
}
