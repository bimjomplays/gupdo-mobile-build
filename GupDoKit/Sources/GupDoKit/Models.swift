import Foundation

// The saved data: places, reminders, habits, events and the habit day logs. Everything is Codable so the app can
// keep it in one local JSON file (see GupDoData).

struct Place: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    /// Geofence radius in metres.
    var radius: Double = 100
    var isHome = false
}

// MARK: - Reminders

enum RepeatRule: Codable, Hashable {
    case never, daily, weekly, monthly
    /// Pick days: weekdays 1 = Sunday ... 7 = Saturday.
    case days(Set<Int>)
}

enum ReminderTrigger: Codable, Hashable {
    /// Date + time.
    case time(Date)
    /// "When I arrive somewhere".
    case arrival(placeID: UUID)
}

struct Reminder: Codable, Hashable, Identifiable {
    enum Status: String, Codable { case active, done, deleted }

    var id = UUID()
    var title: String
    var trigger: ReminderTrigger
    var repeatRule: RepeatRule = .never
    var alarmIfIgnored = true
    var note: String?

    // State
    /// Start of the current ringing cycle: the occurrence, a Later time, or the arrival. nil = waiting (arrival).
    var due: Date?
    /// The occurrence repeats are anchored on (its clock time is kept by Tomorrow and Pick a day).
    var occurrence: Date
    var laterCount = 0
    var status: Status = .active
    /// Arrival reminders: arrivals before this moment don't count (set after Done on a repeating one).
    var armedFrom: Date?

    init(id: UUID = UUID(), title: String, trigger: ReminderTrigger, repeatRule: RepeatRule = .never,
         alarmIfIgnored: Bool = true, note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.trigger = trigger
        self.repeatRule = repeatRule
        self.alarmIfIgnored = alarmIfIgnored
        self.note = note
        switch trigger {
        case .time(let date):
            due = date
            occurrence = date
        case .arrival:
            due = nil
            occurrence = createdAt
            armedFrom = createdAt
        }
    }

    var placeID: UUID? {
        if case .arrival(let id) = trigger { return id }
        return nil
    }
}

enum LaterOption: Codable, Hashable {
    case fifteenMinutes, oneHour, tonight, tomorrow
    case pick(Date)
}

enum ReminderAnswer: Codable, Hashable {
    case done
    case later(LaterOption)
    /// Only after the 3rd Later: a day (the reminder keeps its clock time).
    case pickDay(Date)
    case delete
}

// MARK: - Habits

enum ProofKind: String, Codable, Hashable, CaseIterable {
    /// Live camera photo matching the reference photo of the spot (no camera roll).
    case photo
    /// Being at the habit's place.
    case location
    /// Scanning the habit's NFC tag.
    case nfc
}

/// What the phone offers as proof when Done is pressed. Photo matching itself happens in the app (Vision); the
/// logic only gets its verdict.
enum ProofEvidence: Codable, Hashable {
    case photo(matchesReference: Bool, fromLiveCamera: Bool)
    case location(placeID: UUID)
    case nfc(tagID: String)
}

struct TimeWindow: Codable, Hashable {
    var start: TimeOfDay
    var end: TimeOfDay
}

struct Habit: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var days: DaySet = .everyDay
    var window: TimeWindow
    /// nil = Anywhere.
    var placeID: UUID?
    var proof: ProofKind = .photo
    /// File name of the reference photo taken at setup (photo proof).
    var referencePhoto: String?
    /// NFC proof: the tag registered at setup.
    var nfcTagID: String?
    /// First day the habit counts.
    var startDay: DayKey
}

enum HabitAnswer: Codable, Hashable {
    case done(ProofEvidence)
    case fifteenMinutes
    case cantRightNow(PauseReason)
    /// Quiet habits: the Today checkbox.
    case check
}

enum PauseReason: String, Codable, Hashable {
    /// Away from the habit's place: resumes on arrival (+ arrival delay).
    case away
    /// Driving: resumes when driving stops.
    case driving
}

struct HabitPause: Codable, Hashable {
    var reason: PauseReason
    var start: Date
    var end: Date?
}

/// What happened with one habit on one day.
struct HabitDayLog: Codable, Hashable {
    var habitID: UUID
    var day: DayKey
    var provedAt: Date?
    /// The one "15 min" of the day.
    var snoozedAt: Date?
    var pauses: [HabitPause] = []
    /// First time the phone saw him at the habit's place during the window (the window start if he was already
    /// there). Place habits only.
    var atPlaceAt: Date?

    init(habitID: UUID, day: DayKey) {
        self.habitID = habitID
        self.day = day
    }
}

/// All habit day logs, looked up by habit and day.
struct HabitHistory: Codable, Hashable {
    var logs: [String: HabitDayLog] = [:]

    private static func key(_ habitID: UUID, _ day: DayKey) -> String { "\(habitID.uuidString)|\(day)" }

    subscript(habitID: UUID, day: DayKey) -> HabitDayLog {
        get { logs[Self.key(habitID, day)] ?? HabitDayLog(habitID: habitID, day: day) }
        set { logs[Self.key(habitID, day)] = newValue }
    }

    func log(_ habitID: UUID, _ day: DayKey) -> HabitDayLog? { logs[Self.key(habitID, day)] }

    mutating func removeAll(for habitID: UUID) { logs = logs.filter { $0.value.habitID != habitID } }
}

// MARK: - Events

enum HeadsUpPreset: Codable, Hashable {
    /// 2 weeks, 1 week, 5 days, 3 days, 1 day, morning of.
    case big
    /// 5 days, 3 days, 1 day, morning of (default).
    case normal
    /// Morning of.
    case small
    case custom(daysBefore: [Int], morningOf: Bool)

    var daysBefore: [Int] {
        switch self {
        case .big: return [14, 7, 5, 3, 1]
        case .normal: return [5, 3, 1]
        case .small: return []
        case .custom(let days, _): return days
        }
    }

    var morningOf: Bool {
        if case .custom(_, let m) = self { return m }
        return true
    }
}

enum MainAlertTiming: String, Codable, Hashable, CaseIterable {
    case atStart, thirtyMinutesBefore, hourBefore, timeToLeave
}

/// Where an event is: one of the saved places (copied, so the event keeps working if the place is deleted) or an
/// address found with search. Not watched by region monitoring: it is only where the drive time goes to.
struct EventLocation: Codable, Hashable {
    var name: String
    /// One line, for an address found with search.
    var address: String?
    var latitude: Double
    var longitude: Double
    /// Picked from the saved places: that place (its moves are copied over).
    var placeID: UUID?

    init(name: String, address: String? = nil, latitude: Double, longitude: Double, placeID: UUID? = nil) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.placeID = placeID
    }

    init(place: Place) {
        self.init(name: place.name, latitude: place.latitude, longitude: place.longitude, placeID: place.id)
    }
}

struct Event: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date?
    /// Where (optional): a saved place or a searched address.
    var location: EventLocation?
    var headsUps: HeadsUpPreset = .normal
    /// nil = the default: time to leave when the event has a place, else at start.
    var mainAlert: MainAlertTiming?
    /// Drive time from where the phone was, worked out by the app (MapKit ETA); used by time to leave.
    var travelMinutes: Int?
    /// When that drive time was worked out (see TravelTime: it is refreshed as the alert comes closer).
    var travelCheckedAt: Date?
    /// The time-to-leave alarm time TravelTime picked from the drive times so far (nil: none picked yet).
    var leaveAt: Date?
    /// Main alert answered ("Got it"): stops its alarms.
    var mainAlertAnsweredAt: Date?
    /// Last advance heads-up "Got it" (heads-ups never escalate; this only clears it from Today).
    var headsUpAcknowledgedAt: Date?
}

extension Event {
    /// A copy with a change.
    func with(_ change: (inout Event) -> Void) -> Event {
        var e = self
        change(&e)
        return e
    }
}

enum EventAnswer: Codable, Hashable {
    case gotItHeadsUp
    case gotItMainAlert
}
