import Foundation
import Observation
import UIKit

/// The app's state: the saved data (one JSON file), the screen to show for an answer, and the glue that runs every
/// answer through GupDoKit (`Answers`, `AlertActions`), saves, and replans the notifications and alarms
/// (`Planner` -> `AlertScheduler`). Notification buttons, alarm buttons, the Now card and the Today strip all end up in
/// `handle(_:_:)` or `answer(_:)`, so answering anywhere stops the escalation the same way.
@MainActor
@Observable
final class AppModel {
    /// The one model the app, its notification delegate and its alarm intents share.
    static let shared = AppModel(store: .appSupport, scheduler: AlertScheduler(), clock: .system,
                                 sensors: Sensors.shared, drive: MapDriveTimes(sensors: Sensors.shared))

    private(set) var data: GupDoData
    /// "Now" for the screens; moves on a timer (tests pin it with a fixed clock).
    private(set) var now: Date
    /// A screen an answer needs (Pick a time, Pick a day, proof, an item's answers).
    var screen: AnswerScreen?
    /// A short note after an answer that couldn't be applied ("Can't right now is only for driving...").
    var notice: String?
    /// Driving right now, as Core Motion (or the GPS speed) last said (`updateDriving`).
    private(set) var isDriving = false

    let calendar: Calendar
    private let store: DataStore
    private let scheduler: AlertScheduling?
    private let clock: AppClock
    let sensors: PhoneSensors?
    let photos: PhotoStore
    /// MapKit drive times for time to leave (nil: none, the alert stays at its fallback).
    let drive: DriveTimes?
    @ObservationIgnored private var checkingTravel = false
    @ObservationIgnored private var scheduling: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    init(store: DataStore, scheduler: AlertScheduling?, clock: AppClock, calendar: Calendar = .current,
         sensors: PhoneSensors? = nil, photos: PhotoStore = .app, drive: DriveTimes? = nil) {
        self.store = store
        self.drive = drive
        self.scheduler = scheduler
        self.clock = clock
        self.calendar = calendar
        self.sensors = sensors
        self.photos = photos
        self.data = store.load()
        self.now = clock.now()
    }

    /// For screens and tests: these items, this moment, nothing saved or scheduled.
    convenience init(preview data: GupDoData, now: Date, calendar: Calendar = .current, isDriving: Bool = false,
                     photos: PhotoStore = .app) {
        self.init(store: .memory(data), scheduler: nil, clock: .fixed(now), calendar: calendar, photos: photos)
        self.isDriving = isDriving
    }

    /// What the phone knows when he answers: the saved places it is inside (region monitoring) and driving.
    var phoneContext: PhoneContext { Presence.context(data, isDriving: isDriving) }

    // MARK: Main screen

    var nowCard: NowCard? { TodayLogic.nowCard(data, now: now, presence: Presence.inside(data), calendar: calendar) }
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
        let before = data
        data = Presence.settle(data, now: now, calendar: calendar)
        await endDrivingPauses()
        if data != before { store.save(data) }
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
        if !data.places.isEmpty { sensors?.requestPermissions() }
        await replan()
    }

    // MARK: Answers

    /// A button on a notification or an alarm (or "open" from a tap on one).
    func handle(_ action: AlertAction, _ payload: AlertPayload) async {
        data = store.load()
        now = clock.now()
        if payload.itemKind == .habit { await updateDriving() }
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
        // "when I arrive" needs region monitoring (Always location)
        if r.placeID != nil { sensors?.requestPermissions() }
        await commit()
    }

    func save(_ h: Habit) async {
        if let i = data.habits.firstIndex(where: { $0.id == h.id }) { data.habits[i] = h } else { data.habits.append(h) }
        await commit()
    }

    /// Saves an event. `driveMinutes`: a drive time the form already got for its Where (else it is asked for here,
    /// so the time-to-leave alarm is scheduled with the best drive time known right away).
    func save(_ e: Event, driveMinutes: Int? = nil) async {
        var e = e
        let old = data.events.first { $0.id == e.id }
        if old == nil || old?.start != e.start || old?.location != e.location || old?.mainAlert != e.mainAlert {
            now = clock.now()
            var minutes = driveMinutes
            if minutes == nil, TravelTime.wantsTravel(e.with { $0.leaveAt = nil }, now: now, settings: data.settings),
               let place = e.location {
                minutes = await drive?.minutes(to: place, departure: TravelTime.departure(e, now: now, settings: data.settings))
            }
            e = TravelTime.update(e, minutes: minutes, now: clock.now(), restart: true, settings: data.settings)
        }
        if let i = data.events.firstIndex(where: { $0.id == e.id }) { data.events[i] = e } else { data.events.append(e) }
        if e.location != nil { sensors?.requestPermissions() }
        await commit()
    }

    /// The drive time to a Where from here now, for the event form (nil: unknown).
    func driveMinutes(to place: EventLocation, for e: Event) async -> Int? {
        await drive?.minutes(to: place, departure: max(clock.now(), e.start.addingTimeInterval(-3600)))
    }

    func deleteReminder(_ id: UUID) async {
        data.reminders.removeAll { $0.id == id }
        await commit(cleared: [id])
    }

    func deleteHabit(_ id: UUID) async {
        photos.delete(habit(id)?.referencePhoto)
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

    // MARK: Places

    /// Places in use by habits.
    func habits(at placeID: UUID) -> [Habit] { data.habits.filter { $0.placeID == placeID } }

    /// Arrival reminders waiting on a place.
    func reminders(at placeID: UUID) -> [Reminder] {
        data.reminders.filter { $0.status == .active && $0.placeID == placeID }
    }

    func save(_ p: Place) async {
        var p = p
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        if p.isHome { for i in data.places.indices where data.places[i].id != p.id { data.places[i].isHome = false } }
        if let i = data.places.firstIndex(where: { $0.id == p.id }) {
            let old = data.places[i]
            data.places[i] = p
            // moved: where the phone was means nothing for the new circle (region monitoring reports it afresh)
            if old.latitude != p.latitude || old.longitude != p.longitude || old.radius != p.radius {
                data = Presence.forget(p.id, data: data)
            }
        } else {
            data.places.append(p)
        }
        data = TravelTime.placeChanged(p, data: data)
        sensors?.requestPermissions()
        await commit()
    }

    /// Deletes a place no habit or arrival reminder uses; returns false (and says why) otherwise. Events keep their
    /// own copy of it.
    @discardableResult
    func deletePlace(_ id: UUID) async -> Bool {
        let users = PlaceUse.users(id, data: data)
        guard users.isEmpty else {
            notice = "Used by \(users.joined(separator: ", ")). Change those first."
            return false
        }
        data.places.removeAll { $0.id == id }
        data = Presence.forget(id, data: data)
        await commit()
        return true
    }

    // MARK: Phone signals

    /// Region monitoring: the phone entered or left a saved place.
    func regionEvent(place: UUID, inside: Bool, at date: Date) async {
        data = store.load()
        now = clock.now()
        guard data.places.contains(where: { $0.id == place }) else { return }
        let when = min(date, now)
        data = inside ? Presence.entered(place, at: when, now: now, data: data, calendar: calendar)
            : Presence.left(place, at: when, data: data, calendar: calendar)
        await commit()
    }

    /// Asks Core Motion (and the last GPS speed) whether the phone is driving now.
    func updateDriving() async {
        guard let sensors else { return }
        let t = clock.now()
        let samples = await sensors.motionSamples(from: t.addingTimeInterval(-30 * 60), to: t)
        isDriving = Driving.isDriving(samples: samples, fix: sensors.lastFix, now: t)
    }

    /// Ends driving pauses whose end Core Motion shows (on every refresh and wake).
    private func endDrivingPauses(stationarySince: Date? = nil) async {
        let open = DrivingPauses.open(data, now: now, calendar: calendar)
        guard let sensors, let since = open.map(\.since).min() else { return }
        let samples = await sensors.motionSamples(from: since.addingTimeInterval(-10 * 60), to: now)
        data = DrivingPauses.end(data, samples: samples, stationarySince: stationarySince, now: now, calendar: calendar)
    }

    /// A location update while a habit waits for driving to stop.
    func drivingUpdate(stationarySince: Date?) async {
        data = store.load()
        now = clock.now()
        let before = data
        await endDrivingPauses(stationarySince: stationarySince)
        guard data != before else { return }
        isDriving = false
        await commit()
    }

    // MARK: Proof

    /// The result of a proof attempt, for the proof screen.
    enum ProofResult: Equatable {
        case proved([UUID])
        case photoNoMatch(close: Bool, distance: Double)
        case notThere(String)
        case wrongTag
        case failed(String)
    }

    /// The habits of `ids` still waiting for proof today.
    func unproved(_ ids: [UUID]) -> [Habit] {
        ids.compactMap(habit).filter { !Answers.isProved($0, data: data, now: now, calendar: calendar) }
    }

    /// A live camera photo for a photo-proof habit: compared with its reference photo on the phone.
    func provePhoto(_ habitID: UUID, photo: UIImage) async -> ProofResult {
        guard let h = habit(habitID), let reference = photos.load(h.referencePhoto) else {
            return .failed("This habit has no reference photo. Take one in the habit's settings.")
        }
        let distance: Double
        do {
            distance = try await PhotoMatcher.distance(reference, photo)
        } catch {
            return .failed("Couldn't compare the photos. Try again.")
        }
        switch PhotoMatch.verdict(distance: distance) {
        case .match:
            let ok = await answer(.habit(habitID, .done(.photo(matchesReference: true, fromLiveCamera: true))))
            return ok ? .proved([habitID]) : .failed(notice ?? "That didn't work.")
        case .close: return .photoNoMatch(close: true, distance: distance)
        case .noMatch: return .photoNoMatch(close: false, distance: distance)
        }
    }

    /// Location proof for the location-proof habits among `ids`: a fresh fix inside their place.
    func proveLocation(_ ids: [UUID]) async -> ProofResult {
        let waiting = unproved(ids).filter { $0.proof == .location }
        guard !waiting.isEmpty else { return .proved([]) }
        guard let fix = await sensors?.currentFix(timeout: 12) else {
            return .failed("No location. Allow location for GupDo in Settings, then try again.")
        }
        let proved = ProofCheck.byLocation(waiting, places: data.places, fix: fix)
        guard !proved.isEmpty else {
            let names = Set(waiting.compactMap { h in data.places.first { $0.id == h.placeID }?.name })
            let place = names.sorted().joined(separator: " or ")
            return .notThere(fix.accuracy > Geo.maxProofAccuracy
                             ? "Location is too rough right now (±\(Int(fix.accuracy)) m). Try again in a moment."
                             : "You're not at \(place.isEmpty ? "the habit's place" : place) yet.")
        }
        for (h, evidence) in proved { await answer(.habit(h.id, .done(evidence))) }
        return .proved(proved.map(\.habit.id))
    }

    /// An NFC tag scanned for the NFC-proof habits among `ids`.
    func proveTag(_ ids: [UUID], tagID: String) async -> ProofResult {
        let proved = ProofCheck.byTag(unproved(ids), tagID: tagID)
        guard !proved.isEmpty else { return .wrongTag }
        for (h, evidence) in proved { await answer(.habit(h.id, .done(evidence))) }
        return .proved(proved.map(\.habit.id))
    }

    // MARK: Time to leave

    /// Asks MapKit again for the drive times that are getting old (GupDoKit's TravelTime says which), and saves what
    /// they do to the time-to-leave alarms. Runs whenever the app runs anyway (launch, front, background refresh,
    /// region monitoring, answers): background refresh alone isn't guaranteed to come before an alarm.
    func refreshTravel() async {
        guard let drive, !checkingTravel else { return }
        checkingTravel = true
        defer { checkingTravel = false }
        for e in TravelTime.due(data, now: clock.now()) {
            guard let place = e.location else { continue }
            let minutes = await drive.minutes(to: place, departure: TravelTime.departure(e, now: clock.now(),
                                                                                         settings: data.settings))
            // the data may have changed while MapKit answered: update the event as it is now
            guard let i = data.events.firstIndex(where: { $0.id == e.id }), data.events[i].location == place
            else { continue }
            let updated = TravelTime.update(data.events[i], minutes: minutes, now: clock.now(), settings: data.settings)
            if updated != data.events[i] {
                data.events[i] = updated
                store.save(data)
            }
        }
    }

    /// When the background refresh should come next: before a time-to-leave alarm if one is near, else in 3 hours.
    var nextWake: Date {
        let t = clock.now()
        let regular = t.addingTimeInterval(3 * 3600)
        guard let travel = TravelTime.nextCheck(data, now: t) else { return regular }
        return min(regular, max(travel, t.addingTimeInterval(60)))
    }

    // MARK: Planning

    /// Plans from the data as it is and hands the plan to the scheduler; waits until it is scheduled (a background
    /// wake must not end before that). Runs one at a time.
    func replan() async {
        await refreshTravel()
        if let sensors {
            let places = PlaceWatch.pick(data, now: clock.now(), calendar: calendar)
            await sensors.watch(places) { [weak self] place, inside, date in
                Task { await self?.regionEvent(place: place, inside: inside, at: date) }
            }
            let waiting = !DrivingPauses.open(data, now: clock.now(), calendar: calendar).isEmpty
            sensors.followDriving(waiting) { [weak self] stillSince in
                Task { await self?.drivingUpdate(stationarySince: stillSince) }
            }
        }
        guard let scheduler else { return }
        let plan = Planner.plan(data, now: clock.now(), presence: Presence.inside(data), calendar: calendar)
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
