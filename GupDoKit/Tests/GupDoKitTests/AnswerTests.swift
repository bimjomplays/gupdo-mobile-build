import Foundation
import XCTest
#if canImport(GupDoKit)
@testable import GupDoKit
#else
@testable import GupDo
#endif

final class AnswerTests: XCTestCase {
    let today = day(2026, 11, 16)
    let ctx = PhoneContext()

    func reminderData(due: Date) -> (GupDoData, Reminder) {
        var d = GupDoData()
        let r = Reminder(title: "Call", trigger: .time(due), createdAt: due - 3600)
        d.reminders = [r]
        return (d, r)
    }

    func payload(_ alert: PlannedAlert?) -> AlertPayload { AlertPayload(alert!) }

    // MARK: Answering stops the escalation

    func testDoneFromNotificationStopsAlarms() throws {
        let due = at(2026, 11, 16, 10)
        let (d, r) = reminderData(due: due)
        let now = due + minutes(7)
        let before = Planner.plan(d, now: now, calendar: cal)
        XCTAssertEqual(before.alarms.count, 11)
        let res = AlertActions.resolve(.done, payload: payload(before.alarms.first), data: d, context: ctx, now: now,
                                       calendar: cal)
        guard case .apply(let answers) = res else { return XCTFail("\(res)") }
        let after = try Answers.apply(answers[0], to: d, now: now, calendar: cal)
        XCTAssertEqual(after.reminders[0].status, .done)
        XCTAssertTrue(Planner.plan(after, now: now, calendar: cal).alerts.isEmpty)
        // The alarm sync cancels every alarm that was pending.
        let sync = AlarmSync.diff(plan: Planner.plan(after, now: now, calendar: cal),
                                  existing: before.alarms.map { StableID.uuid($0.id) })
        XCTAssertEqual(sync.cancel.count, 11)
        XCTAssertTrue(sync.schedule.isEmpty)
        _ = r
    }

    func testLaterFromNotificationStartsOverAndThirdLaterGoesFinal() throws {
        let due = at(2026, 11, 16, 10)
        var (d, r) = reminderData(due: due)
        var now = due + minutes(1)
        for n in 1...3 {
            let p = Planner.plan(d, now: now, calendar: cal)
            let res = AlertActions.resolve(.later15, payload: payload(p.alarms.first), data: d, context: ctx, now: now,
                                           calendar: cal)
            guard case .apply(let a) = res else { return XCTFail("later \(n): \(res)") }
            d = try Answers.apply(a[0], to: d, now: now, calendar: cal)
            r = d.reminders[0]
            XCTAssertEqual(r.due, now + minutes(15))
            XCTAssertEqual(r.laterCount, n)
            now = r.due! + minutes(1)
        }
        let p = Planner.plan(d, now: now - minutes(2), calendar: cal)
        XCTAssertEqual(p.alerts.first?.category, .reminderFinal)
        XCTAssertEqual(AlertActions.actions(for: .reminderFinal), [.done, .pickDay, .delete])
        // A 4th Later from an old notification shows the final choices instead of failing.
        let old = AlertPayload(alertID: "x", itemKind: .reminder, itemIDs: [r.id], category: .reminder)
        XCTAssertEqual(AlertActions.resolve(.later60, payload: old, data: d, context: ctx, now: now, calendar: cal),
                       .show(.answers(.reminder, [r.id])))
        XCTAssertEqual(AlertActions.resolve(.pickDay, payload: payload(p.alerts.first), data: d, context: ctx,
                                            now: now, calendar: cal), .show(.pickDay(r.id)))
        guard case .apply(let del) = AlertActions.resolve(.delete, payload: payload(p.alerts.first), data: d,
                                                          context: ctx, now: now, calendar: cal)
        else { return XCTFail() }
        d = try Answers.apply(del[0], to: d, now: now, calendar: cal)
        XCTAssertEqual(d.reminders[0].status, .deleted)
        XCTAssertTrue(Planner.plan(d, now: now, calendar: cal).alerts.isEmpty)
        // Gone: nothing to do.
        XCTAssertEqual(AlertActions.resolve(.done, payload: old, data: d, context: ctx, now: now, calendar: cal), .nothing)
    }

    func testPickTimeAndTonight() throws {
        let due = at(2026, 11, 16, 19, 50)
        let (d, r) = reminderData(due: due)
        let p = AlertPayload(alertID: "x", itemKind: .reminder, itemIDs: [r.id], category: .reminder)
        XCTAssertEqual(AlertActions.resolve(.pickTime, payload: p, data: d, context: ctx, now: due, calendar: cal),
                       .show(.pickTime(r.id)))
        // Tonight (8pm) is 10 minutes away: the picker instead.
        XCTAssertEqual(AlertActions.resolve(.tonight, payload: p, data: d, context: ctx, now: due, calendar: cal),
                       .show(.pickTime(r.id)))
        XCTAssertEqual(AlertActions.resolve(.tonight, payload: p, data: d, context: ctx, now: at(2026, 11, 16, 12),
                                            calendar: cal), .apply([.reminder(r.id, .later(.tonight))]))
        // The notification's own buttons leave Tonight out near 8pm.
        let alert = Planner.plan(d, now: due - 60, calendar: cal).alerts[0]
        XCTAssertEqual(AlertActions.categoryID(for: alert, settings: d.settings, calendar: cal), "reminder-notonight")
        XCTAssertFalse(AlertActions.actions(forCategoryID: "reminder-notonight").contains(.tonight))
        XCTAssertTrue(AlertActions.actions(forCategoryID: "reminder").contains(.tonight))
        XCTAssertEqual(Set(AlertActions.categoryIDs).count, 6)
    }

    // MARK: Habits

    func testHabitButtons() throws {
        var d = GupDoData()
        let h = Habit(name: "Stretch", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), startDay: today)
        let h2 = Habit(name: "Water", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), startDay: today)
        d.habits = [h, h2]
        let now = at(2026, 11, 16, 7, 6)
        let alarm = Planner.plan(d, now: now, calendar: cal).alarms[0]
        XCTAssertEqual(alarm.itemIDs, [h.id, h2.id])
        let p = AlertPayload(alarm)
        // Done + proof opens the proof screen for the whole group.
        XCTAssertEqual(AlertActions.resolve(.prove, payload: p, data: d, context: ctx, now: now, calendar: cal),
                       .show(.proof([h.id, h2.id])))
        // 15 min applies to each; the alarms move 15 minutes.
        guard case .apply(let snooze) = AlertActions.resolve(.habit15, payload: p, data: d, context: ctx, now: now,
                                                             calendar: cal) else { return XCTFail() }
        XCTAssertEqual(snooze.count, 2)
        d = Answers.applyAll(snooze, to: d, now: now, calendar: cal).data
        XCTAssertEqual(Planner.plan(d, now: now, calendar: cal).alerts.first?.fireDate, now + minutes(15))
        // Only once a day: the second time shows the answers.
        XCTAssertEqual(AlertActions.resolve(.habit15, payload: p, data: d, context: ctx, now: now, calendar: cal),
                       .show(.answers(.habit, [h.id, h2.id])))
        // Can't right now only while driving (Anywhere habits).
        XCTAssertEqual(AlertActions.resolve(.cantRightNow, payload: p, data: d, context: ctx, now: now, calendar: cal),
                       .show(.answers(.habit, [h.id, h2.id])))
        XCTAssertEqual(AlertActions.resolve(.cantRightNow, payload: p, data: d, context: PhoneContext(isDriving: true),
                                            now: now, calendar: cal),
                       .apply([.habit(h.id, .cantRightNow(.driving)), .habit(h2.id, .cantRightNow(.driving))]))
        // Prove one: the group keeps ringing for the other only.
        d = try Answers.apply(.habit(h.id, .done(ProofStub.evidence(for: h))), to: d, now: now, calendar: cal)
        // (tomorrow's alerts for both are planned too)
        let rest = Planner.plan(d, now: now, calendar: cal).alerts.filter { $0.fireDate < at(2026, 11, 17) }
        XCTAssertFalse(rest.isEmpty)
        XCTAssertTrue(rest.allSatisfy { $0.itemIDs == [h2.id] })
        XCTAssertEqual(AlertActions.resolve(.prove, payload: p, data: d, context: ctx, now: now, calendar: cal),
                       .show(.proof([h2.id])))
        d = try Answers.apply(.habit(h2.id, .done(ProofStub.evidence(for: h2))), to: d, now: now, calendar: cal)
        XCTAssertTrue(Planner.plan(d, now: now, calendar: cal).alerts.allSatisfy { $0.fireDate >= at(2026, 11, 17) })
        XCTAssertEqual(AlertActions.resolve(.prove, payload: p, data: d, context: ctx, now: now, calendar: cal), .nothing)
    }

    func testProofStubMatchesEachKind() {
        let place = UUID()
        var h = Habit(name: "x", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)), placeID: place,
                      startDay: today)
        for kind in ProofKind.allCases {
            h.proof = kind
            h.nfcTagID = "tag"
            XCTAssertTrue(HabitLogic.accepts(ProofStub.evidence(for: h), for: h), "\(kind)")
        }
    }

    func testQuietHabitCheckFromToday() throws {
        var d = GupDoData()
        let h = Habit(name: "Read", window: TimeWindow(start: TimeOfDay(21), end: TimeOfDay(22)), startDay: today)
        d.habits = [h]
        // Not Quiet yet: the check isn't allowed.
        XCTAssertThrowsError(try Answers.apply(.habit(h.id, .check), to: d, now: at(2026, 11, 16, 21), calendar: cal))
        XCTAssertThrowsError(try Answers.apply(.habit(UUID(), .check), to: d, now: at(2026, 11, 16, 21), calendar: cal)) {
            XCTAssertEqual($0 as? AnswerError, .unknownItem)
        }
    }

    // MARK: Events

    func testEventGotIt() throws {
        var d = GupDoData()
        let e = Event(title: "Dentist", start: at(2026, 11, 20, 15))
        d.events = [e]
        let now = at(2026, 11, 20, 15, 6)
        let p = Planner.plan(d, now: now, calendar: cal)
        XCTAssertEqual(p.alarms.first?.category, .eventMain)
        guard case .apply(let a) = AlertActions.resolve(.gotIt, payload: AlertPayload(p.alarms[0]), data: d,
                                                        context: ctx, now: now, calendar: cal) else { return XCTFail() }
        d = try Answers.apply(a[0], to: d, now: now, calendar: cal)
        XCTAssertTrue(Planner.plan(d, now: now, calendar: cal).alarms.isEmpty)
        let hu = AlertPayload(alertID: "h", itemKind: .event, itemIDs: [e.id], category: .headsUp)
        XCTAssertEqual(AlertActions.resolve(.gotIt, payload: hu, data: d, context: ctx, now: now, calendar: cal),
                       .apply([.event(e.id, .gotItHeadsUp)]))
        XCTAssertEqual(AlertActions.alarmButtons(for: .eventMain).secondary, .gotIt)
        XCTAssertEqual(AlertActions.alarmButtons(for: .reminder).secondary, .done)
        XCTAssertEqual(AlertActions.alarmButtons(for: .habit).secondary, .prove)
    }

    // MARK: Payload, ids, sync

    func testPayloadRoundTrip() {
        let p = AlertPayload(alertID: "r-1-ts", itemKind: .habit, itemIDs: [UUID(), UUID()], category: .habit)
        XCTAssertEqual(AlertPayload(fields: p.fields), p)
        XCTAssertNil(AlertPayload(fields: ["alertID": "x"]))
        XCTAssertNil(AlertPayload(fields: ["alertID": "x", "itemKind": "habit", "category": "habit", "itemIDs": ""]))
    }

    func testStableIDs() {
        XCTAssertEqual(StableID.uuid("r-abc-ts"), StableID.uuid("r-abc-ts"))
        XCTAssertNotEqual(StableID.uuid("r-abc-a1"), StableID.uuid("r-abc-a2"))
        let many = Set((0..<5000).map { StableID.uuid("e-\($0)-main-a\($0 % 13)") })
        XCTAssertEqual(many.count, 5000)
        XCTAssertEqual(StableID.uuid("x").uuidString.split(separator: "-")[2].first, "5")
    }

    func testAlarmSyncKeepsUnchangedAndCaps() {
        let due = at(2026, 11, 16, 10)
        let (d, _) = reminderData(due: due)
        let p = Planner.plan(d, now: due - 60, calendar: cal)
        let ids = p.alarms.map { StableID.uuid($0.id) }
        let same = AlarmSync.diff(plan: p, existing: ids)
        XCTAssertTrue(same.cancel.isEmpty && same.schedule.isEmpty)
        let stray = UUID()
        let fresh = AlarmSync.diff(plan: p, existing: [stray, ids[0]], limit: 5)
        XCTAssertEqual(fresh.cancel, [stray])
        XCTAssertEqual(fresh.schedule.map(\.id), p.alarms.prefix(5).dropFirst().map(\.id))
    }
}

final class DefaultsTests: XCTestCase {
    let us = Locale(identifier: "en_US_POSIX")

    func testQuickTimes() {
        let t = Defaults.quickTimes(now: at(2026, 11, 16, 13, 2), calendar: cal)
        XCTAssertEqual(t.map(\.label), ["In 1 hour", "Tonight", "Tomorrow"])
        XCTAssertEqual(t.map(\.date), [at(2026, 11, 16, 14, 5), at(2026, 11, 16, 20), at(2026, 11, 17, 9)])
        XCTAssertEqual(Defaults.quickTimes(now: at(2026, 11, 16, 19, 50), calendar: cal).map(\.label),
                       ["In 1 hour", "Tomorrow"])
        XCTAssertEqual(Defaults.reminderTime(now: at(2026, 11, 16, 13, 0), calendar: cal), at(2026, 11, 16, 14, 0))
        XCTAssertEqual(Defaults.reminderTime(now: at(2026, 11, 16, 13, 0) + 1, calendar: cal), at(2026, 11, 16, 14, 5))
    }

    func testNewItems() {
        let now = at(2026, 11, 16, 13, 20)
        let h = Defaults.habit(now: now, calendar: cal)
        XCTAssertEqual(h.window, TimeWindow(start: TimeOfDay(14), end: TimeOfDay(15)))
        XCTAssertEqual(h.days, .everyDay)
        XCTAssertNil(h.placeID)
        XCTAssertEqual(h.proof, .photo)
        XCTAssertEqual(h.startDay, day(2026, 11, 16))
        let late = Defaults.habit(now: at(2026, 11, 16, 23, 10), calendar: cal)
        XCTAssertEqual(late.window, TimeWindow(start: TimeOfDay(0), end: TimeOfDay(1)))
        let e = Defaults.event(now: now, calendar: cal)
        XCTAssertEqual(e.start, at(2026, 11, 17, 14))
        XCTAssertNil(e.end)
        XCTAssertEqual(e.headsUps, .normal)
        XCTAssertNil(e.mainAlert)
    }

    func testFormats() {
        let now = at(2026, 11, 16, 9)
        XCTAssertEqual(Formats.when(at(2026, 11, 16, 15), now: now, calendar: cal, locale: us), "3:00 PM")
        XCTAssertEqual(Formats.when(at(2026, 11, 17, 15), now: now, calendar: cal, locale: us), "Tomorrow 3:00 PM")
        XCTAssertEqual(Formats.when(at(2026, 11, 21, 15), now: now, calendar: cal, locale: us), "Sat 3:00 PM")
        XCTAssertEqual(Formats.when(at(2026, 12, 1, 15), now: now, calendar: cal, locale: us), "Dec 1, 3:00 PM")
        XCTAssertEqual(Formats.dayDistance(at(2026, 11, 22, 15), now: now, calendar: cal), "In 6 days")
        XCTAssertEqual(Formats.dayDistance(at(2026, 12, 10, 15), now: now, calendar: cal), "In 3 weeks")
        XCTAssertEqual(Formats.window(TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8, 30)), calendar: cal, locale: us),
                       "7:00 AM – 8:30 AM")
        XCTAssertEqual(Formats.days(.weekdays([2, 3, 4, 5, 6]), calendar: cal), "Weekdays")
        XCTAssertEqual(Formats.days(.weekdays([2, 4, 6]), calendar: cal), "Mon, Wed, Fri")
        XCTAssertEqual(Formats.repeatRule(.never, calendar: cal), "Never")
    }
}
