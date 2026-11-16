import UIKit
import Vision
import XCTest
@testable import GupDo

/// Stands in for the phone's sensors: places entered by hand, a fixed location fix, fixed motion activities.
@MainActor
final class FakeSensors: PhoneSensors {
    var watched: [Place] = []
    var onRegion: (@MainActor (UUID, Bool, Date) -> Void)?
    var fix: LocationFix?
    var samples: [MotionSample] = []
    var following = false
    var lastFix: LocationFix?

    func watch(_ places: [Place], onRegion: @escaping @MainActor (UUID, Bool, Date) -> Void) async {
        watched = places
        self.onRegion = onRegion
    }
    func currentFix(timeout: TimeInterval) async -> LocationFix? { fix }
    func motionSamples(from: Date, to: Date) async -> [MotionSample] { samples.filter { $0.start <= to } }
    func followDriving(_ on: Bool, onUpdate: @escaping @MainActor (Date?) -> Void) { following = on }
    func requestPermissions() {}
}

/// The photo set in Fixtures/PhotoMatch (all invented): four spots, each a reference and two retakes on another day
/// (moved camera, other light, things moved), and six other rooms, two of them look-alike bathrooms.
enum PhotoFixtures {
    static let spots = ["sink", "kitchen", "desk", "bedside"]
    static let others = (1...6).map { "other-\($0)" }

    static func image(_ name: String) -> UIImage {
        let url = Bundle(for: FakeSensors.self).url(forResource: name, withExtension: "jpg")!
        return UIImage(contentsOfFile: url.path)!
    }

    /// A temporary photo folder.
    static func store() -> PhotoStore {
        PhotoStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)"))
    }

    // Handheld differences made from a photo: a step closer, tilted, darker, blurred.
    static func closer(_ i: UIImage) -> UIImage { crop(i, 0.8) }
    static func crop(_ i: UIImage, _ f: CGFloat) -> UIImage {
        let w = i.size.width * f, h = i.size.height * f
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            i.draw(at: CGPoint(x: -(i.size.width - w) / 2, y: -(i.size.height - h) / 2))
        }
    }
    static func tilted(_ i: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: i.size).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: i.size.width / 2, y: i.size.height / 2)
            c.rotate(by: 5 * .pi / 180)
            c.scaleBy(x: 1.12, y: 1.12)
            i.draw(at: CGPoint(x: -i.size.width / 2, y: -i.size.height / 2))
        }
    }
    static func darker(_ i: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: i.size).image { ctx in
            i.draw(at: .zero)
            UIColor.black.withAlphaComponent(0.4).setFill()
            ctx.fill(CGRect(origin: .zero, size: i.size))
        }
    }
}

/// Proof in the app: region events, location proof, NFC tag proof, photo proof with Vision on the simulator, and the
/// tuning of the photo threshold on the fixture set.
@MainActor
final class AppProofTests: XCTestCase {
    let cal = Calendar.current
    lazy var day = DayKey(cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!, cal)
    func at(_ h: Int, _ m: Int = 0) -> Date { day.at(TimeOfDay(h, m), cal) }
    let home = Place(name: "Home (example)", latitude: 40, longitude: -75, radius: 150, isHome: true)

    func model(_ d: GupDoData, now: Date, sensors: FakeSensors, fake: FakeScheduler = FakeScheduler(),
               photos: PhotoStore = PhotoFixtures.store()) -> AppModel {
        AppModel(store: .memory(d), scheduler: fake, clock: .fixed(now), calendar: cal, sensors: sensors, photos: photos)
    }

    // MARK: Places and arrival

    func testArrivalDuringTheWindowRingsThreeMinutesLater() async {
        var d = GupDoData()
        d.places = [home]
        let h = Habit(name: "Stretch", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(9)), placeID: home.id,
                      proof: .location, startDay: day)
        d.habits = [h]
        let sensors = FakeSensors(), fake = FakeScheduler()
        let m = model(d, now: at(7, 40), sensors: sensors, fake: fake)
        await m.refresh()
        XCTAssertEqual(sensors.watched.map(\.id), [home.id], "every saved place is watched")
        var plan = await fake.plans.last
        XCTAssertTrue(plan?.alerts.allSatisfy { $0.fireDate > at(23) } ?? false, "away: silent today")
        await m.regionEvent(place: home.id, inside: true, at: at(7, 40))
        plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts.first?.fireDate, at(7, 43))
        XCTAssertEqual(plan?.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(m.nowCard?.itemIDs, [h.id])
        // at home, Can't right now isn't offered; once he leaves it is
        XCTAssertFalse(Answers.habitChoices(h, data: m.data, context: m.phoneContext, now: at(7, 44), calendar: cal)
            .contains(.cantRightNow))
        await m.regionEvent(place: home.id, inside: false, at: at(7, 50))
        XCTAssertTrue(Answers.habitChoices(h, data: m.data, context: m.phoneContext, now: at(7, 50), calendar: cal)
            .contains(.cantRightNow))
    }

    func testCantRightNowWhileDrivingFromMotion() async {
        var d = GupDoData()
        let h = Habit(name: "Read", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(9)), startDay: day)
        d.habits = [h]
        let sensors = FakeSensors(), fake = FakeScheduler()
        let m = model(d, now: at(7, 10), sensors: sensors, fake: fake)
        await m.updateDriving()
        XCTAssertFalse(m.phoneContext.isDriving)
        sensors.samples = [MotionSample(start: at(6, 55), automotive: true)]
        await m.updateDriving()
        XCTAssertTrue(m.phoneContext.isDriving)
        let alarm = Planner.plan(d, now: at(7, 10), calendar: cal).alarms[0]
        await m.handle(.cantRightNow, AlertPayload(alarm))
        XCTAssertEqual(m.data.history[h.id, day].pauses.last?.reason, .driving)
        XCTAssertTrue(sensors.following, "follows the drive to see when it stops")
        // stops driving: the next wake ends the pause and it rings again
        sensors.samples.append(MotionSample(start: at(7, 20), automotive: false))
        let later = model(m.data, now: at(7, 25), sensors: sensors, fake: fake)
        await later.refresh()
        XCTAssertEqual(later.data.history[h.id, day].pauses.last?.end, at(7, 25))
        XCTAssertFalse(sensors.following)
        let plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts.first?.fireDate, at(7, 26))
        XCTAssertEqual(plan?.alerts.first?.kind, .timeSensitive)
    }

    // MARK: Location and NFC proof

    func testLocationProofProvesTheGroupsLocationHabitsAtThePlace() async {
        var d = GupDoData()
        d.places = [home]
        let w = TimeWindow(start: TimeOfDay(7), end: TimeOfDay(9))
        let a = Habit(name: "Plants", window: w, placeID: home.id, proof: .location, startDay: day)
        let b = Habit(name: "Vitamins", window: w, placeID: home.id, proof: .nfc, nfcTagID: "04:A2:2B:91", startDay: day)
        d.habits = [a, b]
        let sensors = FakeSensors()
        let m = model(d, now: at(7, 30), sensors: sensors)
        sensors.fix = LocationFix(latitude: 40.01, longitude: -75, accuracy: 10, time: at(7, 30))  // 1.1 km away
        guard case .notThere = await m.proveLocation([a.id, b.id]) else { return XCTFail() }
        XCTAssertFalse(Answers.isProved(a, data: m.data, now: at(7, 30), calendar: cal))
        sensors.fix = LocationFix(latitude: 40.0003, longitude: -75, accuracy: 12, time: at(7, 30))
        let result = await m.proveLocation([a.id, b.id])
        XCTAssertEqual(result, .proved([a.id]))
        XCTAssertEqual(m.unproved([a.id, b.id]).map(\.id), [b.id])
        // the tag: a wrong one is refused, the right one (any case/format) proves it
        let wrong = await m.proveTag([a.id, b.id], tagID: "04:A2:2B:92")
        XCTAssertEqual(wrong, .wrongTag)
        let right = await m.proveTag([a.id, b.id], tagID: "04a22b91")
        XCTAssertEqual(right, .proved([b.id]))
        XCTAssertTrue(m.unproved([a.id, b.id]).isEmpty)
    }

    // MARK: Photo proof

    func testPhotoProofMatchesTheSpotAndRefusesAnotherRoom() async throws {
        var d = GupDoData()
        let photos = PhotoFixtures.store()
        let h = Habit(name: "Brush teeth", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(9)), proof: .photo,
                      referencePhoto: PhotoMatch.referenceFileName(for: UUID()), startDay: day)
        XCTAssertTrue(photos.save(PhotoFixtures.image("sink-ref"), as: h.referencePhoto!))
        d.habits = [h]
        let m = model(d, now: at(7, 30), sensors: FakeSensors(), photos: photos)
        let other = await m.provePhoto(h.id, photo: PhotoFixtures.image("other-6"))
        guard case .photoNoMatch = other else { return XCTFail("a look-alike bathroom passed: \(other)") }
        XCTAssertFalse(Answers.isProved(h, data: m.data, now: at(7, 30), calendar: cal))
        let same = await m.provePhoto(h.id, photo: PhotoFixtures.image("sink-again-a"))
        XCTAssertEqual(same, .proved([h.id]))
    }

    /// Tunes `PhotoMatch.threshold`: every retake of a spot (and the same photo a step closer, tilted, darker) must
    /// pass against its reference; every other spot and room must fail. Writes the distances to photo-match.txt.
    func testPhotoThresholdSeparatesSameSpotFromOtherRooms() async throws {
        var prints: [String: FeaturePrintObservationBox] = [:]
        func fp(_ name: String, _ image: UIImage) async throws -> FeaturePrintObservationBox {
            if let p = prints[name] { return p }
            let p = FeaturePrintObservationBox(try await PhotoMatcher.featurePrint(image))
            prints[name] = p
            return p
        }
        var same: [(String, Double)] = [], different: [(String, Double)] = []
        for spot in PhotoFixtures.spots {
            let ref = PhotoFixtures.image("\(spot)-ref")
            let r = try await fp("\(spot)-ref", ref)
            var probes: [(String, UIImage)] = [("\(spot)-again-a", PhotoFixtures.image("\(spot)-again-a")),
                                               ("\(spot)-again-b", PhotoFixtures.image("\(spot)-again-b"))]
            probes += [("\(spot)-ref closer", PhotoFixtures.closer(ref)), ("\(spot)-ref tilted", PhotoFixtures.tilted(ref)),
                       ("\(spot)-ref darker", PhotoFixtures.darker(ref)),
                       ("\(spot)-again-a tilted", PhotoFixtures.tilted(PhotoFixtures.image("\(spot)-again-a")))]
            for (name, image) in probes {
                same.append(("\(spot)-ref vs \(name)", try r.value.distance(to: try await fp(name, image).value)))
            }
            let strangers = PhotoFixtures.spots.filter { $0 != spot }.flatMap { ["\($0)-ref", "\($0)-again-a"] }
                + PhotoFixtures.others
            for name in strangers {
                different.append(("\(spot)-ref vs \(name)",
                                  try r.value.distance(to: try await fp(name, PhotoFixtures.image(name)).value)))
            }
        }
        let maxSame = same.map(\.1).max()!, minDifferent = different.map(\.1).min()!
        var report = "threshold \(PhotoMatch.threshold); same spot max \(fmt(maxSame)), other rooms min \(fmt(minDifferent))\n"
        report += "\nsame spot (must be <= threshold):\n"
        for (n, v) in same.sorted(by: { $0.1 > $1.1 }) { report += "  \(fmt(v))  \(n)\n" }
        report += "\nother rooms (must be > threshold):\n"
        for (n, v) in different.sorted(by: { $0.1 < $1.1 }) { report += "  \(fmt(v))  \(n)\n" }
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "photo-match.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? report.write(toFile: dir + "/photo-match.txt", atomically: true, encoding: .utf8)
        }
        for (n, v) in same { XCTAssertLessThanOrEqual(v, PhotoMatch.threshold, "should match: \(n)") }
        for (n, v) in different { XCTAssertGreaterThan(v, PhotoMatch.threshold, "should not match: \(n)") }
    }

    private func fmt(_ v: Double) -> String { String(format: "%.3f", v) }
}

/// FeaturePrintObservation in a reference box (for a dictionary cache).
final class FeaturePrintObservationBox {
    let value: FeaturePrintObservation
    init(_ v: FeaturePrintObservation) { value = v }
}
