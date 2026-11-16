import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

// Windows whose end is at or before their start end the next day (a 10pm-1am bedtime habit). The habit-day belongs
// to the start day.
final class OvernightHabitTests: XCTestCase {
    let start = day(2026, 11, 16)  // Monday
    let s = Settings()

    func bedtime(days: DaySet = .everyDay, place: UUID? = nil, startDay: DayKey? = nil) -> Habit {
        Habit(name: "Bedtime", days: days, window: TimeWindow(start: TimeOfDay(22), end: TimeOfDay(1)), placeID: place,
              startDay: startDay ?? start)
    }

    func testWindowEndsNextDay() {
        let h = bedtime()
        XCTAssertEqual(HabitLogic.windowStart(h, on: start, calendar: cal), at(2026, 11, 16, 22))
        XCTAssertEqual(HabitLogic.windowEnd(h, on: start, calendar: cal), at(2026, 11, 17, 1))
        XCTAssertTrue(HabitLogic.windowCrossesMidnight(h.window))
        let full = Habit(name: "x", window: TimeWindow(start: TimeOfDay(6), end: TimeOfDay(6)), startDay: start)
        XCTAssertEqual(HabitLogic.windowEnd(full, on: start, calendar: cal), at(2026, 11, 17, 6))
    }

    func testOutcomeAcrossMidnight() {
        let h = bedtime()
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: nil, now: at(2026, 11, 16, 23), calendar: cal), .pending)
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: nil, now: at(2026, 11, 17, 0, 30), calendar: cal), .pending)
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: nil, now: at(2026, 11, 17, 1), calendar: cal), .missed)
        var log = HabitDayLog(habitID: h.id, day: start)
        log.provedAt = at(2026, 11, 17, 0, 40)
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: log, now: at(2026, 11, 17, 2), calendar: cal), .done)
        // The next day's window is independent.
        XCTAssertEqual(HabitLogic.outcome(h, on: start.adding(days: 1, cal), log: nil, now: at(2026, 11, 17, 2),
                                          calendar: cal), .pending)
    }

    func testScheduledDayIsTheStartDay() {
        // Monday-only: the Monday 22:00 - Tuesday 01:00 window counts; nothing starts Tuesday night.
        let h = bedtime(days: .weekdays([2]))
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: nil, now: at(2026, 11, 17, 0, 30), calendar: cal), .pending)
        XCTAssertNil(HabitLogic.outcome(h, on: start.adding(days: 1, cal), log: nil, now: at(2026, 11, 17, 23),
                                        calendar: cal))
        XCTAssertEqual(HabitLogic.openDay(h, now: at(2026, 11, 17, 0, 30), calendar: cal), start)
        XCTAssertEqual(HabitLogic.openDay(h, now: at(2026, 11, 17, 1, 30), calendar: cal), start.adding(days: 1, cal))
    }

    func testArrivalAfterMidnightCounts() {
        let gym = UUID()
        let h = bedtime(place: gym)
        let log = HabitLogic.arrived(h, log: HabitDayLog(habitID: h.id, day: start), at: at(2026, 11, 17, 0, 20),
                                     calendar: cal)
        XCTAssertEqual(log.atPlaceAt, at(2026, 11, 17, 0, 20))
        XCTAssertEqual(HabitLogic.cycleStart(h, on: start, log: log, insideNow: true, settings: s, calendar: cal),
                       at(2026, 11, 17, 0, 23))
        XCTAssertNil(HabitLogic.arrived(h, log: HabitDayLog(habitID: h.id, day: start), at: at(2026, 11, 17, 1, 5),
                                        calendar: cal).atPlaceAt)
    }

    func testPlannerRingsAtHalfPastMidnightWithoutDoubles() {
        var d = GupDoData()
        let h = bedtime()
        d.habits = [h]
        let now = at(2026, 11, 17, 0, 30)
        let p = Planner.plan(d, now: now, calendar: cal)
        // Monday's window is still ringing: alarms 00:35 ... 00:55, nothing at or after 01:00 for it.
        let tonight = p.alerts.filter { $0.fireDate < at(2026, 11, 17, 12) }
        XCTAssertEqual(tonight.map(\.fireDate), [35, 40, 45, 50, 55].map { at(2026, 11, 17, 0, $0) })
        XCTAssertTrue(tonight.allSatisfy { $0.kind == .alarm })
        // Tuesday's window starts at 22:00 Tuesday, then Wednesday's; every alert id is unique.
        let later = p.alerts.filter { $0.fireDate >= at(2026, 11, 17, 12) }
        XCTAssertEqual(later.filter { $0.kind == .timeSensitive }.map(\.fireDate),
                       [at(2026, 11, 17, 22), at(2026, 11, 18, 22)])
        XCTAssertEqual(Set(p.alerts.map(\.id)).count, p.alerts.count)
        XCTAssertEqual(Set(p.alerts.map(\.fireDate)).count, p.alerts.count)
        // After 01:00 Monday's window is over: nothing for it.
        let after = Planner.plan(d, now: at(2026, 11, 17, 1), calendar: cal)
        XCTAssertEqual(after.alerts.first?.fireDate, at(2026, 11, 17, 22))
    }

    func testPlannerAt2300IncludesThroughOneAM() {
        var d = GupDoData()
        d.habits = [bedtime()]
        let p = Planner.plan(d, now: at(2026, 11, 16, 23), calendar: cal)
        let first = p.alerts.filter { $0.fireDate < at(2026, 11, 17, 12) }
        XCTAssertEqual(first.first?.fireDate, at(2026, 11, 16, 23, 5))
        XCTAssertEqual(first.last?.fireDate, at(2026, 11, 17, 0, 55))
        XCTAssertEqual(first.count, 23)
    }

    func testTodayShowsLastNightsOpenWindow() {
        var d = GupDoData()
        let h = bedtime()
        d.habits = [h]
        let now = at(2026, 11, 17, 0, 30)
        let card = TodayLogic.nowCard(d, now: now, calendar: cal)
        XCTAssertEqual(card?.itemIDs, [h.id])
        XCTAssertEqual(card?.ringing, true)
        let summary = TodayLogic.today(d, now: now, calendar: cal)
        XCTAssertEqual(summary.habits.map(\.outcome), [.pending])
        XCTAssertEqual(summary.habits.first?.day, start)
        // Answering at 00:40 goes to Monday's log.
        var log = d.history[h.id, HabitLogic.openDay(h, now: now, calendar: cal)]
        log = try! HabitLogic.answer(.done(.photo(matchesReference: true, fromLiveCamera: true)),
                                     habit: Habit(name: h.name, window: h.window, referencePhoto: "r", startDay: start),
                                     log: log, phase: .strict(daysLeft: 66), context: PhoneContext(), now: now,
                                     calendar: cal)
        XCTAssertEqual(log.day, start)
    }

    func testLifecycleCountsOvernightDays() {
        let h = bedtime()
        var hist = HabitHistory()
        for n in 0..<66 {
            let dd = start.adding(days: n, cal)
            var log = hist[h.id, dd]
            log.provedAt = dd.adding(days: 1, cal).at(TimeOfDay(0, 30), cal)  // proved after midnight
            hist[h.id, dd] = log
        }
        let st = HabitLogic.state(h, history: hist, through: start.adding(days: 65, cal), now: at(2028, 1, 1), calendar: cal)
        XCTAssertEqual(st.phase, .quiet)
    }

    func testDSTNights() {
        // Fall back: 2026-11-01 01:00 happens twice; the window still ends after it starts, about 3-4 hours later.
        let fall = bedtime(startDay: day(2026, 10, 31))
        let fs = HabitLogic.windowStart(fall, on: day(2026, 10, 31), calendar: cal)
        let fe = HabitLogic.windowEnd(fall, on: day(2026, 10, 31), calendar: cal)
        XCTAssertTrue([3.0, 4.0].contains(fe.timeIntervalSince(fs) / 3600))
        XCTAssertEqual(HabitLogic.outcome(fall, on: day(2026, 10, 31), log: nil, now: at(2026, 11, 1, 0, 30),
                                          calendar: cal), .pending)
        // Spring forward: 2027-03-14 02:30 doesn't exist; a 22:00-02:30 window ends at or after 03:00 and still
        // rings at 01:30.
        let spring = Habit(name: "Late", window: TimeWindow(start: TimeOfDay(22), end: TimeOfDay(2, 30)),
                           startDay: day(2027, 3, 13))
        let se = HabitLogic.windowEnd(spring, on: day(2027, 3, 13), calendar: cal)
        XCTAssertGreaterThanOrEqual(se, at(2027, 3, 14, 3))
        XCTAssertLessThanOrEqual(se, at(2027, 3, 14, 4))
        var d = GupDoData()
        d.habits = [spring]
        let p = Planner.plan(d, now: at(2027, 3, 14, 1, 30), calendar: cal)
        XCTAssertEqual(p.alerts.first?.fireDate, at(2027, 3, 14, 1, 35))
        XCTAssertTrue(p.alerts.filter { $0.fireDate < at(2027, 3, 14, 12) }.allSatisfy { $0.fireDate < se })
    }

    func testSetupAcceptsOvernightWindows() {
        let h = Habit(name: "Bedtime", window: TimeWindow(start: TimeOfDay(22), end: TimeOfDay(1)), proof: .nfc,
                      nfcTagID: "t", startDay: start)
        XCTAssertEqual(Setup.problems(h, places: []), [])
    }
}
