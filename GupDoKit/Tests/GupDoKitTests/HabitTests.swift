import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class HabitTests: XCTestCase {
    let start = day(2026, 11, 16)  // a Monday
    let home = UUID()
    let s = Settings()

    func habit(place: UUID? = nil, days: DaySet = .everyDay, proof: ProofKind = .photo) -> Habit {
        Habit(name: "Stretch", days: days, window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), placeID: place,
              proof: proof, referencePhoto: "ref.jpg", nfcTagID: "tag-1", startDay: start)
    }

    /// A history where days (offsets from the start) are done; every other day is left empty (a miss).
    func history(_ h: Habit, done: [Int]) -> HabitHistory {
        var hist = HabitHistory()
        for n in done {
            let d = start.adding(days: n, cal)
            var log = hist[h.id, d]
            log.provedAt = d.at(TimeOfDay(7, 10), cal)
            hist[h.id, d] = log
        }
        return hist
    }

    func farFuture() -> Date { at(2028, 1, 1) }

    // MARK: Outcome

    func testOutcomeEndOfWindow() {
        let h = habit()
        let d = start
        var log = HabitDayLog(habitID: h.id, day: d)
        XCTAssertNil(HabitLogic.outcome(h, on: d.adding(days: -1, cal), log: nil, now: farFuture(), calendar: cal))
        XCTAssertEqual(HabitLogic.outcome(h, on: d, log: log, now: at(2026, 11, 16, 7, 59), calendar: cal), .pending)
        XCTAssertEqual(HabitLogic.outcome(h, on: d, log: log, now: at(2026, 11, 16, 8), calendar: cal), .missed)
        XCTAssertEqual(HabitLogic.outcome(h, on: d, log: nil, now: at(2026, 11, 16, 9), calendar: cal), .missed)
        log.provedAt = at(2026, 11, 16, 7, 30)
        XCTAssertEqual(HabitLogic.outcome(h, on: d, log: log, now: at(2026, 11, 16, 7, 31), calendar: cal), .done)
    }

    func testPlaceHabitNeverThereIsExcused() {
        let h = habit(place: home)
        var log = HabitDayLog(habitID: h.id, day: start)
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: log, now: at(2026, 11, 16, 9), calendar: cal), .excused)
        log = HabitLogic.arrived(h, log: log, at: at(2026, 11, 16, 7, 20), calendar: cal)
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: log, now: at(2026, 11, 16, 9), calendar: cal), .missed)
    }

    func testNotScheduledDaysHaveNoOutcome() {
        let h = habit(days: .weekdays([2, 4]))  // Mon, Wed
        XCTAssertNotNil(HabitLogic.outcome(h, on: start, log: nil, now: farFuture(), calendar: cal))
        XCTAssertNil(HabitLogic.outcome(h, on: start.adding(days: 1, cal), log: nil, now: farFuture(), calendar: cal))
    }

    // MARK: Lifecycle

    func testStrictNeeds66DoneDaysThenQuiet() {
        let h = habit()
        var hist = history(h, done: Array(0..<65))
        var st = HabitLogic.state(h, history: hist, through: start.adding(days: 64, cal), now: farFuture(), calendar: cal)
        XCTAssertEqual(st.phase, .strict(daysLeft: 1))
        XCTAssertEqual(st.doneDays, 65)
        hist = history(h, done: Array(0..<66))
        st = HabitLogic.state(h, history: hist, through: start.adding(days: 65, cal), now: farFuture(), calendar: cal)
        XCTAssertEqual(st.phase, .quiet)
        XCTAssertEqual(HabitLogic.phase(h, on: start.adding(days: 65, cal), history: hist, now: farFuture(), calendar: cal),
                       .strict(daysLeft: 1))
        XCTAssertEqual(HabitLogic.phase(h, on: start.adding(days: 66, cal), history: hist, now: farFuture(), calendar: cal),
                       .quiet)
        XCTAssertEqual(HabitLogic.phase(h, on: start, history: hist, now: farFuture(), calendar: cal),
                       .strict(daysLeft: 66))
    }

    func testEachMissAddsTwoDays() {
        let h = habit()
        // Day 1 and 2 missed, the rest done.
        let done = [0] + Array(3..<200)
        let hist = history(h, done: done)
        var st = HabitLogic.state(h, history: hist, through: start.adding(days: 2, cal), now: farFuture(), calendar: cal)
        XCTAssertEqual(st.phase, .strict(daysLeft: 66 + 4 - 1))
        XCTAssertEqual(st.misses, 2)
        // 70 done days needed: done on day 0 and days 3...71 -> quiet after day 71.
        st = HabitLogic.state(h, history: hist, through: start.adding(days: 70, cal), now: farFuture(), calendar: cal)
        XCTAssertEqual(st.phase, .strict(daysLeft: 1))
        st = HabitLogic.state(h, history: hist, through: start.adding(days: 71, cal), now: farFuture(), calendar: cal)
        XCTAssertEqual(st.phase, .quiet)
    }

    func testExcusedAndPendingDaysAreNeutral() {
        let h = habit(place: home)
        // Never at the place for 10 days: excused, countdown unchanged.
        let st = HabitLogic.state(h, history: HabitHistory(), through: start.adding(days: 9, cal), now: farFuture(),
                                  calendar: cal)
        XCTAssertEqual(st.phase, .strict(daysLeft: 66))
        XCTAssertEqual(st.misses, 0)
        // Today still pending.
        let today = HabitLogic.state(habit(), history: HabitHistory(), through: start, now: at(2026, 11, 16, 7, 30),
                                     calendar: cal)
        XCTAssertEqual(today.phase, .strict(daysLeft: 66))
    }

    func testTwoQuietMissesInSevenDaysGoStrictFor14Days() {
        let h = habit()
        // Days 0-65 done (quiet from 66). Misses on 70 and 76 (6 days apart).
        let done = Array(0..<66) + Array(66..<70) + Array(71..<76) + Array(77..<120)
        let hist = history(h, done: done)
        func phase(_ n: Int) -> HabitPhase {
            HabitLogic.phase(h, on: start.adding(days: n, cal), history: hist, now: farFuture(), calendar: cal)
        }
        XCTAssertEqual(phase(70), .quiet)
        XCTAssertEqual(phase(76), .quiet)
        XCTAssertEqual(phase(77), .restrict(until: start.adding(days: 90, cal), daysLeft: 14))
        XCTAssertEqual(phase(78), .restrict(until: start.adding(days: 90, cal), daysLeft: 13))
        XCTAssertEqual(phase(90), .restrict(until: start.adding(days: 90, cal), daysLeft: 1))
        XCTAssertTrue(phase(90).notifies)
        XCTAssertEqual(phase(91), .quiet)
        XCTAssertFalse(phase(91).notifies)
    }

    func testQuietMissesFarApartStayQuiet() {
        let h = habit()
        // Misses on 70 and 77 (7 days apart: not in one 7-day span).
        let done = Array(0..<70) + Array(71..<77) + Array(78..<100)
        let hist = history(h, done: done)
        XCTAssertEqual(HabitLogic.phase(h, on: start.adding(days: 90, cal), history: hist, now: farFuture(), calendar: cal),
                       .quiet)
        // A miss during the 14 strict days doesn't count toward the next Quiet pair.
        let done2 = Array(0..<70) + Array(71..<73) + [74] + Array(76..<100)  // misses 70, 73 -> restrict 74..87; miss 75
        let hist2 = history(h, done: done2)
        XCTAssertEqual(HabitLogic.phase(h, on: start.adding(days: 74, cal), history: hist2, now: farFuture(), calendar: cal),
                       .restrict(until: start.adding(days: 87, cal), daysLeft: 14))
        XCTAssertEqual(HabitLogic.phase(h, on: start.adding(days: 88, cal), history: hist2, now: farFuture(), calendar: cal),
                       .quiet)
    }

    // MARK: Progress

    func testWeekProgressAndImportant() {
        let h = habit()
        // Week of Sun 2026-11-15 .. Sat 11-21; habit starts Mon 16. Done Mon, Wed, Thu; Tue missed.
        let hist = history(h, done: [0, 2, 3])
        let now = at(2026, 11, 20, 12)  // Friday after the window: Friday missed
        let week = HabitLogic.weekProgress(h, history: hist, today: day(2026, 11, 20), now: now, calendar: cal)
        XCTAssertEqual(week.done, 3)
        XCTAssertEqual(week.of, 6)  // Mon-Sat (Sunday is before the start)
        XCTAssertTrue(HabitLogic.isImportantToday(h, history: hist, today: day(2026, 11, 18), now: now, calendar: cal))
        XCTAssertFalse(HabitLogic.isImportantToday(h, history: hist, today: day(2026, 11, 19), now: now, calendar: cal))
        XCTAssertFalse(HabitLogic.isImportantToday(h, history: hist, today: start, now: now, calendar: cal))
        // Pick-days habit: previous scheduled day counts.
        let mw = habit(days: .weekdays([2, 4]))
        XCTAssertTrue(HabitLogic.isImportantToday(mw, history: HabitHistory(), today: day(2026, 11, 18), now: now,
                                                  calendar: cal))
        XCTAssertFalse(HabitLogic.isImportantToday(mw, history: HabitHistory(), today: day(2026, 11, 19), now: now,
                                                   calendar: cal))
    }

    // MARK: Answers

    func testChoices() {
        let h = habit(place: home)
        var log = HabitDayLog(habitID: h.id, day: start)
        let strict = HabitPhase.strict(daysLeft: 66)
        let atHome = PhoneContext(isDriving: false, insidePlaces: [home])
        XCTAssertEqual(HabitLogic.choices(h, log: log, phase: strict, context: atHome), [.done, .fifteenMinutes])
        XCTAssertEqual(HabitLogic.choices(h, log: log, phase: strict, context: PhoneContext()),
                       [.done, .fifteenMinutes, .cantRightNow])
        log.snoozedAt = at(2026, 11, 16, 7)
        XCTAssertEqual(HabitLogic.choices(h, log: log, phase: strict, context: atHome), [.done])
        XCTAssertEqual(HabitLogic.choices(h, log: log, phase: .quiet, context: atHome), [.check])
        // Anywhere habit: Can't right now only while driving.
        let any = habit()
        let anyLog = HabitDayLog(habitID: any.id, day: start)
        XCTAssertEqual(HabitLogic.choices(any, log: anyLog, phase: strict, context: PhoneContext()), [.done, .fifteenMinutes])
        XCTAssertEqual(HabitLogic.choices(any, log: anyLog, phase: strict, context: PhoneContext(isDriving: true)),
                       [.done, .fifteenMinutes, .cantRightNow])
    }

    func testProofRules() {
        XCTAssertTrue(HabitLogic.accepts(.photo(matchesReference: true, fromLiveCamera: true), for: habit()))
        XCTAssertFalse(HabitLogic.accepts(.photo(matchesReference: false, fromLiveCamera: true), for: habit()))
        XCTAssertFalse(HabitLogic.accepts(.photo(matchesReference: true, fromLiveCamera: false), for: habit()))
        XCTAssertFalse(HabitLogic.accepts(.nfc(tagID: "tag-1"), for: habit()))
        XCTAssertTrue(HabitLogic.accepts(.location(placeID: home), for: habit(place: home, proof: .location)))
        XCTAssertFalse(HabitLogic.accepts(.location(placeID: UUID()), for: habit(place: home, proof: .location)))
        XCTAssertFalse(HabitLogic.accepts(.location(placeID: home), for: habit(proof: .location)))
        XCTAssertTrue(HabitLogic.accepts(.nfc(tagID: "tag-1"), for: habit(proof: .nfc)))
        XCTAssertFalse(HabitLogic.accepts(.nfc(tagID: "other"), for: habit(proof: .nfc)))
    }

    func testAnswers() throws {
        let h = habit(place: home)
        let strict = HabitPhase.strict(daysLeft: 10)
        let now = at(2026, 11, 16, 7, 10)
        let log = HabitDayLog(habitID: h.id, day: start)
        let ctx = PhoneContext(isDriving: false, insidePlaces: [home])
        func ans(_ a: HabitAnswer, _ l: HabitDayLog = log, phase: HabitPhase = strict,
                 context: PhoneContext? = nil) throws -> HabitDayLog {
            try HabitLogic.answer(a, habit: h, log: l, phase: phase, context: context ?? ctx, now: now, calendar: cal)
        }
        XCTAssertEqual(try ans(.done(.photo(matchesReference: true, fromLiveCamera: true))).provedAt, now)
        XCTAssertThrowsError(try ans(.done(.photo(matchesReference: false, fromLiveCamera: true)))) {
            XCTAssertEqual($0 as? HabitError, .proofRejected)
        }
        XCTAssertThrowsError(try ans(.check)) { XCTAssertEqual($0 as? HabitError, .answerNotAllowed) }
        XCTAssertEqual(try ans(.check, phase: .quiet).provedAt, now)
        XCTAssertThrowsError(try ans(.done(.photo(matchesReference: true, fromLiveCamera: true)), phase: .quiet))
        // 15 min once per day.
        let snoozed = try ans(.fifteenMinutes)
        XCTAssertEqual(snoozed.snoozedAt, now)
        XCTAssertThrowsError(try ans(.fifteenMinutes, snoozed)) { XCTAssertEqual($0 as? HabitError, .answerNotAllowed) }
        // Can't right now: refused at the place and not driving; accepted when away or driving.
        XCTAssertThrowsError(try ans(.cantRightNow(.away))) { XCTAssertEqual($0 as? HabitError, .answerNotAllowed) }
        XCTAssertThrowsError(try ans(.cantRightNow(.driving)))
        let paused = try ans(.cantRightNow(.away), context: PhoneContext())
        XCTAssertEqual(paused.pauses, [HabitPause(reason: .away, start: now)])
        XCTAssertEqual(try ans(.cantRightNow(.driving), context: PhoneContext(isDriving: true, insidePlaces: [home])).pauses,
                       [HabitPause(reason: .driving, start: now)])
        // A second Can't right now during an open pause changes nothing.
        XCTAssertEqual(try ans(.cantRightNow(.away), paused, context: PhoneContext()).pauses.count, 1)
        // Not a habit day.
        let tue = HabitDayLog(habitID: h.id, day: start.adding(days: 1, cal))
        let mondays = Habit(name: "x", days: .weekdays([2]), window: h.window, startDay: start)
        XCTAssertThrowsError(try HabitLogic.answer(.fifteenMinutes, habit: mondays, log: tue, phase: strict, context: ctx,
                                                   now: now, calendar: cal)) {
            XCTAssertEqual($0 as? HabitError, .notScheduledToday)
        }
    }

    func testCantRightNowIsAPauseNotAPass() throws {
        let h = habit(place: home)
        var log = HabitLogic.arrived(h, log: HabitDayLog(habitID: h.id, day: start), at: at(2026, 11, 16, 7), calendar: cal)
        log = try HabitLogic.answer(.cantRightNow(.away), habit: h, log: log, phase: .strict(daysLeft: 9),
                                    context: PhoneContext(), now: at(2026, 11, 16, 7, 10), calendar: cal)
        // Still away when the window ends: excused.
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: log, now: at(2026, 11, 16, 8), calendar: cal), .excused)
        XCTAssertNil(HabitLogic.cycleStart(h, on: start, log: log, insideNow: false, settings: s, calendar: cal))
        // Comes back during the window: fires again 3 min after arriving; unproved by the end -> missed.
        let back = HabitLogic.arrived(h, log: log, at: at(2026, 11, 16, 7, 30), calendar: cal)
        XCTAssertEqual(back.pauses.last?.end, at(2026, 11, 16, 7, 30))
        XCTAssertEqual(back.atPlaceAt, at(2026, 11, 16, 7))
        XCTAssertEqual(HabitLogic.cycleStart(h, on: start, log: back, insideNow: true, settings: s, calendar: cal),
                       at(2026, 11, 16, 7, 33))
        XCTAssertEqual(HabitLogic.outcome(h, on: start, log: back, now: at(2026, 11, 16, 8), calendar: cal), .missed)
    }

    func testDrivingPauseResumesWhenDrivingStops() throws {
        let h = habit()
        var log = try HabitLogic.answer(.cantRightNow(.driving), habit: h, log: HabitDayLog(habitID: h.id, day: start),
                                        phase: .strict(daysLeft: 9), context: PhoneContext(isDriving: true),
                                        now: at(2026, 11, 16, 7, 5), calendar: cal)
        XCTAssertNil(HabitLogic.cycleStart(h, on: start, log: log, insideNow: false, settings: s, calendar: cal))
        // Arriving somewhere doesn't end a driving pause; stopping does.
        XCTAssertNil(HabitLogic.arrived(h, log: log, at: at(2026, 11, 16, 7, 20), calendar: cal).pauses.last?.end)
        log = HabitLogic.stoppedDriving(log: log, at: at(2026, 11, 16, 7, 25))
        XCTAssertEqual(HabitLogic.cycleStart(h, on: start, log: log, insideNow: false, settings: s, calendar: cal),
                       at(2026, 11, 16, 7, 26))
        XCTAssertEqual(HabitLogic.stoppedDriving(log: log, at: at(2026, 11, 16, 7, 40)).pauses.last?.end,
                       at(2026, 11, 16, 7, 25))
    }

    // MARK: Firing

    func testCycleStart() {
        let any = habit()
        XCTAssertEqual(HabitLogic.cycleStart(any, on: start, log: nil, insideNow: false, settings: s, calendar: cal),
                       at(2026, 11, 16, 7))
        let place = habit(place: home)
        // Not there and no arrival yet: silent. Already there: window start.
        XCTAssertNil(HabitLogic.cycleStart(place, on: start, log: nil, insideNow: false, settings: s, calendar: cal))
        XCTAssertEqual(HabitLogic.cycleStart(place, on: start, log: nil, insideNow: true, settings: s, calendar: cal),
                       at(2026, 11, 16, 7))
        // Arrived before the window: window start. Arrived during it: 3 minutes later.
        var log = HabitLogic.arrived(place, log: HabitDayLog(habitID: place.id, day: start), at: at(2026, 11, 16, 6),
                                     calendar: cal)
        XCTAssertEqual(log.atPlaceAt, at(2026, 11, 16, 7))
        XCTAssertEqual(HabitLogic.cycleStart(place, on: start, log: log, insideNow: true, settings: s, calendar: cal),
                       at(2026, 11, 16, 7))
        log = HabitLogic.arrived(place, log: HabitDayLog(habitID: place.id, day: start), at: at(2026, 11, 16, 7, 20),
                                 calendar: cal)
        XCTAssertEqual(HabitLogic.cycleStart(place, on: start, log: log, insideNow: true, settings: s, calendar: cal),
                       at(2026, 11, 16, 7, 23))
        // Arrival after the window or for an Anywhere habit isn't recorded.
        XCTAssertNil(HabitLogic.arrived(place, log: HabitDayLog(habitID: place.id, day: start), at: at(2026, 11, 16, 8),
                                        calendar: cal).atPlaceAt)
        XCTAssertNil(HabitLogic.arrived(any, log: HabitDayLog(habitID: any.id, day: start), at: at(2026, 11, 16, 7, 5),
                                        calendar: cal).atPlaceAt)
        // A later arrival doesn't move the first.
        XCTAssertEqual(HabitLogic.arrived(place, log: log, at: at(2026, 11, 16, 7, 40), calendar: cal).atPlaceAt,
                       at(2026, 11, 16, 7, 20))
        // 15 min snooze restarts 15 minutes later; proved: silent; not a habit day: silent.
        var snoozed = HabitDayLog(habitID: any.id, day: start)
        snoozed.snoozedAt = at(2026, 11, 16, 7, 6)
        XCTAssertEqual(HabitLogic.cycleStart(any, on: start, log: snoozed, insideNow: false, settings: s, calendar: cal),
                       at(2026, 11, 16, 7, 21))
        var proved = snoozed
        proved.provedAt = at(2026, 11, 16, 7, 22)
        XCTAssertNil(HabitLogic.cycleStart(any, on: start, log: proved, insideNow: false, settings: s, calendar: cal))
        XCTAssertNil(HabitLogic.cycleStart(habit(days: .weekdays([3])), on: start, log: nil, insideNow: false, settings: s,
                                           calendar: cal))
        // A snooze after a finished pause wins.
        var both = HabitDayLog(habitID: any.id, day: start)
        both.pauses = [HabitPause(reason: .driving, start: at(2026, 11, 16, 7, 1), end: at(2026, 11, 16, 7, 10))]
        both.snoozedAt = at(2026, 11, 16, 7, 12)
        XCTAssertEqual(HabitLogic.cycleStart(any, on: start, log: both, insideNow: false, settings: s, calendar: cal),
                       at(2026, 11, 16, 7, 27))
    }
}
