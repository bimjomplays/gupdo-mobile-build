import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class ReminderTests: XCTestCase {
    let t = at(2026, 11, 16, 10)  // Monday 10:00

    func reminder(_ rule: RepeatRule = .never, alarm: Bool = true) -> Reminder {
        Reminder(title: "Call the bank", trigger: .time(t), repeatRule: rule, alarmIfIgnored: alarm, createdAt: t - 3600)
    }

    func answer(_ a: ReminderAnswer, _ r: Reminder, now: Date) throws -> Reminder {
        try ReminderLogic.answer(a, to: r, now: now, calendar: cal)
    }

    func testDefaults() {
        let r = reminder()
        XCTAssertEqual(r.repeatRule, .never)
        XCTAssertTrue(r.alarmIfIgnored)
        XCTAssertEqual(r.due, t)
        XCTAssertEqual(r.status, .active)
    }

    func testRingingOnlyOnceDue() {
        let r = reminder()
        XCTAssertFalse(ReminderLogic.isRinging(r, now: t - 1))
        XCTAssertTrue(ReminderLogic.isRinging(r, now: t))
        XCTAssertTrue(ReminderLogic.isRinging(r, now: t + minutes(40)))
    }

    func testDoneFinishesOneOff() throws {
        let r = try answer(.done, reminder(), now: t + 60)
        XCTAssertEqual(r.status, .done)
        XCTAssertNil(r.due)
        XCTAssertFalse(ReminderLogic.isRinging(r, now: t + 120))
        XCTAssertThrowsError(try answer(.done, r, now: t + 120)) { XCTAssertEqual($0 as? ReminderError, .notActive) }
    }

    func testLaterOptionsStartOver() throws {
        let now = t + minutes(2)
        XCTAssertEqual(try answer(.later(.fifteenMinutes), reminder(), now: now).due, now + minutes(15))
        XCTAssertEqual(try answer(.later(.oneHour), reminder(), now: now).due, now + minutes(60))
        XCTAssertEqual(try answer(.later(.tonight), reminder(), now: now).due, at(2026, 11, 16, 20))
        XCTAssertEqual(try answer(.later(.tomorrow), reminder(), now: now).due, at(2026, 11, 17, 10))
        XCTAssertEqual(try answer(.later(.pick(at(2026, 11, 18, 7))), reminder(), now: now).due, at(2026, 11, 18, 7))
        let later = try answer(.later(.oneHour), reminder(), now: now)
        XCTAssertEqual(later.laterCount, 1)
        XCTAssertFalse(ReminderLogic.isRinging(later, now: now + minutes(30)))
        XCTAssertThrowsError(try answer(.later(.pick(now - 60)), reminder(), now: now)) {
            XCTAssertEqual($0 as? ReminderError, .dateInPast)
        }
    }

    func testTonightNotOfferedLateInTheDay() throws {
        XCTAssertEqual(ReminderLogic.laterChoices(now: at(2026, 11, 16, 19, 44), calendar: cal),
                       [.fifteenMinutes, .oneHour, .tonight, .tomorrow, .pickTime])
        XCTAssertEqual(ReminderLogic.laterChoices(now: at(2026, 11, 16, 19, 50), calendar: cal),
                       [.fifteenMinutes, .oneHour, .tomorrow, .pickTime])
        XCTAssertThrowsError(try answer(.later(.tonight), reminder(), now: at(2026, 11, 16, 21))) {
            XCTAssertEqual($0 as? ReminderError, .answerNotAllowed)
        }
        var s = Settings()
        s.tonightTime = TimeOfDay(22)
        let r = try ReminderLogic.answer(.later(.tonight), to: reminder(), now: at(2026, 11, 16, 21), settings: s,
                                         calendar: cal)
        XCTAssertEqual(r.due, at(2026, 11, 16, 22))
    }

    func testAfterThirdLaterOnlyDonePickDayDelete() throws {
        var r = reminder()
        XCTAssertEqual(ReminderLogic.choices(for: r), [.done, .later])
        XCTAssertThrowsError(try answer(.delete, r, now: t)) { XCTAssertEqual($0 as? ReminderError, .answerNotAllowed) }
        XCTAssertThrowsError(try answer(.pickDay(at(2026, 11, 20)), r, now: t))
        var now = t
        for _ in 0..<3 {
            r = try answer(.later(.fifteenMinutes), r, now: now)
            now = r.due!
        }
        XCTAssertEqual(r.laterCount, 3)
        XCTAssertEqual(ReminderLogic.choices(for: r), [.done, .pickDay, .delete])
        XCTAssertThrowsError(try answer(.later(.oneHour), r, now: now)) {
            XCTAssertEqual($0 as? ReminderError, .answerNotAllowed)
        }
        // Pick a day keeps the clock time and starts the Laters over.
        let picked = try answer(.pickDay(at(2026, 11, 20, 15)), r, now: now)
        XCTAssertEqual(picked.due, at(2026, 11, 20, 10))
        XCTAssertEqual(picked.laterCount, 0)
        XCTAssertThrowsError(try answer(.pickDay(at(2026, 11, 16)), r, now: now)) {
            XCTAssertEqual($0 as? ReminderError, .dateInPast)
        }
        let deleted = try answer(.delete, r, now: now)
        XCTAssertEqual(deleted.status, .deleted)
        XCTAssertEqual(try answer(.done, r, now: now).status, .done)
    }

    func testRepeatsScheduleNextOccurrence() throws {
        // Daily: done late keeps the original clock time.
        let daily = try answer(.done, reminder(.daily), now: t + minutes(30))
        XCTAssertEqual(daily.status, .active)
        XCTAssertEqual(daily.due, at(2026, 11, 17, 10))
        XCTAssertEqual(daily.occurrence, at(2026, 11, 17, 10))
        // Done the next day after it slept: the next one after now.
        XCTAssertEqual(try answer(.done, reminder(.daily), now: at(2026, 11, 17, 11)).due, at(2026, 11, 18, 10))
        XCTAssertEqual(try answer(.done, reminder(.weekly), now: t).due, at(2026, 11, 23, 10))
        XCTAssertEqual(try answer(.done, reminder(.monthly), now: t).due, at(2026, 12, 16, 10))
        // Pick days Mon/Wed/Fri.
        XCTAssertEqual(try answer(.done, reminder(.days([2, 4, 6])), now: t).due, at(2026, 11, 18, 10))
        // Laters reset for the next occurrence.
        var r = try answer(.later(.oneHour), reminder(.daily), now: t)
        r = try answer(.done, r, now: r.due!)
        XCTAssertEqual(r.laterCount, 0)
        XCTAssertEqual(r.due, at(2026, 11, 17, 10))
    }

    func testNextOccurrenceEdges() {
        let jan31 = at(2027, 1, 31, 8)
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .monthly, anchor: jan31, after: jan31, calendar: cal),
                       at(2027, 2, 28, 8))
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .monthly, anchor: jan31, after: at(2027, 3, 1), calendar: cal),
                       at(2027, 3, 31, 8))
        // Across the DST change the clock time stays 10:00.
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .daily, anchor: at(2026, 10, 31, 10), after: at(2026, 10, 31, 10),
                                                    calendar: cal), at(2026, 11, 1, 10))
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .weekly, anchor: t, after: at(2026, 12, 1), calendar: cal),
                       at(2026, 12, 7, 10))
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .never, anchor: t, after: t, calendar: cal), t)
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .days([]), anchor: t, after: t, calendar: cal), t)
        // Pick days: same day later is fine when the time hasn't passed.
        XCTAssertEqual(ReminderLogic.nextOccurrence(of: .days([2]), anchor: t, after: t - 60, calendar: cal), t)
    }

    func testArrivalReminder() throws {
        let place = UUID()
        let created = at(2026, 11, 16, 8)
        var r = Reminder(title: "Grab the package", trigger: .arrival(placeID: place), createdAt: created)
        XCTAssertNil(r.due)
        XCTAssertFalse(ReminderLogic.isRinging(r, now: created + 3600))
        XCTAssertNil(ReminderLogic.arrived(r, placeID: UUID(), now: created + 3600).due)
        r = ReminderLogic.arrived(r, placeID: place, now: created + 3600)
        // rings half a minute after the arrival is seen (its Time Sensitive notification must be in the future)
        XCTAssertEqual(r.due, created + 3630)
        XCTAssertTrue(ReminderLogic.isRinging(r, now: created + 3630))
        // A second arrival doesn't move it.
        XCTAssertEqual(ReminderLogic.arrived(r, placeID: place, now: created + 7200).due, created + 3630)
        XCTAssertEqual(try answer(.done, r, now: created + 3700).status, .done)
        // Tomorrow keeps now's clock time for arrival reminders.
        XCTAssertEqual(try answer(.later(.tomorrow), r, now: at(2026, 11, 16, 9, 10)).due, at(2026, 11, 17, 9, 10))
    }

    func testRepeatingArrivalReminderWaitsForNextDay() throws {
        let place = UUID()
        var r = Reminder(title: "Gym bag", trigger: .arrival(placeID: place), repeatRule: .daily,
                         createdAt: at(2026, 11, 16, 8))
        r = ReminderLogic.arrived(r, placeID: place, now: at(2026, 11, 16, 9))
        r = try answer(.done, r, now: at(2026, 11, 16, 9, 5))
        XCTAssertEqual(r.status, .active)
        XCTAssertNil(r.due)
        XCTAssertEqual(r.armedFrom, at(2026, 11, 17))
        XCTAssertNil(ReminderLogic.arrived(r, placeID: place, now: at(2026, 11, 16, 18)).due)
        XCTAssertEqual(ReminderLogic.arrived(r, placeID: place, now: at(2026, 11, 17, 9)).due, at(2026, 11, 17, 9) + 30)
    }
}
