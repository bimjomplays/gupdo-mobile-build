import UserNotifications
import XCTest
@testable import GupDo

/// Catches what the scheduler is asked to do, instead of the phone's notification center and AlarmKit.
actor FakeScheduler: AlertScheduling {
    var plans: [Plan] = []
    var cleared: Set<UUID> = []
    func requestPermissions() async {}
    func apply(_ plan: Plan, settings: Settings, calendar: Calendar) async { plans.append(plan) }
    func clearDelivered(items: Set<UUID>) async { cleared.formUnion(items) }
}

/// The app's wiring: answers from the Now card, a notification button and an alarm button all go through GupDoKit,
/// save, and replan; the notification requests and alarm configurations carry the right buttons.
@MainActor
final class AppModelTests: XCTestCase {
    let cal = Calendar.current
    lazy var now = cal.date(bySettingHour: 10, minute: 7, second: 0, of: cal.date(from: DateComponents(year: 2026, month: 11, day: 16))!)!

    func model(_ data: GupDoData, _ fake: FakeScheduler) -> AppModel {
        AppModel(store: .memory(data), scheduler: fake, clock: .fixed(now), calendar: cal)
    }

    func ringingReminder(laters: Int = 0) -> (GupDoData, Reminder) {
        var d = GupDoData()
        var r = Reminder(title: "Call back", trigger: .time(now.addingTimeInterval(-6 * 60)), createdAt: now.addingTimeInterval(-3600))
        r.laterCount = laters
        d.reminders = [r]
        return (d, r)
    }

    func testDoneOnTheNowCardStopsTheAlarms() async {
        let (d, r) = ringingReminder()
        let fake = FakeScheduler()
        let m = model(d, fake)
        XCTAssertEqual(m.nowCard?.ringing, true)
        await m.replan()
        let before = await fake.plans.last
        XCTAssertEqual(before?.alarms.count, 11)
        let ok = await m.answer(.reminder(r.id, .done))
        XCTAssertTrue(ok)
        let after = await fake.plans.last
        XCTAssertEqual(after?.alerts.count, 0)
        let cleared = await fake.cleared
        XCTAssertTrue(cleared.contains(r.id))
        XCTAssertNil(m.nowCard)
    }

    func testLaterFromANotificationButtonStartsOver() async {
        let (d, r) = ringingReminder()
        let fake = FakeScheduler()
        let m = model(d, fake)
        let alert = Planner.plan(d, now: now, calendar: cal).alarms[0]
        await m.handle(.later15, AlertPayload(alert))
        XCTAssertEqual(m.reminder(r.id)?.due, now.addingTimeInterval(15 * 60))
        let plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts.first?.kind, .timeSensitive)
        XCTAssertEqual(plan?.alerts.first?.fireDate, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(plan?.alarms.first?.fireDate, now.addingTimeInterval(20 * 60))
    }

    func testAfterTheThirdLaterTheAlarmOpensTheFinalChoices() async {
        let (d, r) = ringingReminder(laters: 3)
        let fake = FakeScheduler()
        let m = model(d, fake)
        let alarm = Planner.plan(d, now: now, calendar: cal).alarms[0]
        XCTAssertEqual(alarm.category, .reminderFinal)
        // the alarm's Stop opens the app on the answers, which offer Done / Pick a day / Delete
        XCTAssertEqual(AlertActions.alarmButtons(for: alarm.category).stop, .open)
        await m.handle(.open, AlertPayload(alarm))
        XCTAssertEqual(m.screen, .answers(.reminder, [r.id]))
        XCTAssertEqual(ReminderLogic.choices(for: m.reminder(r.id)!), [.done, .pickDay, .delete])
        // a Later from an old notification can't happen any more: it shows the same choices
        m.screen = nil
        await m.handle(.later60, AlertPayload(alarm))
        XCTAssertEqual(m.screen, .answers(.reminder, [r.id]))
        XCTAssertEqual(m.reminder(r.id)?.laterCount, 3)
    }

    func testAlarmGotItAnswersAnEvent() async {
        var d = GupDoData()
        let e = Event(title: "Lunch", start: now.addingTimeInterval(-6 * 60))
        d.events = [e]
        let fake = FakeScheduler()
        let m = model(d, fake)
        let alarm = Planner.plan(d, now: now, calendar: cal).alarms[0]
        let intent = AlarmFactory.intent(AlertActions.alarmButtons(for: .eventMain).secondary, AlertPayload(alarm))
        XCTAssertTrue(intent is AlarmAnswerIntent)
        await m.handle(.gotIt, AlertPayload(alarm))
        XCTAssertNotNil(m.event(e.id)?.mainAlertAnsweredAt)
        let plan = await fake.plans.last
        XCTAssertEqual(plan?.alarms.count, 0)
    }

    // MARK: Notifications and alarms

    func testNotificationCategoriesAndButtons() {
        let cats = NotificationFactory.categories()
        XCTAssertEqual(cats.count, 6)
        let reminder = cats.first { $0.identifier == "reminder" }!
        XCTAssertEqual(reminder.actions.map(\.identifier), ["done", "later15", "later60", "tonight", "tomorrow", "pickTime"])
        XCTAssertTrue(reminder.actions.last!.options.contains(.foreground))
        XCTAssertFalse(reminder.actions[0].options.contains(.foreground))
        let final = cats.first { $0.identifier == "reminderFinal" }!
        XCTAssertEqual(final.actions.map(\.title), ["Done", "Pick a day…", "Delete"])
        XCTAssertTrue(final.actions[2].options.contains(.destructive))
        XCTAssertEqual(cats.first { $0.identifier == "habit" }!.actions.map(\.identifier), ["prove", "habit15", "cantRightNow"])
        XCTAssertEqual(cats.first { $0.identifier == "headsUp" }!.actions.map(\.title), ["Got it"])
        XCTAssertEqual(NotificationFactory.action(for: UNNotificationDefaultActionIdentifier), .open)
    }

    func testNotificationRequests() {
        var d = GupDoData()
        let r = Reminder(title: "Call back", trigger: .time(now.addingTimeInterval(3600)), note: "the bank", createdAt: now)
        let e = Event(title: "Dinner", start: now.addingTimeInterval(5 * 86_400))
        d.reminders = [r]
        d.events = [e]
        let plan = Planner.plan(d, now: now, calendar: cal)
        let ts = plan.notifications.first { $0.itemKind == .reminder }!
        let req = NotificationFactory.request(for: ts, settings: d.settings, calendar: cal)
        XCTAssertEqual(req.content.interruptionLevel, .timeSensitive)
        XCTAssertEqual(req.content.title, "Call back")
        XCTAssertEqual(req.content.body, "the bank")
        XCTAssertEqual(req.content.categoryIdentifier, "reminder")
        XCTAssertEqual(AlertPayload(fields: NotificationFactory.fields(req.content.userInfo)), AlertPayload(ts))
        let comps = (req.trigger as? UNCalendarNotificationTrigger)?.dateComponents
        XCTAssertEqual(comps.flatMap { cal.date(from: $0) }, ts.fireDate)
        let headsUp = plan.notifications.first { $0.category == .headsUp }!
        let hreq = NotificationFactory.request(for: headsUp, settings: d.settings, calendar: cal)
        XCTAssertEqual(hreq.content.interruptionLevel, .active)
        XCTAssertEqual(hreq.content.categoryIdentifier, "headsUp")
    }

    func testWithoutAlarmPermissionAlarmsComeAsTimeSensitiveNotifications() {
        let (d, _) = ringingReminder()
        let plan = Planner.plan(d, now: now, calendar: cal)
        XCTAssertEqual(NotificationFactory.notifications(plan, alarmsAllowed: true, limit: 60).count, 0)
        let fallback = NotificationFactory.notifications(plan, alarmsAllowed: false, limit: 60)
        XCTAssertEqual(fallback.count, 11)
        XCTAssertTrue(fallback.allSatisfy { $0.kind == .timeSensitive })
        XCTAssertEqual(NotificationFactory.notifications(plan, alarmsAllowed: false, limit: 5).count, 5)
    }

    func testAlarmConfigurationAndIntents() {
        let (d, _) = ringingReminder()
        let alarm = Planner.plan(d, now: now, calendar: cal).alarms[0]
        _ = AlarmFactory.configuration(for: alarm)
        let buttons = AlertActions.alarmButtons(for: .reminder)
        XCTAssertTrue(AlarmFactory.intent(buttons.secondary, AlertPayload(alarm)) is AlarmAnswerIntent)
        XCTAssertTrue(AlarmFactory.intent(buttons.stop, AlertPayload(alarm)) is AlarmOpenIntent)
        XCTAssertTrue(AlarmFactory.intent(.prove, AlertPayload(alarm)) is AlarmOpenIntent)
        XCTAssertEqual(AlarmIntentFields.decode(AlarmIntentFields.encode(AlertPayload(alarm))), AlertPayload(alarm))
        XCTAssertEqual(AlarmFactory.title(.prove), "Prove it")
    }

    func testSavedDataSurvivesAReload() async {
        let box = DataStore.memory(GupDoData())
        let fake = FakeScheduler()
        let m = AppModel(store: box, scheduler: fake, clock: .fixed(now), calendar: cal)
        await m.save(Reminder(title: "Buy milk", trigger: .time(now.addingTimeInterval(600)), createdAt: now))
        XCTAssertEqual(box.load().reminders.map(\.title), ["Buy milk"])
        let again = AppModel(store: box, scheduler: fake, clock: .fixed(now), calendar: cal)
        XCTAssertEqual(again.data.reminders.map(\.title), ["Buy milk"])
        let plan = await fake.plans.last
        XCTAssertEqual(plan?.alerts.first?.kind, .timeSensitive)
    }
}
