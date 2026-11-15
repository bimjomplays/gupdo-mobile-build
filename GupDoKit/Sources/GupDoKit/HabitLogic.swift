import Foundation

// Habits: fire at window start (Anywhere, or already at the place) or a few minutes after arriving at the place
// during the window; Time Sensitive notification, then an alarm every 5 min until proved or the window ends.
// Answers: Done + proof, 15 min (once per habit per day), Can't right now (only while driving, or away from the
// habit's place; a pause, not a pass: it fires again on arrival or when driving stops). End of window: done ->
// counts; never at the place (or still away after Can't right now) -> excused; otherwise missed. Nothing carries
// over. Life: Strict until 66 done days (+2 per miss), then Quiet (no notifications, a Today checkbox); 2 misses in
// any 7-day span while Quiet -> Strict again for 14 days, then Quiet.

enum HabitOutcome: String, Codable, Hashable {
    /// The window is still open (or hasn't started) and it isn't done yet.
    case pending
    case done
    case excused
    case missed
}

enum HabitPhase: Codable, Hashable {
    case strict(daysLeft: Int)
    /// Strict again after 2 Quiet misses, through `until` (inclusive).
    case restrict(until: DayKey, daysLeft: Int)
    case quiet

    var notifies: Bool {
        if case .quiet = self { return false }
        return true
    }
}

struct HabitState: Codable, Hashable {
    var phase: HabitPhase
    var doneDays: Int
    var misses: Int
}

enum HabitChoice: String, Codable, Hashable {
    case done, fifteenMinutes, cantRightNow, check
}

/// What the phone knows about him when he answers.
struct PhoneContext: Codable, Hashable {
    var isDriving = false
    /// Places the phone is inside right now.
    var insidePlaces: Set<UUID> = []
}

enum HabitError: Error, Equatable {
    case answerNotAllowed
    case proofRejected
    case notScheduledToday
}

enum HabitLogic {
    static let lockInDays = 66
    static let daysPerMiss = 2
    static let restrictDays = 14
    static let quietMissLimit = 2
    static let quietMissSpanDays = 7

    // MARK: Days and windows

    static func isScheduled(_ h: Habit, on day: DayKey, calendar: Calendar) -> Bool {
        day >= h.startDay && h.days.contains(day, calendar)
    }

    static func windowStart(_ h: Habit, on day: DayKey, calendar: Calendar) -> Date { day.at(h.window.start, calendar) }
    /// A window whose end is at or before its start (10pm-1am) ends the next day; it still belongs to the start day.
    static func windowCrossesMidnight(_ w: TimeWindow) -> Bool { w.end <= w.start }

    static func windowEnd(_ h: Habit, on day: DayKey, calendar: Calendar) -> Date {
        let endDay = windowCrossesMidnight(h.window) ? day.adding(days: 1, calendar) : day
        return endDay.at(h.window.end, calendar)
    }

    /// The habit-day that answers and the Today strip refer to now: yesterday while last night's overnight window is
    /// still open, else today.
    static func openDay(_ h: Habit, now: Date, calendar: Calendar) -> DayKey {
        let today = DayKey(now, calendar)
        let yesterday = today.adding(days: -1, calendar)
        if windowCrossesMidnight(h.window), isScheduled(h, on: yesterday, calendar: calendar),
           now < windowEnd(h, on: yesterday, calendar: calendar) {
            return yesterday
        }
        return today
    }

    // MARK: Outcome

    static func outcome(_ h: Habit, on day: DayKey, log: HabitDayLog?, now: Date, calendar: Calendar) -> HabitOutcome? {
        guard isScheduled(h, on: day, calendar: calendar) else { return nil }
        if log?.provedAt != nil { return .done }
        if now < windowEnd(h, on: day, calendar: calendar) { return .pending }
        if let last = log?.pauses.last, last.end == nil { return .excused }
        if h.placeID != nil && log?.atPlaceAt == nil { return .excused }
        return .missed
    }

    // MARK: Lifecycle

    /// The habit's state after every final day up to and including `through` (a pending day is skipped).
    static func state(_ h: Habit, history: HabitHistory, through: DayKey, now: Date, calendar: Calendar) -> HabitState {
        var done = 0, misses = 0
        var strictMisses = 0, strictDone = 0
        var phase = HabitPhase.strict(daysLeft: lockInDays)
        var quietMisses: [DayKey] = []
        var day = h.startDay
        while day <= through {
            let result = outcome(h, on: day, log: history.log(h.id, day), now: now, calendar: calendar)
            if result == .done { done += 1 }
            if result == .missed { misses += 1 }
            switch phase {
            case .strict:
                if result == .done { strictDone += 1 }
                if result == .missed { strictMisses += 1 }
                let left = lockInDays + daysPerMiss * strictMisses - strictDone
                phase = left <= 0 ? .quiet : .strict(daysLeft: left)
            case .quiet:
                if result == .missed {
                    quietMisses.append(day)
                    quietMisses = quietMisses.filter { $0.days(until: day, calendar) < quietMissSpanDays }
                    if quietMisses.count >= quietMissLimit {
                        phase = .restrict(until: day.adding(days: restrictDays, calendar), daysLeft: restrictDays)
                        quietMisses = []
                    }
                }
            case .restrict(let until, _):
                if day >= until {
                    phase = .quiet
                } else {
                    phase = .restrict(until: until, daysLeft: day.days(until: until, calendar))
                }
            }
            day = day.adding(days: 1, calendar)
        }
        return HabitState(phase: phase, doneDays: done, misses: misses)
    }

    /// The phase that rules `day` (decided by the days before it).
    static func phase(_ h: Habit, on day: DayKey, history: HabitHistory, now: Date, calendar: Calendar) -> HabitPhase {
        state(h, history: history, through: day.adding(days: -1, calendar), now: now, calendar: calendar).phase
    }

    // MARK: Progress

    /// "5 of 7 this week": done days of the scheduled, not excused days in the week containing `today`.
    static func weekProgress(_ h: Habit, history: HabitHistory, today: DayKey, now: Date,
                             calendar: Calendar) -> (done: Int, of: Int) {
        let todayStart = today.start(calendar)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: todayStart)?.start ?? todayStart
        var day = DayKey(weekStart, calendar)
        var done = 0, of = 0
        for _ in 0..<7 {
            if let result = outcome(h, on: day, log: history.log(h.id, day), now: now, calendar: calendar),
               result != .excused {
                of += 1
                if result == .done { done += 1 }
            }
            day = day.adding(days: 1, calendar)
        }
        return (done, of)
    }

    /// Marked important today when the previous scheduled day was a miss.
    static func isImportantToday(_ h: Habit, history: HabitHistory, today: DayKey, now: Date, calendar: Calendar) -> Bool {
        guard isScheduled(h, on: today, calendar: calendar) else { return false }
        var day = today.adding(days: -1, calendar)
        for _ in 0..<7 {
            guard day >= h.startDay else { return false }
            if isScheduled(h, on: day, calendar: calendar) {
                return outcome(h, on: day, log: history.log(h.id, day), now: now, calendar: calendar) == .missed
            }
            day = day.adding(days: -1, calendar)
        }
        return false
    }

    // MARK: Answers

    /// The answers offered right now (Strict/re-Strict habits; Quiet ones only have the Today checkbox).
    static func choices(_ h: Habit, log: HabitDayLog, phase: HabitPhase, context: PhoneContext) -> [HabitChoice] {
        guard phase.notifies else { return [.check] }
        var out: [HabitChoice] = [.done]
        if log.snoozedAt == nil { out.append(.fifteenMinutes) }
        if pauseReason(h, context: context) != nil { out.append(.cantRightNow) }
        return out
    }

    /// Why Can't right now is allowed now, if it is: driving, or (place habits) away from the place.
    static func pauseReason(_ h: Habit, context: PhoneContext) -> PauseReason? {
        if context.isDriving { return .driving }
        if let place = h.placeID, !context.insidePlaces.contains(place) { return .away }
        return nil
    }

    static func accepts(_ evidence: ProofEvidence, for h: Habit) -> Bool {
        switch (h.proof, evidence) {
        case (.photo, .photo(let matches, let live)): return matches && live
        case (.location, .location(let place)): return h.placeID != nil && place == h.placeID
        case (.nfc, .nfc(let tag)): return h.nfcTagID != nil && tag == h.nfcTagID
        default: return false
        }
    }

    static func answer(_ answer: HabitAnswer, habit h: Habit, log: HabitDayLog, phase: HabitPhase,
                       context: PhoneContext, now: Date, calendar: Calendar) throws -> HabitDayLog {
        guard isScheduled(h, on: log.day, calendar: calendar) else { throw HabitError.notScheduledToday }
        var log = log
        switch answer {
        case .done(let evidence):
            guard phase.notifies else { throw HabitError.answerNotAllowed }
            guard accepts(evidence, for: h) else { throw HabitError.proofRejected }
            log.provedAt = now
        case .check:
            guard !phase.notifies else { throw HabitError.answerNotAllowed }
            log.provedAt = now
        case .fifteenMinutes:
            guard phase.notifies, log.snoozedAt == nil else { throw HabitError.answerNotAllowed }
            log.snoozedAt = now
        case .cantRightNow(let reason):
            // The stated reason must hold right now.
            let holds: Bool
            switch reason {
            case .driving: holds = context.isDriving
            case .away: holds = h.placeID.map { !context.insidePlaces.contains($0) } ?? false
            }
            guard phase.notifies, holds else { throw HabitError.answerNotAllowed }
            if let last = log.pauses.last, last.end == nil { return log }
            log.pauses.append(HabitPause(reason: reason, start: now))
        }
        return log
    }

    /// The phone saw him at the habit's place (arrival, or inside at window start). Only the first time inside the
    /// window counts; an open "away" pause ends here.
    static func arrived(_ h: Habit, log: HabitDayLog, at time: Date, calendar: Calendar) -> HabitDayLog {
        var log = log
        let start = windowStart(h, on: log.day, calendar: calendar)
        let end = windowEnd(h, on: log.day, calendar: calendar)
        guard h.placeID != nil, time < end else { return log }
        if log.atPlaceAt == nil { log.atPlaceAt = max(time, start) }
        if let i = log.pauses.indices.last, log.pauses[i].end == nil, log.pauses[i].reason == .away, time >= start {
            log.pauses[i].end = time
        }
        return log
    }

    /// Driving stopped: an open "driving" pause ends.
    static func stoppedDriving(log: HabitDayLog, at time: Date) -> HabitDayLog {
        var log = log
        if let i = log.pauses.indices.last, log.pauses[i].end == nil, log.pauses[i].reason == .driving {
            log.pauses[i].end = time
        }
        return log
    }

    // MARK: Firing

    /// When the current ringing cycle starts today (nil = silent: not firing, paused, done, or a place habit he
    /// hasn't been at). `insideNow` = the phone is at the habit's place now (used before an arrival is logged).
    static func cycleStart(_ h: Habit, on day: DayKey, log: HabitDayLog?, insideNow: Bool, settings: Settings,
                           calendar: Calendar) -> Date? {
        let log = log ?? HabitDayLog(habitID: h.id, day: day)
        guard isScheduled(h, on: day, calendar: calendar), log.provedAt == nil else { return nil }
        let start = windowStart(h, on: day, calendar: calendar)
        let base: Date
        if h.placeID == nil {
            base = start
        } else if let at = log.atPlaceAt {
            base = at <= start ? start : at.addingTimeInterval(TimeInterval(settings.arrivalDelayMinutes * 60))
        } else if insideNow {
            base = start
        } else {
            return nil
        }
        // The latest answer decides: a snooze restarts 15 min later, a pause is silent until it ends.
        let snooze = log.snoozedAt
        let pause = log.pauses.last
        if let pause, pause.start >= (snooze ?? .distantPast) {
            guard let end = pause.end else { return nil }
            let delay = pause.reason == .away ? settings.arrivalDelayMinutes : 0
            return max(base, end.addingTimeInterval(TimeInterval(delay * 60)))
        }
        if let snooze { return max(base, snooze.addingTimeInterval(TimeInterval(settings.habitSnoozeMinutes * 60))) }
        return base
    }
}
