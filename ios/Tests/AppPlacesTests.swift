import XCTest
@testable import GupDo

/// Answers drive-time questions with a set number of minutes (nil: unknown), and counts them.
@MainActor
final class FakeDrive: DriveTimes {
    var minutes: Int?
    var asked: [(place: EventLocation, departure: Date)] = []
    init(_ minutes: Int?) { self.minutes = minutes }
    func minutes(to place: EventLocation, departure: Date) async -> Int? {
        asked.append((place, departure))
        return minutes
    }
}

/// Places for reminders and events in the app: an arrival from region monitoring rings an arrival reminder, an event
/// with a Where gets its time-to-leave alarm from the drive time on save and as it comes closer, and region
/// monitoring watches the places that matter (at most 19).
@MainActor
final class AppPlacesTests: XCTestCase {
    let cal = Calendar.current
    lazy var day = DayKey(cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!, cal)
    func at(_ h: Int, _ m: Int = 0, plus days: Int = 0) -> Date { day.adding(days: days, cal).at(TimeOfDay(h, m), cal) }
    let store = Place(name: "Store (example)", latitude: 40.01, longitude: -75.01, radius: 150)
    let dentist = EventLocation(name: "Dentist (example)", address: "1 Example St", latitude: 40.1, longitude: -75.2)

    func model(_ d: GupDoData, now: Date, sensors: FakeSensors? = nil, drive: FakeDrive? = nil,
               fake: FakeScheduler) -> AppModel {
        AppModel(store: .memory(d), scheduler: fake, clock: .fixed(now), calendar: cal, sensors: sensors, drive: drive)
    }

    // MARK: When I arrive

    func testArrivalRingsTheReminderTimeSensitiveThenAlarms() async {
        var d = GupDoData()
        d.places = [store]
        let r = Reminder(title: "Buy milk", trigger: .arrival(placeID: store.id), createdAt: at(8))
        d.reminders = [r]
        let sensors = FakeSensors(), fake = FakeScheduler()
        let m = model(d, now: at(17, 30), sensors: sensors, fake: fake)
        await m.refresh()
        XCTAssertEqual(sensors.watched.map(\.id), [store.id])
        var plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts, [], "waiting for the arrival")
        // CLMonitor reports the arrival (the app may hear of it a little later)
        await m.regionEvent(place: store.id, inside: true, at: at(17, 29))
        plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(plan?.alerts.first?.fireDate, at(17, 30) + 30)
        XCTAssertEqual(plan?.alerts.first?.category, .reminder)
        XCTAssertEqual(plan?.alarms.first?.fireDate, at(17, 35) + 30)
        // Done from the notification stops it
        let alert = plan!.alerts[0]
        await m.handle(.done, AlertPayload(alert))
        XCTAssertEqual(m.reminder(r.id)?.status, .done)
        plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts, [])
    }

    func testAPlaceWithAWaitingReminderCantBeDeleted() async {
        var d = GupDoData()
        d.places = [store]
        d.reminders = [Reminder(title: "Buy milk", trigger: .arrival(placeID: store.id), createdAt: at(8))]
        let m = model(d, now: at(9), fake: FakeScheduler())
        let deleted = await m.deletePlace(store.id)
        XCTAssertFalse(deleted)
        XCTAssertEqual(m.notice, "Used by Buy milk. Change those first.")
        XCTAssertEqual(m.data.places.count, 1)
    }

    func testRegionMonitoringWatchesAtMost19NeededFirst() async {
        var d = GupDoData()
        d.places = (0..<22).map { Place(name: String(format: "Place %02d", $0), latitude: 40, longitude: -75 + Double($0) / 100) }
        d.reminders = [Reminder(title: "Buy milk", trigger: .arrival(placeID: d.places[21].id), createdAt: at(8))]
        let sensors = FakeSensors()
        let m = model(d, now: at(9), sensors: sensors, fake: FakeScheduler())
        await m.refresh()
        XCTAssertEqual(sensors.watched.count, 19)
        XCTAssertEqual(sensors.watched.first?.name, "Place 21")
    }

    // MARK: Time to leave

    func testSavingAnEventWithAWhereSchedulesTimeToLeaveFromTheDriveTime() async {
        let drive = FakeDrive(25), fake = FakeScheduler()
        let m = model(GupDoData(), now: at(9), drive: drive, fake: fake)
        let e = Event(title: "Dentist", start: at(14, plus: 1), location: dentist)
        await m.save(e)
        let saved = m.event(e.id)!
        XCTAssertEqual(saved.travelMinutes, 25)
        XCTAssertEqual(saved.travelCheckedAt, at(9))
        // 25 min drive + 10 min buffer
        XCTAssertEqual(EventLogic.mainAlertDate(saved), at(13, 25, plus: 1))
        XCTAssertEqual(drive.asked.count, 1)
        XCTAssertEqual(drive.asked.first?.place, dentist)
        let plan = await fake.plans.last
        let ts = plan?.alerts.first { $0.kind == .timeSensitive }
        XCTAssertEqual(ts?.fireDate, at(13, 25, plus: 1))
        XCTAssertEqual(ts?.body, "Time to leave · 25 min drive to Dentist (example)")
        XCTAssertEqual(plan?.alarms.first?.fireDate, at(13, 30, plus: 1))
    }

    func testUnknownDriveTimeIsAnHourBefore() async {
        let fake = FakeScheduler()
        let m = model(GupDoData(), now: at(9), drive: FakeDrive(nil), fake: fake)
        let e = Event(title: "Dentist", start: at(14, plus: 1), location: dentist)
        await m.save(e)
        XCTAssertEqual(EventLogic.mainAlertDate(m.event(e.id)!), at(13, plus: 1))
        let ts = await fake.plans.last?.alerts.first { $0.kind == .timeSensitive }
        XCTAssertEqual(ts?.fireDate, at(13, plus: 1))
    }

    func testTheDriveTimeIsAskedAgainAsTheAlarmComesCloser() async {
        // saved yesterday with a 20 min drive; this morning traffic says 40
        var d = GupDoData()
        let e = TravelTime.update(Event(title: "Dentist", start: at(14), location: dentist), minutes: 20,
                                  now: at(9, plus: -1), restart: true)
        d.events = [e]
        let drive = FakeDrive(40), fake = FakeScheduler()
        let m = model(d, now: at(11, 40), drive: drive, fake: fake)
        await m.refresh()
        XCTAssertEqual(drive.asked.count, 1)
        XCTAssertEqual(EventLogic.mainAlertDate(m.event(e.id)!), at(13, 10))
        let ts = await fake.plans.last?.alerts.first { $0.kind == .timeSensitive }
        XCTAssertEqual(ts?.fireDate, at(13, 10))
        // just asked: an answer right after doesn't ask MapKit again
        await m.replan()
        XCTAssertEqual(drive.asked.count, 1)
        // the background refresh is asked for before the alarm (2 h before it already passed: 45 min before)
        XCTAssertEqual(m.nextWake, at(12, 25))
    }

    func testEditingTheSavedPlaceMovesItsEvents() async {
        var d = GupDoData()
        var gym = Place(name: "Gym", latitude: 40, longitude: -75)
        d.places = [gym]
        d.events = [Event(title: "Class", start: at(18), location: EventLocation(place: gym))]
        let m = model(d, now: at(9), fake: FakeScheduler())
        gym.name = "Gym (new)"
        gym.latitude = 40.5
        await m.save(gym)
        XCTAssertEqual(m.data.events[0].location?.name, "Gym (new)")
        XCTAssertEqual(m.data.events[0].location?.latitude, 40.5)
    }
}
