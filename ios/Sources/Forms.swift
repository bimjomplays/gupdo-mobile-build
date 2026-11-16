import SwiftUI
import UIKit

// Adding and editing. A reminder takes seconds: type what, keep "In 1 hour" or tap another time, Add. Everything else
// has the spec's defaults and sits under "More". Habits and events have short setup forms with their defaults filled
// in.

/// The + sheet: Reminder (default), Habit or Event.
struct AddSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case reminder = "Reminder", habit = "Habit", event = "Event"
        var id: Self { self }
    }

    @State var kind: Kind = .reminder

    var body: some View {
        NavigationStack {
            Group {
                switch kind {
                case .reminder: ReminderEditor(original: nil)
                case .habit: HabitEditor(original: nil)
                case .event: EventEditor(original: nil)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Type", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
                .accessibilityIdentifier("add-kind")
            }
        }
    }
}

struct ReminderForm: View {
    let editing: Reminder
    var body: some View { NavigationStack { ReminderEditor(original: editing) } }
}

struct HabitForm: View {
    let editing: Habit
    var body: some View { NavigationStack { HabitEditor(original: editing) } }
}

struct EventForm: View {
    let editing: Event
    var body: some View { NavigationStack { EventEditor(original: editing) } }
}

// MARK: - Reminder

enum RepeatChoice: String, CaseIterable, Identifiable {
    case never = "Never", daily = "Daily", weekly = "Weekly", monthly = "Monthly", days = "Pick days"
    var id: Self { self }

    init(_ rule: RepeatRule) {
        switch rule {
        case .never: self = .never
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .days: self = .days
        }
    }

    func rule(days: Set<Int>) -> RepeatRule {
        switch self {
        case .never: return .never
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        case .days: return .days(days)
        }
    }
}

struct ReminderEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Reminder?

    @State private var title = ""
    /// At a time, or when I arrive at a saved place.
    @State private var arrival = false
    @State private var placeID: UUID?
    /// The chosen time; until he picks one, the default (an hour from now) or the reminder's own time.
    @State private var picked: Date?
    @State private var repeatChoice = RepeatChoice.never
    @State private var days: Set<Int> = []
    @State private var alarm = true
    @State private var note = ""
    @State private var more = false
    @State private var loaded = false
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            Section {
                TextField("What?", text: $title)
                    .font(.title3)
                    .focused($typing)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("reminder-title")
            }
            Section {
                Picker("When", selection: $arrival) {
                    Text("At a time").tag(false)
                    Text("When I arrive").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("reminder-when")
                if arrival {
                    if !model.data.places.isEmpty {
                        Picker("At", selection: $placeID) {
                            if placeID == nil { Text("Pick a place").tag(UUID?.none) }
                            ForEach(sortedPlaces) { p in Text(p.name).tag(UUID?.some(p.id)) }
                        }
                        .accessibilityIdentifier("reminder-place")
                    }
                    NavigationLink(model.data.places.isEmpty ? "Add a place…" : "Add another place…") {
                        PlaceEditor(original: nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        ForEach(Defaults.quickTimes(now: model.now, settings: model.data.settings, calendar: model.calendar),
                                id: \.self) { q in
                            let on = abs(when.timeIntervalSince(q.date)) < 30
                            Button(q.label) { picked = q.date }
                                .buttonStyle(.bordered)
                                .tint(on ? .accentColor : .primary)
                                .fontWeight(on ? .semibold : .regular)
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    DatePicker("Time", selection: Binding(get: { when }, set: { picked = $0 }), displayedComponents: [.date, .hourAndMinute])
                }
            } header: {
                Text("When")
            } footer: {
                if arrival {
                    Text(arrivalHint)
                }
            }
            Section {
                DisclosureGroup("More", isExpanded: $more) {
                    Picker("Repeat", selection: $repeatChoice) {
                        ForEach(RepeatChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if repeatChoice == .days { WeekdayPicker(selection: $days) }
                    Toggle("Alarm if ignored", isOn: $alarm)
                    TextField("Note", text: $note, axis: .vertical)
                }
            } footer: {
                if !more {
                    Text("\(Formats.repeatRule(repeatChoice.rule(days: days), calendar: model.calendar)) · alarm if ignored \(alarm ? "on" : "off")")
                }
            }
            if let original {
                Section {
                    Button("Delete reminder", role: .destructive) {
                        Task { await model.deleteReminder(original.id); dismiss() }
                    }
                }
            }
        }
        .navigationTitle(original == nil ? "New reminder" : "Reminder")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(original == nil ? "Add" : "Save", action: save)
                    .disabled(!valid)
                    .accessibilityIdentifier("reminder-save")
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.data.places.count) { _, _ in pickDefaultPlace() }
        .onChange(of: arrival) { _, _ in pickDefaultPlace() }
    }

    private var sortedPlaces: [Place] {
        model.data.places.sorted { ($0.isHome ? 0 : 1, $0.name) < ($1.isHome ? 0 : 1, $1.name) }
    }

    private var arrivalHint: String {
        if model.data.places.isEmpty { return "Save the place first: arriving in its circle rings the reminder." }
        if model.sensors?.canWatchPlaces == false {
            return "Needs location set to Always to see you arrive: Settings › GupDo › Location › Always."
        }
        return "Rings as you arrive: a Time Sensitive notification, then the alarm if you don't answer."
    }

    /// "When I arrive" starts at Home (or the first place, or a place just added).
    private func pickDefaultPlace() {
        guard arrival else { return }
        if let id = placeID, model.data.places.contains(where: { $0.id == id }) { return }
        placeID = model.data.home?.id ?? sortedPlaces.first?.id
    }

    private var when: Date {
        picked ?? original.map { $0.due ?? $0.occurrence } ?? Defaults.reminderTime(now: model.now, calendar: model.calendar)
    }

    private var draftRule: RepeatRule { repeatChoice.rule(days: days) }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !(repeatChoice == .days && days.isEmpty)
            && !(arrival && placeID == nil)
    }

    private var draftTrigger: ReminderTrigger {
        if arrival, let placeID { return .arrival(placeID: placeID) }
        return .time(when)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let r = original else {
            typing = true
            return
        }
        title = r.title
        if case .arrival(let id) = r.trigger {
            arrival = true
            placeID = id
        }
        repeatChoice = RepeatChoice(r.repeatRule)
        if case .days(let set) = r.repeatRule { days = set }
        alarm = r.alarmIfIgnored
        note = r.note ?? ""
    }

    private func save() {
        guard valid else { return }
        let name = title.trimmingCharacters(in: .whitespaces)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var r: Reminder
        if let original {
            r = original
            let retimed: Bool
            switch (original.trigger, draftTrigger) {
            case (.time, .time): retimed = (original.due ?? original.occurrence) != when
            case (.arrival(let a), .arrival(let b)): retimed = a != b
            default: retimed = true
            }
            if retimed || original.repeatRule != draftRule || original.status != .active {
                // New time, place or repeat: it starts over from there.
                let trigger: ReminderTrigger = retimed ? draftTrigger : original.trigger
                r = Reminder(id: original.id, title: name, trigger: trigger, repeatRule: draftRule, createdAt: model.now)
            }
            r.title = name
        } else {
            r = Reminder(title: name, trigger: draftTrigger, repeatRule: draftRule, createdAt: model.now)
        }
        r.alarmIfIgnored = alarm
        r.note = text.isEmpty ? nil : text
        Task { await model.save(r); dismiss() }
    }
}

/// S M T W T F S toggles (Calendar's weekday numbers, 1 = Sunday).
struct WeekdayPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<Int>

    var body: some View {
        let cal = model.calendar
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(cal.veryShortWeekdaySymbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cal.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
                if day != order.last { Spacer(minLength: 0) }
            }
        }
    }
}

// MARK: - Habit

struct HabitEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Habit?

    @State private var habit = Habit(name: "", window: TimeWindow(start: TimeOfDay(7), end: TimeOfDay(8)),
                                     startDay: DayKey(year: 2026, month: 1, day: 1))
    @State private var everyDay = true
    @State private var days: Set<Int> = []
    @State private var loaded = false
    /// A new reference photo, saved with the habit.
    @State private var newReference: UIImage?
    @State private var takingPhoto = false
    @State private var scanning = false
    @State private var scanMessage: String?
    @State private var scanner = TagScanner()

    private var referenceImage: UIImage? { newReference ?? model.photos.load(habit.referencePhoto) }

    private var proofHint: String {
        switch habit.proof {
        case .photo: return "Done needs a new photo from the camera that matches this one. Take it the way you'll stand there each time."
        case .location: return "Done needs your iPhone to be at the habit's place."
        case .nfc: return scanMessage ?? "Stick an NFC tag at the spot. Done needs scanning it."
        }
    }

    private func scanTag() {
        scanning = true
        scanMessage = nil
        Task {
            do {
                habit.nfcTagID = try await scanner.scan(prompt: "Hold the top of your iPhone near the habit's tag.")
            } catch TagScanner.Failure.unavailable {
                scanMessage = "This iPhone can't read NFC tags."
            } catch TagScanner.Failure.cancelled {
            } catch {
                scanMessage = "Couldn't read the tag. Try again."
            }
            scanning = false
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Habit", text: $habit.name)
                    .font(.title3)
                    .accessibilityIdentifier("habit-name")
            }
            Section("Days") {
                Toggle("Every day", isOn: $everyDay)
                if !everyDay { WeekdayPicker(selection: $days) }
            }
            Section {
                DatePicker("Starts", selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker("Ends", selection: time(\.end), displayedComponents: .hourAndMinute)
            } header: {
                Text("Window")
            } footer: {
                if HabitLogic.windowCrossesMidnight(habit.window) { Text("Ends the next day.") }
            }
            Section {
                Picker("Place", selection: $habit.placeID) {
                    Text("Anywhere").tag(UUID?.none)
                    ForEach(model.data.places) { p in Text(p.name).tag(UUID?.some(p.id)) }
                }
                NavigationLink("Add a place…") { PlaceEditor(original: nil) }
            } header: {
                Text("Place")
            } footer: {
                if habit.placeID != nil {
                    Text("Rings at the window's start if you're there, otherwise a few minutes after you arrive. Never there during the window: the day is excused.")
                }
            }
            Section {
                Picker("Proof", selection: $habit.proof) {
                    Text(ProofText.name(.photo)).tag(ProofKind.photo)
                    Text("Being at the place").tag(ProofKind.location)
                    Text("NFC tag").tag(ProofKind.nfc)
                }
                switch habit.proof {
                case .photo:
                    if let image = referenceImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Reference photo")
                    }
                    Button(referenceImage == nil ? "Take the reference photo" : "Retake the reference photo",
                           systemImage: "camera") { takingPhoto = true }
                        .accessibilityIdentifier("habit-reference")
                case .nfc:
                    Button(habit.nfcTagID == nil ? "Scan the tag" : "Tag \(habit.nfcTagID!) ✓ · Scan again",
                           systemImage: "wave.3.right") { scanTag() }
                        .disabled(scanning)
                case .location:
                    EmptyView()
                }
            } header: {
                Text("Proof")
            } footer: {
                Text(problemText ?? proofHint)
            }
            Section {
                if let original {
                    LabeledContent("Now", value: phaseText(original))
                } else {
                    Text("Starts Strict: it rings until you prove it. After 66 done days (each miss adds 2) it goes Quiet: just a tick on Today.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let original {
                Section {
                    Button("Delete habit", role: .destructive) {
                        Task { await model.deleteHabit(original.id); dismiss() }
                    }
                }
            }
        }
        .navigationTitle(original == nil ? "New habit" : "Habit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(original == nil ? "Add" : "Save", action: save)
                    .disabled(!problems.isEmpty)
                    .accessibilityIdentifier("habit-save")
            }
        }
        .onAppear(perform: load)
        .fullScreenCover(isPresented: $takingPhoto) {
            LiveCamera(title: "Reference photo of the spot", reference: nil,
                       onPhoto: { photo in
                           newReference = PhotoStore.prepared(photo)
                           habit.referencePhoto = PhotoMatch.referenceFileName(for: habit.id)
                           takingPhoto = false
                       },
                       onCancel: { takingPhoto = false })
        }
    }

    private var draft: Habit {
        var h = habit
        h.name = h.name.trimmingCharacters(in: .whitespaces)
        h.days = everyDay ? .everyDay : .weekdays(days)
        return h
    }

    private var problems: [SetupProblem] { Setup.problems(draft, places: model.data.places) }

    private var problemText: String? {
        guard let p = problems.first(where: { $0 != .emptyName }) else { return nil }
        switch p {
        case .noDaysPicked: return "Pick at least one day."
        case .locationProofNeedsPlace: return "Location proof needs a place."
        case .nfcProofNeedsTag: return "Scan the habit's tag first."
        case .photoProofNeedsReference: return "Take the reference photo of the spot first."
        default: return nil
        }
    }

    private func phaseText(_ h: Habit) -> String {
        let day = HabitLogic.openDay(h, now: model.now, calendar: model.calendar)
        switch HabitLogic.phase(h, on: day, history: model.data.history, now: model.now, calendar: model.calendar) {
        case .strict(let left): return "Strict · \(left) days to lock in"
        case .restrict(_, let left): return "Strict again · \(left) days"
        case .quiet: return "Quiet"
        }
    }

    private func time(_ path: WritableKeyPath<TimeWindow, TimeOfDay>) -> Binding<Date> {
        Binding(get: { habit.window[keyPath: path].on(model.now, model.calendar) },
                set: { habit.window[keyPath: path] = TimeOfDay(of: $0, model.calendar) })
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        habit = original ?? Defaults.habit(now: model.now, calendar: model.calendar)
        if case .weekdays(let set) = habit.days {
            everyDay = false
            days = set
        }
    }

    private func save() {
        guard problems.isEmpty else { return }
        var h = draft
        if let newReference {
            let name = PhotoMatch.referenceFileName(for: h.id)
            guard model.photos.save(newReference, as: name) else {
                scanMessage = nil
                model.notice = "Couldn't save the photo. Try again."
                return
            }
            h.referencePhoto = name
        }
        Task { await model.save(h); dismiss() }
    }
}

// MARK: - Event

enum PresetChoice: String, CaseIterable, Identifiable {
    case big = "Big", normal = "Normal", small = "Small", custom = "Custom"
    var id: Self { self }

    var summary: String {
        switch self {
        case .big: return "2 weeks, 1 week, 5 days, 3 days, 1 day and the morning of"
        case .normal: return "5 days, 3 days, 1 day and the morning of"
        case .small: return "The morning of"
        case .custom: return "Your own days"
        }
    }
}

enum AlertChoice: String, CaseIterable, Identifiable {
    case standard = "Default", atStart = "At start", thirty = "30 min before", hour = "1 hour before",
         leave = "Time to leave"
    var id: Self { self }

    var timing: MainAlertTiming? {
        switch self {
        case .standard: return nil
        case .atStart: return .atStart
        case .thirty: return .thirtyMinutesBefore
        case .hour: return .hourBefore
        case .leave: return .timeToLeave
        }
    }

    init(_ t: MainAlertTiming?) {
        switch t {
        case nil: self = .standard
        case .atStart?: self = .atStart
        case .thirtyMinutesBefore?: self = .thirty
        case .hourBefore?: self = .hour
        case .timeToLeave?: self = .leave
        }
    }
}

struct EventEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Event?

    @State private var event = Event(title: "", start: Date())
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var preset = PresetChoice.normal
    @State private var customDays: Set<Int> = [1]
    @State private var morningOf = true
    @State private var alert = AlertChoice.standard
    @State private var loaded = false
    /// The drive time from here to the Where, asked when it is picked (nil: unknown or not asked yet).
    @State private var drive: (place: EventLocation, minutes: Int?)?
    @State private var askingDrive = false
    /// The start the end last moved with (set on load, so loading an event doesn't move its end).
    @State private var lastStart: Date?

    var body: some View {
        Form {
            Section {
                TextField("What?", text: $event.title)
                    .font(.title3)
                    .accessibilityIdentifier("event-title")
            }
            Section {
                DatePicker("Starts", selection: $event.start, displayedComponents: [.date, .hourAndMinute])
                Toggle("Ends", isOn: $hasEnd)
                if hasEnd {
                    DatePicker("Ends at", selection: $end, in: event.start..., displayedComponents: [.date, .hourAndMinute])
                }
            } footer: {
                if let clash = clashes.first {
                    Label("Overlaps \(clash.title) (\(Formats.when(clash.start, now: model.now, calendar: model.calendar)))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("clash-warning")
                }
            }
            Section {
                NavigationLink {
                    WherePicker(selection: $event.location)
                } label: {
                    LabeledContent("Where") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(event.location?.name ?? "None")
                            if let address = event.location?.address, address != event.location?.name {
                                Text(address).font(.caption)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("event-where")
            } footer: {
                if let text = driveText { Text(text) }
            }
            Section {
                Picker("Heads-ups", selection: $preset) {
                    ForEach(PresetChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if preset == .custom {
                    ForEach([14, 7, 5, 3, 1], id: \.self) { n in
                        Toggle(n == 14 ? "2 weeks before" : n == 7 ? "1 week before" : n == 1 ? "1 day before" : "\(n) days before",
                               isOn: Binding(get: { customDays.contains(n) },
                                             set: { if $0 { customDays.insert(n) } else { customDays.remove(n) } }))
                    }
                    Toggle("Morning of", isOn: $morningOf)
                }
            } header: {
                Text("Heads-ups")
            } footer: {
                Text("\(preset.summary), at \(Formats.time(model.data.settings.headsUpTime, calendar: model.calendar)). Just a notification, answered Got it.")
            }
            Section {
                Picker("Main alert", selection: $alert) {
                    ForEach(AlertChoice.allCases.filter { $0 != .leave || event.location != nil }) { Text($0.rawValue).tag($0) }
                }
            } footer: {
                Text("An alarm at \(mainAlertText), again every \(model.data.settings.alarmEveryMinutes) min until you answer Got it.")
            }
            if let original {
                Section {
                    Button("Delete event", role: .destructive) {
                        Task { await model.deleteEvent(original.id); dismiss() }
                    }
                }
            }
        }
        .navigationTitle(original == nil ? "New event" : "Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(original == nil ? "Add" : "Save", action: save)
                    .disabled(!Setup.problems(draft, places: model.data.places).isEmpty)
                    .accessibilityIdentifier("event-save")
            }
        }
        .onAppear(perform: load)
        .onChange(of: event.start) { _, new in
            // the end moves with the start (not when the event is loaded)
            if hasEnd, let last = lastStart { end = end.addingTimeInterval(new.timeIntervalSince(last)) }
            lastStart = new
        }
        .onChange(of: event.location) { _, place in
            if place == nil, alert == .leave { alert = .standard }
            askDrive()
        }
    }

    /// The drive time as the form knows it: just asked for this Where, else the saved one (same Where).
    private var knownDrive: Int? {
        if let drive, drive.place == event.location { return drive.minutes }
        if let original, original.location == event.location { return original.travelMinutes }
        return nil
    }

    private var driveText: String? {
        guard event.location != nil else { return nil }
        if askingDrive { return "Working out the drive from here…" }
        guard let minutes = knownDrive else {
            return "Drive time unknown (no location or route yet): time to leave comes 1 hour before."
        }
        return "\(Formats.duration(minutes: minutes)) drive from here. Checked again as the event comes closer."
    }

    private func askDrive() {
        guard let place = event.location, model.drive != nil else { return }
        askingDrive = true
        let e = draft
        Task {
            let minutes = await model.driveMinutes(to: place, for: e)
            if event.location == place { drive = (place, minutes) }
            askingDrive = false
        }
    }

    private var draft: Event {
        var e = event
        e.title = e.title.trimmingCharacters(in: .whitespaces)
        e.end = hasEnd ? max(end, e.start) : nil
        switch preset {
        case .big: e.headsUps = .big
        case .normal: e.headsUps = .normal
        case .small: e.headsUps = .small
        case .custom: e.headsUps = .custom(daysBefore: customDays.sorted(by: >), morningOf: morningOf)
        }
        e.mainAlert = alert.timing
        return e
    }

    private var clashes: [Event] { EventLogic.clashes(for: draft, among: model.data.events) }

    private var mainAlertText: String {
        // as it would be with the drive time the form knows (the saved alarm time is picked again on save)
        let d = draft.with {
            $0.travelMinutes = knownDrive
            $0.travelCheckedAt = nil
            $0.leaveAt = nil
        }
        let date = EventLogic.mainAlertDate(d, settings: model.data.settings)
        return "\(Formats.time(date, calendar: model.calendar)) (“\(Planner.mainAlertText(d))”)"
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        event = original ?? Defaults.event(now: model.now, calendar: model.calendar)
        hasEnd = event.end != nil
        end = event.end ?? event.start.addingTimeInterval(3600)
        lastStart = event.start
        switch event.headsUps {
        case .big: preset = .big
        case .normal: preset = .normal
        case .small: preset = .small
        case .custom(let days, let morning):
            preset = .custom
            customDays = Set(days)
            morningOf = morning
        }
        alert = AlertChoice(event.mainAlert)
    }

    private func save() {
        var e = draft
        if let original, original.start != e.start || original.mainAlert != e.mainAlert || original.location != e.location {
            // a new time or place: its alerts start over
            e.mainAlertAnsweredAt = nil
            e.headsUpAcknowledgedAt = nil
        }
        let minutes = drive?.place == e.location ? drive?.minutes : nil
        Task { await model.save(e, driveMinutes: minutes); dismiss() }
    }
}

/// An event's Where: none, a saved place, or an address or place found with search (MapKit).
struct WherePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: EventLocation?

    @State private var search = AddressSearch()
    @State private var text = ""
    @State private var finding = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                TextField("Search an address or place", text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("where-search")
            } footer: {
                if let message { Text(message).foregroundStyle(.orange) }
            }
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Section("Results") {
                    if search.suggestions.isEmpty {
                        Text(search.failed ? "Nothing found." : "Searching…").foregroundStyle(.secondary)
                    }
                    ForEach(search.suggestions) { s in
                        Button { pick(s) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).foregroundStyle(.primary)
                                if !s.subtitle.isEmpty {
                                    Text(s.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(finding)
                    }
                }
            } else {
                Section {
                    choice("None", detail: nil, on: selection == nil) { selection = nil }
                    if let current = selection, current.placeID == nil {
                        choice(current.name, detail: current.address, on: true) {}
                    }
                    ForEach(model.data.places.sorted { ($0.isHome ? 0 : 1, $0.name) < ($1.isHome ? 0 : 1, $1.name) }) { p in
                        choice(p.name, detail: p.isHome && p.name != "Home" ? "Home" : nil, on: selection?.placeID == p.id) {
                            selection = EventLocation(place: p)
                        }
                    }
                } header: {
                    Text(model.data.places.isEmpty ? "" : "Saved places")
                } footer: {
                    Text("With a Where, the main alert defaults to time to leave: the drive time from where you are, plus \(model.data.settings.leaveBufferMinutes) minutes.")
                }
            }
        }
        .navigationTitle("Where")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: text) { _, new in
            message = nil
            search.update(new)
        }
        .onAppear {
            if let fix = model.sensors?.recentFix(maxAge: 6 * 3600) { search.near(latitude: fix.latitude, longitude: fix.longitude) }
        }
    }

    private func choice(_ title: String, detail: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
    }

    private func pick(_ s: AddressSearch.Suggestion) {
        finding = true
        Task {
            if let found = await search.resolve(s) {
                selection = found
                dismiss()
            } else {
                message = "Couldn't find that one. Try another result."
            }
            finding = false
        }
    }
}

// MARK: - Everything

/// Every reminder, habit and event, to edit or delete (the main screen only shows what matters now).
struct EverythingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let reminders = model.data.reminders.filter { $0.status == .active }
                    .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                Section("Reminders") {
                    if reminders.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(reminders) { r in
                        NavigationLink { ReminderEditor(original: r) } label: {
                            row(r.title, r.due.map { Formats.when($0, now: model.now, calendar: model.calendar) } ?? arrivalText(r))
                        }
                    }
                }
                Section("Habits") {
                    if model.data.habits.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(model.data.habits.sorted { $0.window.start < $1.window.start }) { h in
                        NavigationLink { HabitEditor(original: h) } label: {
                            row(h.name, "\(Formats.days(h.days, calendar: model.calendar)) · \(Formats.window(h.window, calendar: model.calendar))")
                        }
                    }
                }
                Section("Events") {
                    if model.upcoming.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(model.upcoming) { e in
                        NavigationLink { EventEditor(original: e) } label: {
                            row(e.title, Formats.when(e.start, now: model.now, calendar: model.calendar)
                                + (e.location.map { " · \($0.name)" } ?? ""))
                        }
                    }
                }
                Section {
                    let inside = Presence.inside(model.data)
                    ForEach(model.data.places.sorted { ($0.isHome ? 0 : 1, $0.name) < ($1.isHome ? 0 : 1, $1.name) }) { p in
                        NavigationLink { PlaceEditor(original: p) } label: {
                            row(p.name, PlaceText.detail(p, inside: inside.contains(p.id),
                                                         habits: model.habits(at: p.id).count,
                                                         reminders: model.reminders(at: p.id).count))
                        }
                    }
                    NavigationLink { PlaceEditor(original: nil) } label: {
                        Label(model.data.home == nil ? "Add Home" : "Add a place", systemImage: "plus")
                    }
                } header: {
                    Text("Places")
                } footer: {
                    if !model.data.places.isEmpty, model.sensors?.canWatchPlaces == false {
                        Text("Location is not set to Always, so GupDo can't see you arrive: place habits and arrival reminders stay quiet. Settings › GupDo › Location › Always.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Everything")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func arrivalText(_ r: Reminder) -> String {
        let place = model.data.places.first { $0.id == r.placeID }?.name
        return place.map { "When you arrive at \($0)" } ?? "When you arrive"
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
