import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

// Fixed calendar and time zone so every rule is checked against known dates (New York has DST changes on
// 2026-11-01 and 2027-03-14).

let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    c.firstWeekday = 1
    return c
}()

/// A date in New York time.
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func day(_ y: Int, _ m: Int, _ d: Int) -> DayKey { DayKey(year: y, month: m, day: d) }

func minutes(_ n: Double) -> TimeInterval { n * 60 }
