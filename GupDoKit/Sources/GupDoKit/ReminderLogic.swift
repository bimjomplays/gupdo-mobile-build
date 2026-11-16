import Foundation

// Reminders: a Time Sensitive notification at the time, an alarm after 5 min unanswered, repeating every 5 min
// until answered. Answers: Done, Later (15 min / 1 hour / Tonight / Tomorrow / Pick a time). After the 3rd Later
// the only answers are Done, Pick a day, Delete. Repeats schedule the next occurrence on Done.

enum ReminderChoice: String, Codable, Hashable {
    case done, later, pickDay, delete
}

enum ReminderLaterChoice: String, Codable, Hashable {
    case fifteenMinutes, oneHour, tonight, tomorrow, pickTime
}

enum ReminderError: Error, Equatable {
    case answerNotAllowed
    case notActive
    case dateInPast
}

enum ReminderLogic {
    static let maxLaters = 3

    /// The answers shown on the notification, the alarm and the Now card.
    static func choices(for r: Reminder) -> [ReminderChoice] {
        r.laterCount >= maxLaters ? [.done, .pickDay, .delete] : [.done, .later]
    }

    /// The Later options offered right now. Tonight is left out once it is within 15 minutes of the Tonight time.
    static func laterChoices(now: Date, settings: Settings = Settings(), calendar: Calendar) -> [ReminderLaterChoice] {
        let tonight = settings.tonightTime.on(now, calendar)
        var out: [ReminderLaterChoice] = [.fifteenMinutes, .oneHour]
        if tonight.timeIntervalSince(now) >= 15 * 60 { out.append(.tonight) }
        out += [.tomorrow, .pickTime]
        return out
    }

    /// Is it ringing (due and unanswered)?
    static func isRinging(_ r: Reminder, now: Date) -> Bool {
        guard r.status == .active, let due = r.due else { return false }
        return due <= now
    }

    /// An arrival reminder rings this long after the arrival is seen: its Time Sensitive notification has to be
    /// scheduled in the future to be delivered, and the replan right after the arrival takes a moment.
    static let arrivalRingSeconds: TimeInterval = 30

    /// The phone arrived at a place (at `arrival`, seen `now`): arrival reminders for it start their normal cycle
    /// (Time Sensitive notification, then alarms) right away. Arrivals before the reminder was armed don't count.
    static func arrived(_ r: Reminder, placeID: UUID, at arrival: Date? = nil, now: Date) -> Reminder {
        var r = r
        guard r.status == .active, r.placeID == placeID, r.due == nil else { return r }
        if let armed = r.armedFrom, (arrival ?? now) < armed { return r }
        r.due = max(arrival ?? now, now).addingTimeInterval(arrivalRingSeconds)
        return r
    }

    /// Applies an answer. Returns the updated reminder (status .deleted for Delete).
    static func answer(_ answer: ReminderAnswer, to r: Reminder, now: Date, settings: Settings = Settings(),
                       calendar: Calendar) throws -> Reminder {
        guard r.status == .active else { throw ReminderError.notActive }
        var r = r
        switch answer {
        case .done:
            if r.repeatRule == .never {
                r.status = .done
                r.due = nil
            } else {
                r.laterCount = 0
                switch r.trigger {
                case .time:
                    let next = nextOccurrence(of: r.repeatRule, anchor: r.occurrence,
                                              after: max(now, r.occurrence), calendar: calendar)
                    r.occurrence = next
                    r.due = next
                case .arrival:
                    // Waits for the next arrival on the next day the rule allows.
                    let anchor = calendar.startOfDay(for: r.occurrence)
                    let next = nextOccurrence(of: r.repeatRule, anchor: anchor,
                                              after: calendar.startOfDay(for: now), calendar: calendar)
                    r.occurrence = next
                    r.armedFrom = next
                    r.due = nil
                }
            }
        case .later(let option):
            guard r.laterCount < maxLaters else { throw ReminderError.answerNotAllowed }
            let target: Date
            switch option {
            case .fifteenMinutes: target = now.addingTimeInterval(15 * 60)
            case .oneHour: target = now.addingTimeInterval(60 * 60)
            case .tonight:
                guard laterChoices(now: now, settings: settings, calendar: calendar).contains(.tonight) else {
                    throw ReminderError.answerNotAllowed
                }
                target = settings.tonightTime.on(now, calendar)
            case .tomorrow:
                let tomorrow = DayKey(now, calendar).adding(days: 1, calendar)
                target = tomorrow.at(clockTime(of: r, now: now, calendar: calendar), calendar)
            case .pick(let date):
                guard date > now else { throw ReminderError.dateInPast }
                target = date
            }
            r.due = target
            r.laterCount += 1
        case .pickDay(let day):
            guard r.laterCount >= maxLaters else { throw ReminderError.answerNotAllowed }
            let target = DayKey(day, calendar).at(clockTime(of: r, now: now, calendar: calendar), calendar)
            guard target > now else { throw ReminderError.dateInPast }
            r.due = target
            r.laterCount = 0
        case .delete:
            guard r.laterCount >= maxLaters else { throw ReminderError.answerNotAllowed }
            r.status = .deleted
            r.due = nil
        }
        return r
    }

    /// The clock time Tomorrow and Pick a day keep: the occurrence's for timed reminders, now's for arrival ones.
    private static func clockTime(of r: Reminder, now: Date, calendar: Calendar) -> TimeOfDay {
        if case .time = r.trigger { return TimeOfDay(of: r.occurrence, calendar) }
        return TimeOfDay(of: now, calendar)
    }

    /// The first occurrence of `rule` strictly after `after`, keeping the anchor's clock time.
    static func nextOccurrence(of rule: RepeatRule, anchor: Date, after: Date, calendar: Calendar) -> Date {
        let time = TimeOfDay(of: anchor, calendar)
        let anchorDay = DayKey(anchor, calendar)
        let afterDay = DayKey(after, calendar)
        switch rule {
        case .never:
            return anchor
        case .daily, .weekly:
            let step = rule == .daily ? 1 : 7
            let gap = max(0, anchorDay.days(until: afterDay, calendar))
            var n = gap / step
            while true {
                let date = anchorDay.adding(days: n * step, calendar).at(time, calendar)
                if date > after { return date }
                n += 1
            }
        case .monthly:
            var n = 0
            while true {
                // Adding months to the anchor (not chaining) keeps the 31st as the 31st where it exists.
                let date = calendar.date(byAdding: .month, value: n, to: anchor) ?? anchor
                if date > after { return date }
                n += 1
            }
        case .days(let weekdays):
            guard !weekdays.isEmpty else { return anchor }
            var day = max(anchorDay, afterDay)
            for _ in 0..<15 {
                let date = day.at(time, calendar)
                if weekdays.contains(day.weekday(calendar)), date > after, date >= anchor { return date }
                day = day.adding(days: 1, calendar)
            }
            return anchor
        }
    }
}
