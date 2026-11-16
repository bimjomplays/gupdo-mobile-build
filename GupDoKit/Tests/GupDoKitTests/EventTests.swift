import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class EventTests: XCTestCase {
    let start = at(2026, 12, 10, 14)  // Thursday 2pm

    func event(_ preset: HeadsUpPreset = .normal, place: UUID? = nil, timing: MainAlertTiming? = nil,
               travel: Int? = nil, start: Date? = nil, end: Date? = nil) -> Event {
        Event(title: "Dentist", start: start ?? self.start, end: end,
              location: place.map { EventLocation(name: "Dentist", latitude: 40, longitude: -75, placeID: $0) },
              headsUps: preset, mainAlert: timing, travelMinutes: travel)
    }

    func dates(_ e: Event, _ s: Settings = Settings()) -> [Date] { EventLogic.headsUps(e, settings: s, calendar: cal).map(\.date) }

    func testDefaultPresetIsNormal() {
        XCTAssertEqual(Event(title: "x", start: start).headsUps, .normal)
    }

    func testPresets() {
        XCTAssertEqual(dates(event(.big)), [at(2026, 11, 26, 9), at(2026, 12, 3, 9), at(2026, 12, 5, 9), at(2026, 12, 7, 9),
                                            at(2026, 12, 9, 9), at(2026, 12, 10, 9)])
        XCTAssertEqual(dates(event(.normal)), [at(2026, 12, 5, 9), at(2026, 12, 7, 9), at(2026, 12, 9, 9),
                                               at(2026, 12, 10, 9)])
        XCTAssertEqual(dates(event(.small)), [at(2026, 12, 10, 9)])
        XCTAssertEqual(dates(event(.custom(daysBefore: [2, 2, 10, 0], morningOf: false))),
                       [at(2026, 11, 30, 9), at(2026, 12, 8, 9)])
        XCTAssertEqual(EventLogic.headsUps(event(.small), calendar: cal).first?.daysBefore, 0)
    }

    func testHeadsUpTimeConfigurable() {
        var s = Settings()
        s.headsUpTime = TimeOfDay(7, 30)
        XCTAssertEqual(dates(event(.small), s), [at(2026, 12, 10, 7, 30)])
    }

    func testMorningOfDroppedWhenAtOrAfterMainAlert() {
        // 9:30 event, main alert at 9:00 (30 min before): the 9am morning-of would collide -> dropped.
        let e = event(.small, timing: .thirtyMinutesBefore, start: at(2026, 12, 10, 9, 30))
        XCTAssertEqual(dates(e), [])
        XCTAssertEqual(dates(event(.small, start: at(2026, 12, 10, 8))), [])
    }

    func testMainAlertTiming() {
        XCTAssertEqual(EventLogic.mainAlertDate(event()), start)
        XCTAssertEqual(EventLogic.mainAlertDate(event(timing: .thirtyMinutesBefore)), start - minutes(30))
        XCTAssertEqual(EventLogic.mainAlertDate(event(timing: .hourBefore)), start - minutes(60))
        // With a place it defaults to time to leave.
        let place = UUID()
        XCTAssertEqual(EventLogic.defaultTiming(for: event(place: place)), .timeToLeave)
        // drive time + the 10-minute buffer
        XCTAssertEqual(EventLogic.mainAlertDate(event(place: place, travel: 25)), start - minutes(35))
        XCTAssertEqual(EventLogic.mainAlertDate(event(place: place)), start - minutes(60))  // travel unknown yet
        XCTAssertEqual(EventLogic.mainAlertDate(event(place: place, timing: .atStart, travel: 25)), start)
    }

    func testAnswersAndRinging() {
        var e = event()
        XCTAssertFalse(EventLogic.isRinging(e, now: start - 1))
        XCTAssertTrue(EventLogic.isRinging(e, now: start))
        e = EventLogic.answer(.gotItHeadsUp, to: e, now: start - 3600)
        XCTAssertEqual(e.headsUpAcknowledgedAt, start - 3600)
        XCTAssertTrue(EventLogic.isRinging(e, now: start))
        e = EventLogic.answer(.gotItMainAlert, to: e, now: start + 60)
        XCTAssertFalse(EventLogic.isRinging(e, now: start + 120))
    }

    func testClashes() {
        let a = event(start: at(2026, 12, 10, 14), end: at(2026, 12, 10, 15))
        let b = event(start: at(2026, 12, 10, 14, 30), end: at(2026, 12, 10, 16))
        let c = event(start: at(2026, 12, 10, 15), end: at(2026, 12, 10, 16))  // back to back with a
        let instantInA = event(start: at(2026, 12, 10, 14, 45))
        let instantAtStartOfA = event(start: at(2026, 12, 10, 14))
        let instantAtEndOfA = event(start: at(2026, 12, 10, 15))
        let otherDay = event(start: at(2026, 12, 11, 14), end: at(2026, 12, 11, 15))
        XCTAssertEqual(EventLogic.clashes(for: a, among: [a, b, c, otherDay]).map(\.id), [b.id])
        XCTAssertTrue(EventLogic.overlaps(a, instantInA))
        XCTAssertTrue(EventLogic.overlaps(instantInA, a))
        XCTAssertTrue(EventLogic.overlaps(a, instantAtStartOfA))
        XCTAssertFalse(EventLogic.overlaps(a, instantAtEndOfA))
        XCTAssertTrue(EventLogic.overlaps(instantAtStartOfA, event(start: at(2026, 12, 10, 14))))
        XCTAssertFalse(EventLogic.overlaps(instantInA, instantAtStartOfA))
        XCTAssertTrue(EventLogic.overlaps(b, c))
    }

    func testUpcomingSorted() {
        let now = at(2026, 12, 10, 14, 30)
        let past = event(start: at(2026, 12, 9, 10))
        let ongoing = event(start: at(2026, 12, 10, 14), end: at(2026, 12, 10, 15))
        let later = event(start: at(2026, 12, 20, 9))
        let soon = event(start: at(2026, 12, 11, 9))
        XCTAssertEqual(EventLogic.upcoming([later, past, soon, ongoing], now: now).map(\.id), [ongoing.id, soon.id, later.id])
    }
}
