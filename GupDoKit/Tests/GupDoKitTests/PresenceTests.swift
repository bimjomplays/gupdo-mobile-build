import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class PresenceTests: XCTestCase {
    let today = day(2026, 11, 16)
    let home = Place(name: "Home (example)", latitude: 40, longitude: -75, isHome: true)

    func data(proof: ProofKind = .location) -> (GupDoData, Habit) {
        var d = GupDoData()
        d.places = [home]
        let h = Habit(name: "Stretch", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), placeID: home.id,
                      proof: proof, referencePhoto: "r", startDay: today)
        d.habits = [h]
        return (d, h)
    }

    func testArrivalDuringWindowFiresThreeMinutesLater() {
        var (d, h) = data()
        XCTAssertTrue(Planner.plan(d, now: at(2026, 11, 16, 6, 50), calendar: cal).alerts
            .filter { $0.fireDate < at(2026, 11, 17) }.isEmpty, "not there: silent")
        d = Presence.entered(home.id, at: at(2026, 11, 16, 7, 20), data: d, calendar: cal)
        XCTAssertEqual(Presence.inside(d), [home.id])
        XCTAssertEqual(d.history[h.id, today].atPlaceAt, at(2026, 11, 16, 7, 20))
        let plan = Planner.plan(d, now: at(2026, 11, 16, 7, 20), presence: Presence.inside(d), calendar: cal)
        let todays = plan.alerts.filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertEqual(todays.first?.fireDate, at(2026, 11, 16, 7, 23))
        XCTAssertEqual(todays.first?.kind, .timeSensitive)
        XCTAssertEqual(todays.dropFirst().first?.fireDate, at(2026, 11, 16, 7, 28))
        XCTAssertEqual(plan.regions.map(\.place.id), [home.id])
    }

    func testHomeAllDayCountsAtWindowStartWithoutAnyEventInTheWindow() {
        var (d, h) = data()
        d = Presence.entered(home.id, at: at(2026, 11, 15, 18), data: d, calendar: cal)
        // the app runs again only the next evening, after the window: still "there", so unproved = missed
        d = Presence.settle(d, now: at(2026, 11, 16, 19), calendar: cal)
        XCTAssertEqual(d.history[h.id, today].atPlaceAt, at(2026, 11, 16, 7))
        XCTAssertEqual(HabitLogic.outcome(h, on: today, log: d.history.log(h.id, today), now: at(2026, 11, 16, 19),
                                          calendar: cal), .missed)
    }

    func testNeverThereDuringWindowIsExcused() {
        var (d, h) = data()
        d = Presence.entered(home.id, at: at(2026, 11, 16, 5), data: d, calendar: cal)
        d = Presence.left(home.id, at: at(2026, 11, 16, 6, 30), data: d, calendar: cal)
        d = Presence.entered(home.id, at: at(2026, 11, 16, 8, 30), data: d, calendar: cal)
        d = Presence.settle(d, now: at(2026, 11, 16, 9), calendar: cal)
        XCTAssertNil(d.history.log(h.id, today)?.atPlaceAt)
        XCTAssertEqual(HabitLogic.outcome(h, on: today, log: d.history.log(h.id, today), now: at(2026, 11, 16, 9),
                                          calendar: cal), .excused)
        XCTAssertEqual(TodayLogic.today(d, now: at(2026, 11, 16, 9), calendar: cal).habits.first?.outcome, .excused)
    }

    func testEnteringTwiceKeepsOneVisitAndLeavingCloses() {
        var (d, _) = data()
        d = Presence.entered(home.id, at: at(2026, 11, 16, 5), data: d, calendar: cal)
        d = Presence.entered(home.id, at: at(2026, 11, 16, 6), data: d, calendar: cal)
        XCTAssertEqual(d.visits.count, 1)
        d = Presence.left(home.id, at: at(2026, 11, 16, 6, 30), data: d, calendar: cal)
        XCTAssertEqual(d.visits.first?.left, at(2026, 11, 16, 6, 30))
        XCTAssertTrue(Presence.inside(d).isEmpty)
        // old visits are dropped
        d = Presence.settle(d, now: at(2026, 11, 20), calendar: cal)
        XCTAssertTrue(d.visits.isEmpty)
        XCTAssertTrue(Presence.forget(home.id, data: Presence.entered(home.id, at: at(2026, 11, 20), data: d,
                                                                      calendar: cal)).visits.isEmpty)
    }

    func testCantRightNowAwayOnlyWhenAwayAndResumesOnReturn() throws {
        var (d, h) = data()
        d = Presence.entered(home.id, at: at(2026, 11, 16, 6), data: d, calendar: cal)
        let atHome = Presence.context(d, isDriving: false)
        XCTAssertFalse(Answers.habitChoices(h, data: d, context: atHome, now: at(2026, 11, 16, 7, 5), calendar: cal)
            .contains(.cantRightNow))
        // leaves during the window: now it's offered, as "away"
        d = Presence.left(home.id, at: at(2026, 11, 16, 7, 10), data: d, calendar: cal)
        let away = Presence.context(d, isDriving: false)
        XCTAssertTrue(Answers.habitChoices(h, data: d, context: away, now: at(2026, 11, 16, 7, 12), calendar: cal)
            .contains(.cantRightNow))
        XCTAssertEqual(HabitLogic.pauseReason(h, context: away), .away)
        d = try Answers.apply(.habit(h.id, .cantRightNow(.away)), to: d, context: away, now: at(2026, 11, 16, 7, 12),
                              calendar: cal)
        // a settle with an old visit doesn't end the newer pause
        d = Presence.settle(d, now: at(2026, 11, 16, 7, 15), calendar: cal)
        XCTAssertNil(d.history[h.id, today].pauses.last?.end)
        XCTAssertTrue(Planner.plan(d, now: at(2026, 11, 16, 7, 15), presence: Presence.inside(d), calendar: cal).alerts
            .allSatisfy { $0.fireDate >= at(2026, 11, 17) })
        // back home: rings again 3 minutes later
        d = Presence.entered(home.id, at: at(2026, 11, 16, 7, 30), data: d, calendar: cal)
        XCTAssertEqual(d.history[h.id, today].pauses.last?.end, at(2026, 11, 16, 7, 30))
        XCTAssertEqual(Planner.plan(d, now: at(2026, 11, 16, 7, 30), presence: Presence.inside(d), calendar: cal)
            .alerts.first?.fireDate, at(2026, 11, 16, 7, 33))
        // still away at window end instead: excused
        var e = data().0
        e.habits = d.habits
        e = Presence.entered(home.id, at: at(2026, 11, 16, 6), data: e, calendar: cal)
        e = Presence.left(home.id, at: at(2026, 11, 16, 7, 10), data: e, calendar: cal)
        e = try Answers.apply(.habit(h.id, .cantRightNow(.away)), to: e, context: Presence.context(e, isDriving: false),
                              now: at(2026, 11, 16, 7, 12), calendar: cal)
        XCTAssertEqual(HabitLogic.outcome(h, on: today, log: e.history.log(h.id, today), now: at(2026, 11, 16, 8),
                                          calendar: cal), .excused)
    }

    func testGroupedPlaceHabitsRingAsOneUntilEachIsProved() throws {
        var (d, h) = data()
        let h2 = Habit(name: "Vitamins", window: h.window, placeID: home.id, proof: .nfc, nfcTagID: "04:AA",
                       startDay: today)
        d.habits.append(h2)
        d = Presence.entered(home.id, at: at(2026, 11, 16, 7, 20), data: d, calendar: cal)
        let now = at(2026, 11, 16, 7, 24)
        var todays = Planner.plan(d, now: now, presence: Presence.inside(d), calendar: cal).alerts
            .filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertFalse(todays.isEmpty)
        XCTAssertTrue(todays.allSatisfy { $0.itemIDs == [h.id, h2.id] && $0.title == "2 habits" })
        // prove the location one by a fix at home: the alarm goes on for the other only
        let fix = LocationFix(latitude: 40.0001, longitude: -75, accuracy: 10, time: now)
        for (habit, evidence) in ProofCheck.byLocation(d.habits, places: d.places, fix: fix) {
            d = try Answers.apply(.habit(habit.id, .done(evidence)), to: d, now: now, calendar: cal)
        }
        todays = Planner.plan(d, now: now, presence: Presence.inside(d), calendar: cal).alerts
            .filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertFalse(todays.isEmpty)
        XCTAssertTrue(todays.allSatisfy { $0.itemIDs == [h2.id] })
        for (habit, evidence) in ProofCheck.byTag(d.habits, tagID: "04aa") {
            d = try Answers.apply(.habit(habit.id, .done(evidence)), to: d, now: now, calendar: cal)
        }
        XCTAssertTrue(Planner.plan(d, now: now, presence: Presence.inside(d), calendar: cal).alerts
            .allSatisfy { $0.fireDate >= at(2026, 11, 17) })
        // a proof from somewhere else is rejected
        var far = data().0
        far.habits = [h]
        XCTAssertThrowsError(try Answers.apply(.habit(h.id, .done(.location(placeID: UUID()))), to: far, now: now,
                                               calendar: cal))
    }

    func testOldSavedFileWithoutVisitsStillLoads() throws {
        var (d, _) = data()
        d = Presence.entered(home.id, at: at(2026, 11, 16, 7), data: d, calendar: cal)
        let json = try JSONSerialization.jsonObject(with: d.encoded()) as! [String: Any]
        var old = json
        old.removeValue(forKey: "visits")
        let loaded = try GupDoData.decode(JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(loaded.habits, d.habits)
        XCTAssertTrue(loaded.visits.isEmpty)
        XCTAssertEqual(try GupDoData.decode(d.encoded()), d)
    }
}
