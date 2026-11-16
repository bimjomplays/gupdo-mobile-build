import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class TodayTests: XCTestCase {
    let today = day(2026, 11, 16)

    func testNowCardPrefersRingingThenNextToday() throws {
        var d = GupDoData()
        let h = Habit(name: "Stretch", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), startDay: today)
        let r = Reminder(title: "Call", trigger: .time(at(2026, 11, 16, 10)), createdAt: at(2026, 11, 16))
        let e = Event(title: "Lunch", start: at(2026, 11, 16, 12))
        let tomorrow = Event(title: "Tomorrow", start: at(2026, 11, 17, 12))
        d.habits = [h]
        d.reminders = [r]
        d.events = [e, tomorrow]
        func now(_ date: Date) -> NowCard? { TodayLogic.nowCard(d, now: date, calendar: cal) }
        XCTAssertEqual(now(at(2026, 11, 16, 6))?.title, "Stretch")
        XCTAssertEqual(now(at(2026, 11, 16, 6))?.ringing, false)
        XCTAssertEqual(now(at(2026, 11, 16, 7, 5))?.ringing, true)
        XCTAssertEqual(now(at(2026, 11, 16, 7, 5))?.itemKind, .habit)
        XCTAssertEqual(now(at(2026, 11, 16, 8, 30))?.title, "Call")
        // Unanswered reminder (10:00) outranks the event that starts ringing at 12.
        XCTAssertEqual(now(at(2026, 11, 16, 12, 1))?.title, "Call")
        d.reminders = [try ReminderLogic.answer(.done, to: r, now: at(2026, 11, 16, 10), calendar: cal)]
        XCTAssertEqual(now(at(2026, 11, 16, 11))?.title, "Lunch")
        XCTAssertEqual(now(at(2026, 11, 16, 12, 1))?.ringing, true)
        d.events = [EventLogic.answer(.gotItMainAlert, to: e, now: at(2026, 11, 16, 12, 2)), tomorrow]
        XCTAssertNil(now(at(2026, 11, 16, 12, 3)))
    }

    func testGroupedHabitsShowAsOneCard() {
        var d = GupDoData()
        let w = TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8))
        d.habits = [Habit(name: "A", window: w, startDay: today), Habit(name: "B", window: w, startDay: today)]
        let card = TodayLogic.nowCard(d, now: at(2026, 11, 16, 7, 1), calendar: cal)
        XCTAssertEqual(card?.itemIDs.count, 2)
        XCTAssertEqual(card?.title, "2 habits")
    }

    func testTodaySummary() {
        var d = GupDoData()
        let late = Habit(name: "Late", window: TimeWindow(start: TimeOfDay(21), end: TimeOfDay(22)), startDay: today)
        let early = Habit(name: "Early", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)),
                          startDay: today.adding(days: -1, cal))
        let notToday = Habit(name: "Tue", days: .weekdays([3]), window: early.window, startDay: today)
        d.habits = [late, early, notToday]
        let r1 = Reminder(title: "Today", trigger: .time(at(2026, 11, 16, 15)), createdAt: at(2026, 11, 16))
        let r2 = Reminder(title: "Tomorrow", trigger: .time(at(2026, 11, 17, 15)), createdAt: at(2026, 11, 16))
        let overdue = Reminder(title: "Overdue", trigger: .time(at(2026, 11, 15, 15)), createdAt: at(2026, 11, 15))
        d.reminders = [r1, r2, overdue]
        d.events = [Event(title: "Lunch", start: at(2026, 11, 16, 12)), Event(title: "Later", start: at(2026, 11, 18, 12))]
        let s = TodayLogic.today(d, now: at(2026, 11, 16, 9), calendar: cal)
        XCTAssertEqual(s.habits.map(\.habit.name), ["Early", "Late"])
        XCTAssertEqual(s.habits.map(\.outcome), [.missed, .pending])
        XCTAssertTrue(s.habits[0].important)  // yesterday missed
        XCTAssertEqual(s.habits[0].week, 0)
        XCTAssertEqual(s.habits[0].weekOf, 7)
        XCTAssertFalse(s.habits[0].isCheckbox)
        XCTAssertEqual(s.habits[0].phase, .strict(daysLeft: 68))
        XCTAssertEqual(s.reminders.map(\.title), ["Overdue", "Today"])
        XCTAssertEqual(s.events.map(\.title), ["Lunch"])
    }
}

final class StoreTests: XCTestCase {
    func testRoundTripKeepsEverything() throws {
        let now = at(2026, 11, 16, 9)
        var d = Samples.data(now: now, calendar: cal)
        let h = d.habits[0]
        var log = d.history[h.id, DayKey(now, cal)]
        log.snoozedAt = now
        log.atPlaceAt = now
        log.pauses = [HabitPause(reason: .driving, start: now, end: now + 60)]
        d.history[h.id, DayKey(now, cal)] = log
        d.reminders.append(Reminder(title: "Arrive", trigger: .arrival(placeID: d.places[0].id), repeatRule: .days([2, 4]),
                                    createdAt: now))
        d.events.append(Event(title: "Custom", start: now + 86_400, headsUps: .custom(daysBefore: [2], morningOf: false),
                              mainAlert: .hourBefore, travelMinutes: 12))
        d.settings.headsUpTime = TimeOfDay(8, 15)
        let back = try GupDoData.decode(d.encoded())
        XCTAssertEqual(back, d)
        XCTAssertEqual(back.version, GupDoData.currentVersion)
        XCTAssertEqual(back.home?.id, d.places[0].id)
    }

    func testSamplesArePlaceholdersAndValid() {
        let d = Samples.data(now: at(2026, 11, 16, 9), calendar: cal)
        let names = d.habits.map(\.name) + d.reminders.map(\.title) + d.events.map(\.title) + d.places.map(\.name)
        XCTAssertTrue(names.allSatisfy { $0.lowercased().contains("example") })
        XCTAssertTrue(d.habits.allSatisfy { Setup.problems($0, places: d.places).isEmpty })
        XCTAssertTrue(d.reminders.allSatisfy { Setup.problems($0, places: d.places).isEmpty })
        XCTAssertTrue(d.events.allSatisfy { Setup.problems($0, places: d.places).isEmpty })
    }

    func testSetupProblems() {
        let day = DayKey(year: 2026, month: 11, day: 16)
        var h = Habit(name: " ", days: .weekdays([]), window: TimeWindow(start: TimeOfDay(8), end: TimeOfDay(7)),
                      placeID: UUID(), proof: .nfc, startDay: day)
        XCTAssertEqual(Setup.problems(h, places: []), [.emptyName, .noDaysPicked, .unknownPlace,
                                                        .nfcProofNeedsTag])
        h = Habit(name: "x", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), proof: .location, startDay: day)
        XCTAssertEqual(Setup.problems(h, places: []), [.locationProofNeedsPlace])
        h.proof = .photo
        XCTAssertEqual(Setup.problems(h, places: []), [.photoProofNeedsReference])
        let r = Reminder(title: "", trigger: .arrival(placeID: UUID()), repeatRule: .days([]))
        XCTAssertEqual(Setup.problems(r, places: []), [.emptyName, .noDaysPicked, .unknownPlace])
        // an event keeps its own copy of the place: a deleted saved place is no problem
        let e = Event(title: "", start: at(2026, 11, 16, 10), end: at(2026, 11, 16, 9),
                      location: EventLocation(name: "Gone", latitude: 1, longitude: 2, placeID: UUID()))
        XCTAssertEqual(Setup.problems(e, places: []), [.emptyName, .endBeforeStart])
    }

    func testHistoryRemoveAll() {
        var hist = HabitHistory()
        let a = UUID(), b = UUID()
        let day = DayKey(year: 2026, month: 11, day: 16)
        hist[a, day] = HabitDayLog(habitID: a, day: day)
        hist[b, day] = HabitDayLog(habitID: b, day: day)
        hist.removeAll(for: a)
        XCTAssertNil(hist.log(a, day))
        XCTAssertNotNil(hist.log(b, day))
    }
}
