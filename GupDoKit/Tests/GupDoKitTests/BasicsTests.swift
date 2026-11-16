import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class BasicsTests: XCTestCase {
    func testTimeOfDayOnDay() {
        XCTAssertEqual(TimeOfDay(9, 30).on(at(2026, 11, 15, 22), cal), at(2026, 11, 15, 9, 30))
        XCTAssertEqual(TimeOfDay(of: at(2026, 11, 15, 7, 5), cal), TimeOfDay(7, 5))
        XCTAssertTrue(TimeOfDay(7) < TimeOfDay(7, 1))
    }

    func testDayKeyArithmeticAcrossDST() {
        let d = day(2026, 10, 31)
        XCTAssertEqual(d.adding(days: 1, cal), day(2026, 11, 1))
        XCTAssertEqual(d.adding(days: 2, cal), day(2026, 11, 2))
        XCTAssertEqual(day(2026, 11, 1).at(TimeOfDay(9), cal), at(2026, 11, 1, 9))
        XCTAssertEqual(d.days(until: day(2026, 11, 7), cal), 7)
        XCTAssertEqual(day(2027, 3, 13).adding(days: 1, cal), day(2027, 3, 14))
        XCTAssertEqual(day(2026, 12, 31).adding(days: 1, cal), day(2027, 1, 1))
        XCTAssertEqual(day(2026, 11, 15).description, "2026-11-15")
        XCTAssertEqual(DayKey(at(2026, 11, 15, 23, 59), cal), day(2026, 11, 15))
    }

    func testWeekdaysAndDaySet() {
        XCTAssertEqual(day(2026, 11, 15).weekday(cal), 1)  // a Sunday
        XCTAssertTrue(DaySet.everyDay.contains(day(2026, 11, 15), cal))
        XCTAssertTrue(DaySet.weekdays([2, 4]).contains(day(2026, 11, 16), cal))  // Monday
        XCTAssertFalse(DaySet.weekdays([2, 4]).contains(day(2026, 11, 17), cal))
    }

    func testClock() {
        XCTAssertEqual(AppClock.fixed(at(2026, 1, 1)).now(), at(2026, 1, 1))
        XCTAssertLessThan(abs(AppClock.system.now().timeIntervalSinceNow), 5)
    }

    func testSettingsDefaults() {
        let s = Settings()
        XCTAssertEqual(s.headsUpTime, TimeOfDay(9))
        XCTAssertEqual(s.alarmEveryMinutes, 5)
    }
}
