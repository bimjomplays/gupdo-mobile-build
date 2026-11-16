import Foundation

// Where the phone has been: the app's region monitoring reports entering and leaving saved places, and they are kept
// as visits. Visits decide everything place-based: which places the phone is inside now (the planner's presence,
// "Can't right now" when away), and for place habits whether he was at the place during the window (arrival fires the
// habit a few minutes later; never there = excused). Settling from visits rather than only from live events means a
// phone that sat at home all day still counts as "there" at window start, even if the app never ran in the window.

/// A stay at a saved place. `left == nil`: still there.
struct PlaceVisit: Codable, Hashable {
    var placeID: UUID
    var arrived: Date
    var left: Date?
}

enum Presence {
    /// Visits that ended longer ago than this are dropped (only today's and yesterday's windows still need them).
    static let keepDays = 3

    /// Places the phone is inside now.
    static func inside(_ data: GupDoData) -> Set<UUID> {
        Set(data.visits.filter { $0.left == nil }.map(\.placeID))
    }

    /// Region monitoring says the phone is inside `placeID` (since `time`, seen `now`). A new arrival also starts
    /// the arrival reminders waiting for that place. Nothing changes if already inside.
    static func entered(_ placeID: UUID, at time: Date, now: Date? = nil, data: GupDoData,
                        calendar: Calendar) -> GupDoData {
        var data = data
        if !data.visits.contains(where: { $0.placeID == placeID && $0.left == nil }) {
            data.visits.append(PlaceVisit(placeID: placeID, arrived: time))
            for i in data.reminders.indices {
                data.reminders[i] = ReminderLogic.arrived(data.reminders[i], placeID: placeID, at: time,
                                                          now: max(now ?? time, time))
            }
        }
        return settle(data, now: max(now ?? time, time), calendar: calendar)
    }

    /// Region monitoring says the phone is outside `placeID` (since `time`).
    static func left(_ placeID: UUID, at time: Date, data: GupDoData, calendar: Calendar) -> GupDoData {
        var data = data
        for i in data.visits.indices where data.visits[i].placeID == placeID && data.visits[i].left == nil {
            data.visits[i].left = max(time, data.visits[i].arrived)
        }
        return settle(data, now: time, calendar: calendar)
    }

    /// A place was deleted or moved: its visits no longer mean anything.
    static func forget(_ placeID: UUID, data: GupDoData) -> GupDoData {
        var data = data
        data.visits.removeAll { $0.placeID == placeID }
        return data
    }

    /// Writes what the visits say into the place habits' day logs (the first moment at the place inside each open or
    /// just-closed window, and the end of an "away" pause), and drops old visits. Safe to run any number of times.
    static func settle(_ data: GupDoData, now: Date, calendar: Calendar) -> GupDoData {
        var data = data
        let today = DayKey(now, calendar)
        for h in data.habits {
            guard let place = h.placeID else { continue }
            let visits = data.visits.filter { $0.placeID == place }.sorted { $0.arrived < $1.arrived }
            guard !visits.isEmpty else { continue }
            for day in [today.adding(days: -2, calendar), today.adding(days: -1, calendar), today]
            where HabitLogic.isScheduled(h, on: day, calendar: calendar) {
                let start = HabitLogic.windowStart(h, on: day, calendar: calendar)
                let end = HabitLogic.windowEnd(h, on: day, calendar: calendar)
                let before = data.history[h.id, day]
                guard before.provedAt == nil else { continue }
                var log = before
                for v in visits where v.arrived < end && (v.left ?? .distantFuture) > start {
                    let at = max(v.arrived, start)
                    guard at <= now else { continue }
                    log = HabitLogic.arrived(h, log: log, at: at, calendar: calendar)
                }
                if log != before { data.history[h.id, day] = log }
            }
        }
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86_400)
        data.visits.removeAll { ($0.left ?? .distantFuture) < cutoff }
        return data
    }

    /// The phone context for answers: inside places from the visits, driving from the phone.
    static func context(_ data: GupDoData, isDriving: Bool) -> PhoneContext {
        PhoneContext(isDriving: isDriving, insidePlaces: inside(data))
    }
}

/// Driving pauses that should end: Core Motion (or the location) says driving stopped.
enum DrivingPauses {
    /// Habit days with an open driving pause (the app watches for the end of driving while any exist).
    static func open(_ data: GupDoData, now: Date, calendar: Calendar) -> [(habit: Habit, day: DayKey, since: Date)] {
        data.habits.compactMap { h in
            let day = HabitLogic.openDay(h, now: now, calendar: calendar)
            guard let log = data.history.log(h.id, day), log.provedAt == nil, let p = log.pauses.last,
                  p.end == nil, p.reason == .driving, now < HabitLogic.windowEnd(h, on: day, calendar: calendar)
            else { return nil }
            return (h, day, p.start)
        }
    }

    /// Ends every open driving pause whose end the samples show.
    static func end(_ data: GupDoData, samples: [MotionSample], stationarySince: Date? = nil, now: Date,
                    calendar: Calendar) -> GupDoData {
        var data = data
        for (h, day, since) in open(data, now: now, calendar: calendar) {
            var stop = Driving.stoppedAt(samples: samples, since: since, now: now)
            if stop == nil, let still = stationarySince, now.timeIntervalSince(still) >= Driving.stopMinutes * 60 {
                stop = max(still, since)
            }
            guard stop != nil else { continue }
            // It rings again from when this was noticed (a minute later), not from when driving stopped: a ringing
            // cycle that started in the past would skip its first notification.
            data.history[h.id, day] = HabitLogic.stoppedDriving(log: data.history[h.id, day], at: now)
        }
        return data
    }
}

/// Which saved places region monitoring watches. iOS allows 20 conditions per app; one is left spare. First the
/// places something waits on (habits with a window today or tomorrow, arrival reminders not yet arrived), soonest
/// first; then places of events in the next 48 hours, soonest first; then the rest (Home first, then by name). The app
/// picks again on every run (launch, front, wake, answer), so a place comes back into the watch when it's needed.
enum PlaceWatch {
    static let limit = 19

    static func pick(_ data: GupDoData, now: Date, calendar: Calendar, limit: Int = PlaceWatch.limit) -> [Place] {
        var need: [UUID: (tier: Int, at: Date)] = [:]
        func want(_ id: UUID?, _ tier: Int, _ at: Date) {
            guard let id else { return }
            if let have = need[id], (have.tier, have.at) <= (tier, at) { return }
            need[id] = (tier, at)
        }
        for r in data.reminders where r.status == .active && r.due == nil { want(r.placeID, 0, now) }
        let today = DayKey(now, calendar)
        for h in data.habits {
            for d in [today.adding(days: -1, calendar), today, today.adding(days: 1, calendar)]
            where HabitLogic.isScheduled(h, on: d, calendar: calendar)
                && HabitLogic.windowEnd(h, on: d, calendar: calendar) > now {
                want(h.placeID, 0, max(now, HabitLogic.windowStart(h, on: d, calendar: calendar)))
            }
        }
        for e in data.events where e.start > now && e.start <= now.addingTimeInterval(48 * 3600) {
            want(e.location?.placeID, 1, e.start)
        }
        func key(_ p: Place) -> (Int, Date, Int, String) {
            let n = need[p.id]
            return (n?.tier ?? 2, n?.at ?? .distantFuture, p.isHome ? 0 : 1, p.name)
        }
        return Array(data.places.sorted { key($0) < key($1) }.prefix(max(0, limit)))
    }
}

/// What still uses a saved place (it can't be deleted while something does): habits and waiting arrival reminders.
/// Events keep their own copy of the place, so they don't count.
enum PlaceUse {
    static func users(_ placeID: UUID, data: GupDoData) -> [String] {
        data.habits.filter { $0.placeID == placeID }.map(\.name)
            + data.reminders.filter { $0.status == .active && $0.placeID == placeID }.map(\.title)
    }
}
