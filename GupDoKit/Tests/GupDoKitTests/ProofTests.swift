import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class ProofTests: XCTestCase {
    let today = day(2026, 11, 16)
    // An invented spot (a park in the middle of the Atlantic would do; any coordinates work).
    let place = Place(name: "Gym (example)", latitude: 40.0, longitude: -75.0, radius: 100)

    // MARK: Photo

    func testPhotoVerdict() {
        XCTAssertEqual(PhotoMatch.verdict(distance: 0), .match)
        XCTAssertEqual(PhotoMatch.verdict(distance: PhotoMatch.threshold), .match)
        XCTAssertEqual(PhotoMatch.verdict(distance: PhotoMatch.threshold + 0.01), .close)
        XCTAssertEqual(PhotoMatch.verdict(distance: PhotoMatch.threshold + PhotoMatch.closeMargin + 0.01), .noMatch)
        XCTAssertEqual(PhotoMatch.verdict(distance: .nan), .noMatch)
        XCTAssertEqual(PhotoMatch.verdict(distance: -1), .noMatch)
        XCTAssertEqual(PhotoMatch.verdict(distance: 0.3, threshold: 0.2), .close)
    }

    func testPhotoProofNeedsMatchAndLiveCamera() {
        let h = Habit(name: "x", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), proof: .photo,
                      referencePhoto: "ref.jpg", startDay: today)
        XCTAssertTrue(HabitLogic.accepts(.photo(matchesReference: true, fromLiveCamera: true), for: h))
        XCTAssertFalse(HabitLogic.accepts(.photo(matchesReference: true, fromLiveCamera: false), for: h))
        XCTAssertFalse(HabitLogic.accepts(.photo(matchesReference: false, fromLiveCamera: true), for: h))
        XCTAssertFalse(HabitLogic.accepts(.nfc(tagID: "x"), for: h))
    }

    // MARK: Location

    func testDistance() {
        // 0.001 degrees of latitude is about 111 m
        XCTAssertEqual(Geo.distance(40, -75, 40.001, -75), 111.2, accuracy: 0.5)
        XCTAssertEqual(Geo.distance(40, -75, 40, -75), 0, accuracy: 0.001)
    }

    func testIsAtPlace() {
        XCTAssertTrue(Geo.isAt(place, latitude: 40.0005, longitude: -75, accuracy: 10))   // 56 m
        XCTAssertTrue(Geo.isAt(place, latitude: 40.0011, longitude: -75, accuracy: 25))   // 122 m, fuzzy fix
        XCTAssertFalse(Geo.isAt(place, latitude: 40.0011, longitude: -75, accuracy: 5))   // 122 m, sharp fix
        XCTAssertFalse(Geo.isAt(place, latitude: 40.0015, longitude: -75, accuracy: 90))  // slack is capped
        XCTAssertFalse(Geo.isAt(place, latitude: 40, longitude: -75, accuracy: 150))      // too vague to prove
        XCTAssertFalse(Geo.isAt(place, latitude: 40, longitude: -75, accuracy: -1))       // invalid fix
    }

    func testGroupProofByLocationAndTag() {
        let other = Place(name: "Shop (example)", latitude: 41, longitude: -75)
        let w = TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8))
        let a = Habit(name: "a", window: w, placeID: place.id, proof: .location, startDay: today)
        let b = Habit(name: "b", window: w, placeID: place.id, proof: .location, startDay: today)
        let c = Habit(name: "c", window: w, placeID: other.id, proof: .location, startDay: today)
        let d = Habit(name: "d", window: w, placeID: place.id, proof: .nfc, nfcTagID: "04:a2:2b:91", startDay: today)
        let e = Habit(name: "e", window: w, placeID: place.id, proof: .photo, referencePhoto: "r", startDay: today)
        let fix = LocationFix(latitude: 40.0002, longitude: -75, accuracy: 8, time: Date())
        let byFix = ProofCheck.byLocation([a, b, c, d, e], places: [place, other], fix: fix)
        XCTAssertEqual(byFix.map(\.habit.name), ["a", "b"])
        XCTAssertTrue(byFix.allSatisfy { HabitLogic.accepts($0.evidence, for: $0.habit) })

        let byTag = ProofCheck.byTag([a, d, e], tagID: "04A22B91")
        XCTAssertEqual(byTag.map(\.habit.name), ["d"])
        XCTAssertTrue(HabitLogic.accepts(byTag[0].evidence, for: d))
        XCTAssertTrue(ProofCheck.byTag([d], tagID: "04:A2:2B:92").isEmpty)
        XCTAssertTrue(ProofCheck.byTag([d], tagID: "").isEmpty)
    }

    func testTagIDs() {
        XCTAssertEqual(NFCTagID.string([0x04, 0xA2, 0x0B]), "04:A2:0B")
        XCTAssertEqual(NFCTagID.normalized("04:a2:0b"), "04A20B")
    }

    // MARK: Driving

    func testDrivingFromMotionOrSpeed() {
        let now = at(2026, 11, 16, 7, 30)
        let driving = [MotionSample(start: now - minutes(20), automotive: false),
                       MotionSample(start: now - minutes(10), automotive: true)]
        XCTAssertTrue(Driving.isDriving(samples: driving, fix: nil, now: now))
        // a low-confidence walking guess doesn't override
        XCTAssertTrue(Driving.isDriving(samples: driving + [MotionSample(start: now - minutes(1), automotive: false,
                                                                         confident: false)], fix: nil, now: now))
        XCTAssertFalse(Driving.isDriving(samples: driving + [MotionSample(start: now - minutes(1), automotive: false)],
                                         fix: nil, now: now))
        XCTAssertFalse(Driving.isDriving(samples: [], fix: nil, now: now))
        // GPS speed backs it up: 15 m/s with a good fix, recent
        let fast = LocationFix(latitude: 0, longitude: 0, accuracy: 10, speed: 15, time: now - 30)
        XCTAssertTrue(Driving.isDriving(samples: [], fix: fast, now: now))
        var old = fast; old.time = now - minutes(5)
        XCTAssertFalse(Driving.isDriving(samples: [], fix: old, now: now))
        var slow = fast; slow.speed = 1.5
        XCTAssertFalse(Driving.isDriving(samples: [], fix: slow, now: now))
    }

    func testDrivingStops() {
        let pause = at(2026, 11, 16, 7, 10)
        let samples = [MotionSample(start: at(2026, 11, 16, 7, 0), automotive: true),
                       MotionSample(start: at(2026, 11, 16, 7, 20), automotive: false, stationary: true),
                       MotionSample(start: at(2026, 11, 16, 7, 21), automotive: true),   // just a red light
                       MotionSample(start: at(2026, 11, 16, 7, 30), automotive: false)]
        // still in the first two minutes of walking: not sure yet
        XCTAssertNil(Driving.stoppedAt(samples: samples, since: pause, now: at(2026, 11, 16, 7, 31)))
        XCTAssertEqual(Driving.stoppedAt(samples: samples, since: pause, now: at(2026, 11, 16, 7, 33)),
                       at(2026, 11, 16, 7, 30))
        // nothing after the last drive yet
        XCTAssertNil(Driving.stoppedAt(samples: Array(samples.prefix(3)), since: pause, now: at(2026, 11, 16, 7, 40)))
    }

    func testDrivingPauseEndsFromMotion() throws {
        var d = GupDoData()
        let h = Habit(name: "x", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), startDay: today)
        d.habits = [h]
        d = try Answers.apply(.habit(h.id, .cantRightNow(.driving)), to: d,
                              context: PhoneContext(isDriving: true), now: at(2026, 11, 16, 7, 5), calendar: cal)
        XCTAssertEqual(DrivingPauses.open(d, now: at(2026, 11, 16, 7, 6), calendar: cal).count, 1)
        XCTAssertTrue(Planner.plan(d, now: at(2026, 11, 16, 7, 6), calendar: cal).alerts
            .allSatisfy { $0.fireDate >= at(2026, 11, 17) })
        let samples = [MotionSample(start: at(2026, 11, 16, 6, 50), automotive: true),
                       MotionSample(start: at(2026, 11, 16, 7, 20), automotive: false)]
        let now = at(2026, 11, 16, 7, 24)
        d = DrivingPauses.end(d, samples: samples, now: now, calendar: cal)
        XCTAssertEqual(d.history[h.id, today].pauses.last?.end, now)
        XCTAssertTrue(DrivingPauses.open(d, now: now, calendar: cal).isEmpty)
        // it rings again a minute after the phone noticed, with a fresh Time Sensitive notification
        let next = Planner.plan(d, now: now, calendar: cal).alerts.filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertEqual(next.first?.fireDate, at(2026, 11, 16, 7, 25))
        XCTAssertEqual(next.first?.kind, .timeSensitive)

        // stationary location updates also end it
        var e = GupDoData()
        e.habits = [h]
        e = try Answers.apply(.habit(h.id, .cantRightNow(.driving)), to: e,
                              context: PhoneContext(isDriving: true), now: at(2026, 11, 16, 7, 5), calendar: cal)
        XCTAssertEqual(DrivingPauses.end(e, samples: [], stationarySince: at(2026, 11, 16, 7, 23), now: now,
                                         calendar: cal).history[h.id, today].pauses.last?.end, nil)
        XCTAssertEqual(DrivingPauses.end(e, samples: [], stationarySince: at(2026, 11, 16, 7, 21), now: now,
                                         calendar: cal).history[h.id, today].pauses.last?.end, now)
    }
}
