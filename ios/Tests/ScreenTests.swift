import SwiftUI
import UIKit
import XCTest
@testable import GupDo

/// Pictures of the real screens with invented example data at a fixed moment, rendered inside the unit-test process
/// (seconds per screen). Each one is attached to the run (xcresult) and written to $SHOTS_DIR when the runner sets it.
@MainActor
final class ScreenTests: XCTestCase {
    let cal = Calendar.current
    lazy var today = DayKey(cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!, cal)
    func at(_ h: Int, _ m: Int = 0, plus days: Int = 0) -> Date { today.adding(days: days, cal).at(TimeOfDay(h, m), cal) }
    lazy var now = at(10, 7)

    /// A believable day: a ringing reminder, habits done / coming / Quiet, events today and ahead. All invented.
    func dayData(ringing: Bool = true) -> GupDoData {
        var d = GupDoData()
        var call = Reminder(title: "Call the garage", trigger: .time(at(10, 1)), note: "Ask about the brakes", createdAt: at(8))
        call.laterCount = 1
        let bins = Reminder(title: "Put the bins out", trigger: .time(at(19)), createdAt: at(8))
        d.reminders = ringing ? [call, bins] : [bins]
        let stretch = Habit(name: "Stretch", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)),
                            referencePhoto: "x", startDay: today.adding(days: -20, cal))
        let read = Habit(name: "Read 10 pages", window: TimeWindow(start: TimeOfDay(21), end: TimeOfDay(22)),
                         referencePhoto: "x", startDay: today.adding(days: -9, cal))
        let plants = Habit(name: "Water the plants", window: TimeWindow(start: TimeOfDay(17), end: TimeOfDay(19)),
                           referencePhoto: "x", startDay: today.adding(days: -80, cal))
        d.habits = [stretch, read, plants]
        for back in 1...80 {
            let day = today.adding(days: -back, cal)
            if back <= 20, back != 2 { d.history[stretch.id, day].provedAt = day.at(TimeOfDay(7, 20), cal) }
            if back <= 9, back % 4 != 0 { d.history[read.id, day].provedAt = day.at(TimeOfDay(21, 10), cal) }
            d.history[plants.id, day].provedAt = day.at(TimeOfDay(17, 30), cal)
        }
        d.history[stretch.id, today].provedAt = at(7, 12)
        d.events = [
            Event(title: "Coffee with Sam", start: at(15), end: at(16)),
            Event(title: "Team lunch", start: at(12, 30, plus: 1)),
            Event(title: "Dentist", start: at(14, plus: 6), end: at(15, plus: 6)),
            Event(title: "Flight to Denver", start: at(7, 45, plus: 19), headsUps: .big),
        ]
        return d
    }

    func testMainScreenRinging() {
        let m = AppModel(preview: dayData(), now: now, calendar: cal)
        XCTAssertEqual(m.nowCard?.title, "Call the garage")
        XCTAssertEqual(m.nowCard?.ringing, true)
        shot("1-main-ringing-reminder", m, RootView())
    }

    func testMainScreenScrolledToEnd() {
        // the last Upcoming row scrolls clear of the Add button
        shot("1b-main-scrolled-to-end", AppModel(preview: dayData(), now: now, calendar: cal), RootView(scrolledToEnd: true))
    }

    func testMainScreenNext() {
        let m = AppModel(preview: dayData(ringing: false), now: now, calendar: cal)
        XCTAssertEqual(m.nowCard?.ringing, false)
        shot("2-main-next", m, RootView())
    }

    func testMainScreenHabitGroup() {
        var d = dayData(ringing: false)
        let a = Habit(name: "Vitamins", window: TimeWindow(start: TimeOfDay(10), end: TimeOfDay(11)), referencePhoto: "x", startDay: today)
        let b = Habit(name: "Make the bed", window: TimeWindow(start: TimeOfDay(10), end: TimeOfDay(11)), referencePhoto: "x", startDay: today)
        d.habits += [a, b]
        let m = AppModel(preview: d, now: now, calendar: cal)
        XCTAssertEqual(m.nowCard?.itemIDs, [a.id, b.id])
        shot("3-main-habit-group", m, RootView())
        shot("9-proof-checklist", m, AnswerSheet(screen: .proof([a.id, b.id])))
        shot("10-habit-not-now", m, AnswerSheet(screen: .answers(.habit, [a.id, b.id])))
    }

    func testMainScreenEmpty() {
        shot("4-main-empty", AppModel(preview: GupDoData(), now: now, calendar: cal), RootView())
    }

    func testAddReminder() {
        shot("5-add-reminder", AppModel(preview: dayData(), now: now, calendar: cal), AddSheet())
    }

    func testAddHabit() {
        shot("6-add-habit", AppModel(preview: dayData(), now: now, calendar: cal), AddSheet(kind: .habit))
    }

    func testAddEventWarnsAboutAClash() {
        var d = dayData()
        // the new event's default (tomorrow at 11) overlaps this one
        d.events.append(Event(title: "Car service", start: at(10, 30, plus: 1), end: at(12, plus: 1)))
        shot("7-add-event-clash", AppModel(preview: d, now: now, calendar: cal), AddSheet(kind: .event))
    }

    func testLaterPicker() {
        let d = dayData()
        let m = AppModel(preview: d, now: now, calendar: cal)
        shot("8-later-picker", m, AnswerSheet(screen: .answers(.reminder, [d.reminders[0].id])))
    }

    func testAfterThirdLater() {
        var d = dayData()
        d.reminders[0].laterCount = 3
        let m = AppModel(preview: d, now: now, calendar: cal)
        shot("11-after-3rd-later", m, AnswerSheet(screen: .answers(.reminder, [d.reminders[0].id])))
    }

    func testProofChecklistWithEachKind() {
        var d = dayData(ringing: false)
        let home = Place(name: "Home", latitude: 40, longitude: -75, radius: 150, isHome: true)
        d.places = [home]
        let w = TimeWindow(start: TimeOfDay(10), end: TimeOfDay(11))
        let a = Habit(name: "Make the bed", window: w, placeID: home.id, proof: .photo, referencePhoto: "x", startDay: today)
        let b = Habit(name: "Water the herbs", window: w, placeID: home.id, proof: .location, startDay: today)
        let c = Habit(name: "Vitamins", window: w, placeID: home.id, proof: .nfc, nfcTagID: "04:A2:2B:91", startDay: today)
        d.habits += [a, b, c]
        d.visits = [PlaceVisit(placeID: home.id, arrived: at(6))]
        d.history[b.id, today].provedAt = at(10, 4)
        let m = AppModel(preview: d, now: now, calendar: cal)
        shot("13-proof-each-kind", m, AnswerSheet(screen: .proof([a.id, b.id, c.id])))
    }

    func testHabitAnswersWhileDriving() {
        var d = dayData(ringing: false)
        let a = Habit(name: "Vitamins", window: TimeWindow(start: TimeOfDay(10), end: TimeOfDay(11)), referencePhoto: "x", startDay: today)
        d.habits.append(a)
        let m = AppModel(preview: d, now: now, calendar: cal, isDriving: true)
        shot("14-habit-driving", m, AnswerSheet(screen: .answers(.habit, [a.id])))
    }

    func testHabitEditorWithReferencePhotoAndPlace() {
        var d = dayData()
        let home = Place(name: "Home", latitude: 40, longitude: -75, radius: 150, isHome: true)
        d.places = [home]
        let photos = PhotoStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID())"))
        var h = Habit(name: "Brush teeth", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), placeID: home.id,
                      proof: .photo, startDay: today)
        h.referencePhoto = PhotoMatch.referenceFileName(for: h.id)
        let url = Bundle(for: ScreenTests.self).url(forResource: "sink-ref", withExtension: "jpg")!
        XCTAssertTrue(photos.save(UIImage(contentsOfFile: url.path)!, as: h.referencePhoto!))
        d.habits.append(h)
        let m = AppModel(preview: d, now: now, calendar: cal, photos: photos)
        shot("15-habit-reference-photo", m, HabitForm(editing: h))
    }

    func testPlaceEditor() {
        var d = dayData()
        let home = Place(name: "Home", latitude: 40.7484, longitude: -73.9857, radius: 150, isHome: true)
        d.places = [home]
        d.visits = [PlaceVisit(placeID: home.id, arrived: at(6))]
        let m = AppModel(preview: d, now: now, calendar: cal)
        shot("16-place-editor", m, NavigationStack { PlaceEditor(original: home) })
        shot("17-everything-places", m, EverythingView())
    }

    func testEverything() {
        shot("12-everything", AppModel(preview: dayData(), now: now, calendar: cal), EverythingView())
    }

    // MARK: Rendering

    private func shot<V: View>(_ name: String, _ model: AppModel, _ view: V) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = UIHostingController(rootView: view.environment(model))
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        XCTAssertGreaterThan(image.size.width, 0)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOTS_DIR"], let png = image.pngData() {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
