import Foundation

// Time to leave for events with a Where. The app asks MapKit for the drive time from where the phone is (an ETA) and
// hands it here; these rules pick the alarm time from it and say when to ask again. Waking the app at a set time
// isn't possible on iOS (background refresh may come late or never), so the alarm is scheduled as soon as the event
// is saved, with the best drive time known then, and only refined when the app runs anyway (launch, coming to the
// front, a background refresh, region monitoring, any answer).

enum TravelTime {
    /// A drive time that says "you should have left already" rings this long after it came in.
    static let leaveNowSeconds: TimeInterval = 60

    /// The time-to-leave alarm time.
    /// - The start minus the drive time and the buffer; never before the drive time was known (then it rings a
    ///   minute after it came in, so the alarm isn't silently in the past) and never after the start.
    /// - Unknown drive time: what was picked before, else 1 hour before (the spec).
    /// - A fresh drive time (younger than `freshTravelMinutes`) may move the alarm either way; an older one only
    ///   earlier than `previous`.
    /// - Once `previous` has come (it rang), it stays.
    static func leaveTime(start: Date, travelMinutes: Int?, checkedAt: Date?, previous: Date?, now: Date,
                          settings: Settings = Settings()) -> Date {
        if let previous, previous <= now { return previous }
        guard let travel = travelMinutes else {
            return previous ?? start.addingTimeInterval(TimeInterval(-settings.fallbackLeadMinutes * 60))
        }
        var candidate = start.addingTimeInterval(TimeInterval(-(travel + settings.leaveBufferMinutes) * 60))
        if let checkedAt { candidate = max(candidate, min(checkedAt.addingTimeInterval(leaveNowSeconds), start)) }
        guard let previous else { return candidate }
        let fresh = checkedAt.map { now.timeIntervalSince($0) < TimeInterval(settings.freshTravelMinutes * 60) } ?? false
        return fresh ? candidate : min(previous, candidate)
    }

    /// A drive time came in (`minutes`, nil = MapKit couldn't work one out): keeps it and picks the alarm time again.
    /// `restart`: the event was just saved (new start, Where or alert), so nothing picked before counts.
    static func update(_ e: Event, minutes: Int?, now: Date, restart: Bool = false, settings: Settings = Settings())
        -> Event {
        var e = e
        if restart { e.leaveAt = nil }
        let previous = restart ? nil : EventLogic.mainAlertDate(e, settings: settings)
        if let minutes {
            e.travelMinutes = max(0, minutes)
            e.travelCheckedAt = now
        } else if restart {
            e.travelMinutes = nil
            e.travelCheckedAt = nil
        }
        guard EventLogic.timing(e) == .timeToLeave, e.location != nil else {
            e.leaveAt = nil
            return e
        }
        e.leaveAt = leaveTime(start: e.start, travelMinutes: e.travelMinutes, checkedAt: e.travelCheckedAt,
                              previous: previous, now: now, settings: settings)
        return e
    }

    /// MapKit's travel time in seconds -> whole minutes, rounded up.
    static func minutes(fromSeconds seconds: Double) -> Int { max(0, Int((seconds / 60).rounded(.up))) }

    /// Does the event take a drive time at all (time to leave, a Where, its alarm still to come)?
    static func wantsTravel(_ e: Event, now: Date, settings: Settings = Settings()) -> Bool {
        e.location != nil && EventLogic.timing(e) == .timeToLeave && e.mainAlertAnsweredAt == nil && e.start > now
            && EventLogic.mainAlertDate(e, settings: settings) > now
    }

    /// How old a drive time may be: a quarter of the time left until the alarm, between 10 minutes and 12 hours (a
    /// week ahead: twice a day; 2 hours ahead: every 30 min; the last 40 min: every 10 min).
    static func maxAge(untilAlert: TimeInterval) -> TimeInterval {
        min(max(untilAlert / 4, 10 * 60), 12 * 3600)
    }

    /// Should the app ask MapKit for this event's drive time now?
    static func needsCheck(_ e: Event, now: Date, settings: Settings = Settings()) -> Bool {
        guard wantsTravel(e, now: now, settings: settings) else { return false }
        guard let checked = e.travelCheckedAt else { return true }
        let untilAlert = EventLogic.mainAlertDate(e, settings: settings).timeIntervalSince(now)
        return now.timeIntervalSince(checked) >= maxAge(untilAlert: untilAlert)
    }

    /// The events whose drive time to ask for now, soonest first.
    static func due(_ data: GupDoData, now: Date) -> [Event] {
        data.events.filter { needsCheck($0, now: now, settings: data.settings) }.sorted { $0.start < $1.start }
    }

    /// Asking before the alarm: 2 hours, 45 and 15 minutes before it. The earliest still to come (or now, if one is
    /// due), for the background refresh request. Not guaranteed to run: it only refines an alarm already scheduled.
    static func nextCheck(_ data: GupDoData, now: Date) -> Date? {
        var best: Date?
        for e in data.events where wantsTravel(e, now: now, settings: data.settings) {
            if needsCheck(e, now: now, settings: data.settings) { return now }
            let alert = EventLogic.mainAlertDate(e, settings: data.settings)
            for before in [120.0, 45, 15] {
                let at = alert.addingTimeInterval(-before * 60)
                if at > now, best.map({ at < $0 }) ?? true { best = at }
            }
        }
        return best
    }

    /// When the drive should start, for MapKit's traffic estimate: the alarm time as it stands, or now.
    static func departure(_ e: Event, now: Date, settings: Settings = Settings()) -> Date {
        max(now, EventLogic.mainAlertDate(e, settings: settings))
    }

    /// A saved place was edited: events that picked it get its new name and point (a moved point drops the drive
    /// time, which is asked for again).
    static func placeChanged(_ p: Place, data: GupDoData) -> GupDoData {
        var data = data
        for i in data.events.indices where data.events[i].location?.placeID == p.id {
            guard let old = data.events[i].location else { continue }
            var loc = EventLocation(place: p)
            loc.address = old.address
            data.events[i].location = loc
            if old.latitude != p.latitude || old.longitude != p.longitude {
                data.events[i].travelCheckedAt = nil
            }
        }
        return data
    }
}
