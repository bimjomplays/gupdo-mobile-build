import Foundation
import Observation

/// The app's state: the saved data (one JSON file), the screen to show for an answer, and the glue that runs every
/// answer through GupDoKit (`Answers`, `AlertActions`), saves, and replans the notifications and alarms
/// (`Planner` -> `AlertScheduler`). Notification buttons, alarm buttons, the Now card and the Today strip all end up in
/// `handle(_:_:)` or `answer(_:)`, so answering anywhere stops the escalation the same way.
@MainActor
@Observable
final class AppModel {
    /// The one model the app, its notification delegate and its alarm intents share.
    static let shared = AppModel(store: .appSupport, scheduler: AlertScheduler(), clock: .system)

    private(set) var data: GupDoData
    /// "Now" for the screens; moves on a timer (tests pin it with a fixed clock).
    private(set) var now: Date
    /// A screen an answer needs (Pick a time, Pick a day, proof, an item's answers).
    var screen: AnswerScreen?
    /// A short note after an answer that couldn't be applied ("Can't right now is only for driving...").
    var notice: String?

    let calendar: Calendar
    private let store: DataStore
    private let scheduler: AlertScheduling?
    private let clock: AppClock
    @ObservationIgnored private var scheduling: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(store: DataStore, scheduler: AlertScheduling?, clock: AppClock, calendar: Calendar = .current) {
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
        self.data = store.load()
        self.now = clock.now()
    }

    /// For screens and tests: these items, this moment, nothing saved or scheduled.
    convenience init(preview data: GupDoData, now: Date, calendar: Calendar = .current) {
        self.init(store: .memory(data), scheduler: nil, clock: .fixed(now), calendar: calendar)
    }

    /// What the phone knows when he answers. Driving and places come with location (later builds); until then
    /// "Can't right now" isn't offered.
    var phoneContext: PhoneContext { PhoneContext() }

    // MARK: Main screen

    var nowCard: NowCard? { TodayLogic.nowCard(data, now: now, calendar: calendar) }
    var today: TodaySummary { TodayLogic.today(data, now: now, calendar: calendar) }
    var upcoming: [Event] { EventLogic.upcoming(data.events, now: now) }

    func reminder(_ id: UUID) -> Reminder? { data.reminders.first { $0.id == id } }
    func habit(_ id: UUID) -> Habit? { data.habits.first { $0.id == id } }
    func event(_ id: UUID) -> Event? { data.events.first { $0.id == id } }

    // MARK: Lifecycle

    /// Launch, coming to the front, a background wake: reread, move the clock, replan.
    func refresh() async {
        data = store.load()
        now = clock.now()
        await replan()
    }

    /// Keeps `now` current while the app is open (the Now card flips to ringing on time).
    func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                let t = self.clock.now()
                if self.calendar.component(.minute, from: t) != self.calendar.component(.minute, from: self.now) {
                    self.now = t
                }
            }
        }
    }

    func requestPermissions() async {
        await scheduler?.requestPermissions()
        await replan()
    }

    // MARK: Answers

    /// A button on a notification or an alarm (or "open" from a tap on one).
    func handle(_ action: AlertAction, _ payload: AlertPayload) async {
        data = store.load()
        now = clock.now()
        switch AlertActions.resolve(action, payload: payload, data: data, context: phoneContext, now: now,
                                    calendar: calendar) {
        case .apply(let answers):
            await apply(answers)
        case .show(let screen):
            notice = nil
            self.screen = screen
            await replan()
        case .nothing:
            await replan()
        }
    }

    /// An answer given in the app. Returns false (and sets `notice`) when the rules don't allow it now.
    @discardableResult
    func answer(_ answer: AppAnswer) async -> Bool {
        now = clock.now()
        do {
            data = try Answers.apply(answer, to: data, context: phoneContext, now: now, calendar: calendar)
        } catch {
            notice = Self.explain(error)
            return false
        }
        store.save(data)
        await scheduler?.clearDelivered(items: [answer.itemID])
        await replan()
        return true
    }

    /// Answers from a notification or alarm button (a group habit alarm answers each habit it can).
    func apply(_ answers: [AppAnswer]) async {
        now = clock.now()
        data = Answers.applyAll(answers, to: data, context: phoneContext, now: now, calendar: calendar).data
        await commit(cleared: Set(answers.map(\.itemID)))
    }

    static func explain(_ error: Error) -> String {
        if let e = error as? HabitError {
            return e == .proofRejected ? "That proof didn't match." : "That answer isn't available right now."
        }
        if let e = error as? ReminderError {
            return e == .dateInPast ? "Pick a time in the future." : "That answer isn't available after 3 Laters."
        }
        return "That didn't work. Try again."
    }

    // MARK: Editing

    func save(_ r: Reminder) async {
        if let i = data.reminders.firstIndex(where: { $0.id == r.id }) { data.reminders[i] = r } else { data.reminders.append(r) }
        await commit()
    }

    func save(_ h: Habit) async {
        if let i = data.habits.firstIndex(where: { $0.id == h.id }) { data.habits[i] = h } else { data.habits.append(h) }
        await commit()
    }

    func save(_ e: Event) async {
        if let i = data.events.firstIndex(where: { $0.id == e.id }) { data.events[i] = e } else { data.events.append(e) }
        await commit()
    }

    func deleteReminder(_ id: UUID) async {
        data.reminders.removeAll { $0.id == id }
        await commit(cleared: [id])
    }

    func deleteHabit(_ id: UUID) async {
        data.habits.removeAll { $0.id == id }
        data.history.removeAll(for: id)
        await commit(cleared: [id])
    }

    func deleteEvent(_ id: UUID) async {
        data.events.removeAll { $0.id == id }
        await commit(cleared: [id])
    }

    private func commit(cleared: Set<UUID> = []) async {
        now = clock.now()
        store.save(data)
        if !cleared.isEmpty { await scheduler?.clearDelivered(items: cleared) }
        await replan()
    }

    // MARK: Planning

    /// Plans from the data as it is and hands the plan to the scheduler; waits until it is scheduled (a background
    /// wake must not end before that). Runs one at a time.
    func replan() async {
        guard let scheduler else { return }
        let plan = Planner.plan(data, now: clock.now(), calendar: calendar)
        let settings = data.settings, cal = self.calendar
        let previous = scheduling
        let task = Task {
            await previous?.value
            await scheduler.apply(plan, settings: settings, calendar: cal)
        }
        scheduling = task
        await task.value
    }
}

/// Where the data lives: one JSON file in Application Support (readable after the first unlock, so a notification
/// or alarm answer works on a locked phone), or memory for screens and tests.
struct DataStore {
    var load: () -> GupDoData
    var save: (GupDoData) -> Void

    static let appSupport: DataStore = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("gupdo.json")
        return DataStore(
            load: {
                guard let bytes = try? Data(contentsOf: url), let data = try? GupDoData.decode(bytes) else {
                    return GupDoData()
                }
                return data
            },
            save: { data in
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard let bytes = try? data.encoded() else { return }
                try? bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            })
    }()

    static func memory(_ initial: GupDoData) -> DataStore {
        final class Box { var data: GupDoData; init(_ d: GupDoData) { data = d } }
        let box = Box(initial)
        return DataStore(load: { box.data }, save: { box.data = $0 })
    }
}
