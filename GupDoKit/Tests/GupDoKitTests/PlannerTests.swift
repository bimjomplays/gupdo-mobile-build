import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class PlannerTests: XCTestCase {
    let home = Place(name: "Home", latitude: 1, longitude: 2, isHome: true)
    let gym = Place(name: "Gym", latitude: 3, longitude: 4)
    let today = day(2026, 11, 16)

    func data() -> GupDoData {
        var d = GupDoData()
        d.places = [home, gym]
        return d
    }

    func habit(_ name: String, place: UUID? = nil, start: TimeOfDay = TimeOfDay(7), end: TimeOfDay = TimeOfDay(8)) -> Habit {
        Habit(name: name, window: TimeWindow(start: start, end: end), placeID: place, startDay: today)
    }

    func plan(_ d: GupDoData, now: Date, presence: Set<UUID> = []) -> Plan {
        Planner.plan(d, now: now, presence: presence, calendar: cal)
    }

    // MARK: Reminders

    func testReminderTimeSensitiveThenAlarmsEvery5Minutes() {
        var d = data()
        let due = at(2026, 11, 16, 10)
        let r = Reminder(title: "Call", trigger: .time(due), createdAt: due - 3600)
        d.reminders = [r]
        let p = plan(d, now: due - 3600)
        XCTAssertEqual(p.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(p.alerts.first?.fireDate, due)
        XCTAssertEqual(p.alerts.first?.category, .reminder)
        XCTAssertEqual(p.alarms.map(\.fireDate), (1...12).map { due + minutes(Double($0) * 5) })
        XCTAssertTrue(p.alerts.allSatisfy { $0.itemIDs == [r.id] && $0.itemKind == .reminder })
        // While ringing only the future alarms remain.
        let ringing = plan(d, now: due + minutes(7))
        XCTAssertEqual(ringing.notifications.count, 0)
        XCTAssertEqual(ringing.alarms.first?.fireDate, due + minutes(10))
        XCTAssertEqual(ringing.alarms.count, 11)
        // Ids stay stable across replans.
        XCTAssertEqual(ringing.alarms.first?.id, p.alarms[1].id)
    }

    func testReminderWithoutAlarmAndAnsweredOnes() throws {
        var d = data()
        let due = at(2026, 11, 16, 10)
        let quiet = Reminder(title: "No alarm", trigger: .time(due), alarmIfIgnored: false, createdAt: due)
        var done = Reminder(title: "Done", trigger: .time(due), createdAt: due)
        done = try ReminderLogic.answer(.done, to: done, now: due - 60, calendar: cal)
        let far = Reminder(title: "Far", trigger: .time(at(2027, 6, 1)), createdAt: due)
        d.reminders = [quiet, done, far]
        let p = plan(d, now: due - 60)
        XCTAssertEqual(p.alerts.map(\.kind), [.timeSensitive])
        XCTAssertEqual(p.alerts.map(\.itemIDs), [[quiet.id]])
    }

    func testReminderAfterThirdLaterUsesFinalCategory() throws {
        var d = data()
        var r = Reminder(title: "Call", trigger: .time(at(2026, 11, 16, 10)), createdAt: at(2026, 11, 16, 9))
        var now = at(2026, 11, 16, 10)
        for _ in 0..<3 {
            r = try ReminderLogic.answer(.later(.fifteenMinutes), to: r, now: now, calendar: cal)
            now = r.due!
        }
        d.reminders = [r]
        XCTAssertTrue(plan(d, now: now - 60).alerts.allSatisfy { $0.category == .reminderFinal })
    }

    func testArrivalReminderWatchesRegion() {
        var d = data()
        let r = Reminder(title: "Package", trigger: .arrival(placeID: gym.id), createdAt: at(2026, 11, 16))
        d.reminders = [r]
        let p = plan(d, now: at(2026, 11, 16, 9))
        XCTAssertEqual(p.alerts, [])
        XCTAssertEqual(p.regions, [RegionWatch(place: gym, itemIDs: [r.id])])
        d.reminders = [ReminderLogic.arrived(r, placeID: gym.id, now: at(2026, 11, 16, 9))]
        let ringing = plan(d, now: at(2026, 11, 16, 9))
        XCTAssertEqual(ringing.regions, [])
        XCTAssertEqual(ringing.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(ringing.alerts.first?.fireDate, at(2026, 11, 16, 9) + 30)
        XCTAssertEqual(ringing.alarms.first?.fireDate, at(2026, 11, 16, 9, 5) + 30)
    }

    // MARK: Habits

    func testHabitRingsUntilWindowEnd() {
        var d = data()
        let h = habit("Stretch")
        d.habits = [h]
        let p = plan(d, now: at(2026, 11, 16, 6))
        let todays = p.alerts.filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertEqual(todays.first?.kind, .timeSensitive)
        XCTAssertEqual(todays.first?.fireDate, at(2026, 11, 16, 7))
        XCTAssertEqual(todays.filter { $0.kind == .alarm }.map(\.fireDate),
                       (1...11).map { at(2026, 11, 16, 7) + minutes(Double($0) * 5) })
        // Tomorrow is planned too.
        XCTAssertEqual(p.alerts.filter { $0.fireDate >= at(2026, 11, 17) }.first?.fireDate, at(2026, 11, 17, 7))
        XCTAssertTrue(p.alerts.allSatisfy { $0.category == .habit && $0.itemIDs == [h.id] })
    }

    func testProvedHabitStopsAndWindowOverIsSilent() {
        var d = data()
        let h = habit("Stretch")
        d.habits = [h]
        var log = d.history[h.id, today]
        log.provedAt = at(2026, 11, 16, 7, 2)
        d.history[h.id, today] = log
        let p = plan(d, now: at(2026, 11, 16, 7, 3))
        XCTAssertTrue(p.alerts.allSatisfy { $0.fireDate >= at(2026, 11, 17) })
        // Nothing carries over: after the window, nothing for today.
        d.history = HabitHistory()
        XCTAssertTrue(plan(d, now: at(2026, 11, 16, 8)).alerts.allSatisfy { $0.fireDate >= at(2026, 11, 17) })
    }

    func testSameWindowAndPlaceRingTogetherAsChecklist() {
        var d = data()
        let a = habit("Vitamins", place: home.id)
        let b = habit("Make bed", place: home.id)
        let c = habit("Gym habit", place: gym.id)
        let other = habit("Read", place: home.id, start: TimeOfDay(7), end: TimeOfDay(9))
        d.habits = [a, b, c, other]
        let now = at(2026, 11, 16, 6)
        let p = plan(d, now: now, presence: [home.id])
        let first = p.alerts.filter { $0.fireDate == at(2026, 11, 16, 7) }
        // One alert for the home 7-8 pair, one for the 7-9 habit; the gym habit is silent (not there).
        XCTAssertEqual(Set(first.map(\.itemIDs)), [[a.id, b.id], [other.id]])
        XCTAssertEqual(first.first { $0.itemIDs.count == 2 }?.title, "2 habits")
        XCTAssertEqual(first.first { $0.itemIDs.count == 2 }?.body, "Vitamins · Make bed")
        XCTAssertFalse(p.alerts.contains { $0.itemIDs.contains(c.id) })
        XCTAssertEqual(Set(p.regions.map(\.place.name)), ["Gym", "Home"])
        // One item proved: the group keeps ringing for the rest.
        var log = d.history[a.id, today]
        log.atPlaceAt = at(2026, 11, 16, 7)
        log.provedAt = at(2026, 11, 16, 7, 6)
        d.history[a.id, today] = log
        let after = plan(d, now: at(2026, 11, 16, 7, 6), presence: [home.id])
        XCTAssertTrue(after.alarms.filter { $0.fireDate < at(2026, 11, 16, 8) && $0.itemIDs.contains(b.id) }
            .allSatisfy { $0.itemIDs == [b.id] })
        XCTAssertFalse(after.alarms.contains { $0.fireDate < at(2026, 11, 17) && $0.itemIDs.contains(a.id) })
    }

    func testSnoozedHabitLeavesGroupAndComesBack15MinLater() {
        var d = data()
        let a = habit("A"), b = habit("B")
        d.habits = [a, b]
        var log = d.history[a.id, today]
        log.snoozedAt = at(2026, 11, 16, 7, 6)
        d.history[a.id, today] = log
        let p = plan(d, now: at(2026, 11, 16, 7, 6))
        let aAlerts = p.alerts.filter { $0.itemIDs.contains(a.id) && $0.fireDate < at(2026, 11, 17) }
        XCTAssertEqual(aAlerts.first?.kind, .timeSensitive)
        XCTAssertEqual(aAlerts.first?.fireDate, at(2026, 11, 16, 7, 21))
        XCTAssertTrue(aAlerts.allSatisfy { $0.itemIDs == [a.id] })
        XCTAssertEqual(p.alarms.first { $0.itemIDs == [b.id] }?.fireDate, at(2026, 11, 16, 7, 10))
    }

    func testArrivalDuringWindowFiresThreeMinutesLater() {
        var d = data()
        let h = habit("Gym", place: gym.id)
        d.habits = [h]
        d.history[h.id, today] = HabitLogic.arrived(h, log: d.history[h.id, today], at: at(2026, 11, 16, 7, 30),
                                                    calendar: cal)
        let p = plan(d, now: at(2026, 11, 16, 7, 30), presence: [gym.id])
        let todays = p.alerts.filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertEqual(todays.first?.kind, .timeSensitive)
        XCTAssertEqual(todays.first?.fireDate, at(2026, 11, 16, 7, 33))
        XCTAssertEqual(todays.last?.fireDate, at(2026, 11, 16, 7, 58))
    }

    func testPausedHabitIsSilentButWatched() throws {
        var d = data()
        let h = habit("Gym", place: gym.id)
        d.habits = [h]
        var log = HabitLogic.arrived(h, log: d.history[h.id, today], at: at(2026, 11, 16, 7), calendar: cal)
        log = try HabitLogic.answer(.cantRightNow(.away), habit: h, log: log, phase: .strict(daysLeft: 66),
                                    context: PhoneContext(), now: at(2026, 11, 16, 7, 10), calendar: cal)
        d.history[h.id, today] = log
        let p = plan(d, now: at(2026, 11, 16, 7, 10))
        XCTAssertFalse(p.alerts.contains { $0.fireDate < at(2026, 11, 17) })
        XCTAssertEqual(p.regions.map(\.place), [gym])
    }

    func testQuietHabitsHaveNoNotifications() {
        var d = data()
        let h = Habit(name: "Old habit", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)),
                      startDay: today.adding(days: -80, cal))
        d.habits = [h]
        for n in 1...80 {
            let dd = today.adding(days: -n, cal)
            var log = d.history[h.id, dd]
            log.provedAt = dd.at(TimeOfDay(7, 5), cal)
            d.history[h.id, dd] = log
        }
        XCTAssertEqual(plan(d, now: at(2026, 11, 16, 6)).alerts, [])
    }

    // MARK: Events

    func testEventHeadsUpsAndMainAlert() {
        var d = data()
        let e = Event(title: "Dentist", start: at(2026, 11, 20, 14), location: EventLocation(place: gym), travelMinutes: 10)
        d.events = [e]
        let p = plan(d, now: at(2026, 11, 16, 10))
        // Normal preset: 5 days (past), 3 days (11-17), 1 day (11-19), morning of (11-20) at 9.
        XCTAssertEqual(p.alerts.filter { $0.kind == .plain }.map(\.fireDate),
                       [at(2026, 11, 17, 9), at(2026, 11, 19, 9), at(2026, 11, 20, 9)])
        XCTAssertTrue(p.alerts.filter { $0.kind == .plain }.allSatisfy { $0.category == .headsUp })
        XCTAssertEqual(p.alerts.filter { $0.kind == .plain }.map(\.body), ["In 3 days", "Tomorrow at 14:00", "Today at 14:00"])
        let ts = p.alerts.filter { $0.kind == .timeSensitive }
        XCTAssertEqual(ts.map(\.fireDate), [at(2026, 11, 20, 13, 40)])
        // 10 min drive + 10 min buffer
        XCTAssertEqual(ts.first?.body, "Time to leave · 10 min drive to Gym")
        XCTAssertEqual(p.alarms.first?.fireDate, at(2026, 11, 20, 13, 45))
        XCTAssertEqual(p.alarms.count, 12)
        // Answered: no more main alert; heads-ups (plain, no escalation) stay.
        d.events = [EventLogic.answer(.gotItMainAlert, to: e, now: at(2026, 11, 16, 10))]
        XCTAssertEqual(plan(d, now: at(2026, 11, 16, 10)).alerts.map(\.kind), [.plain, .plain, .plain])
    }

    func testHeadsUpTextAndHorizon() {
        let e = Event(title: "Trip", start: at(2026, 12, 20, 8, 5), headsUps: .big)
        XCTAssertEqual(Planner.headsUpText(14, e: e, calendar: cal), "In 2 weeks")
        XCTAssertEqual(Planner.headsUpText(7, e: e, calendar: cal), "In 1 week")
        XCTAssertEqual(Planner.headsUpText(21, e: e, calendar: cal), "In 3 weeks")
        XCTAssertEqual(Planner.headsUpText(5, e: e, calendar: cal), "In 5 days")
        XCTAssertEqual(Planner.headsUpText(0, e: e, calendar: cal), "Today at 8:05")
        XCTAssertEqual(Planner.mainAlertText(Event(title: "x", start: e.start, mainAlert: .hourBefore)), "In 1 hour")
        XCTAssertEqual(Planner.mainAlertText(Event(title: "x", start: e.start, mainAlert: .thirtyMinutesBefore)), "In 30 minutes")
        XCTAssertEqual(Planner.mainAlertText(e), "Starting now")
        var d = data()
        d.events = [e]
        // 15-day horizon: on 11-16 nothing is in range yet (first heads-up 12-6); on 11-22 the 2-week one is.
        XCTAssertEqual(Planner.plan(d, now: at(2026, 11, 16), calendar: cal).alerts, [])
        XCTAssertEqual(Planner.plan(d, now: at(2026, 11, 22), calendar: cal).alerts.map(\.fireDate), [at(2026, 12, 6, 9)])
    }

    func testNotificationCapKeepsEarliestAndAllAlarms() {
        var d = data()
        d.settings.maxNotifications = 3
        d.reminders = (0..<10).map { Reminder(title: "R\($0)", trigger: .time(at(2026, 11, 17, 8 + $0)), createdAt: at(2026, 11, 16)) }
        let p = plan(d, now: at(2026, 11, 16, 12))
        XCTAssertEqual(p.notifications.map(\.title), ["R0", "R1", "R2"])
        XCTAssertEqual(p.alarms.count, 120)
        XCTAssertEqual(p.alerts, p.alerts.sorted { $0.fireDate < $1.fireDate })
    }
}
