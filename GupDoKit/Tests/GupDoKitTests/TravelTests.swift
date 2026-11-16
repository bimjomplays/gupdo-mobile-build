import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

/// Time to leave (drive time from MapKit -> the alarm time) and arrival reminders on the saved places.
final class TravelTests: XCTestCase {
    let start = at(2026, 12, 10, 14)  // Thursday 2pm
    let dentist = EventLocation(name: "Dentist", address: "1 Example St", latitude: 40, longitude: -75)

    func event(travel: Int? = nil, checked: Date? = nil, timing: MainAlertTiming? = nil) -> Event {
        Event(title: "Dentist", start: start, location: dentist, mainAlert: timing, travelMinutes: travel,
              travelCheckedAt: checked)
    }

    func leave(_ travel: Int?, checked: Date?, previous: Date?, now: Date) -> Date {
        TravelTime.leaveTime(start: start, travelMinutes: travel, checkedAt: checked, previous: previous, now: now)
    }

    // MARK: The alarm-time rule

    func testUnknownDriveTimeIsAnHourBefore() {
        XCTAssertEqual(leave(nil, checked: nil, previous: nil, now: start - 86_400), start - minutes(60))
        XCTAssertEqual(EventLogic.mainAlertDate(event()), start - minutes(60))
        XCTAssertEqual(Planner.mainAlertText(event()), "In 1 hour · Dentist")
        // unknown again later: what was picked before stays
        XCTAssertEqual(leave(nil, checked: nil, previous: start - minutes(42), now: start - 86_400), start - minutes(42))
    }

    func testDriveTimePlusTenMinuteBuffer() {
        let now = start - minutes(180)
        XCTAssertEqual(leave(25, checked: now, previous: nil, now: now), start - minutes(35))
        var s = Settings()
        s.leaveBufferMinutes = 0
        XCTAssertEqual(TravelTime.leaveTime(start: start, travelMinutes: 25, checkedAt: now, previous: nil, now: now,
                                            settings: s), start - minutes(25))
    }

    func testFreshDriveTimeMovesEitherWay() {
        let now = start - minutes(180)
        // earlier (traffic) and later (it cleared), both from a drive time just worked out
        XCTAssertEqual(leave(50, checked: now, previous: start - minutes(35), now: now), start - minutes(60))
        XCTAssertEqual(leave(15, checked: now, previous: start - minutes(60), now: now), start - minutes(25))
        // 1h59 old still counts as fresh
        XCTAssertEqual(leave(15, checked: now - minutes(119), previous: start - minutes(60), now: now), start - minutes(25))
    }

    func testStaleDriveTimeOnlyMovesEarlier() {
        let now = start - minutes(180)
        let old = now - minutes(121)
        XCTAssertEqual(leave(15, checked: old, previous: start - minutes(60), now: now), start - minutes(60),
                       "an old, shorter drive time doesn't make him leave later")
        XCTAssertEqual(leave(70, checked: old, previous: start - minutes(60), now: now), start - minutes(80),
                       "an old, longer one still moves it earlier")
        XCTAssertEqual(leave(15, checked: nil, previous: start - minutes(60), now: now), start - minutes(60))
    }

    func testAnAlarmThatRangStays() {
        let now = start - minutes(30)
        XCTAssertEqual(leave(5, checked: now, previous: start - minutes(40), now: now), start - minutes(40))
    }

    func testTooLateDriveTimeRingsAMinuteAfterItCameIn() {
        // 40 min drive found 30 min before the start: ring now, not silently in the past
        let now = start - minutes(30)
        XCTAssertEqual(leave(40, checked: now, previous: nil, now: now), now + 60)
        // ...but never after the start
        XCTAssertEqual(leave(40, checked: start + 600, previous: nil, now: start + 600), start)
    }

    func testUpdateKeepsTheDriveTimeAndPicks() {
        let saved = start - 86_400
        var e = TravelTime.update(event(), minutes: 20, now: saved, restart: true)
        XCTAssertEqual(e.travelMinutes, 20)
        XCTAssertEqual(e.travelCheckedAt, saved)
        XCTAssertEqual(e.leaveAt, start - minutes(30))
        XCTAssertEqual(Planner.mainAlertText(e), "Time to leave · 20 min drive to Dentist")
        // MapKit failed: nothing changes
        XCTAssertEqual(TravelTime.update(e, minutes: nil, now: saved + 3600), e.with { $0.leaveAt = e.leaveAt })
        // a fresh one later in the day moves it
        e = TravelTime.update(e, minutes: 45, now: start - minutes(120))
        XCTAssertEqual(e.leaveAt, start - minutes(55))
        // saved again with no drive time (MapKit failed on save): the hour-before default, not the old pick
        let restarted = TravelTime.update(e, minutes: nil, now: saved, restart: true)
        XCTAssertNil(restarted.travelMinutes)
        XCTAssertEqual(EventLogic.mainAlertDate(restarted), start - minutes(60))
        // a fixed alert doesn't take a drive time
        let fixed = TravelTime.update(event(timing: .atStart), minutes: 20, now: saved, restart: true)
        XCTAssertNil(fixed.leaveAt)
        XCTAssertEqual(EventLogic.mainAlertDate(fixed), start)
    }

    func testNoPlaceMeansAtStart() {
        let e = Event(title: "Call", start: start)
        XCTAssertEqual(EventLogic.mainAlertDate(e), start)
        XCTAssertFalse(TravelTime.wantsTravel(e, now: start - 86_400))
    }

    // MARK: When to ask MapKit

    func testAskingMoreOftenAsTheAlarmComesCloser() {
        let saved = start - 7 * 86_400
        let e = TravelTime.update(event(), minutes: 20, now: saved, restart: true)  // alarm 13:30
        XCTAssertTrue(TravelTime.needsCheck(event(), now: saved), "never asked")
        XCTAssertFalse(TravelTime.needsCheck(e, now: saved + 11 * 3600))
        XCTAssertTrue(TravelTime.needsCheck(e, now: saved + 12 * 3600), "a week ahead: twice a day")
        let near = e.with { $0.travelCheckedAt = start - minutes(150) }  // alarm in 1 h at 12:30
        XCTAssertFalse(TravelTime.needsCheck(near, now: start - minutes(140)))
        XCTAssertTrue(TravelTime.needsCheck(near, now: start - minutes(90)), "an hour ahead: every 15 min")
        let last = e.with { $0.travelCheckedAt = start - minutes(45) }
        XCTAssertFalse(TravelTime.needsCheck(last, now: start - minutes(40)))
        XCTAssertTrue(TravelTime.needsCheck(last, now: start - minutes(35)), "the last minutes: every 10 min")
        // the alarm came, was answered, or the event started: never again
        XCTAssertFalse(TravelTime.needsCheck(e, now: start - minutes(30)))
        XCTAssertFalse(TravelTime.needsCheck(e.with { $0.mainAlertAnsweredAt = saved }, now: saved + 86_400))
        XCTAssertFalse(TravelTime.needsCheck(event(timing: .hourBefore), now: saved))
    }

    func testNextCheckIsBeforeTheAlarm() {
        var d = GupDoData()
        let saved = start - 86_400
        d.events = [TravelTime.update(event(), minutes: 20, now: saved, restart: true)]  // alarm 13:30
        XCTAssertEqual(TravelTime.nextCheck(d, now: saved + 3600), at(2026, 12, 10, 11, 30))
        d.events[0].travelCheckedAt = at(2026, 12, 10, 11, 30)
        XCTAssertEqual(TravelTime.nextCheck(d, now: at(2026, 12, 10, 11, 31)), at(2026, 12, 10, 12, 45))
        XCTAssertEqual(TravelTime.nextCheck(d, now: at(2026, 12, 10, 12, 50)), at(2026, 12, 10, 12, 50), "due now")
        XCTAssertEqual(TravelTime.due(d, now: at(2026, 12, 10, 12, 50)).map(\.id), [d.events[0].id])
        XCTAssertNil(TravelTime.nextCheck(d, now: at(2026, 12, 10, 13, 31)))
        XCTAssertEqual(TravelTime.departure(d.events[0], now: saved), at(2026, 12, 10, 13, 30))
        XCTAssertEqual(TravelTime.minutes(fromSeconds: 1201), 21)
        XCTAssertEqual(TravelTime.minutes(fromSeconds: 1200), 20)
    }

    func testPlannerMovesTheAlarmsWithTheDriveTime() {
        var d = GupDoData()
        let now = start - minutes(180)
        d.events = [TravelTime.update(event(), minutes: 20, now: now, restart: true)]
        let before = Planner.plan(d, now: now, calendar: cal)
        d.events[0] = TravelTime.update(d.events[0], minutes: 40, now: now + 60)
        let after = Planner.plan(d, now: now + 60, calendar: cal)
        XCTAssertEqual(before.alerts.first { $0.kind == .timeSensitive }?.fireDate, start - minutes(30))
        XCTAssertEqual(after.alerts.first { $0.kind == .timeSensitive }?.fireDate, start - minutes(50))
        // new ids: the app's alarm diff (by id) cancels the old alarms instead of keeping them
        XCTAssertTrue(Set(before.alarms.map(\.id)).isDisjoint(with: Set(after.alarms.map(\.id))))
        XCTAssertEqual(after.alarms.first?.fireDate, start - minutes(45))
    }

    func testEditedSavedPlaceIsCopiedToItsEvents() {
        var d = GupDoData()
        var gym = Place(name: "Gym", latitude: 1, longitude: 2)
        d.places = [gym]
        d.events = [TravelTime.update(Event(title: "Class", start: start, location: EventLocation(place: gym)),
                                      minutes: 12, now: start - 86_400, restart: true), event()]
        gym.name = "Gym (new)"
        var renamed = TravelTime.placeChanged(gym, data: d)
        XCTAssertEqual(renamed.events[0].location?.name, "Gym (new)")
        XCTAssertNotNil(renamed.events[0].travelCheckedAt, "only renamed: the drive time stands")
        XCTAssertEqual(renamed.events[1], d.events[1])
        gym.latitude = 1.5
        renamed = TravelTime.placeChanged(gym, data: d)
        XCTAssertEqual(renamed.events[0].location?.latitude, 1.5)
        XCTAssertTrue(TravelTime.needsCheck(renamed.events[0], now: start - 86_400 + 60), "moved: ask again")
    }

    func testOldSavedSettingsAndEventsStillLoad() throws {
        // a file from before these fields: the Settings keep their defaults, the event has no Where
        let json = #"{"settings":{"headsUpTime":{"hour":8,"minute":0},"tonightTime":{"hour":20,"minute":0},"alarmEveryMinutes":5,"alarmRepeats":12,"arrivalDelayMinutes":3,"habitSnoozeMinutes":15,"fallbackLeadMinutes":60,"planDays":15,"maxNotifications":60},"events":[{"id":"9C1D3B8E-0000-4000-8000-000000000001","title":"Old","start":800000000,"placeID":"9C1D3B8E-0000-4000-8000-000000000002","headsUps":{"normal":{}}}]}"#
        let d = try GupDoData.decode(Data(json.utf8))
        XCTAssertEqual(d.settings.headsUpTime, TimeOfDay(8, 0))
        XCTAssertEqual(d.settings.leaveBufferMinutes, 10)
        XCTAssertEqual(d.settings.freshTravelMinutes, 120)
        XCTAssertEqual(d.events.first?.title, "Old")
        XCTAssertNil(d.events.first?.location)
        XCTAssertEqual(try GupDoData.decode(d.encoded()), d)
    }

    // MARK: Arrival reminders on the saved places

    func testArrivalStartsTheNormalCycle() {
        var d = GupDoData()
        let store = Place(name: "Store", latitude: 1, longitude: 2)
        d.places = [store]
        let r = Reminder(title: "Buy milk", trigger: .arrival(placeID: store.id), createdAt: at(2026, 11, 16, 8))
        d.reminders = [r]
        // region monitoring saw the arrival at 17:58, the app got it at 18:00
        d = Presence.entered(store.id, at: at(2026, 11, 16, 17, 58), now: at(2026, 11, 16, 18), data: d, calendar: cal)
        XCTAssertEqual(d.reminders[0].due, at(2026, 11, 16, 18) + 30)
        let plan = Planner.plan(d, now: at(2026, 11, 16, 18), presence: Presence.inside(d), calendar: cal)
        XCTAssertEqual(plan.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(plan.alerts.first?.fireDate, at(2026, 11, 16, 18) + 30)
        XCTAssertEqual(plan.alerts.first?.category, .reminder)
        XCTAssertEqual(plan.alarms.first?.fireDate, at(2026, 11, 16, 18, 5) + 30)
        XCTAssertEqual(plan.alarms.count, 12)
        // Done stops it
        let done = try? ReminderLogic.answer(.done, to: d.reminders[0], now: at(2026, 11, 16, 18, 1), calendar: cal)
        XCTAssertEqual(done?.status, .done)
    }

    func testOnlyAFreshArrivalCounts() {
        var d = GupDoData()
        let home = Place(name: "Home (example)", latitude: 1, longitude: 2, isHome: true)
        d.places = [home]
        // already home when the reminder is made: it waits for the next arrival
        d = Presence.entered(home.id, at: at(2026, 11, 16, 7), data: d, calendar: cal)
        d.reminders = [Reminder(title: "Trash out", trigger: .arrival(placeID: home.id), createdAt: at(2026, 11, 16, 9))]
        d = Presence.entered(home.id, at: at(2026, 11, 16, 9, 30), data: d, calendar: cal)
        XCTAssertNil(d.reminders[0].due, "still the same stay")
        d = Presence.left(home.id, at: at(2026, 11, 16, 10), data: d, calendar: cal)
        d = Presence.entered(home.id, at: at(2026, 11, 16, 18), data: d, calendar: cal)
        XCTAssertEqual(d.reminders[0].due, at(2026, 11, 16, 18) + 30)
        // another place's arrival doesn't touch it
        var other = d
        other.reminders[0].due = nil
        other = Presence.entered(UUID(), at: at(2026, 11, 16, 19), data: other, calendar: cal)
        XCTAssertNil(other.reminders[0].due)
    }

    func testPlacesInUseCantBeDeleted() {
        var d = GupDoData()
        let home = Place(name: "Home (example)", latitude: 1, longitude: 2, isHome: true)
        d.places = [home]
        d.reminders = [Reminder(title: "Trash out", trigger: .arrival(placeID: home.id))]
        d.events = [Event(title: "Party", start: start, location: EventLocation(place: home))]
        XCTAssertEqual(PlaceUse.users(home.id, data: d), ["Trash out"])
        d.reminders[0].status = .done
        XCTAssertEqual(PlaceUse.users(home.id, data: d), [], "events keep their own copy")
    }

    // MARK: Which places region monitoring watches (iOS: 20 per app)

    func testPlaceWatchKeepsNeededPlacesUnderTheLimit() {
        var d = GupDoData()
        let now = at(2026, 11, 16, 9)
        let places = (0..<25).map { Place(name: String(format: "Place %02d", $0), latitude: 1, longitude: Double($0)) }
        d.places = places
        d.places[24].isHome = true
        // waiting on: an arrival reminder (Place 20), a habit at 18:00 today (Place 21), an event in 30 h (Place 22),
        // an event in 3 days (Place 23, no priority)
        d.reminders = [Reminder(title: "Milk", trigger: .arrival(placeID: places[20].id), createdAt: now)]
        d.habits = [Habit(name: "Read", window: TimeWindow(start: TimeOfDay(18), end: TimeOfDay(19)),
                          placeID: places[21].id, proof: .location, startDay: DayKey(now, cal))]
        d.events = [Event(title: "Soon", start: now + 30 * 3600, location: EventLocation(place: places[22])),
                    Event(title: "Later", start: now + 72 * 3600, location: EventLocation(place: places[23]))]
        let picked = PlaceWatch.pick(d, now: now, calendar: cal)
        XCTAssertEqual(picked.count, 19)
        XCTAssertEqual(picked.prefix(4).map(\.name), ["Place 20", "Place 21", "Place 22", "Place 24"],
                       "reminder (now), habit (18:00), event (48 h), then Home")
        XCTAssertEqual(picked[4].name, "Place 00")
        XCTAssertFalse(picked.contains { $0.name == "Place 23" })
        // few places: all of them
        d.places = Array(places.prefix(3))
        XCTAssertEqual(PlaceWatch.pick(d, now: now, calendar: cal).count, 3)
    }
}
